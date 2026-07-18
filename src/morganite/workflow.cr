require "uuid"
require "json"
require "./job"
require "./client"
require "./redis_connection"

module Morganite
  class Workflow
    KEY_PREFIX = "morganite:workflow:"
    STEPS_KEY  = "steps"

    record Step, worker_name : String, args : Array(JSON::Any), queue : String

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
      return unless step

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
        steps_json = @steps.map { |step| {worker_name: step.worker_name, args: step.args, queue: step.queue}.to_json }.to_json
        redis.hset(key, STEPS_KEY, steps_json)
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

        steps = Array(String).from_json(steps_json)
        step_json = steps[index]?
        return unless step_json

        step_data = Hash(String, JSON::Any).from_json(step_json)

        Step.new(
          step_data["worker_name"].as_s,
          step_data["args"].as_a,
          step_data["queue"].as_s,
        )
      end
    end

    private def key
      "#{KEY_PREFIX}#{@wid}"
    end
  end
end
