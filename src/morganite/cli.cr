require "option_parser"
require "json"
require "../morganite"

module Morganite
  class CLI
    @config_path : String?
    @concurrency : Int32?
    @queue : String?
    @verbose : Bool
    @web_only : Bool
    @inline_worker : String?
    @inline_args : String?
    @show_help : Bool
    @show_version : Bool

    def self.run(args = ARGV)
      new(args).run
    end

    def initialize(@args : Array(String))
      @config_path = nil
      @concurrency = nil
      @queue = nil
      @verbose = false
      @web_only = false
      @inline_worker = nil
      @inline_args = nil
      @show_help = false
      @show_version = false
    end

    def run
      parse_options

      if @show_help
        print_help
        return
      end

      if @show_version
        puts "Morganite #{Morganite::VERSION}"
        return
      end

      if config = build_configuration
        Morganite.config = config
      end

      if @inline_worker
        run_inline
        return
      end

      if @web_only
        Morganite::Web.start(Morganite.config.web_port)
        return
      end

      start_processor
    end

    private def parse_options
      OptionParser.parse(@args) do |parser|
        parser.banner = "Usage: morganite [options]"

        parser.on("-c PATH", "--config PATH", "Load configuration from YAML or JSON file") do |path|
          @config_path = path
        end

        parser.on("--concurrency N", "Number of concurrent workers") do |value|
          @concurrency = value.to_i? || raise ArgumentError.new("Invalid concurrency: #{value}")
        end

        parser.on("--queue NAME", "Queue to process") do |value|
          @queue = value
        end

        parser.on("-v", "--verbose", "Enable debug logging") do
          @verbose = true
        end

        parser.on("--web-only", "Start only the Web UI") do
          @web_only = true
        end

        parser.on("--inline VALUE", "Run a worker inline with 'WORKER [args]' format") do |value|
          parts = value.split(' ', 2)
          @inline_worker = parts[0]
          @inline_args = parts[1]? || "[]"
        end

        parser.on("--version", "Show version") do
          @show_version = true
        end

        parser.on("-h", "--help", "Show this help") do
          @show_help = true
        end

        parser.invalid_option do |flag|
          STDERR.puts "Invalid option: #{flag}"
          print_help
          exit 1
        end
      end
    end

    private def build_configuration : Configuration
      config = if config_path = @config_path
                 Configuration.from_file(config_path)
               else
                 Morganite.config.dup
               end

      if concurrency = @concurrency
        config.concurrency = concurrency
      end
      if queue = @queue
        config.queue = queue
      end
      config.log_level = "debug" if @verbose
      config
    end

    private def run_inline
      worker_name = @inline_worker
      args_json = @inline_args || "[]"

      unless worker_name
        STDERR.puts "Missing worker name for inline execution"
        exit 1
      end

      factory = WorkerRegistry.fetch(worker_name)
      worker = factory.call
      args = JSON.parse(args_json).as_a
      worker.perform(args)
    rescue ex : MissingWorkerError
      STDERR.puts "Unknown worker: #{worker_name}"
      exit 1
    rescue ex : JSON::ParseException
      STDERR.puts "Invalid JSON args: #{args_json}"
      exit 1
    end

    private def start_processor
      Signal::INT.trap do
        puts "Shutting down Morganite..."
        Morganite.stop
      end

      Signal::TERM.trap do
        Morganite.stop
      end

      Morganite.start
      Morganite.wait
    end

    private def print_help
      puts "Usage: morganite [options]"
      puts ""
      puts "Options:"
      puts "  -c, --config PATH       Load configuration from YAML or JSON file"
      puts "      --concurrency N     Number of concurrent workers"
      puts "      --queue NAME        Queue to process"
      puts "  -v, --verbose           Enable debug logging"
      puts "      --web-only          Start only the Web UI"
      puts "      --inline 'WORKER ARGS'  Run a worker inline with JSON args"
      puts "      --version           Show version"
      puts "  -h, --help              Show this help"
    end
  end
end
