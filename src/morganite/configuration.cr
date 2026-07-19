require "random/secure"
require "yaml"
require "json"

module Morganite
  class Configuration
    property redis_url : String
    property queue : String
    property concurrency : Int32
    property web_port : Int32
    property log_level : String
    property log_format : String
    property dead_max_jobs : Int32
    property dead_timeout_in_seconds : Int32
    property web_username : String?
    property web_password : String?
    property secret_key : String
    property statsd_addr : String?
    property orphan_reaper_poll_interval_seconds : Int32

    # JQCP (docs/jqcp_conformance.md) Bearer-token scopes (Section 6). Unset
    # = that scope's routes are disabled entirely (fail closed, not open).
    # `jqcp_operator_write_token` also satisfies operator:read checks.
    property jqcp_worker_token : String?
    property jqcp_operator_read_token : String?
    property jqcp_operator_write_token : String?
    # How long the JQCP Fetch RPC's bounded-blocking poll (Section 7.3's
    # non-streaming fallback) waits for a Job before returning empty.
    property jqcp_fetch_timeout_seconds : Int32

    # Experimental, opt-in HTTP/3 Fetch (docs/jqcp_conformance.md) using
    # quic.cr's real Server Push instead of bounded polling. Off by default:
    # requires its own UDP port + TLS cert/key, and only a quic.cr-based
    # client can consume it.
    property? jqcp_http3_enabled : Bool
    property jqcp_http3_port : Int32
    property jqcp_http3_cert_file : String
    property jqcp_http3_key_file : String
    # How long one HTTP/3 Fetch "window" (an open push session) stays open
    # pushing eligible Jobs before ending and expecting the worker to
    # reconnect — bounds the server-side fiber lifetime per request. Default
    # is deliberately under 5s: quic.cr's H3::Client#get has a hardcoded 5s
    # read timeout on the *unary* final response (pushes themselves arrive
    # via a separate, unbounded code path and are unaffected) — a window at
    # or above that would still deliver every push correctly but the client
    # would never see the final `{"windowEnded":true}` response. Reconnects
    # are cheap regardless (a new stream on the same QUIC connection, not a
    # new handshake), so a short window has no real downside today.
    property jqcp_http3_fetch_window_seconds : Int32

    def initialize(
      @redis_url : String = ENV.fetch("MORGANITE_REDIS_URL", "redis://localhost:6379/0"),
      @queue : String = ENV.fetch("MORGANITE_QUEUE", "default"),
      @concurrency : Int32 = ENV.fetch("MORGANITE_CONCURRENCY", "5").to_i,
      @web_port : Int32 = ENV.fetch("MORGANITE_WEB_PORT", "7420").to_i,
      @log_level : String = ENV.fetch("MORGANITE_LOG_LEVEL", "info"),
      @log_format : String = ENV.fetch("MORGANITE_LOG_FORMAT", "text"),
      @dead_max_jobs : Int32 = ENV.fetch("MORGANITE_DEAD_MAX_JOBS", "10000").to_i,
      @dead_timeout_in_seconds : Int32 = ENV.fetch("MORGANITE_DEAD_TIMEOUT_IN_SECONDS", "15552000").to_i,
      @web_username : String? = ENV["MORGANITE_WEB_USERNAME"]?,
      @web_password : String? = ENV["MORGANITE_WEB_PASSWORD"]?,
      @secret_key : String = ENV.fetch("MORGANITE_SECRET_KEY", Random::Secure.hex(32)),
      @statsd_addr : String? = ENV["MORGANITE_STATSD_ADDR"]?,
      @orphan_reaper_poll_interval_seconds : Int32 = ENV.fetch("MORGANITE_ORPHAN_REAPER_POLL_INTERVAL_SECONDS", "30").to_i,
      @jqcp_worker_token : String? = ENV["MORGANITE_JQCP_WORKER_TOKEN"]?,
      @jqcp_operator_read_token : String? = ENV["MORGANITE_JQCP_OPERATOR_READ_TOKEN"]?,
      @jqcp_operator_write_token : String? = ENV["MORGANITE_JQCP_OPERATOR_WRITE_TOKEN"]?,
      @jqcp_fetch_timeout_seconds : Int32 = ENV.fetch("MORGANITE_JQCP_FETCH_TIMEOUT_SECONDS", "5").to_i,
      @jqcp_http3_enabled : Bool = ENV.fetch("MORGANITE_JQCP_HTTP3_ENABLED", "false") == "true",
      @jqcp_http3_port : Int32 = ENV.fetch("MORGANITE_JQCP_HTTP3_PORT", "7444").to_i,
      @jqcp_http3_cert_file : String = ENV.fetch("MORGANITE_JQCP_HTTP3_CERT_FILE", "cert.pem"),
      @jqcp_http3_key_file : String = ENV.fetch("MORGANITE_JQCP_HTTP3_KEY_FILE", "key.pem"),
      @jqcp_http3_fetch_window_seconds : Int32 = ENV.fetch("MORGANITE_JQCP_HTTP3_FETCH_WINDOW_SECONDS", "3").to_i,
    )
    end

    def self.from_file(path : String) : Configuration
      case File.extname(path).downcase
      when ".yaml", ".yml"
        from_yaml(path)
      when ".json"
        from_json(path)
      else
        raise ArgumentError.new("Unsupported config format: #{path}")
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def self.from_yaml(path : String) : Configuration
      content = File.read(path)
      yaml = YAML.parse(content)
      config = Configuration.new

      config.redis_url = yaml["redis_url"].as_s if yaml["redis_url"]?
      config.queue = yaml["queue"].as_s if yaml["queue"]?
      config.concurrency = yaml["concurrency"].as_i if yaml["concurrency"]?
      config.web_port = yaml["web_port"].as_i if yaml["web_port"]?
      config.log_level = yaml["log_level"].as_s if yaml["log_level"]?
      config.log_format = yaml["log_format"].as_s if yaml["log_format"]?
      config.dead_max_jobs = yaml["dead_max_jobs"].as_i if yaml["dead_max_jobs"]?
      config.dead_timeout_in_seconds = yaml["dead_timeout_in_seconds"].as_i if yaml["dead_timeout_in_seconds"]?
      config.web_username = yaml["web_username"].as_s if yaml["web_username"]?
      config.web_password = yaml["web_password"].as_s if yaml["web_password"]?
      config.secret_key = yaml["secret_key"].as_s if yaml["secret_key"]?
      config.statsd_addr = yaml["statsd_addr"].as_s if yaml["statsd_addr"]?
      config.orphan_reaper_poll_interval_seconds = yaml["orphan_reaper_poll_interval_seconds"].as_i if yaml["orphan_reaper_poll_interval_seconds"]?
      config.jqcp_worker_token = yaml["jqcp_worker_token"].as_s if yaml["jqcp_worker_token"]?
      config.jqcp_operator_read_token = yaml["jqcp_operator_read_token"].as_s if yaml["jqcp_operator_read_token"]?
      config.jqcp_operator_write_token = yaml["jqcp_operator_write_token"].as_s if yaml["jqcp_operator_write_token"]?
      config.jqcp_fetch_timeout_seconds = yaml["jqcp_fetch_timeout_seconds"].as_i if yaml["jqcp_fetch_timeout_seconds"]?
      config.jqcp_http3_enabled = yaml["jqcp_http3_enabled"].as_bool if yaml["jqcp_http3_enabled"]?
      config.jqcp_http3_port = yaml["jqcp_http3_port"].as_i if yaml["jqcp_http3_port"]?
      config.jqcp_http3_cert_file = yaml["jqcp_http3_cert_file"].as_s if yaml["jqcp_http3_cert_file"]?
      config.jqcp_http3_key_file = yaml["jqcp_http3_key_file"].as_s if yaml["jqcp_http3_key_file"]?
      config.jqcp_http3_fetch_window_seconds = yaml["jqcp_http3_fetch_window_seconds"].as_i if yaml["jqcp_http3_fetch_window_seconds"]?

      config
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def self.from_json(path : String) : Configuration
      content = File.read(path)
      json = JSON.parse(content)
      config = Configuration.new

      config.redis_url = json["redis_url"].as_s if json["redis_url"]?
      config.queue = json["queue"].as_s if json["queue"]?
      config.concurrency = json["concurrency"].as_i if json["concurrency"]?
      config.web_port = json["web_port"].as_i if json["web_port"]?
      config.log_level = json["log_level"].as_s if json["log_level"]?
      config.log_format = json["log_format"].as_s if json["log_format"]?
      config.dead_max_jobs = json["dead_max_jobs"].as_i if json["dead_max_jobs"]?
      config.dead_timeout_in_seconds = json["dead_timeout_in_seconds"].as_i if json["dead_timeout_in_seconds"]?
      config.web_username = json["web_username"].as_s if json["web_username"]?
      config.web_password = json["web_password"].as_s if json["web_password"]?
      config.secret_key = json["secret_key"].as_s if json["secret_key"]?
      config.statsd_addr = json["statsd_addr"].as_s if json["statsd_addr"]?
      config.orphan_reaper_poll_interval_seconds = json["orphan_reaper_poll_interval_seconds"].as_i if json["orphan_reaper_poll_interval_seconds"]?
      config.jqcp_worker_token = json["jqcp_worker_token"].as_s if json["jqcp_worker_token"]?
      config.jqcp_operator_read_token = json["jqcp_operator_read_token"].as_s if json["jqcp_operator_read_token"]?
      config.jqcp_operator_write_token = json["jqcp_operator_write_token"].as_s if json["jqcp_operator_write_token"]?
      config.jqcp_fetch_timeout_seconds = json["jqcp_fetch_timeout_seconds"].as_i if json["jqcp_fetch_timeout_seconds"]?
      config.jqcp_http3_enabled = json["jqcp_http3_enabled"].as_bool if json["jqcp_http3_enabled"]?
      config.jqcp_http3_port = json["jqcp_http3_port"].as_i if json["jqcp_http3_port"]?
      config.jqcp_http3_cert_file = json["jqcp_http3_cert_file"].as_s if json["jqcp_http3_cert_file"]?
      config.jqcp_http3_key_file = json["jqcp_http3_key_file"].as_s if json["jqcp_http3_key_file"]?
      config.jqcp_http3_fetch_window_seconds = json["jqcp_http3_fetch_window_seconds"].as_i if json["jqcp_http3_fetch_window_seconds"]?

      config
    end

    def validate!
      raise ArgumentError.new("concurrency must be greater than 0") if @concurrency <= 0
      raise ArgumentError.new("web_port must be between 1 and 65535") unless (1..65535).includes?(@web_port)
      raise ArgumentError.new("redis_url cannot be empty") if @redis_url.empty?
      raise ArgumentError.new("dead_max_jobs must be greater than or equal to 0") if @dead_max_jobs < 0
      raise ArgumentError.new("dead_timeout_in_seconds must be greater than or equal to 0") if @dead_timeout_in_seconds < 0
      raise ArgumentError.new("orphan_reaper_poll_interval_seconds must be greater than 0") if @orphan_reaper_poll_interval_seconds <= 0
      raise ArgumentError.new("jqcp_fetch_timeout_seconds must be greater than 0") if @jqcp_fetch_timeout_seconds <= 0
      raise ArgumentError.new("jqcp_http3_port must be between 1 and 65535") unless (1..65535).includes?(@jqcp_http3_port)
      raise ArgumentError.new("jqcp_http3_fetch_window_seconds must be greater than 0") if @jqcp_http3_fetch_window_seconds <= 0

      if @web_username && !@web_password
        raise ArgumentError.new("web_password is required when web_username is set")
      end
    end
  end

  class_getter config : Configuration = Configuration.new

  def self.config=(config : Configuration)
    config.validate!
    @@config = config
    Logger.level = Logger::Level.parse(config.log_level.upcase)
    Logger.json_format = config.log_format == "json"
  end
end
