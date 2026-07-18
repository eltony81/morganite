# Morganite – Piano di sviluppo

> **Morganite** è un job scheduler / background worker scritto in [Crystal](https://crystal-lang.org/) ispirato funzionalmente a [Sidekiq](https://sidekiq.org/).  
> Questo file è il punto unico di verità per il lavoro da svolgere: ogni task ha una checkbox che OpenCode e il dev aggiornano man mano.

---

## 0. Scope e scelte iniziali

### 0.1 Cosa coprire

- **Core (must-have)** – enqueue, dequeue, esecuzione concorrente, retry, dead jobs, scheduled jobs, Web UI basilare.
- **Pro/Enterprise (should-have)** – batches, unique jobs, rate limiting, cron.
- **Nice-to-have** – embedded dashboard avanzata, metrics Prometheus, admin API REST, plugin system.

### 0.2 Stack tecnologico proposto

| Componente | Scelta | Motivo |
|------------|--------|--------|
| Linguaggio | Crystal 1.15+ | Compilato, Ruby-like, fiber-based concurrency |
| Backend queue | Redis 6+ | Stessa filosofia di Sidekiq; strutture dati già pronte (lists, sorted sets, hashes) |
| Client Redis | `stefanwille/crystal-redis` | Maturo, pooled, supporta pipelines/transactions |
| Web UI | Kemal | Leggero, DSL simile a Sinatra, già usato da progetti Crystal |
| Serializzazione | JSON | Interoperabilità con altri linguaggi; schema compatibile Sidekiq where possible |
| Testing | `crystal spec` + Redis locale | Match nativo del linguaggio |
| CLI | Built-in `OptionParser` | Nessuna dipendenza extra |
| Packaging | `shards` + Dockerfile + binary statico | Semplicità di deploy |

### 0.3 Knowledge base

Si raccomanda di mantenere aggiornata la cartella [`./crystal_knowledge`](./crystal_knowledge) con snippet, lezioni apprese e link utili durante lo sviluppo.

- [x] Popolare `crystal_knowledge/` con le sezioni minime (linguaggio, concurrency, Redis, web, testing, packaging)
- [ ] Aggiornare i file della knowledge base ogni volta che si prende una decisione tecnica non ovvia

---

## M0 – Setup e scaffold del progetto

- [x] Inizializzare `shard.yml` con nome, versione, licenza e dipendenze iniziali (`redis`, `kemal`)
- [x] Creare struttura directory: `src/morganite/`, `spec/`, `bin/`, `web/`, `config/`
- [x] Configurare `.gitignore`, `.editorconfig`, `Makefile`/`justfile` con task comuni (`build`, `test`, `run`, `fmt`, `lint`)
- [x] Scrivere il primo spec di smoke test che verifichi l’avvio del processo
- [x] Aggiungere Docker Compose con Redis per lo sviluppo locale
- [x] Definire convenzioni di naming e stile Crystal per il progetto
- [x] Aggiungere Docker Compose E2E (`docker-compose.e2e.yml`) con app esempio (`examples/demo_app/`)
- [x] Verificare che lo suite E2E passi con Podman

---

## M1 – Core queue engine

Obiettivo: un processo Morganite che preleva job da Redis e li esegue in modo concorrente.

### M1.1 Modello dati job

- [x] Definire la struct/classe `Morganite::Job` con campi: `jid`, `class`, `args`, `queue`, `created_at`, `enqueued_at`, `retry`, `retry_count`, `error_message`, `error_backtrace`, `failed_at`, `retried_at`
- [x] Implementare serializzazione/deserializzazione JSON bidirezionale
- [x] Generatore di `jid` (SecureRandom/UUID)

### M1.2 Producer (enqueue)

- [x] Implementare `Morganite::Client` per enqueue su una coda Redis list (`lpush` su `morganite:queue:<name>`)
- [x] Supportare `perform_async`, `perform_at`, `perform_in`
- [x] Implementare la coda scheduled come sorted set `morganite:scheduled` con score timestamp
- [ ] Aggiungere transaction/pipeline per ridurre round-trip Redis

### M1.3 Consumer (fetch + execute)

- [x] Implementare fetch atomico da coda con `brpop`
- [ ] Supportare `reliable fetch` con `rpoplpush` / `brpoplpush` verso una working list per evitare perdite
- [x] Implementare worker pool basato su fiber con concurrency configurabile
- [x] Eseguire il job invocando il worker registrato via `Morganite::Worker.included`
- [x] Gestire graceful shutdown base (fermare fetch al segnale)

### M1.4 Registrazione worker

- [x] Modulo `Morganite::Worker` con macro per definire `perform(args)`
- [x] Registry runtime dei worker (Hash nome -> factory proc)
- [ ] Supporto per `sidekiq_options` equivalenti (`queue`, `retry`, `backtrace`, `dead`)

### M1.5 Test

- [x] Spec per enqueue/dequeue con Redis reale
- [x] Spec per esecuzione worker
- [ ] Spec per graceful shutdown

---

## M2 – Affidabilità: retry, errori e dead jobs

### M2.1 Retry

- [x] Catturare eccezioni in `perform`
- [x] Implementare contatore `retry_count`
- [x] Rienqueue in `morganite:retry` sorted set con score = `now + backoff(retry_count)`
- [x] Implementare backoff esponenziale con jitter (default Sidekiq-like)
- [ ] Permettere override del backoff a livello di job/worker
- [x] Limitare `max_retries` (default 25)

### M2.2 Dead letter queue

- [x] Dopo max retries spostare il job in `morganite:dead` sorted set (score = now)
- [ ] Implementare `dead_max_jobs` e `dead_timeout_in_seconds`
- [x] Permettere retry manuale dalla dead queue (sposta in `morganite:queue:<name>`)
- [x] Permettere cancellazione dalla dead queue

### M2.3 Gestione errori

- [x] Salvare `error_message`, `error_backtrace`, `failed_at`, `retried_at`
- [x] Opzione `backtrace` (true/false/numero linee)
- [x] Distinguere errori ritrattabili vs non ritrattabili (es. `Morganite::Discard`)

### M2.4 Test

- [x] Spec per retry automatico
- [x] Spec per dead job dopo esaurimento retry
- [x] Spec per backoff
- [x] Spec per retry manuale dalla dead queue

---

## M3 – Scheduling e cron

### M3.1 Scheduled jobs

- [x] Processo `scheduler` (`ScheduledPoller`) che sposta job da `morganite:scheduled` alla rispettiva `morganite:queue:<name>` quando il timestamp è maturo
- [ ] Usare `zrangebyscore` + `zrem` atomica con Lua script o Redis transaction
- [x] Bilanciare frequenza polling vs latenza (configurabile, default 1s)

### M3.2 Retry poller

- [x] Processo dedicato (`RetryPoller`) che sposta job da `morganite:retry` alle code quando maturi
- [x] Riutilizzare lo stesso meccanismo dello scheduler

### M3.3 Cron (Pro-like)

- [x] Parser cron (`Morganite::CronExpression`) con supporto a `*`, `*/n`, liste, range
- [x] Schedulare istanze di job ricorrenti in `morganite:scheduled`
- [x] Persistenza dell’ultima esecuzione in Redis hash
- [ ] Gestione timezone

### M3.4 Test

- [x] Spec per job schedulato nel futuro
- [x] Spec per retry schedulato
- [x] Spec per job cron

---

## M4 – Web UI

### M4.1 Server web

- [x] Integrare Kemal nel processo Morganite (porta configurabile via `MORGANITE_WEB_PORT`)
- [x] Route `/` -> redirect a `/morganite`
- [x] Route `/morganite` -> dashboard
- [x] Stili inline per semplicità

### M4.2 Dashboard views

- [x] Vista riepilogo: code, job schedulati, retry, dead
- [x] Vista coda: lista job, pulsante delete
- [x] Vista scheduled/retry/dead: lista con pulsanti delete/retry
- [ ] Vista processi: PID, hostname, concurrency, uptime, code ascoltate
- [ ] Vista dettaglio job: payload, errori, backtrace

### M4.3 API per azioni

- [x] POST `/morganite/queues/:name/delete` – svuota coda
- [x] POST `/morganite/dead/:jid/retry` – retry dead job
- [x] POST `/morganite/dead/:jid/delete` – cancella dead job
- [x] POST `/morganite/scheduled/:jid/delete` – cancella scheduled/retry job

### M4.4 Sicurezza

- [ ] Supporto autenticazione base (username/password) opzionale
- [ ] CSRF token per azioni destructive (se necessario)

### M4.5 Test

- [x] Spec HTTP per le route principali
- [x] Spec per azioni destructive

---

## M5 – Middleware e hooks

### M5.1 Middleware server

- [x] Definire `Morganite::ServerMiddleware` con `call(job, worker, queue, next_middleware)`
- [x] Permettere registrazione globale
- [ ] Permettere registrazione per worker specifico
- [ ] Implementare esempi: logging, metrics, datadog

### M5.2 Middleware client

- [x] Definire `Morganite::ClientMiddleware` per intercettare enqueue
- [ ] Esempi pronti: logging, metadata, tracing

### M5.3 Hooks

- [x] `on_startup`, `on_shutdown`
- [x] `before_first_fetch`, `after_last_fetch`

### M5.4 Test

- [x] Spec per server middleware che avvolge l’esecuzione
- [x] Spec per client middleware che modifica job
- [x] Spec per hook lifecycle

---

## M6 – Monitoraggio e metriche

### M6.1 Logging

- [x] Logger strutturato con livelli (debug, info, warn, error)
- [x] Formato JSON opzionale per ambienti produttivi
- [x] Correlation ID/job JID nei log

### M6.2 Metriche

- [x] Contatori: jobs_processed, jobs_failed, jobs_retried, jobs_dead
- [x] Tempo di esecuzione per job (histogram)
- [x] Esportazione Prometheus `/metrics`
- [ ] Esportazione statsd opzionale (backlog)

### M6.3 Health check

- [x] Endpoint `/health` per load balancer
- [x] Verifica connettività Redis

### M6.4 Test

- [x] Spec per logger
- [x] Spec per metriche
- [x] Spec per health check e endpoint `/metrics`

---

## M7 – Funzionalità avanzate (Pro-like)

### M7.1 Unique jobs

- [ ] Blocco basato su chiave (args + queue + class) con Redis `SET NX EX`
- [ ] Strategie: while_executing, until_executed, until_expired
- [ ] Unlock al termine o in caso di errore

### M7.2 Batches (Bento-like)

- [ ] Definire `Morganite::Batch` con descrizione, callback (success, complete)
- [ ] Tracciamento contatori jobs totali/success/fail
- [ ] Callback batch eseguiti quando i contatori raggiungono la soglia

### M7.3 Rate limiting

- [ ] Limitatore basato su Redis (token bucket / sliding window)
- [ ] Configurazione per worker

### M7.4 Workflows

- [ ] Supporto per job che dipendono da altri job (chained jobs)

### M7.5 Test

- [ ] Spec per unique jobs
- [ ] Spec per batches
- [ ] Spec per rate limiting

---

## M8 – CLI, packaging e documentazione

### M8.1 CLI

- [ ] Comando `morganite` con opzioni: `--config`, `--concurrency`, `--queue`, `--require`, `--verbose`
- [ ] Comando `morganite-web` per avviare solo la Web UI
- [ ] Comando `morganite` per eseguire un job inline (debug)
- [ ] Hot reload dei worker in dev? (nice-to-have)

### M8.2 Configurazione

- [ ] File di configurazione YAML/JSON
- [ ] Variabili d’ambiente (`MORGANITE_REDIS_URL`, `MORGANITE_CONCURRENCY`, ecc.)
- [ ] Validazione config all’avvio

### M8.3 Packaging

- [ ] Dockerfile multistage per build leggera
- [ ] Script per binary statico
- [ ] Release su GitHub tramite CI
- [ ] Shard pubblico o privato?

### M8.4 Documentazione

- [ ] `README.md` con installazione, uso, API
- [ ] `docs/` per guide avanzate
- [ ] Documentare schema Redis (chiavi, sorted set, liste)
- [ ] Changelog

### M8.5 Test end-to-end

- [ ] Suite di integrazione con Redis reale
- [ ] Test di carico base (es. 10k job)
- [ ] Benchmark vs Sidekiq (opzionale)

---

## Note per chi usa questo file

1. **Completamento task**: quando un task è fatto, sostituire `[ ]` con `[x]`.
2. **Task bloccati**: aggiungere un commento `<!-- bloccato: motivo -->` sotto il task.
3. **Nuovi task**: aggiungerli nella milestone corretta o in una sezione `Backlog` in fondo.
4. **Decisioni tecniche**: documentarle in `crystal_knowledge/decisions.md`.

---

## Backlog / idee future

- [ ] Supporto multi-Redis (cluster/sentinel)
- [ ] Storage alternativo (SQLite? NATS?)
- [ ] Plugin system formale
- [ ] Admin API REST completa
- [ ] Web UI in React/Vue separata
- [ ] Integrazione con OpenTelemetry
- [ ] Job encryption dei payload
- [ ] Ottimizzazione allocazioni: valutare conversione di classi interne in `struct` (stack) dove immutabili/piccole (es. `Job`, `CronJob`)
- [ ] Pool di oggetti Crystal per entità ricorrenti (job temporanei, wrapper args) per ridurre pressione sul GC
- [ ] Profilazione con `crystal tool profile` o strumenti esterni per individuare hot spot di allocazione
