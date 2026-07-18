# Crystal – Redis per Morganite

Morganite usa Redis come backend. Questo file raccoglie pattern e libreria utili.

## 1. Libreria consigliata

- **Shard**: `redis`
- **Repository**: `github: jgaskins/redis`
- **Versione**: `~> 0.13`

```yaml
dependencies:
  redis:
    github: jgaskins/redis
```

```crystal
require "redis"
```

Questo client è puro Crystal, include già un connection pool ed è compatibile con le versioni recenti di Crystal.

## 2. Client e connection pool

```crystal
redis = Redis::Client.new                      # localhost:6379
redis = Redis::Client.new(URI.parse(url))      # da URL
redis = Redis::Client.from_env("REDIS_URL")    # da variabile d'ambiente
```

Il `Redis::Client` gestisce automaticamente un pool di connessioni, quindi è safe condividerlo tra più fiber.

## 3. Comandi principali per le code

### Lista come coda

```crystal
redis.lpush("queue:default", job.to_json)           # producer
job_json = redis.brpop("queue:default", 2)         # consumer bloccante, timeout 2s
```

### Sorted set per scheduled/retry

```crystal
redis.zadd("morganite:scheduled", score, job.to_json)
mature = redis.zrangebyscore("morganite:scheduled", "-inf", Time.utc.to_unix.to_s)
```

### Hash per metadati

```crystal
redis.hset("morganite:stats", "processed", count.to_s)
```

## 4. Pipeline e transaction

### Pipeline

Riduce i round-trip:

```crystal
redis.pipelined do |pipe|
  pipe.lpush("queue:default", job1.to_json)
  pipe.lpush("queue:default", job2.to_json)
end
```

### Transaction

```crystal
redis.multi do |tx|
  tx.lpush("queue:default", job.to_json)
  tx.incr("morganite:stats:enqueued")
end
```

## 5. Lua per operazioni atomiche

Spostare job da sorted set a lista in modo atomico:

```lua
local jobs = redis.call('zrangebyscore', KEYS[1], ARGV[1], ARGV[2])
for _, job in ipairs(jobs) do
  redis.call('lpush', ARGV[3], job)
  redis.call('zrem', KEYS[1], job)
end
return jobs
```

In Crystal:

```crystal
script = <<-LUA
  local jobs = redis.call('zrangebyscore', KEYS[1], ARGV[1], ARGV[2])
  ...
LUA
redis.eval(script, keys, args)
```

## 6. Schema dati proposto per Morganite

| Chiave | Tipo | Scopo |
|--------|------|-------|
| `queue:<name>` | List | Coda pronta per l’esecuzione |
| `morganite:scheduled` | Sorted set | Job da eseguire in futuro (score = timestamp) |
| `morganite:retry` | Sorted set | Job in retry (score = retry_at) |
| `morganite:dead` | Sorted set | Dead jobs (score = died_at) |
| `morganite:processes` | Set | Processi attivi (`hostname:pid`) |
| `morganite:workers` | Hash | Info worker per processo |
| `morganite:stats` | Hash | Contatori globali |
| `morganite:unique:<key>` | String | Lock per unique jobs |

## 7. Connection pool e thread safety

- `Redis::PooledClient` è thread/fiber safe.
- Non condividere una `Redis` singola tra fiber in scrittura concorrente.
- Nella Web UI usare un pool dedicato.

## 8. Testing

Per i test utilizzare Redis locale su DB separato (es. `SELECT 15`) oppure un container Redis temporaneo.  
Pulire sempre le chiavi usate in `before_each`/`after_each`.
