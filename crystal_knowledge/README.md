# Crystal Knowledge Base

Questa cartella raccoglie conoscenza, snippet e decisioni tecniche sul linguaggio Crystal, utili durante lo sviluppo di Morganite.

## Perché esiste

Morganite è scritto in Crystal, un linguaggio relativamente giovane con un ecosistema più piccolo di Ruby.  
Tenere qui note concrete velocizza lo sviluppo e aiuta OpenCode a mantenere coerenza tra iterazioni.

## Indice

| File | Contenuto |
|------|-----------|
| [`00_language_basics.md`](./00_language_basics.md) | Sintassi, tipi, classi/struct, macro, JSON, differenze chiave con Ruby |
| [`01_concurrency.md`](./01_concurrency.md) | Fibers, Channels, spawn, select, mutex, best practice per worker pool |
| [`02_redis.md`](./02_redis.md) | Client Redis in Crystal, connection pool, pipeline, transaction, Lua, schema dati |
| [`03_web_frameworks.md`](./03_web_frameworks.md) | Kemal: routing, middleware, static files, integrazione con Morganite |
| [`04_testing.md`](./04_testing.md) | `crystal spec`, mocking, test con Redis, factory/job helper |
| [`05_packaging_deployment.md`](./05_packaging_deployment.md) | `shard.yml`, build, binary statico, Docker, CI |
| [`06_sidekiq_redis_schema.md`](./06_sidekiq_redis_schema.md) | Come Sidekiq usa Redis; riferimento per replicare lo schema in Morganite |
| [`99_references.md`](./99_references.md) | Link utili ufficiali e della community |
| [`decisions.md`](./decisions.md) | Log delle decisioni tecniche (ADR minimali) |

## Come usarla

- Leggi `00_language_basics.md` e `01_concurrency.md` se arrivi da Ruby.
- Aggiorna `decisions.md` ogni volta che viene presa una scelta non ovvia (es. "usiamo `brpop` invece di Redis Streams").
- Aggiungi snippet nuovi quando scopri pattern utili.
