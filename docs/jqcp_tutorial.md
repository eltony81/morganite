# Tutorial JQCP: Broker, Producer, Worker e Operator in azione

JQCP (`draft-difluri-jqcp-02`, vedi [`docs/jqcp_conformance.md`](jqcp_conformance.md)
per il reference completo) definisce quattro ruoli. Questo tutorial li fa
girare tutti e quattro, dal vivo, contro un Broker Morganite reale:

| Ruolo | Cosa fa | Come lo interpretiamo qui |
|-------|---------|----------------------------|
| **Broker** | Il processo che accetta le RPC ed è l'autorità sullo stato dei Job/Queue. | Un piccolo binario Crystal: `examples/jqcp_demo/src/broker.cr`. |
| **Producer** | Crea e sottomette Job (RPC `Enqueue`). | `curl` verso `/jqcp/v1/worker/enqueue`. |
| **Worker** | Rivendica Job (`Fetch`), li esegue, riporta l'esito (`Ack`/`Fail`), rinnova la Lease (`RenewLease`). | `curl` verso `/jqcp/v1/worker/*`. |
| **Operator** | Ispeziona e amministra Broker/Queue/Job (`GetJob`, `KillJob`, `GetStats`, ...). | `curl` verso `/jqcp/v1/operator/*`. |

Nella RFC, Producer e Worker condividono la stessa API (`JobWorker`, Sezione
7) — sono due modi diversi di usarla, non due servizi separati. Operator ha
invece una API dedicata (`JobOperator`, Sezione 9). Qui li teniamo separati
solo per chiarezza didattica: nella realtà possono essere lo stesso processo,
processi diversi, o perfino linguaggi diversi (Python, Node.js, ...) — è
proprio questo il punto di un protocollo di controllo esposto su HTTP.

## Prerequisiti

- Redis in esecuzione (`redis://localhost:6379`).
- `curl` e [`jq`](https://jqlang.org/) (solo per formattare l'output, non
  richiesto dal protocollo).
- Il repository di Morganite clonato, con `shards install` già eseguito.

## 1. Avviare il Broker

`examples/jqcp_demo/src/broker.cr` è l'app più piccola possibile: registra
una classe worker (serve solo perché Morganite tiene comunque attivo il
proprio loop nativo sulla coda `--queue`, indipendente da JQCP — vedi la nota
sulle code più sotto) e poi chiama `Morganite::CLI.run`:

```crystal
require "morganite"
require "morganite/cli"

class JqcpDemoWorker
  include Morganite::Worker

  def perform(args)
  end
end

Morganite::CLI.run
```

```bash
cd examples/jqcp_demo
shards install
crystal build src/broker.cr -o bin/broker

export MORGANITE_REDIS_URL=redis://localhost:6379/0
export MORGANITE_QUEUE=default
export MORGANITE_WEB_PORT=7420
export MORGANITE_JQCP_WORKER_TOKEN=worker-secret
export MORGANITE_JQCP_OPERATOR_READ_TOKEN=read-secret
export MORGANITE_JQCP_OPERATOR_WRITE_TOKEN=write-secret

./bin/broker
```

```
launcher starting: queues=default concurrency=5
kemal: [production] Kemal is ready to lead at http://0.0.0.0:7420
```

Il Broker è ora raggiungibile su `http://localhost:7420/jqcp/v1/`, con tre
scope Bearer-token distinti (`jqcp:worker`, `jqcp:operator:read`,
`jqcp:operator:write` — Sezione 6 di `jqcp_conformance.md`).

**Nota sulle code**: il Broker gira anche il proprio worker loop nativo
(quello di `Morganite.start`), che consuma dalla coda `MORGANITE_QUEUE`
(`default` qui). Per evitare che rubi i Job a questo tutorial prima che il
Worker JQCP li veda, il Producer qui sotto li mette esplicitamente su una
coda diversa, `jqcp-demo`, che il loop nativo non tocca — sono due
consumatori indipendenti della stessa astrazione "coda Redis".

## 2. Producer: sottomettere un Job

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/worker/enqueue \
  -H "Authorization: Bearer worker-secret" \
  -H "Content-Type: application/json" \
  -d '{"job":{"type":"JqcpDemoWorker","queue":"jqcp-demo","args":[{"to":"alice@example.com"}]}}' | jq .
