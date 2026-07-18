FROM crystallang/crystal:1.21-alpine

WORKDIR /app

# Install Morganite and its dependencies first (used as a local path dependency)
COPY shard.yml shard.lock ./
COPY src ./src
RUN shards install --production

# Copy the demo app and install its own shards
COPY examples/demo_app/ ./examples/demo_app/
WORKDIR /app/examples/demo_app
RUN shards install --production

# Default command can be overridden by docker-compose
CMD ["crystal", "run", "src/demo_app.cr", "--", "work"]
