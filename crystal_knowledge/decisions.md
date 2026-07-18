# Decision Log (ADR minimale)

Usare questo file per registrare decisioni tecniche non ovvie.

## Template

```markdown
### YYYY-MM-DD – Titolo decisione

- **Contesto**: perché dovevamo decidere
- **Opzioni**: elenco opzioni considerate
- **Decisione**: cosa abbiamo scelto
- **Conseguenze**: trade-off
- **Reversibilità**: alta/media/bassa
```

## Decisioni

### 2026-07-18 – Scelta del client Redis

- **Contesto**: la libreria `stefanwille/crystal-redis` non compila con Crystal 1.20.2 (errore interno su `String#each`).
- **Opzioni**: cercare un fork compatibile, usare `jgaskins/redis`, scrivere un client ad-hoc.
- **Decisione**: adottare `jgaskins/redis` (`~> 0.13.0`).
- **Conseguenze**:
  - Client puro Crystal con connection pool integrato.
  - API leggermente diversa (`Redis::Client.new(URI)`, `brpop(key, timeout:)`).
  - Immagine Docker può restare su `crystallang/crystal:1.15.0-alpine` (codice compatibile).
- **Reversibilità**: alta – il client è incapsulato in una sottile astrazione di Morganite.

### 2026-07-18 – Registrazione dei worker

- **Contesto**: serve una registry runtime che mappi il nome del worker (stringa nel job JSON) alla classe da istanziare.
- **Opzioni**: `Hash(String, Worker.class)`, `Hash(String, WorkerFactory proc)`.
- **Decisione**: usare `Hash(String, WorkerFactory)` con proc `-> { MyWorker.new.as(Worker) }`.
- **Conseguenze**:
  - In Crystal il metaclass di una classe che include un modulo non è sottotipo del metaclass del modulo, quindi `Worker.class` non può contenere `MyWorker.class`.
  - La factory consente istanziazione type-safe senza dover conoscere il tipo esatto a compile time.
- **Reversibilità**: media – il proc è leggermente più verboso ma isolato in `WorkerRegistry`.

### 2026-07-18 – Namespace Redis

- **Contesto**: Morganite deve poter convivere con Sidekiq nella stessa istanza Redis.
- **Decisione**: usare prefisso `morganite:` per tutte le chiavi (es. `morganite:queue:<name>`, `morganite:scheduled`).
- **Conseguenze**: nessun conflitto con Sidekiq; leggermente più verboso.
- **Reversibilità**: alta – centralizzato nei metodi `queue_key` e nelle costanti.

### 2026-07-18 – Refactoring concorrenza

- **Contesto**: il task parallelo di review ha evidenziato anti-pattern: `while @running`, connessione Redis condivisa tra fiber, busy wait in `Morganite.wait`, nuova connessione per ogni enqueue.
- **Decisione**:
  - Introdotto `Morganite::RedisPool` basato su `Channel(Redis::Client)`.
  - Refactor di `Launcher` con un fetcher dedicato in una fiber, worker pool che consuma da `Channel(String)`, shutdown via `@jobs.close` e sincronizzazione con `@done`.
  - `RetryPoller` usa `select` con `@shutdown` e `timeout` per reagire immediatamente allo stop.
  - `Client` usa `Morganite.pool.with`.
  - `Morganite.wait` usa un `Channel(Nil)` invece di `loop { sleep }`.
- **Conseguenze**: codice più idiomatico Crystal, shutdown graceful, nessuna connessione Redis condivisa in scrittura concorrente.
- **Reversibilità**: media – il pool è una astrazione interna, sostituibile.

### 2026-07-18 – Gestione errori e retry

- **Contesto**: M2 richiede retry con backoff, dead queue e distinzione errori ritrattabili.
- **Decisione**:
  - `Morganite::Retry` calcola backoff Sidekiq-like e massimo retry.
  - `Morganite::Failures` sposta job in `morganite:retry` o `morganite:dead`.
  - `Morganite::RetryPoller` sposta job maturi da retry a queue.
  - Eccezione `Morganite::Discard` fa saltare retry/dead.
- **Conseguenze**: retry automatico funzionante, dead queue accessibile via API/Client.
- **Reversibilità**: alta – la logica è isolata in moduli dedicati.

### 2026-07-18 – Ottimizzazioni future (pianificazione)

- **Contesto**: suggerimento di ottimizzare allocazioni heap e uso del GC a fine sviluppo funzionale.
- **Decisione**: non applicare ora, ma pianificare in backlog.
  - Valutare conversione di `Morganite::Job` e altre entità immutabili da `class` a `struct`.
  - Valutare introduzione di pool di oggetti per entità ad alto turnover (job temporanei, buffer JSON).
  - Usare `crystal tool profile` e benchmark E2E per guidare le scelte.
- **Conseguenze**: nessuna modifica immediata; evita ottimizzazioni premature.
- **Reversibilità**: alta – le decisioni verranno prese con dati di profilazione.

### 2026-07-18 – Scheduling e cron

