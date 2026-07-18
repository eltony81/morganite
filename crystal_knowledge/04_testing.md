# Crystal – Testing per Morganite

Crystal include un framework di test integrato, simile a RSpec.

## 1. Struttura

```
spec/
  spec_helper.cr
  morganite/
    client_spec.cr
    worker_spec.cr
    retry_spec.cr
    web_spec.cr
```

## 2. Spec helper

```crystal
require "spec"
require "../src/morganite"

Spec.before_each do
  RedisCleaner.flush
end
```

## 3. Sintassi base

```crystal
require "./spec_helper"

describe Morganite::Job do
  it "serializes to JSON" do
    job = Morganite::Job.new(class: "MyWorker", args: [1, 2], queue: "default")
    json = job.to_json
    json.should contain("\"class\":\"MyWorker\"")
  end
end
```

## 4. Test con Redis

Opzioni:

1. **Redis locale su DB 15**: pulire prima di ogni test.
2. **Testcontainers / Docker**: avviare Redis in un container dedicato.
3. **Fake Redis**: non consigliato; il comportamento reale è troppo diverso.

Esempio helper:

```crystal
class RedisCleaner
  @@redis = Redis.new

  def self.flush
    @@redis.flushdb
  end
end
```

## 5. Factory per job

```crystal
module JobFactory
  def self.build(**args)
    Morganite::Job.new(
      jid: args[:jid]? || "test-#{Random.new.hex(4)}",
      class: args[:class]? || "TestWorker",
      args: args[:args]? || [] of JSON::Any,
      queue: args[:queue]? || "default"
    )
  end
end
```

## 6. Test worker

```crystal
class TestWorker
  include Morganite::Worker

  def perform(args)
    @@called = true
  end

  def self.called?
    @@called
  end
end

describe TestWorker do
  it "processes a job" do
    job = JobFactory.build(class: "TestWorker")
    Morganite::Processor.new.process(job)
    TestWorker.called?.should be_true
  end
end
```

## 7. Test Web UI

Usare `HTTP::Client` contro Kemal avviato su una porta effimera:

```crystal
spawn { Kemal.run(9090) }
sleep 0.1

response = HTTP::Client.get("http://localhost:9090/morganite")
response.status_code.should eq(200)
```

## 8. Best practice

- Tenere i test veloci; evitare `sleep` arbitrari.
- Usare `Spec.after_each` per pulire lo stato globale.
- Raggruppare i test per feature.
