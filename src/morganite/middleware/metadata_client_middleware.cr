require "../client_middleware"
require "json"

module Morganite
  class MetadataClientMiddleware
    include ClientMiddleware

    def initialize(@metadata : Hash(String, JSON::Any))
    end

    def call(job : Job, next_middleware : -> Nil)
      job.args.unshift(JSON.parse(@metadata.to_json))
      next_middleware.call
    end
  end
end
