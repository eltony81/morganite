module Morganite
  module Metrics
    BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

    @@counters = Hash(String, Int64).new(0_i64)
    @@histograms = Hash(String, Array(Float64)).new
    @@mutex = Mutex.new

    def self.increment(name : String, value : Int64 = 1_i64)
      @@mutex.synchronize do
        @@counters[name] += value
      end
    end

    def self.observe(name : String, value : Float64)
      @@mutex.synchronize do
        @@histograms[name] ||= [] of Float64
        @@histograms[name] << value
      end
    end

    def self.to_prometheus : String
      @@mutex.synchronize do
        io = IO::Memory.new
        @@counters.each do |name, count|
          io.puts "# HELP morganite_#{name} total count"
          io.puts "# TYPE morganite_#{name} counter"
          io.puts "morganite_#{name} #{count}"
        end

        @@histograms.each do |name, values|
          io.puts "# HELP morganite_#{name}_duration_seconds execution duration"
          io.puts "# TYPE morganite_#{name}_duration_seconds histogram"

          BUCKETS.each do |bucket|
            count = values.count { |v| v <= bucket }
            io.puts %(morganite_#{name}_duration_seconds_bucket{le="#{bucket}"} #{count})
          end

          io.puts %(morganite_#{name}_duration_seconds_bucket{le="+Inf"} #{values.size})
          io.puts "morganite_#{name}_duration_seconds_sum #{values.sum}"
          io.puts "morganite_#{name}_duration_seconds_count #{values.size}"
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
