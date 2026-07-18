module Morganite
  class Cron
    FIELD_RANGES = [0..59, 0..23, 1..31, 1..12, 0..6]

    def initialize(@expression : String)
      @fields = parse(@expression)
    end

    def next(from : Time = Time.utc) : Time
      t = from + 1.minute
      t = Time.utc(t.year, t.month, t.day, t.hour, t.minute, 0)

      # Search up to ~10 years of minutes
      5_257_600.times do
        return t if matches?(t)
        t += 1.minute
      end

      raise "Unable to find next cron occurrence for '#{@expression}'"
    end

    private def parse(expression : String) : Array(Array(Int32))
      parts = expression.split(" ")
      raise "Invalid cron expression: '#{expression}' (expected 5 fields)" unless parts.size == 5

      parts.map_with_index do |part, index|
        parse_field(part, FIELD_RANGES[index])
      end
    end

    private def parse_field(part : String, range : Range(Int32, Int32)) : Array(Int32)
      return (range.begin..range.end).to_a if part == "*"

      if part.starts_with?("*/")
        step = part[2..].to_i
        return (range.begin..range.end).step(step).to_a
      end

      if part.includes?(",")
        return part.split(",").flat_map { |piece| parse_single(piece, range) }.uniq.sort
      end

      parse_single(part, range)
    end

    private def parse_single(part : String, range : Range(Int32, Int32)) : Array(Int32)
      if part.includes?("-")
        a, b = part.split("-", 2)
        return (a.to_i..b.to_i).to_a
      end

      value = part.to_i
      unless range.includes?(value)
        raise "Invalid cron value #{value} for range #{range}"
      end
      [value]
    end

    private def matches?(time : Time) : Bool
      @fields[0].includes?(time.minute) &&
        @fields[1].includes?(time.hour) &&
        @fields[2].includes?(time.day) &&
        @fields[3].includes?(time.month) &&
        @fields[4].includes?(time.day_of_week.value % 7)
    end
  end
end
