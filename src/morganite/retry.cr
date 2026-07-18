module Morganite
  module Retry
    DEFAULT_MAX_RETRIES = 25

    # Sidekiq-like backoff in seconds.
    def self.backoff_for(retry_count : Int32) : Int32
      (retry_count ** 4) + 15 + (Random.rand(30) * (retry_count + 1))
    end

    def self.max_retries_for(job : Job) : Int32
      case job.retry
      when false
        0
      when Int32
        job.retry.as(Int32)
      else
        DEFAULT_MAX_RETRIES
      end
    end

    def self.retry_job?(job : Job) : Bool
      return false if job.retry == false
      max = max_retries_for(job)
      job.retry_count < max
    end

    def self.next_retry_at(job : Job) : Time
      Time.utc + backoff_for(job.retry_count).seconds
    end
  end
end