- **Contesto**: M3 richiede scheduled jobs, retry poller e cron.
- **Decisione**:
  - `ScheduledPoller` sposta job maturi da `morganite:scheduled` alle code.
  - `RetryPoller` (già introdotto in M2) usa lo stesso pattern.
  - Parser cron implementato internamente come `Morganite::CronExpression` per evitare dipendenze esterne potenzialmente non compatibili.
  - `CronScheduler` registra job ricorrenti, ne calcola il prossimo istante e li inserisce in `morganite:scheduled`, salvando l’ultima esecuzione in un hash Redis.
  - Macro `cron` nel modulo `Worker` per dichiarare espressioni ricorrenti nelle classi worker.
- **Conseguenze**: scheduling e cron funzionanti senza shard aggiuntivi; timezone non ancora supportata.
- **Reversibilità**: media – il parser interno può essere sostituito da uno shard specializzato in futuro.

### 2026-07-18 – Web UI

- **Contesto**: M4 richiede una dashboard per monitorare code e job.
- **Decisione**:
  - Usare Kemal come web framework.
  - Aggiornare Kemal a `~> 1.11.0` per compatibilità con Crystal 1.20.
  - Web UI avviata all'interno del processo `Launcher` su porta configurabile (default 7420).
  - HTML generato inline con `String.build` per evitare dipendenze da motori di template.
  - Route per dashboard, dettaglio coda, azioni delete/retry.
- **Conseguenze**: nessuna dipendenza extra; UI minimale ma funzionante. Autenticazione e CSRF rimandati a future iterazioni.
- **Reversibilità**: alta – le route e le view sono isolate in `Morganite::Web`.

### 2026-07-18 – Middleware e hooks

- **Contesto**: M5 richiede punti di estensione lato server, client e lifecycle.
- **Decisione**:
  - `Morganite::ServerMiddleware` con pattern chain-of-responsibility: ogni middleware riceve `job`, `worker`, `queue` e una proc `next_middleware`.
  - `Morganite::ClientMiddleware` stesso pattern per intercettare `enqueue`/`schedule`.
  - `Morganite::Hooks` con callback `on_startup`, `on_shutdown`, `before_first_fetch`, `after_last_fetch`.
  - `Launcher` invoca `run_startup`, `run_before_first_fetch` (una sola volta tramite `Atomic`), `run_after_last_fetch` e `run_shutdown`.
- **Conseguenze**: l’API usa `Proc(Nil)` esplicita invece di blocchi catturati per evitare un bug del compilatore Crystal 1.20.2 con `&block : -> Nil` in combinazione con metodi astratti.
- **Reversibilità**: alta – middleware e hook sono opzionali e non influenzano il flusso base.

### 2026-07-18 – Unique jobs

- **Contesto**: M7.1 richiede di evitare l'esecuzione/concorrenza di job duplicati basandosi su worker class + queue + args.
- **Opzioni**: lock lato Redis con `SET NX EX`, lock in-memory, o chiave derivata solo dal payload.
- **Decisione**:
  - Creato `Morganite::UniqueJobs` con chiave `morganite:unique:<sha256(class|queue|args.to_json)>`.
  - Tre strategie:
    - `while_executing`: lock acquisito dal `Processor` prima dell'esecuzione e rilasciato in `ensure`.
    - `until_executed`: lock acquisito dal `Client` in fase di enqueue; rilasciato dal `Processor` solo al successo, o in caso di dead/discard.
    - `until_expired`: lock acquisito dal `Client` con TTL (`unique_for`, default 300s) e rilasciato automaticamente da Redis.
  - Il `Client` restituisce `Job?`: `nil` quando il lock è già presente per `until_executed`/`until_expired`; `while_executing` permette l'enqueue e blocca solo l'esecuzione.
  - Aggiunta macro `unique :strategia, ttl: N` nel modulo `Worker` per dichiarare la strategia a livello di worker.
- **Conseguenze**: nessun job duplicato nelle combinazioni dichiarate; il lock è distribuito e sopravvive a più processi Morganite. `while_executing` usa un TTL per evitare lock fantasma in caso di crash del processo; `until_executed` invece usa un lock senza scadenza, persistente attraverso i retry.
- **Reversibilità**: media – la logica è concentrata in `UniqueJobs`, `Client` e `Processor`, ma richiede un campo aggiuntivo su `Job`.

### 2026-07-18 – Logging, metriche e health check

- **Contesto**: M6 richiede osservabilità per produzione.
- **Decisione**:
  - `Morganite::Logger` custom con livelli, formato testo/JSON, `jid` e `correlation_id`. Output default su `STDERR`.
  - `Morganite::Metrics` in-memory con `Mutex`, contatori e histogram; esportazione Prometheus su `/metrics`.
  - Endpoint `/health` nel Web UI che pinga Redis e ritorna JSON.
  - Configurazione tramite `MORGANITE_LOG_LEVEL` e `MORGANITE_LOG_FORMAT`.
- **Conseguenze**: le metriche sono in-memory (non persistenti); se si avviano più processi Morganite, ognuno ha i propri contatori. Per produzione con più repliche serve un aggregatore esterno (Prometheus scrape per pod).
- **Reversibilità**: media – i log sono centralizzati in `Logger` e le metriche in `Metrics`, facili da sostituire con librerie esterne.
