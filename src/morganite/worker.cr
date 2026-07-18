require "./registry"
require "./client"
require "./cron"

module Morganite
  module Worker
    macro included
      extend ::Morganite::Worker::ClassMethods

      # Register this worker class by name as soon as it is defined.
      ::Morganite::WorkerRegistry.register({{@type.name.stringify}}, -> { {{@type}}.new.as(::Morganite::Worker) })
    end

    module ClassMethods
      def perform_async(*args)
        ::Morganite::Client.enqueue(
          self.name,
          args.to_a.map { |arg| JSON.parse(arg.to_json) },
          default_queue,
          unique: unique_strategy,
          unique_for: unique_for
        )
      end

      def perform_at(time : Time, *args)
        ::Morganite::Client.schedule(
          self.name,
          time,
          args.to_a.map { |arg| JSON.parse(arg.to_json) },
          default_queue,
          unique: unique_strategy,
          unique_for: unique_for
        )
      end

      def perform_in(duration : Time::Span, *args)
        perform_at(Time.utc + duration, *args)
      end

      def default_queue
        ::Morganite.config.queue
      end

      def queue(name : String)
        # TODO: allow per-worker queue override (stored in class-level metadata)
        name
      end

      def unique_strategy : String?
        nil
      end

      def unique_for : Int32
        300
      end
    end

    macro cron(expression)
      ::Morganite::Cron.register({{@type.name.stringify}}, {{expression}})
    end

    macro unique(strategy, ttl = 300)
      def self.unique_strategy : String?
        {{strategy.id.stringify}}
      end

      def self.unique_for : Int32
        {{ttl}}
      end
    end

    abstract def perform(args : Array(JSON::Any))
  end
end
