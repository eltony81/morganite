require "../../spec_helper"
require "./support"

describe Morganite::Jqcp::QueueControl do
  describe "strict (default)" do
    it "always tries queues in the given order" do
      redis = Morganite::RedisConnection.new_client
      keys = Morganite::Jqcp::QueueControl.select_queue_keys(redis, ["critical", "default", "low"])
      keys.should eq(["morganite:queue:critical", "morganite:queue:default", "morganite:queue:low"])
    end

    it "excludes a paused queue entirely" do
      redis = Morganite::RedisConnection.new_client
      Morganite::Jqcp::QueueControl.pause(redis, "default")

      keys = Morganite::Jqcp::QueueControl.select_queue_keys(redis, ["critical", "default", "low"])
      keys.should eq(["morganite:queue:critical", "morganite:queue:low"])
    end
  end

  describe "weighted" do
    it "draws every configured queue exactly once per call, order weighted by configured weight" do
      redis = Morganite::RedisConnection.new_client
      Morganite::Jqcp::QueueControl.set_strategy(redis, "weighted", {"critical" => 9, "default" => 1})

      first_position_counts = Hash(String, Int32).new(0)
      500.times do
        keys = Morganite::Jqcp::QueueControl.select_queue_keys(redis, ["critical", "default"])
        keys.size.should eq(2)
        keys.to_set.should eq(Set{"morganite:queue:critical", "morganite:queue:default"})
        first_position_counts[keys[0]] += 1
      end

      # "critical" has 9x the weight of "default", so it should win the
      # first-position draw the large majority of the time — generous
      # bounds to avoid flakiness while still catching a broken weighting
      # (e.g. uniform-random would land close to 50/50).
      first_position_counts["morganite:queue:critical"].should be > 350
    end
  end
end
