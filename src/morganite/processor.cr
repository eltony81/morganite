require "./job"
require "./registry"
require "./failures"

module Morganite
  class Processor
    def initialize(@redis : Redis::Client? = nil)
    end

    def process(job_json : String)
      job = Job.from_json(job_json)
      factory = WorkerRegistry.fetch(job.class)
      worker = factory.call
      worker.perform(job.args)
    rescue ex : Exception
      if parsed_job = job
        Failures.handle(parsed_job, ex, @redis)
      else
        STDERR.puts "Failed to parse job: #{ex.message}"
      end
    end
  end
end
