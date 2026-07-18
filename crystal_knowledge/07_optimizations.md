# Ottimizzazioni future

Questo file raccoglie idee per ottimizzare Morganite una volta che le funzionalità core saranno complete.

## 1. Ridurre le allocazioni heap

Crystal distingue:

- `class` – allocato sull'heap, reference semantics, ereditarietà.
- `struct` – allocato sullo stack, value semantics, nessuna ereditarietà.

### Candidati a diventare `struct`

| Tipo | Stato attuale | Nota |
|------|---------------|------|
| `Morganite::Job` | `class` | Immutabile dopo la creazione; candidato ideale a diventare `struct`, ma attenzione alla serializzazione JSON e all'uso come member di sorted set Redis (dove viene serializzato comunque). |
| `Morganite::Cron::Job` | `record` (già struct-like) | OK. |
| `Morganite::Configuration` | `class` | Potrebbe diventare `struct` se letta solamente. |

### Vantaggi attesi

- Meno pressione sul garbage collector.
- Maggiore località dei dati.
- Copia implicita sicura tra fiber.

### Rischi

- `struct` non può essere usata in gerarchie di tipi.
- Grandi struct copiate per valore possono diventare più lente di un puntatore heap.
- Se un oggetto viene condiviso tra fiber e modificato, serve `class`.

## 2. Pool di oggetti

Per entità create e distrutte molto spesso (job temporanei, array di args, stringhe JSON) si può valutare un pool di oggetti riutilizzabili.

In Crystal non esiste un pool standard, ma può essere implementato con un `Channel` o una lista protetta da mutex:

```crystal
module Morganite
  class ObjectPool(T)
    def initialize(@factory : -> T, @reset : T -> Nil, size : Int32)
      @pool = Channel(T).new(size)
      size.times { @pool.send(@factory.call) }
    end

    def with(& : T ->)
      obj = @pool.receive
      begin
        yield obj
      ensure
        @reset.call(obj)
        @pool.send(obj)
      end
    end
  end
end
```

### Candidati al pool

- Buffer `IO::Memory` per la serializzazione JSON.
- Array temporanei usati per args.
- Oggetti `Job` intermedi se rimangono `class`.

## 3. Profilazione

Strumenti utili:

- `crystal tool profile <programma>` – profiler integrato.
- Valgrind / perf su Linux per analizzare allocazioni.
- Benchmark end-to-end con `examples/demo_app/`.

## 4. Ottimizzazioni Redis

- Pipeline per enqueue multipli.
- `BRPOPLPUSH` per reliable fetch.
- Lua script atomico per spostare job da sorted set a lista.

## Decisioni

Nessuna ancora presa; queste voci sono in backlog e verranno rivalutate dopo il completamento delle milestone funzionali.
