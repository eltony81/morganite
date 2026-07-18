# Schema Redis di riferimento (Sidekiq)

Questo file descrive come Sidekiq usa Redis. Morganite può adottare lo stesso schema per massimare compatibilità o replicarlo con prefisso `morganite:`.

## Chiavi principali

| Chiave Sidekiq | Tipo Redis | Scopo |
|----------------|-----------|-------|
| `queue:<name>` | List | Job pronti |
| `retry` | Sorted set | Job da riprovare (score = retry_at) |
| `schedule` | Sorted set | Job schedulati (score = at) |
| `dead` | Sorted set | Dead jobs (score = died_at) |
| `processes` | Set | Identificativi processi attivi |
| `workers` | Hash | Worker busy per processo |
| `stats` | Hash | Contatori (processed, failed, enqueued, ...) |
| `<pid>:workers` | Hash | Dettaglio job in esecuzione per processo |
| `<pid>:workers:started` | String | Timestamp avvio processo |

## Dettagli operativi

### Enqueue

```
LPUSH queue:default <json_job>
```

### Fetch reliable (Sidekiq Pro)

```
BRPOPLPUSH queue:default queue:default:backup timeout
```

Dopo l’esecuzione:
```
LREM queue:default:backup 0 <json_job>
```

### Retry

Quando un job fallisce:
```
ZADD retry <next_time> <json_job>
HINCRBY stats failed 1
```

### Scheduler loop

```
ZRANGEBYSCORE retry -inf <now> LIMIT 0 1
-- per ogni job maturo
ZREM retry <json_job>
LPUSH queue:<name> <json_job>
```

## Schema proposto per Morganite

```
morganite:queue:<name>      # List
morganite:retry             # Sorted set
morganite:scheduled         # Sorted set
morganite:dead              # Sorted set
morganite:processes         # Set
morganite:stats             # Hash
morganite:unique:<key>      # String (lock unique jobs)
```

Vantaggi:
- Namespace pulito per coesistere con Sidekiq nella stessa istanza Redis.
- Facile backup/restore.
- Compatibilità futura opzionale con client Sidekiq.
