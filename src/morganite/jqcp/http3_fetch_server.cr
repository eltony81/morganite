require "quic"
require "../job"
require "../redis_connection"
require "../logger"
require "./auth"
require "./errors"
require "./job_state"
require "./worker_session"
require "./worker_api"

module Morganite
  module Jqcp
    # Experimental, opt-in HTTP/3 transport for the Fetch RPC only (Section
    # 7.3), using quic.cr's real HTTP/3 Server Push instead of bounded
    # polling — see docs/jqcp_conformance.md for the full rationale, the
    # interop caveat (only a quic.cr-based client can consume this), and why
    # every other RPC (Hello/Enqueue/Ack/Fail/Beat/Operator API) deliberately
    # stays on the existing, already-verified JSON-over-HTTP surface.
    #
    # Model: one `GET /jqcp/v1/worker/fetch?wid=...` request opens a bounded
    # "window" (`jqcp_http3_fetch_window_seconds`, default 30s). Every Job
    # that becomes eligible during the window is pushed immediately as a
    # separate, complete pushed resource (Jqcp::WorkerApi.fetch_one — the
    # exact same claim/Lease logic the JSON-HTTP Fetch handler uses, called
    # repeatedly instead of once). When the window elapses the original
    # request finally responds with `{"windowEnded":true}`; the worker is
    # expected to open a new Fetch request to keep receiving work — this
    # bounds the server-side fiber lifetime per request instead of running
    # forever, and matches the pool-connection discipline used everywhere
    # else in Morganite (borrow-and-release per attempt, not held for the
    # whole window).
    module Http3FetchServer
      def self.router : H3::Router
        router = H3::Router.new
        router.get "/jqcp/v1/worker/fetch" { |ctx| handle_fetch(ctx) }
        router
      end

      private def self.handle_fetch(ctx : H3::Context)
        unless Auth.authorized?(ctx, Auth::Scope::Worker)
          ctx.json(Errors.body("unauthorized"), Errors.status_for("unauthorized"))
          return
        end

        wid = ctx.request.query_params["wid"]?
        if wid.nil? || wid.empty?
          ctx.json(Errors.body("invalid_job"), Errors.status_for("invalid_job"))
          return
        end

        identified = Morganite.pool.with { |redis| WorkerSession.identified?(redis, wid) }
        unless identified
          ctx.json(Errors.body("unauthorized"), Errors.status_for("unauthorized"))
          return
        end

        push_eligible_jobs_until_window_ends(ctx, wid)
        ctx.json(%({"windowEnded":true}))
      end

      private def self.push_eligible_jobs_until_window_ends(ctx : H3::Context, wid : String)
        deadline = Time.instant + Morganite.config.jqcp_http3_fetch_window_seconds.seconds

        while (remaining = deadline - Time.instant) > Time::Span.zero
          # Cap each fetch_one call to what's left of the window: fetch_one's
          # own default budget (jqcp_fetch_timeout_seconds, 5s) is unrelated
          # to and can outlast a shorter HTTP/3 window, which would blow past
          # quic.cr's client-side unary response timeout for no reason.
          budget = remaining.total_seconds.ceil.to_i.clamp(1, Int32::MAX)
          job = Morganite.pool.with { |redis| WorkerApi.fetch_one(redis, wid, budget_seconds: budget) }
          next unless job

          body = Jqcp.job_to_json(job, JobState::Active).to_json
          ctx.push_resource("/jqcp/v1/worker/fetch/#{job.jid}", body, {"content-type" => "application/json"})
          Logger.debug("jqcp http3: pushed job #{job.jid} to wid=#{wid}")
        end
      end
    end
  end
end
