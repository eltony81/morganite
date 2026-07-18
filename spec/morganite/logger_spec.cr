require "../spec_helper"

describe Morganite::Logger do
  before_each do
    Morganite::Logger.level = Morganite::Logger::Level::DEBUG
    Morganite::Logger.json_format = false
  end

  it "logs text messages" do
    io = IO::Memory.new
    Morganite::Logger.io = io
    Morganite::Logger.info("hello")
    io.to_s.should contain("INFO")
    io.to_s.should contain("hello")
  end

  it "includes jid and correlation_id" do
    io = IO::Memory.new
    Morganite::Logger.io = io
    Morganite::Logger.info("hello", jid: "abc", correlation_id: "xyz")
    output = io.to_s
    output.should contain("jid=abc")
    output.should contain("correlation_id=xyz")
  end

  it "logs JSON when json_format is enabled" do
    io = IO::Memory.new
    Morganite::Logger.io = io
    Morganite::Logger.json_format = true
    Morganite::Logger.info("hello", jid: "abc")
    json = JSON.parse(io.to_s.lines.first)
    json["level"].as_s.should eq("INFO")
    json["message"].as_s.should eq("hello")
    json["jid"].as_s.should eq("abc")
  end

  it "respects log level" do
    io = IO::Memory.new
    Morganite::Logger.io = io
    Morganite::Logger.level = Morganite::Logger::Level::ERROR
    Morganite::Logger.info("ignored")
    io.to_s.should be_empty
  end

  it "provides a context helper" do
    io = IO::Memory.new
    Morganite::Logger.io = io
    ctx = Morganite::Logger.context(correlation_id: "c1", jid: "j1")
    ctx.warn("alert")
    output = io.to_s
    output.should contain("correlation_id=c1")
    output.should contain("jid=j1")
  end
end
