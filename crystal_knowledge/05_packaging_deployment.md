# Crystal – Packaging e deployment di Morganite

## 1. shard.yml

Esempio di configurazione iniziale:

```yaml
name: morganite
version: 0.1.0

description: |
  Background job processor for Crystal, inspired by Sidekiq

authors:
  - Morganite Team

license: MIT

crystal: 1.15.0

targets:
  morganite:
    main: src/morganite/cli.cr
  morganite-web:
    main: src/morganite/web_cli.cr

dependencies:
  redis:
    github: stefanwille/crystal-redis
    version: ~> 2.8.0
  kemal:
    github: kemalcr/kemal
    version: ~> 1.1.0

dev_dependencies:
  ameba:
    github: crystal-ameba/ameba
    version: ~> 1.6.0
```

## 2. Build

```bash
shards install          # scarica dipendenze
crystal build src/morganite/cli.cr -o bin/morganite --release
```

Per build di sviluppo:

```bash
crystal build src/morganite/cli.cr -o bin/morganite
```

## 3. Binary statico

```bash
crystal build src/morganite/cli.cr -o bin/morganite --release --static
```

Nota: il linking statico può richiedere librerie di sistema (openssl, zlib). Su Alpine Linux è più semplice.

## 4. Dockerfile

```dockerfile
FROM crystallang/crystal:1.15.0-alpine AS builder
WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install --production
COPY . .
RUN crystal build src/morganite/cli.cr -o bin/morganite --release --static

FROM alpine:latest
RUN apk add --no-cache redis-client ca-certificates
WORKDIR /app
COPY --from=builder /app/bin/morganite /usr/local/bin/morganite
ENTRYPOINT ["morganite"]
```

## 5. Docker Compose per sviluppo

```yaml
version: "3.8"
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
  morganite:
    build: .
    command: ["morganite", "-c", "config/morganite.yml"]
    volumes:
      - .:/app
    depends_on:
      - redis
    environment:
      MORGANITE_REDIS_URL: redis://redis:6379/0
```

## 6. Linting

```bash
shards install # per ameba
./bin/ameba
```

## 7. CI/GitHub Actions

- Installare Crystal
- `shards install`
- `crystal tool format --check`
- `crystal spec`
- `bin/ameba`
- Build release

## 8. Deploy

- **Bare metal/VM**: systemd unit che avvia `morganite`.
- **Kubernetes**: Deployment con sidecar Redis o connessione a Redis esterno.
- **Heroku/Fly**: binary + Procfile.
