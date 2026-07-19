require "./statsd"

module Morganite
  module Metrics
    BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

    # Cumulative bucket counters (Prometheus-style) instead of raw observed
    # values: memory is O(BUCKETS.size) per metric name regardless of how many
    # jobs run, instead of growing forever for the life of the process.
    class Histogram
      getter bucket_counts = Array(Int64).new(BUCKETS.size, 0_i64)
      getter sum = 0.0
      getter count = 0_i64

      def observe(value : Float64)
        BUCKETS.each_with_index do |bucket, i|
          @bucket_counts[i] += 1 if value <= bucket
        end
        @sum += value
        @count += 1
      end
    end

    @@counters = Hash(String, Int64).new(0_i64)
    @@histograms = Hash(String, Histogram).new
    @@mutex = Mutex.new

    def self.increment(name : String, value : Int64 = 1_i64)
      @@mutex.synchronize do
        @@counters[name] += value
      end
      Statsd.increment("morganite.#{name}", value)
    end

    def self.observe(name : String, value : Float64)
      @@mutex.synchronize do
        (@@histograms[name] ||= Histogram.new).observe(value)
      end
      Statsd.histogram("morganite.#{name}", value)
    end

    # JQCP Section 9.10 (GetStats): reads back a single counter's current
    # value. `to_prometheus` already exposes all of them formatted as text;
    # this is the same data as a plain Int64 for a JSON API.
    def self.counter(name : String) : Int64
      @@mutex.synchronize { @@counters[name] }
    end

    def self.to_prometheus : String
      @@mutex.synchronize do
        io = IO::Memory.new
        @@counters.each do |name, count|
          io.puts "# HELP morganite_#{name} total count"
          io.puts "# TYPE morganite_#{name} counter"
          io.puts "morganite_#{name} #{count}"
        end

        @@histograms.each do |name, histogram|
          io.puts "# HELP morganite_#{name}_duration_seconds execution duration"
          io.puts "# TYPE morganite_#{name}_duration_seconds histogram"

          BUCKETS.each_with_index do |bucket, i|
            io.puts %(morganite_#{name}_duration_seconds_bucket{le="#{bucket}"} #{histogram.bucket_counts[i]})
          end

          io.puts %(morganite_#{name}_duration_seconds_bucket{le="+Inf"} #{histogram.count})
          io.puts "morganite_#{name}_duration_seconds_sum #{histogram.sum}"
          io.puts "morganite_#{name}_duration_seconds_count #{histogram.count}"
        end

        io.to_s
      end
    end

    def self.reset
      @@mutex.synchronize do
        @@counters.clear
        @@histograms.clear
      end
    end
  end
end
