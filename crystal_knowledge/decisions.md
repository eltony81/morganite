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
