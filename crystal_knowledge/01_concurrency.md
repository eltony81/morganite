# Crystal – Concurrency per Morganite

Crystal usa un **event loop single-thread** con **fibers** cooperativi (multithreading è disponibile via `-Dpreview_mt` ma non ancora stabile).  
Per un job scheduler come Morganite è fondamentale capire come gestire worker pool, I/O e sincronizzazione.

## 1. Fiber e spawn

```crystal
spawn do
  sleep 1
  puts "done"
end

# Il main continua; il programma termina quando il main termina
# se non si attende esplicitamente.
```

Per attendere il completamento:

```crystal
channel = Channel(Nil).new
spawn do
  work
  channel.send(nil)
end
channel.receive
```

## 2. Channel

I Channel sono typed e bloccano in modo cooperativo:

```crystal
jobs = Channel(Job).new(100) # buffer 100

spawn do
  while job = jobs.receive?
    process(job)
  end
end

jobs.send(job)
```

- `send` blocca se il buffer è pieno.
- `receive?` restituisce `nil` quando il channel è chiuso.

## 3. Pattern worker pool

```crystal
class WorkerPool
  def initialize(@size : Int32, @queue : Channel(Job))
    @workers = [] of Fiber
    size.times do
      @workers << spawn { run }
    end
  end

  private def run
    while job = @queue.receive?
      job.perform
    end
  end

  def shutdown
    @queue.close
  end
end
```

Per Morganite il fetch da Redis e l’esecuzione del job dovrebbero essere in fiber separate in modo che un job lento non blocchi il fetch.

## 4. Sincronizzazione

### Mutex

```crystal
require "mutex"

mutex = Mutex.new
mutex.lock
# sezione critica
mutex.unlock
```

Oppure con block:

```crystal
mutex.synchronize do
  # sezione critica
end
```

### Atomic

Per contatori condivisi senza lock:

```crystal
require "atomic"

counter = Atomic(Int32).new(0)
counter.add(1)
```

## 5. Select

Utile per ascoltare più channel o per timeout:

```crystal
select
when job = fetch_channel.receive
  process(job)
when timeout_channel.receive
  puts "timeout"
end
```

## 6. Graceful shutdown

Pattern consigliato per Morganite:

```crystal
shutdown = Channel(Nil).new

Signal::INT.trap do
  shutdown.send(nil)
end

spawn { manager.run }

shutdown.receive
manager.stop
```

`manager.stop` deve:
1. Smettere di fare fetch da Redis.
2. Chiudere la coda interna ai worker.
3. Aspettare che i worker in corso finiscano (con un timeout).
4. Chiudere connessioni Redis.

## 7. Attenzione al multithreading preview

Con `-Dpreview_mt` le fiber possono girare su thread OS multipli.  
Per Morganite conviene inizialmente restare su single-thread e usare processi multipli per scalare orizzontalmente, come fa Sidekiq.
