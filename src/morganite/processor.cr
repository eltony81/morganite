require "./job"
require "./registry"

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
      # TODO: M2 will implement retries, dead queue and error serialization.
      STDERR.puts "Job failed: #{ex.class}: #{ex.message}"
      raise ex
    end

    private def redis
      @redis || RedisConnection.new_client
    end
  end
end
