# Guida completa a Morganite

Questo tutorial copre tutte le principali casistiche d'uso di **Morganite**, la libreria di background jobs per Crystal ispirata a Sidekiq: dal primo worker fino a batch, workflow, rate limiting, middleware e deploy in produzione.

## Indice

1. [Prerequisiti](#1-prerequisiti)
2. [Creare un'applicazione](#2-creare-unapplicazione)
3. [Definire un worker](#3-definire-un-worker)
4. [Enqueue asincrono](#4-enqueue-asincrono)
5. [Schedulare un job nel futuro](#5-schedulare-un-job-nel-futuro)
6. [Job ricorrenti con cron](#6-job-ricorrenti-con-cron)
7. [Avviare il processor](#7-avviare-il-processor)
8. [CLI reference](#8-cli-reference)
9. [Gestione errori, retry e dead queue](#9-gestione-errori-retry-e-dead-queue)
10. [Configurazione](#10-configurazione)
11. [Web UI](#11-web-ui)
12. [Middleware e hooks](#12-middleware-e-hooks)
13. [Unique jobs](#13-unique-jobs)
14. [Rate limiting](#14-rate-limiting)
15. [Batch](#15-batch)
16. [Workflow](#16-workflow)
17. [Logging, metriche e health check](#17-logging-metriche-e-health-check)
18. [Deploy con Docker](#18-deploy-con-docker)
19. [Test](#19-test)
20. [Esempio completo: app di notifiche](#20-esempio-completo-app-di-notifiche)
21. [Buone pratiche](#21-buone-pratiche)

## 1. Prerequisiti

- Crystal 1.20+
- Redis 6+

## 2. Creare un'applicazione

```bash
mkdir my_app
cd my_app
crystal init app my_app
```

Aggiungi `morganite` in `shard.yml`:

```yaml
dependencies:
  morganite:
    github: eltony81/morganite
    version: ~> 0.2.0
```

Poi:

```bash
shards install
```

Avvia Redis con Docker/Podman:

```bash
podman run -d -p 6379:6379 --name redis redis:7-alpine
```

## 3. Definire un worker

```crystal
require "morganite"

class EmailWorker
  include Morganite::Worker

  def perform(args)
    email = args[0].as_s
    subject = args[1].as_s

    puts "Invio email a #{email}: #{subject}"
  end
end
```

Ogni worker deve:
- includere `Morganite::Worker`
- implementare `perform(args : Array(JSON::Any))`

Includere `Morganite::Worker` registra la classe (per nome) in un registry globale al momento della definizione: per questo **i file dei worker devono sempre essere `require`-ati prima di avviare il processor** (vedi [sezione 7](#7-avviare-il-processor)).

## 4. Enqueue asincrono

```crystal
EmailWorker.perform_async("user@example.com", "Benvenuto!")
```

Il job viene inserito in `morganite:queue:default` e processato dal primo worker disponibile. Per usare una coda diversa da quella di default:

```crystal
class CriticalWorker
  include Morganite::Worker
  sidekiq_options queue: "critical"

  def perform(args)
  end
end
```

## 5. Schedulare un job nel futuro

```crystal
# Tra 10 minuti
EmailWorker.perform_in(10.minutes, "user@example.com", "Promemoria")

# A un orario preciso
EmailWorker.perform_at(Time.utc(2026, 12, 25, 9, 0, 0), "user@example.com", "Auguri!")
```

I job schedulati vengono memorizzati in `morganite:scheduled` e spostati nella coda quando il timestamp è maturo.

## 6. Job ricorrenti con cron

```crystal
class CleanupWorker
  include Morganite::Worker
  cron "0 3 * * *" # ogni giorno alle 03:00 UTC

  def perform(args)
    puts "Pulizia giornaliera"
  end
end
```

Il parser supporta:
- `*` (ogni valore)
- `*/n` (ogni n unità)
- liste: `1,2,3`
- range: `9-17`

Una combinazione giorno/mese impossibile da soddisfare (es. "31 febbraio") viene rifiutata a registrazione, non silenziosamente ignorata per sempre.

## 7. Avviare il processor

Morganite è una libreria compilata: i worker devono essere `require`-ati **a tempo di compilazione**, quindi non puoi limitarti a lanciare il binario `bin/morganite` della gemma e aspettarti che conosca i tuoi worker. Serve un piccolo entrypoint nella tua app che richieda i tuoi file worker e poi avvii Morganite.

Il modo più completo è delegare il parsing degli argomenti a `Morganite::CLI` (la stessa CLI usata da `bin/morganite`, ma con i tuoi worker già caricati):

```crystal
# src/my_app_worker.cr
require "morganite"
require "morganite/cli"
require "./workers/email_worker"
require "./workers/cleanup_worker"

Morganite::CLI.run
```

```bash
crystal build src/my_app_worker.cr -o bin/my_app_worker --release
./bin/my_app_worker --queue critical --concurrency 10
```

> Chiama `Morganite::CLI.run` esplicitamente (come sopra) invece di lasciare che scatti da sé: `cli.cr` si autoesegue solo quando il binario compilato si chiama esattamente `morganite` (per non autoeseguirsi quando `require`-ato dai test). Chiamandolo tu stesso funziona sempre, qualunque nome dai al binario.

In alternativa, se non ti serve la CLI (nessun flag da riga di comando), puoi avviare/fermare Morganite programmaticamente:

```crystal
require "morganite"
require "./workers/email_worker"

Morganite.start
Morganite.wait
```

Il processo, in entrambi i casi:
- preleva job dalle code
- li esegue in parallelo tramite fiber (`concurrency` configurabile)
- gestisce retry automatici con backoff esponenziale
- sposta i job schedulati e cron nelle code quando maturano
- richiede indietro i job "orfani" lasciati da un processo terminato senza shutdown pulito (crash, `SIGKILL`, OOM)
- espone la Web UI su `http://localhost:7420/morganite` (a meno di `--web-only` o `start_web: false`)

## 8. CLI reference

Disponibile sia su `bin/morganite` sia su qualsiasi tuo entrypoint che chiama `Morganite::CLI.run`:

| Flag | Descrizione |
|------|-------------|
| `-c, --config PATH` | Carica configurazione da file YAML o JSON |
| `--concurrency N` | Numero di worker fiber |
| `--queue NAME` | Coda da processare |
| `-v, --verbose` | Abilita debug logging |
| `--web-only` | Avvia solo la Web UI (nessun worker) |
| `--inline 'WORKER ARGS'` | Esegue un worker inline, senza processor, utile per debug |
| `--version` | Mostra la versione |
| `-h, --help` | Mostra l'help |

Esempi:

```bash
./bin/my_app_worker --config config/morganite.yml
./bin/my_app_worker --queue critical --concurrency 10
./bin/my_app_worker --inline 'EmailWorker ["user@example.com","Test"]'
./bin/my_app_worker --web-only
```

## 9. Gestione errori, retry e dead queue

Se `perform` solleva un'eccezione:
1. Morganite incrementa `retry_count`.
2. Rischedula il job in `morganite:retry` con backoff esponenziale.
3. Dopo il numero massimo di retry (default 25), il job finisce in `morganite:dead`.

Per saltare retry e dead queue, lancia `Morganite::Discard`:

```crystal
class OptionalWorker
  include Morganite::Worker

  def perform(args)
    raise Morganite::Discard.new("ignora") if args.empty?
    # ...
  end
end
```

Per personalizzare numero di retry, backoff o comportamento sulla dead queue:

```crystal
class FlakyWorker
  include Morganite::Worker
  sidekiq_options retry: 5, dead: false # 5 retry, poi scarta invece di finire in dead

  def perform(args)
  end

  # Backoff custom (secondi) in base al tentativo, invece dell'esponenziale di default
  def self.retry_in(retry_count : Int32) : Int32?
    retry_count * 30
  end
end
```

Un worker fiber sopravvive sempre a un job malformato o a una classe non registrata: il job finisce nel percorso normale di retry/dead invece di uccidere silenziosamente un worker.

## 10. Configurazione

Puoi configurare Morganite via variabili d'ambiente, file YAML/JSON, o codice — le variabili d'ambiente hanno sempre precedenza sul file.

### Variabili d'ambiente

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `MORGANITE_REDIS_URL` | `redis://localhost:6379/0` | URL Redis |
| `MORGANITE_QUEUE` | `default` | Coda di default |
| `MORGANITE_CONCURRENCY` | `5` | Numero di worker fiber |
| `MORGANITE_WEB_PORT` | `7420` | Porta Web UI |
| `MORGANITE_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `MORGANITE_LOG_FORMAT` | `text` | `text` o `json` |
| `MORGANITE_DEAD_MAX_JOBS` | `10000` | Job massimi tenuti in dead queue |
| `MORGANITE_DEAD_TIMEOUT_IN_SECONDS` | `15552000` (180gg) | Retention dei job dead |
| `MORGANITE_WEB_USERNAME` | _(vuoto)_ | Utente Basic Auth per la Web UI |
| `MORGANITE_WEB_PASSWORD` | _(vuoto)_ | Password Basic Auth per la Web UI |
| `MORGANITE_SECRET_KEY` | generata a random | Chiave per token CSRF della Web UI |
| `MORGANITE_STATSD_ADDR` | _(nessuno)_ | Indirizzo StatsD opzionale |
| `MORGANITE_ORPHAN_REAPER_POLL_INTERVAL_SECONDS` | `30` | Intervallo di scansione job orfani |

### File di configurazione

```yaml
# config/morganite.yml
redis_url: redis://localhost:6379/0
queue: default
concurrency: 5
web_port: 7420
log_level: info
log_format: text
web_username: admin
web_password: changeme
```

```bash
./bin/my_app_worker --config config/morganite.yml
```

### Via codice

```crystal
Morganite.config = Morganite::Configuration.new(
  redis_url: "redis://redis:6379/0",
  queue: "critical",
  concurrency: 10,
  web_port: 8080
)
```

Assegna sempre tramite `Morganite.config = ...` (il setter valida la configurazione e riconfigura il logger); mutare in place l'oggetto restituito da `Morganite.config` senza riassegnarlo non ha questi effetti collaterali.

## 11. Web UI

Avvia il processor e apri nel browser:

```
http://localhost:7420/morganite
```

Dalla dashboard puoi:
- vedere le code e il numero di job
- vedere job schedulati, in retry e dead
- eliminare una coda
- rimuovere o rilanciare un job dead/retry/schedulato

Per proteggerla con Basic Auth in produzione, imposta `MORGANITE_WEB_USERNAME`/`MORGANITE_WEB_PASSWORD` (o l'equivalente in configurazione): l'autenticazione si attiva automaticamente quando entrambe sono presenti. Le azioni della dashboard (delete/retry) sono comunque protette da CSRF token indipendentemente dall'auth.

## 12. Middleware e hooks

### Server middleware

Avvolge l'esecuzione di un job:

```crystal
class TimingMiddleware
  include Morganite::ServerMiddleware

  def call(job, worker, queue, next_middleware)
    start = Time.instant
    next_middleware.call
    elapsed = Time.instant - start
    puts "#{job.class} on #{queue} took #{elapsed.total_milliseconds}ms"
  end
end

Morganite::ServerMiddleware.use(TimingMiddleware.new)
```

Oppure registrala solo per uno specifico worker:

```crystal
class ReportWorker
  include Morganite::Worker
  server_middleware TimingMiddleware

  def perform(args)
  end
end
```

Morganite include già alcuni middleware pronti (opt-in, non registrati automaticamente): `Morganite::LoggingMiddleware`, `Morganite::MetricsMiddleware` e `Morganite::DatadogMiddleware` (quest'ultimo è un placeholder illustrativo, va collegato a un vero tracer APM).

### Client middleware

Intercetta gli enqueue:

```crystal
class MetadataMiddleware
  include Morganite::ClientMiddleware

  def call(job, next_middleware)
    job.args << JSON.parse("\"processed-at:#{Time.utc.to_rfc3339}\"")
    next_middleware.call
  end
end

Morganite::ClientMiddleware.use(MetadataMiddleware.new)
```

Inclusi anche `Morganite::LoggingClientMiddleware`, `Morganite::MetadataClientMiddleware` (accetta un `Hash(String, JSON::Any)` da allegare a ogni job) e `Morganite::TracingClientMiddleware`.

### Hooks

```crystal
Morganite::Hooks.on_startup { puts "Morganite started" }
Morganite::Hooks.on_shutdown { puts "Morganite stopped" }
Morganite::Hooks.before_first_fetch { puts "First fetch" }
Morganite::Hooks.after_last_fetch { puts "Last fetch" }
```

## 13. Unique jobs

Puoi garantire che un job non venga eseguito o enqueuato duplicato in base a classe, coda e argomenti:

```crystal
class IdempotentWorker
  include Morganite::Worker

  # Blocca finché il job precedente è in esecuzione
  unique :while_executing, ttl: 60

  # Altre strategie:
  # unique :until_executed, ttl: 300
  # unique :until_expired, ttl: 300

  def perform(args)
    # lavoro idempotente
  end
end
```

Strategie:

- `while_executing`: due istanze uguali non possono girare contemporaneamente (lock solo durante l'esecuzione).
- `until_executed`: il lock viene preso all'enqueue e persiste fino al completamento con successo (sopravvive ai retry) — un secondo enqueue duplicato viene rifiutato finché il primo non ha successo.
- `until_expired`: come `until_executed`, ma il lock scade comunque dopo `ttl` secondi anche se il job non è ancora completato.

```crystal
# Enqueue manuale con strategia
Morganite::Client.enqueue("IdempotentWorker", args, unique: "until_expired", unique_for: 300)
```

## 14. Rate limiting

Limita quante esecuzioni di un worker possono partire in una finestra temporale; i job in eccesso vengono automaticamente rischedulati (non scartati né falliti) fino a quando la finestra si libera:

```crystal
class ThirdPartyApiWorker
  include Morganite::Worker
  rate_limit 5, 10 # massimo 5 esecuzioni ogni 10 secondi

  def perform(args)
    # chiamata a un'API esterna con limiti di rate
  end
end
```

Non serve altro: il `Processor` applica il limite automaticamente prima di eseguire `perform`. Il rate limiting è per classe di worker (non per singolo job/argomenti) ed è condiviso tra tutti i processi che condividono lo stesso Redis.

## 15. Batch

Un batch raggruppa più job e invoca callback quando tutti sono completati (con successo o meno):

```crystal
batch = Morganite::Batch.new(
  description: "invio report mensile",
  success_callback: "ReportSuccessWorker", # eseguito solo se zero fallimenti
  complete_callback: "ReportCompleteWorker" # eseguito sempre, a fine batch
)

users.each do |user|
  batch.add("ReportWorker", [JSON.parse({user_id: user.id}.to_json)])
end

batch.finish # obbligatorio: segnala che hai finito di aggiungere job
```

`Batch.open` fa `finish` automaticamente per te:

```crystal
Morganite::Batch.open(description: "invio report mensile", complete: "ReportCompleteWorker") do |batch|
  users.each { |user| batch.add("ReportWorker", [JSON.parse({user_id: user.id}.to_json)]) }
end
```

I callback ricevono il `bid` (batch id) come unico argomento:

```crystal
class ReportCompleteWorker
  include Morganite::Worker

  def perform(args)
    bid = args[0].as_s
    puts "Batch #{bid} completato"
  end
end
```

## 16. Workflow

Un workflow esegue una sequenza di step in ordine, uno dopo l'altro (lo step successivo parte solo quando il precedente ha completato con successo):

```crystal
workflow = Morganite::Workflow.new
workflow.step("DownloadWorker", [JSON.parse({url: "https://example.com/file"}.to_json)])
workflow.step("ProcessWorker", [] of JSON::Any)
workflow.step("NotifyWorker", [JSON.parse({user_id: 42}.to_json)])
workflow.run
```

Ogni step può usare una coda diversa (`workflow.step(name, args, queue: "critical")`). Se uno step fallisce e va in dead queue, il workflow si ferma; se ha successo, lo step successivo viene enqueuato automaticamente.

## 17. Logging, metriche e health check

### Configurazione logging

```bash
export MORGANITE_LOG_LEVEL=info   # debug, info, warn, error
export MORGANITE_LOG_FORMAT=json  # text (default) o json
```

Nel codice:

```crystal
Morganite::Logger.info("qualcosa di importante")
ctx = Morganite::Logger.context(jid: job.jid, correlation_id: "req-123")
ctx.info("start")
```

### Metriche Prometheus

Il processor incrementa automaticamente:

- `morganite_jobs_processed`
- `morganite_jobs_failed`
- `morganite_jobs_retried`
- `morganite_jobs_dead`
- `morganite_<WorkerClass>_duration_seconds` (histogram, bucket Prometheus-style)

Esponi su `http://localhost:7420/metrics`.

### Health check

```bash
curl http://localhost:7420/health
# {"status":"ok"}
```

## 18. Deploy con Docker

Esempio di Dockerfile multistage per un'app che usa Morganite:

```dockerfile
FROM crystallang/crystal:1.20 AS builder
WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src ./src
RUN crystal build src/my_app_worker.cr -o bin/my_app_worker --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcre2-8-0 libevent-2.1-7 libgc1 libssl3 libyaml-0-2 zlib1g ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/bin/my_app_worker /usr/local/bin/my_app_worker
EXPOSE 7420
ENTRYPOINT ["my_app_worker"]
```

Per un binario **staticamente linkato** (nessuna dipendenza dalla libc dell'host), usa l'immagine Alpine e `--static`:

```dockerfile
FROM crystallang/crystal:1.20-alpine
WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src ./src
RUN crystal build src/my_app_worker.cr -o bin/my_app_worker --release --static
ENTRYPOINT ["/app/bin/my_app_worker"]
```

In entrambi i casi, passa `MORGANITE_REDIS_URL` puntando al Redis del tuo ambiente (es. `redis://redis:6379/0` in un `docker-compose.yml`).

## 19. Test

Nei test usa un database Redis separato o esegui `FLUSHDB` in `before_each`:

```crystal
Spec.before_each do
  Morganite::RedisConnection.new_client.flushdb
end
```

Per testare un worker senza passare dalla coda/processor, chiama `perform` direttamente:

```crystal
it "invia l'email" do
  worker = EmailWorker.new
  worker.perform([JSON.parse(%("user@example.com")), JSON.parse(%("Test"))])
end
```

## 20. Esempio completo: app di notifiche

```crystal
require "morganite"
require "morganite/cli"

class NotifyWorker
  include Morganite::Worker
  rate_limit 20, 60 # non più di 20 notifiche al minuto

  def perform(args)
    user_id = args[0].as_i
    message = args[1].as_s
    puts "[NotifyWorker] user=#{user_id} message=#{message}"
  end
end

class DigestWorker
  include Morganite::Worker
  cron "0 9 * * 1" # ogni lunedì alle 9:00 UTC

  def perform(args)
    puts "[DigestWorker] invio digest settimanale"
  end
end

# Job immediato
NotifyWorker.perform_async(42, "Hai un nuovo messaggio")

# Job schedulato
NotifyWorker.perform_in(1.hour, 42, "Promemoria riunione")

# Avvia il processor con supporto CLI (tipicamente in un altro processo)
Morganite::CLI.run
```

## 21. Buone pratiche

- Tieni i worker idempotenti: possono essere eseguiti più volte in caso di retry.
- Non loggare dati sensibili negli argomenti del job.
- Usa `Morganite::Discard` per errori noti e non ritrattabili.
- Usa `rate_limit` per i worker che chiamano API esterne con limiti propri, invece di implementare un throttling manuale.
- Monitora la dead queue per individuare bug ricorrenti.
- In produzione, proteggi la Web UI con `MORGANITE_WEB_USERNAME`/`MORGANITE_WEB_PASSWORD` o dietro un firewall/reverse proxy.
- Usa batch/workflow invece di orchestrare manualmente contatori Redis per job correlati: la gestione delle race condition è già risolta.
