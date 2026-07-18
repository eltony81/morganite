: it

# Guida completa a Morganite

Questo tutorial copre le principali casistiche d'uso di **Morganite**, la libreria di background jobs per Crystal ispirata a Sidekiq.

## Prerequisiti

- Crystal 1.15+
- Redis 6+

## 1. Creare un'applicazione

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
```

Poi:

```bash
shards install
```

Avvia Redis con Docker/Podman:

```bash
podman run -d -p 6379:6379 --name redis redis:7-alpine
```

## 2. Definire un worker

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

## 3. Enqueue asincrono

```crystal
EmailWorker.perform_async("user@example.com", "Benvenuto!")
```

Il job viene inserito in `morganite:queue:default` e processato dal primo worker disponibile.

## 4. Schedulare un job nel futuro

```crystal
# Tra 10 minuti
EmailWorker.perform_in(10.minutes, "user@example.com", "Promemoria")

# A un orario preciso
EmailWorker.perform_at(Time.utc(2026, 12, 25, 9, 0, 0), "user@example.com", "Auguri!")
```

I job schedulati vengono memorizzati in `morganite:scheduled` e spostati nella coda quando il timestamp è maturo.

## 5. Job ricorrenti con cron

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

## 6. Avviare il processor

```bash
shards build morganite
./bin/morganite
```

Il processo:
- preleva job dalle code
- li esegue in parallelo tramite fiber
- gestisce retry automatici
- sposta i job schedulati e cron nelle code
- espone la Web UI su `http://localhost:7420/morganite`

## 7. Gestione errori, retry e dead queue

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

## 8. Configurazione

Usa variabili d'ambiente:

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `MORGANITE_REDIS_URL` | `redis://localhost:6379/0` | URL Redis |
| `MORGANITE_QUEUE` | `default` | Coda di default |
| `MORGANITE_CONCURRENCY` | `5` | Numero di worker fiber |
| `MORGANITE_WEB_PORT` | `7420` | Porta Web UI |

Oppure configura via codice:

```crystal
Morganite.config = Morganite::Configuration.new(
  redis_url: "redis://redis:6379/0",
  queue: "critical",
  concurrency: 10,
  web_port: 8080
)
```

## 9. Esempio completo: app di notifiche

```crystal
require "morganite"

class NotifyWorker
  include Morganite::Worker

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

# Avvia processor (tipicamente in un altro processo)
Morganite.start
Morganite.wait
```

## 10. Web UI

Avvia il processor e apri nel browser:

```
http://localhost:7420/morganite
```

Dalla dashboard puoi:
- vedere le code e il numero di job
- vedere job schedulati, in retry e dead
- eliminare una coda
- rimuovere o rilanciare un job dead

## 11. Buone pratiche

- Tieni i worker idempotenti: possono essere eseguiti più volte in caso di retry.
- Non loggare dati sensibili negli argomenti del job.
- Usa `Morganite::Discard` per errori noti e non ritrattabili.
- Monitora la dead queue per individuare bug ricorrenti.
- In produzione, proteggi la Web UI dietro autenticazione o firewall.

## 12. Middleware e hooks

### Server middleware

Avvolge l’esecuzione di un job:

```crystal
class TimingMiddleware
  include Morganite::ServerMiddleware

  def call(job, worker, queue, next_middleware)
    start = Time.monotonic
    next_middleware.call
    elapsed = Time.monotonic - start
    puts "#{job.class} on #{queue} took #{elapsed.total_milliseconds}ms"
  end
end

Morganite::ServerMiddleware.use(TimingMiddleware.new)
```

### Client middleware

Intercetta gli enqueue:

```crystal
class MetadataMiddleware
  include Morganite::ClientMiddleware

  def call(job, next_middleware)
    job.args << JSON.parse("\"processed-at:#{Time.utc.to_iso8601}\"")
    next_middleware.call
  end
end

Morganite::ClientMiddleware.use(MetadataMiddleware.new)
```

### Hooks

```crystal
Morganite::Hooks.on_startup { puts "Morganite started" }
Morganite::Hooks.on_shutdown { puts "Morganite stopped" }
Morganite::Hooks.before_first_fetch { puts "First fetch" }
Morganite::Hooks.after_last_fetch { puts "Last fetch" }
```

## 13. Unique jobs

Puoi garantire che un job non venga enqueuato duplicato in base a classe, coda e argomenti:

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

- `while_executing`: due istanze uguali non possono girare contemporaneamente.
- `until_executed`: il lock persiste fino al completamento con successo (sopravvive ai retry).
- `until_expired`: il lock dura per `ttl` secondi; duplicati vengono rifiutati in quel periodo.

```crystal
# Enqueue manuale con strategia
Morganite::Client.enqueue("IdempotentWorker", args, unique: "until_expired", unique_for: 300)
```

## 14. Logging e metriche

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
- `morganite_<WorkerClass>_duration_seconds` (histogram)

Esponi su `http://localhost:7420/metrics`.

### Health check

```bash
curl http://localhost:7420/health
# {"status":"ok"}
```

## 14. Test

Nei test usa un database Redis separato o esegui `FLUSHDB` in `before_each`:

```crystal
Spec.before_each do
  Morganite::RedisConnection.new_client.flushdb
end
```
