require "../spec_helper"
require "file_utils"

def temp_config_path(extension : String) : String
  File.join(Dir.tempdir, "morganite-config-#{Random::Secure.hex(8)}#{extension}")
end

describe Morganite::Configuration do
  it "loads configuration from YAML" do
    path = temp_config_path(".yml")
    begin
      File.write(path, [
        "redis_url: redis://localhost:6379/1",
        "queue: critical",
        "concurrency: 10",
        "web_port: 8080",
        "log_level: debug",
        "log_format: json",
        "dead_max_jobs: 500",
        "dead_timeout_in_seconds: 3600",
        "web_username: admin",
        "web_password: secret",
        "secret_key: my-secret",
        "statsd_addr: localhost:8125",
      ].join("\n"))

      config = Morganite::Configuration.from_file(path)
      config.redis_url.should eq("redis://localhost:6379/1")
      config.queue.should eq("critical")
      config.concurrency.should eq(10)
      config.web_port.should eq(8080)
      config.log_level.should eq("debug")
      config.log_format.should eq("json")
      config.dead_max_jobs.should eq(500)
      config.dead_timeout_in_seconds.should eq(3600)
      config.web_username.should eq("admin")
      config.web_password.should eq("secret")
      config.secret_key.should eq("my-secret")
      config.statsd_addr.should eq("localhost:8125")
    ensure
      FileUtils.rm(path) if File.exists?(path)
    end
  end

  it "loads configuration from JSON" do
    path = temp_config_path(".json")
    begin
      File.write(path, {
        "redis_url":   "redis://localhost:6379/2",
        "queue":       "low",
        "concurrency": 3,
      }.to_json)

      config = Morganite::Configuration.from_file(path)
      config.redis_url.should eq("redis://localhost:6379/2")
      config.queue.should eq("low")
      config.concurrency.should eq(3)
    ensure
      FileUtils.rm(path) if File.exists?(path)
    end
  end

  it "rejects unsupported config formats" do
    path = temp_config_path(".txt")
    begin
      File.write(path, "redis_url: x")

      expect_raises(ArgumentError) do
        Morganite::Configuration.from_file(path)
      end
    ensure
      FileUtils.rm(path) if File.exists?(path)
    end
  end

  it "validates concurrency" do
    config = Morganite::Configuration.new
    config.concurrency = 0
    expect_raises(ArgumentError, /concurrency/) do
      config.validate!
    end
  end

  it "validates web port range" do
    config = Morganite::Configuration.new
    config.web_port = 0
    expect_raises(ArgumentError, /web_port/) do
      config.validate!
    end
  end

  it "validates redis url" do
    config = Morganite::Configuration.new
    config.redis_url = ""
    expect_raises(ArgumentError, /redis_url/) do
      config.validate!
    end
  end

  it "validates web auth credentials" do
    config = Morganite::Configuration.new
    config.web_username = "admin"
    config.web_password = nil
    expect_raises(ArgumentError, /web_password/) do
      config.validate!
    end
  end
end
