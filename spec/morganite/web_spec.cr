require "../spec_helper"
require "http/client"

describe Morganite::Web do
  it "renders the dashboard and allows deleting a queue" do
    Morganite::Client.enqueue("TestWorker", [JSON.parse("\"hello\"")], "default")

    spawn { Morganite::Web.start(17420) }
    sleep 0.5.seconds

    begin
      response = HTTP::Client.get("http://localhost:17420/morganite")
      response.status_code.should eq(200)
      response.body.should contain("Morganite Dashboard")
      response.body.should contain("default")
      response.body.should contain("1</td>")

      HTTP::Client.post("http://localhost:17420/morganite/queues/default/delete")

      redis = Morganite::RedisConnection.new_client
      redis.llen("morganite:queue:default").should eq(0)
    ensure
      Morganite::Web.stop
    end
  end
end
