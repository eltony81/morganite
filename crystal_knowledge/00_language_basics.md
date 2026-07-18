# Crystal – Concetti base per Morganite

Crystal è un linguaggio compilato, type-safe, con sintassi molto simile a Ruby.  
Di seguito i concetti più rilevanti per scrivere Morganite.

## 1. Tipi fondamentali

```crystal
name : String = "Morganite"
count : Int32 = 0
enabled : Bool = true
payload : Hash(String, JSON::Any) = {} of String => JSON::Any
```

- I tipi sono inferiti ma possono essere annotati.
- Le variabili nilabili richiedono `?` e un nil-check prima dell’uso.

```crystal
maybe : String? = nil
if maybe
  puts maybe.upcase # OK, il compilatore sa che non è nil
end
```

## 2. Classi vs Struct

```crystal
class Job
  property jid : String
  property queue : String

  def initialize(@jid : String, @queue : String)
  end
end
```

- `class` -> allocazione heap, reference semantics, permette ereditarietà.
- `struct` -> allocazione stack, value semantics, più performante ma non supporta ereditarietà.

Per i payload immutabili piccoli (es. configurazione) preferire `struct`; per job che devono essere condivisi tra fiber usare `class`.

## 3. Moduli e mixin

```crystal
module Worker
  macro included
    # Registra la classe che include il modulo
    Morganite::WorkerRegistry.register({{@type.name.stringify}}, {{@type}})
  end
end

class MyWorker
  include Worker

  def perform(args : Array(JSON::Any))
    # ...
  end
end
```

## 4. Macro base

Le macro sono eseguite a compile time:

```crystal
macro define_accessor(name)
  def {{name.id}}
    @{{name.id}}
  end
end

define_accessor count
```

Attenzione: le macro non sono sostituti per il codice runtime. Usale per ridurre boilerplate.

## 5. JSON

Crystal ha un parser/generatore JSON nel core:

```crystal
require "json"

struct JobPayload
  include JSON::Serializable

  property jid : String
  property class : String
  property args : Array(JSON::Any)
  property queue : String
end
```

`JSON::Serializable` genera automaticamente `to_json` e `from_json`.  
Per campi opzionali usare `property?` o `@[JSON::Field(ignore: true)]`.

## 6. Eccezioni

```crystal
begin
  risky_call
rescue ex : SpecificError
  puts ex.message
rescue ex : Exception
  puts "generic: #{ex.message}"
ensure
  cleanup
end
```

## 7. Differenze chiave con Ruby

- **Compilazione**: errori di tipo vengono catturati prima del runtime.
- **Type system**: union types (`String | Int32`), type inference, nil safety.
- **Macro**: potenti ma con sintassi diversa (`{{ ... }}` e `{% ... %}`).
- **Concurrency**: basata su fiber e event loop, non su thread OS.
- **Gems -> Shards**: gestite da `shard.yml` e `shards install`.

## 8. Convenzioni stile

- Nomi file: `snake_case.cr`
- Classi/Moduli: `PascalCase`
- Metodi/variabili: `snake_case`
- Costanti: `SCREAMING_SNAKE_CASE`
- Formattatore ufficiale: `crystal tool format`
