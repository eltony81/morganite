module Morganite
  alias WorkerFactory = -> Worker

  class WorkerRegistry
    @@workers = {} of String => WorkerFactory

    def self.register(name : String, factory : WorkerFactory)
      @@workers[name] = factory
    end

    def self.fetch(name : String) : WorkerFactory
      @@workers[name]? || raise MissingWorkerError.new("Unknown worker: #{name}")
    end

    def self.clear
      @@workers.clear
    end
  end

  class MissingWorkerError < Exception
  end
end
