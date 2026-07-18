require "../spec_helper"

describe Morganite::Job do
  it "serializes and deserializes" do
    job = Morganite::Job.new(
      class: "MyWorker",
      args: [JSON.parse("\"hello\""), JSON.parse("42")],
      queue: "critical"
    )

    json = job.to_json
    restored = Morganite::Job.from_json(json)

    restored.class.should eq("MyWorker")
    restored.args.size.should eq(2)
    restored.args[0].as_s.should eq("hello")
    restored.args[1].as_i.should eq(42)
    restored.queue.should eq("critical")
    restored.jid.should eq(job.jid)
  end

  it "computes the queue key" do
    job = Morganite::Job.new(class: "MyWorker", queue: "critical")
    job.queue_key.should eq("morganite:queue:critical")
  end
end
