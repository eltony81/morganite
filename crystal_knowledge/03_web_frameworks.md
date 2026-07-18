# Crystal – Web UI con Kemal

Per la dashboard di Morganite si propone **Kemal**, un micro-framework web simile a Sinatra.

## 1. Installazione

```yaml
dependencies:
  kemal:
    github: kemalcr/kemal
```

```crystal
require "kemal"
```

## 2. Esempio base

```crystal
require "kemal"

get "/" do
  "Morganite Web UI"
end

get "/api/queues" do |env|
  env.response.content_type = "application/json"
  { queues: ["default", "critical"] }.to_json
end

Kemal.run
```

## 3. Route con parametri

```crystal
post "/queues/:name/delete" do |env|
  name = env.params.url["name"]
  QueueService.new.clear(name)
  env.redirect("/queues")
end
```

## 4. Static files

Kemal serve automaticamente la cartella `public/`:

```
public/
  css/
    app.css
  js/
    app.js
```

Se si vuole embedded (un solo binary), includere asset come stringhe nel codice.

## 5. Middleware

```crystal
class AuthHandler < Kemal::Handler
  def call(env)
    unless authorized?(env)
      env.response.status_code = 401
      return
    end
    call_next(env)
  end
end

add_handler AuthHandler.new
```

## 6. Integrazione con Morganite

La Web UI dovrebbe essere opzionale e avviata all’interno del processo principale su porta configurabile (default 7420, come Sidekiq Web):

```crystal
module Morganite
  class Web
    def self.run(port = 7420)
      Kemal.config.port = port
      Kemal.run
    end
  end
end
```

Avviare Kemal in una fiber separata dal fetch loop.

## 7. Considerazioni

- Kemal è single-thread evented; va benissimo per una dashboard amministrativa.
- Non esporre la Web UI in produzione senza autenticazione.
- Usare `Redis::PooledClient` nelle route per non bloccare l’event loop.