```

```json
{
  "jid": "2e57ece8-cc65-4f12-a520-96fe91b682e5",
  "type": "JqcpDemoWorker",
  "queue": "jqcp-demo",
  "args": [{"to": "alice@example.com"}],
  "createdAt": "2026-07-19T19:52:16Z",
  "enqueuedAt": "2026-07-19T19:52:16Z",
  "scheduledAt": null,
  "priority": 0,
  "retry": {"max": 25, "count": 0, "backoff": "BACKOFF_MODE_EXPONENTIAL"},
  "timeoutSeconds": 0,
  "maxLeaseSeconds": 0,
  "state": "JOB_STATE_ENQUEUED",
  "lastError": null
}
```

Il Broker assegna un `jid`; salvalo, serve ai passi successivi.

## 3. Worker: Hello, Fetch, Ack

Un Worker deve prima identificarsi (`Hello`) — questo crea una *Worker
Session*, distinta dallo stato di ogni singolo Job:

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/worker/hello \
  -H "Authorization: Bearer worker-secret" \
  -H "Content-Type: application/json" \
  -d '{"wid":"w-tutorial-1","queues":["jqcp-demo"],"concurrency":5}' | jq .
```

```json
{
  "priorityStrategy": {"mode": "STRICT", "weights": {}},
  "recommendedBeatIntervalSeconds": 15
}
```

