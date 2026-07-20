require "./registry"
require "./client"
require "./cron"

module Morganite
  module Worker
    macro included
      extend ::Morganite::Worker::ClassMethods
      @@server_middlewares = [] of ::Morganite::ServerMiddleware

      # Register this worker class by name as soon as it is defined.
      ::Morganite::WorkerRegistry.register({{@type.name.stringify}}, -> { {{@type}}.new.as(::Morganite::Worker) })
    end

    module ClassMethods
      def perform_async(*args)
        ::Morganite::Client.enqueue(
          self.name,
          args.to_a.map { |arg| JSON.parse(arg.to_json) },
          default_queue,
          retry: retry_policy,
          backtrace: backtrace_policy,
          dead: dead_policy,
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
          retry: retry_policy,
          backtrace: backtrace_policy,
          dead: dead_policy,
          unique: unique_strategy,
          unique_for: unique_for
        )
      end

      def perform_in(duration : Time::Span, *args)
        perform_at(Time.utc + duration, *args)
      end

      def default_queue : String
        ::Morganite.config.queue
      end

      def retry_policy : Bool | Int32
        true
      end

      def retry_in(retry_count : Int32) : Int32?
        nil
      end

      def backtrace_policy : Bool | Int32
        true
      end

      def dead_policy : Bool
        true
      end

      def unique_strategy : String?
        nil
      end

      def unique_for : Int32
        300
      end

      def rate_limit_limit : Int32
        0
      end

      def rate_limit_window : Int32
        0
      end

      def server_middlewares : Array(Morganite::ServerMiddleware)
        @@server_middlewares
      end
    end

    macro cron(expression, timezone = nil)
      ::Morganite::Cron.register({{@type.name.stringify}}, {{expression}}, {{timezone}})
    end

    macro server_middleware(klass)
      @@server_middlewares << {{klass.id}}.new.as(::Morganite::ServerMiddleware)
    end

    macro unique(strategy, ttl = 300)
      def self.unique_strategy : String?
        {{strategy.id.stringify}}
      end

      def self.unique_for : Int32
        {{ttl}}
      end
    end

    macro rate_limit(limit, window)
      def self.rate_limit_limit : Int32
        {{limit}}
      end

      def self.rate_limit_window : Int32
        {{window}}
      end
    end

    macro morganite_options(**options)
      {% if options[:queue] %}
        def self.default_queue : String
          {{options[:queue]}}
        end
      {% end %}

      {% if options[:retry] %}
        def self.retry_policy : Bool | Int32
          {{options[:retry]}}
        end
      {% end %}

      {% if options[:backtrace] %}
        def self.backtrace_policy : Bool | Int32
          {{options[:backtrace]}}
        end
      {% end %}

      {% if options[:dead] %}
        def self.dead_policy : Bool
          {{options[:dead]}}
        end
      {% end %}
    end

    def retry_in(retry_count : Int32) : Int32?
      self.class.retry_in(retry_count)
    end

    abstract def perform(args : Array(JSON::Any))
  end
end
