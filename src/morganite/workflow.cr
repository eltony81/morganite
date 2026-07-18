require "uuid"
require "json"
require "./job"
require "./client"
require "./redis_connection"
require "./logger"

module Morganite
  class Workflow
    KEY_PREFIX = "morganite:workflow:"
    STEPS_KEY  = "steps"

    record Step, worker_name : String, args : Array(JSON::Any), queue : String do
      include JSON::Serializable
    end

    getter wid : String
    getter steps : Array(Step)

    def initialize(@wid : String = UUID.random.to_s)
      @steps = [] of Step
    end

    def step(worker_name : String, args : Array(JSON::Any), queue : String = Morganite.config.queue)
      @steps << Step.new(worker_name, args, queue)
    end

    def run
      return if @steps.empty?

      save_steps
      enqueue_step(0)
    end

    def self.on_step_complete(job : Job)
      return unless wid = job.wid

      next_index = job.step_index + 1
      step = load_step(wid, next_index)
      unless step
        Logger.info("workflow #{wid} complete after step #{job.step_index}")
        return
      end

      Logger.debug("workflow #{wid} advancing to step #{next_index} (#{step.worker_name})")
      Client.enqueue(
        step.worker_name,
        step.args,
        step.queue,
        wid: wid,
        step_index: next_index,
      )
    end

    private def save_steps
      Morganite.pool.with do |redis|
        redis.hset(key, STEPS_KEY, @steps.to_json)
      end
    end

    private def enqueue_step(index : Int32)
      step = @steps[index]
      Client.enqueue(
        step.worker_name,
        step.args,
        step.queue,
        wid: @wid,
        step_index: index,
      )
    end

    private def self.load_step(wid : String, index : Int32) : Step?
      Morganite.pool.with do |redis|
        steps_json = redis.hget("#{KEY_PREFIX}#{wid}", STEPS_KEY)
        return unless steps_json.is_a?(String)

        steps = Array(Step).from_json(steps_json)
        steps[index]?
      end
    end

    private def key
      "#{KEY_PREFIX}#{@wid}"
    end
  end
end