Poi rivendica il Job con `Fetch` (qui una singola chiamata bloccante fino a
`jqcp_fetch_timeout_seconds`, non lo streaming reale della RFC — vedi
["Fetch (non-streaming fallback)"](jqcp_conformance.md#fetch-non-streaming-fallback)):

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/worker/fetch \
  -H "Authorization: Bearer worker-secret" \
  -H "Content-Type: application/json" \
  -d '{"wid":"w-tutorial-1"}' | jq .
```

La risposta è lo stesso Job, ora `"state": "JOB_STATE_ACTIVE"`. Il Worker lo
"esegue" (qui non fa nulla per davvero) e conferma il successo con `Ack`:

```bash
JID=2e57ece8-cc65-4f12-a520-96fe91b682e5

curl -s -X POST http://localhost:7420/jqcp/v1/worker/ack \
  -H "Authorization: Bearer worker-secret" \
  -H "Content-Type: application/json" \
  -d "{\"wid\":\"w-tutorial-1\",\"jid\":\"$JID\"}"
# {}
```

> **Attenzione alla Worker Session**: `Hello` (e `Beat`) hanno una TTL di 45
> secondi (`WorkerSession::HEARTBEAT_TTL_SECONDS`). Se segui questi comandi a
> mano con pause lunghe tra un passo e l'altro, una `Fetch`/`Ack` successiva
> può rispondere `{"reason":"unauthorized"}` semplicemente perché la sessione
> è scaduta — è successo per davvero preparando questo tutorial. Rimedio:
> richiama `Hello` (o `Beat`) per rinfrescarla, non è un errore del Broker.

## 4. Worker: un fallimento e il retry automatico

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/worker/enqueue \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"job":{"type":"JqcpDemoWorker","queue":"jqcp-demo","args":[{"to":"bob@example.com"}],"retry":{"max":3}}}' | jq -c .
# {"jid":"f08d7f89-...","state":"JOB_STATE_ENQUEUED",...}

JID_B=f08d7f89-af0d-4817-94ed-095f9b998929

curl -s -X POST http://localhost:7420/jqcp/v1/worker/fetch \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"w-tutorial-1"}' > /dev/null

curl -s -X POST http://localhost:7420/jqcp/v1/worker/fail \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d "{\"wid\":\"w-tutorial-1\",\"jid\":\"$JID_B\",\"errtype\":\"SMTP::TimeoutError\",\"message\":\"connection timed out\"}"
# {}
```

Un `GetJob` da parte dell'Operator (sotto) conferma che il Job è ora
`JOB_STATE_RETRYING`, con `retry.count` incrementato e `lastError` popolato —
il Broker lo rimetterà automaticamente in coda dopo il backoff, senza che
nessuno debba fare nulla.

## 5. Worker: un Job di lunga durata con RenewLease

`RenewLease` (Sezione 7.6/8.4, nuova in `draft-difluri-jqcp-02`) estende la
Lease di un singolo Job senza rilasciarlo — utile per lavori che durano più
di `timeoutSeconds`. È indipendente da `Beat` (che riguarda solo la
sessione): vedi la sezione ["RenewLease"](jqcp_conformance.md#renewlease) del
reference per la tabella completa degli stati.

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/worker/enqueue \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"job":{"type":"JqcpDemoWorker","queue":"jqcp-demo","args":[{"report":"annual"}],"timeoutSeconds":30,"maxLeaseSeconds":3600}}' | jq -c .

JID_C=08eecf2d-30fd-446b-9699-57a6b69354a9

curl -s -X POST http://localhost:7420/jqcp/v1/worker/fetch \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"w-tutorial-1"}' > /dev/null

# ... il worker sta ancora lavorando, ben prima dei 30s di timeoutSeconds ...
curl -s -X POST http://localhost:7420/jqcp/v1/worker/renew_lease \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d "{\"wid\":\"w-tutorial-1\",\"jid\":\"$JID_C\"}" | jq .
# {"killed": false}   <- la Lease è stata estesa, il Job resta ACTIVE

curl -s -X POST http://localhost:7420/jqcp/v1/worker/ack \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d "{\"wid\":\"w-tutorial-1\",\"jid\":\"$JID_C\"}"
# {}
```

Se il Job (o il cap `maxLeaseSeconds`) fosse stato nel frattempo terminato da
un Operator, la stessa chiamata avrebbe risposto `{"killed": true}` invece di
un errore — il Worker lo scopre entro un intervallo di rinnovo, non solo al
successivo `Ack`/`Fail` fallito.

## 6. Operator: ispezionare il Broker

```bash
curl -s http://localhost:7420/jqcp/v1/operator/get_stats \
  -H "Authorization: Bearer read-secret" | jq .
```
```json
{"processed": 2, "failed": 0, "dead": 0}
```

```bash
curl -s http://localhost:7420/jqcp/v1/operator/list_workers \
  -H "Authorization: Bearer read-secret" | jq .
```
```json
{
  "workers": [
    {
      "wid": "w-tutorial-1",
      "queues": ["jqcp-demo"],
      "concurrency": 5,
      "sessionState": "IDENTIFIED",
      "lastBeat": "2026-07-19T19:52:20Z",
      "leasedJids": []
    }
  ]
}
```

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/operator/get_job \
  -H "Authorization: Bearer read-secret" -H "Content-Type: application/json" \
  -d "{\"jid\":\"$JID_B\"}" | jq '.state, .retry'
```
```
"JOB_STATE_RETRYING"
{"max": 3, "count": 1, "backoff": "BACKOFF_MODE_EXPONENTIAL"}
```

`ListQueues` (`GET /jqcp/v1/operator/list_queues`) elenca solo le code
correntemente non vuote — Morganite non pre-dichiara le code, esistono solo
finché contengono Job.

## 7. Operator: terminare un Job (poison pill)

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/worker/enqueue \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"job":{"type":"JqcpDemoWorker","queue":"jqcp-demo","args":[{"corrupt":true}]}}' | jq -c .

JID_D=6525dcee-a407-45a1-b697-2f4e90fc873a

curl -s -X POST http://localhost:7420/jqcp/v1/worker/fetch \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"w-tutorial-1"}' > /dev/null

curl -s -X POST http://localhost:7420/jqcp/v1/operator/kill_job \
  -H "Authorization: Bearer write-secret" -H "Content-Type: application/json" \
  -d "{\"jid\":\"$JID_D\"}" | jq '.state'
# "JOB_STATE_DEAD"   <- immediato, non aspetta che il worker faccia Fail

curl -s -X POST http://localhost:7420/jqcp/v1/worker/ack \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d "{\"wid\":\"w-tutorial-1\",\"jid\":\"$JID_D\"}" | jq .
```
```json
{"reason": "job_not_found", "domain": "jqcp.morganite", "metadata": {"jid": "6525dcee-..."}}
```

L'`Ack` tardivo del Worker viene rifiutato: la Lease non esiste più, la Sua
verità sullo stato del Job appartiene solo al Broker.

> `GetStats`' `dead` conta solo le morti per esaurimento retry
> (`Fail` ripetuti), non i `KillJob` dell'Operator — per lo stato reale di un
> Job specifico usa sempre `GetJob`/`ListJobs`, non i contatori aggregati.

## Riepilogo

```
   Producer                Worker                  Operator
  (Enqueue)          (Hello/Fetch/Ack/Fail/       (GetJob/KillJob/
      |               RenewLease/Beat)              GetStats/...)
      |                      |                            |
      v                      v                            v
  +-----------------------------------------------------------+
  |                          Broker                           |
  |         (questo processo: examples/jqcp_demo)              |
  +-----------------------------------------------------------+
                              |
                              v
                            Redis
```

Per il reference completo di ogni RPC (shape esatta di richiesta/risposta,
regole di stato per stato, cosa è deliberatamente fuori scope) vedi
[`docs/jqcp_conformance.md`](jqcp_conformance.md).
