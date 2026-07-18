# syntax=docker/dockerfile:1

FROM crystallang/crystal:1.21 AS builder

WORKDIR /app

COPY shard.yml shard.lock ./
RUN shards install --production

COPY src ./src
RUN mkdir -p bin && crystal build src/morganite/cli.cr -o bin/morganite --release

FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcre2-8-0 \
    libevent-2.1-7 \
    libgc1 \
    libssl3 \
    libyaml-0-2 \
    zlib1g \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/bin/morganite /usr/local/bin/morganite

EXPOSE 7420

ENTRYPOINT ["morganite"]
CMD ["morganite"]
