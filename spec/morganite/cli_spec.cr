require "../spec_helper"
require "../../src/morganite/cli"
require "file_utils"

class InlineTestWorker
  include Morganite::Worker

  @@calls = [] of Array(JSON::Any)

  def self.calls
    @@calls
  end

  def self.clear
    @@calls.clear
  end

  def perform(args)
    @@calls << args
  end
end

describe Morganite::CLI do
  before_each do
    InlineTestWorker.clear
  end

  it "prints version" do
    cli = Morganite::CLI.new(["--version"])
    cli.run
    true.should be_true
  end

  it "prints help" do
    cli = Morganite::CLI.new(["--help"])
    cli.run
    true.should be_true
  end

  it "runs a worker inline" do
    cli = Morganite::CLI.new(["--inline", "InlineTestWorker [\"hello\",\"world\"]"])
    cli.run
    InlineTestWorker.calls.size.should eq(1)
    InlineTestWorker.calls.first.size.should eq(2)
    InlineTestWorker.calls.first[0].as_s.should eq("hello")
    InlineTestWorker.calls.first[1].as_s.should eq("world")
  end

  it "raises on invalid configuration" do
    path = File.join(Dir.tempdir, "morganite-config-#{Random::Secure.hex(8)}.yml")
    begin
      File.write(path, "concurrency: -1\n")

      expect_raises(ArgumentError) do
        cli = Morganite::CLI.new(["--config", path])
        cli.run
      end
    ensure
      FileUtils.rm(path) if File.exists?(path)
    end
  end
end
