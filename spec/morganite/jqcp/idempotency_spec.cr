require "../../spec_helper"
require "./support"

class JqcpIdemTestWorker
  include Morganite::Worker

  def perform(args)
  end
end

describe Morganite::Jqcp::Idempotency do
  it "reserves a new key and rejects a second reservation for the same queue+key" do
    redis = Morganite::RedisConnection.new_client

    first = Morganite::Job.new("JqcpIdemTestWorker", idempotency_key: "order-42")
    Morganite::Jqcp::Idempotency.reserve(redis, first).should be_true

    second = Morganite::Job.new("JqcpIdemTestWorker", idempotency_key: "order-42")
    Morganite::Jqcp::Idempotency.reserve(redis, second).should be_false
  end

  it "allows reuse of the same key after release" do
    redis = Morganite::RedisConnection.new_client

    first = Morganite::Job.new("JqcpIdemTestWorker", idempotency_key: "order-43")
    Morganite::Jqcp::Idempotency.reserve(redis, first).should be_true
    Morganite::Jqcp::Idempotency.release(redis, first)

    second = Morganite::Job.new("JqcpIdemTestWorker", idempotency_key: "order-43")
    Morganite::Jqcp::Idempotency.reserve(redis, second).should be_true
  end

  it "does not let a stale job release a different job's active reservation" do
    redis = Morganite::RedisConnection.new_client

    original = Morganite::Job.new("JqcpIdemTestWorker", idempotency_key: "order-44")
    Morganite::Jqcp::Idempotency.reserve(redis, original)
    Morganite::Jqcp::Idempotency.release(redis, original)

    new_holder = Morganite::Job.new("JqcpIdemTestWorker", idempotency_key: "order-44")
    Morganite::Jqcp::Idempotency.reserve(redis, new_holder).should be_true

    # `original`'s (already-released) reservation must not clear
    # `new_holder`'s active one out from under it.
    Morganite::Jqcp::Idempotency.release(redis, original)
    Morganite::Jqcp::Idempotency.reserve(redis, Morganite::Job.new("JqcpIdemTestWorker", idempotency_key: "order-44")).should be_false
  end

  it "end to end via Client.enqueue: a second Enqueue with the same key is rejected" do
    first = Morganite::Client.enqueue("JqcpIdemTestWorker", [] of JSON::Any, idempotency_key: "order-45")
    first.should_not be_nil

    second = Morganite::Client.enqueue("JqcpIdemTestWorker", [] of JSON::Any, idempotency_key: "order-45")
    second.should be_nil
  end
end
