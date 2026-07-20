# Tutorial JQCP: Broker, Producer, Worker e Operator in azione

JQCP (`draft-difluri-jqcp-02`, vedi [`docs/jqcp_conformance.md`](jqcp_conformance.md)
per il reference completo) definisce quattro ruoli. Questo tutorial li fa
girare tutti e quattro, dal vivo, contro un Broker Morganite reale:

| Ruolo | Cosa fa | Come lo interpretiamo qui |
|-------|---------|----------------------------|
| **Broker** | Il processo che accetta le RPC ed è l'autorità sullo stato dei Job/Queue. | Un binario Crystal reale: `examples/jqcp_demo/src/broker.cr`. |
| **Producer** | Crea e sottomette Job (RPC `Enqueue`). | Un binario Crystal reale: `examples/jqcp_demo/src/producer.cr`. |
| **Worker** | Rivendica Job (`Fetch`), li esegue, riporta l'esito (`Ack`/`Fail`), rinnova la Lease (`RenewLease`). | Un binario Crystal reale: `examples/jqcp_demo/src/worker.cr`. |
| **Operator** | Ispeziona e amministra Broker/Queue/Job (`GetJob`, `KillJob`, `GetStats`, ...). | `curl` verso `/jqcp/v1/operator/*`. |

Nella RFC, Producer e Worker condividono la stessa API (`JobWorker`, Sezione
7) — sono due modi diversi di usarla, non due servizi separati. Operator ha
invece una API dedicata (`JobOperator`, Sezione 9); qui resta `curl` perché
è esattamente così che la useresti in pratica — comandi occasionali di
ispezione/amministrazione, non un processo che gira in permanenza.

`producer.cr` e `worker.cr` **non** dipendono dallo shard `morganite`: usano
solo `http/client`+`json` della stdlib di Crystal e parlano al Broker via
JSON-over-HTTP puro. È voluto — un Producer o un Worker JQCP può essere
scritto in un linguaggio completamente diverso (Python, Node.js, ...) e
funzionare identicamente, perché tutto quello che serve è chiamare degli
endpoint HTTP con JSON. Il Worker "nativo" di Morganite (`include
Morganite::Worker`, quello di `docs/usage.md`) è un sistema **separato**,
interno al processo Broker: le due cose coesistono ma non si parlano.

## Prerequisiti

- Redis in esecuzione (`redis://localhost:6379`).
- `curl` e [`jq`](https://jqlang.org/) (solo per formattare l'output, non
  richiesto dal protocollo).
- Il repository di Morganite clonato.

## 1. Build e deploy del Broker

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
Worker JQCP li veda, Producer e Worker qui sotto usano esplicitamente una
coda diversa, `jqcp-demo`, che il loop nativo non tocca — sono due
consumatori indipendenti della stessa astrazione "coda Redis".

## 2. Build e deploy del Producer

`producer.cr` sottomette un piccolo lotto di Job realistici: alcuni
`SendEmailJob` (task breve) e un `GenerateReportJob` (task lungo, con
`timeoutSeconds`/`maxLeaseSeconds` impostati per il passo 5).

```bash
crystal build src/producer.cr -o bin/producer

export JQCP_BROKER_URL=http://localhost:7420
export JQCP_WORKER_TOKEN=worker-secret
export JQCP_QUEUE=jqcp-demo

./bin/producer 4   # invia 4 SendEmailJob + 1 GenerateReportJob
```

```
Producer: submitting 4 SendEmailJob to queue 'jqcp-demo' on http://localhost:7420
  enqueued jid=2c1be5eb-678d-408d-b858-b4a26df04e16 to=alice@example.com
  enqueued jid=d2c620d0-2f91-46b6-9a27-16e293c73e60 to=carol@example.com
  enqueued jid=5c768ec4-62b6-42ee-9c71-32945828809c to=alice@example.com
  enqueued jid=9785fb26-1a44-4bb5-a90f-c0aef1dbf668 to=carol@example.com
Producer: submitting 1 GenerateReportJob (long-running: timeoutSeconds=30, maxLeaseSeconds=3600)
  enqueued jid=638af33f-13ba-497a-8782-f42b07486406
Producer: done.
```

## 3. Build e deploy del Worker

`worker.cr` fa `Hello`, poi entra in un loop: `Fetch` (bloccante e
non-streaming, vedi ["Fetch (non-streaming fallback)"](jqcp_conformance.md#fetch-non-streaming-fallback)),
esegue il Job in base al `type`, riporta `Ack`/`Fail`, e chiama `Beat` ogni
15s per mantenere viva la propria Worker Session. `SendEmailJob` viene
simulato con un piccolo sleep e un 20% di probabilità di `Fail` (per vedere
il retry automatico); `GenerateReportJob` chiama `RenewLease` ogni 10
secondi finché non finisce.

```bash
crystal build src/worker.cr -o bin/worker

export JQCP_BROKER_URL=http://localhost:7420
export JQCP_WORKER_TOKEN=worker-secret
export JQCP_QUEUE=jqcp-demo
export JQCP_WORKER_MAX_JOBS=5   # solo per questo giro dimostrativo: esce dopo 5 job invece di girare per sempre

./bin/worker w-tutorial-A
```

```
Worker[w-tutorial-A]: Hello (queues=[jqcp-demo])
Worker[w-tutorial-A]: fetched SendEmailJob jid=2c1be5eb-678d-408d-b858-b4a26df04e16
  -> sent to alice@example.com, Ack
Worker[w-tutorial-A]: fetched SendEmailJob jid=d2c620d0-2f91-46b6-9a27-16e293c73e60
  -> sent to carol@example.com, Ack
Worker[w-tutorial-A]: fetched SendEmailJob jid=5c768ec4-62b6-42ee-9c71-32945828809c
  -> sent to alice@example.com, Ack
Worker[w-tutorial-A]: fetched SendEmailJob jid=9785fb26-1a44-4bb5-a90f-c0aef1dbf668
  -> simulated SMTP timeout sending to carol@example.com, reporting Fail
Worker[w-tutorial-A]: fetched GenerateReportJob jid=638af33f-13ba-497a-8782-f42b07486406
  -> generating report (long job), RenewLease every 10s
  -> lease renewed
  -> lease renewed
  -> lease renewed
  -> report done, Ack
Worker[w-tutorial-A]: processed 5 job(s), exiting
```

In un deployment reale ometti `JQCP_WORKER_MAX_JOBS` e lascia girare il
processo (fermalo con Ctrl-C); puoi lanciare più istanze con `wid` diversi
per parallelizzare — sono sessioni indipendenti sullo stesso Broker.

> **Attenzione alla Worker Session**: `Hello`/`Beat` hanno una TTL di 45
> secondi (`WorkerSession::HEARTBEAT_TTL_SECONDS`). Se tra un passo e
> l'altro di questo tutorial (o tra la fine del Worker e la tua prossima
> chiamata da Operator) passano più di 45s senza un `Hello`/`Beat`, la
> sessione scade per davvero — è successo mentre preparavo questo tutorial:
> `ListWorkers` sotto è risultato vuoto perché erano passati più di 45s.
> Non è un errore: la Lease dei singoli Job non è in discussione (il Job
> fallito è comunque tornato automaticamente in coda, vedi sotto), solo la
> sessione del Worker che l'aveva presa in carico.

## 4. Operator: ispezionare il Broker

```bash
curl -s http://localhost:7420/jqcp/v1/operator/get_stats \
  -H "Authorization: Bearer read-secret" | jq .
```
```json
{"processed": 4, "failed": 0, "dead": 0}
```

`processed` conta i 3 `SendEmailJob` andati a buon fine più il
`GenerateReportJob` — il quarto `SendEmailJob` (quello fallito) non è ancora
`processed`: è tornato automaticamente in `JOB_STATE_ENQUEUED` dopo il
backoff, pronto per un nuovo `Fetch`.

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/operator/get_job \
  -H "Authorization: Bearer read-secret" -H "Content-Type: application/json" \
  -d '{"jid":"9785fb26-1a44-4bb5-a90f-c0aef1dbf668"}' | jq '.state, .retry, .lastError'
```
```
"JOB_STATE_ENQUEUED"
{"max": 3, "count": 1, "backoff": "BACKOFF_MODE_EXPONENTIAL"}
{"errtype": "SMTP::TimeoutError", "message": "connection timed out", "backtrace": [], "failedAt": "2026-07-20T16:26:53Z"}
```

Nessuno ha dovuto rilanciarlo a mano: il Broker lo ha rimesso in coda da
solo dopo il backoff. `ListQueues` (`GET /jqcp/v1/operator/list_queues`)
elenca solo le code correntemente non vuote — Morganite non pre-dichiara le
code, esistono solo finché contengono Job.

## 5. Operator: terminare un Job (poison pill)

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/worker/enqueue \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"job":{"type":"SendEmailJob","queue":"jqcp-demo","args":[{"to":"broken@example.com","subject":"corrupt"}]}}' | jq -c .
# {"jid":"d114218f-...","state":"JOB_STATE_ENQUEUED",...}

JID_D=d114218f-d065-4d38-87be-ff759c2380c0

curl -s -X POST http://localhost:7420/jqcp/v1/worker/fetch \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"w-tutorial-A"}' > /dev/null

curl -s -X POST http://localhost:7420/jqcp/v1/operator/kill_job \
  -H "Authorization: Bearer write-secret" -H "Content-Type: application/json" \
  -d "{\"jid\":\"$JID_D\"}" | jq '.state'
# "JOB_STATE_DEAD"   <- immediato, non aspetta un Fail dal Worker

curl -s -X POST http://localhost:7420/jqcp/v1/worker/ack \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d "{\"wid\":\"w-tutorial-A\",\"jid\":\"$JID_D\"}" | jq .
```
```json
{"reason": "job_not_found", "domain": "jqcp.morganite", "metadata": {"jid": "d114218f-..."}}
```

L'`Ack` tardivo del Worker viene rifiutato: la Lease non esiste più, la
verità sullo stato del Job appartiene solo al Broker.

> `GetStats`' `dead` conta solo le morti per esaurimento retry (`Fail`
> ripetuti), non i `KillJob` dell'Operator — per lo stato reale di un Job
> specifico usa sempre `GetJob`/`ListJobs`, non i contatori aggregati.

## 6. Test end-to-end: un worker con un carico di elaborazione pesante

`worker_heavy_load.cr` non simula il lavoro con uno `sleep`: conta davvero i
numeri primi per trial division fino a `HEAVY_PRIMES_UPTO` (default
3.000.000), a blocchi (`HEAVY_CHUNKS`, default 5), chiamando `RenewLease` tra
un blocco e l'altro. Serve a dimostrare che la Lease sopravvive a lavoro CPU
reale e prolungato, non solo ad attese I/O.

```bash
crystal build src/worker_heavy_load.cr -o bin/worker_heavy_load

# timeoutSeconds deliberatamente corto rispetto al lavoro totale: il punto
# è proprio che RenewLease lo estende ben oltre.
curl -s -X POST http://localhost:7420/jqcp/v1/worker/enqueue \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"job":{"type":"HeavyComputeJob","queue":"jqcp-demo","args":[{"task":"prime-count"}],"timeoutSeconds":60,"maxLeaseSeconds":600}}' | jq -c '.jid, .timeoutSeconds'
# "c63d0b19-...", 60

curl -s -X POST http://localhost:7420/jqcp/v1/worker/hello \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"worker-heavy-2","queues":["jqcp-demo"],"concurrency":1}' > /dev/null
curl -s -X POST http://localhost:7420/jqcp/v1/worker/fetch \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"worker-heavy-2"}' > /dev/null

export JQCP_BROKER_URL=http://localhost:7420
export JQCP_WORKER_TOKEN=worker-secret
export HEAVY_CHUNKS=5
export HEAVY_PRIMES_UPTO=3000000

./bin/worker_heavy_load worker-heavy-2 c63d0b19-c530-4b9e-afb7-3009d1606d8f
```

```
Worker[worker-heavy-2]: heavy-load run on jid=c63d0b19-..., 5 chunks of trial-division primes up to 3000000
  chunk 1/5: found 216816 primes in 2.17s (real CPU work, not sleep)
  -> RenewLease: killed:false, Lease extended
  chunk 2/5: found 216816 primes in 2.2s (real CPU work, not sleep)
  -> RenewLease: killed:false, Lease extended
  chunk 3/5: found 216816 primes in 2.17s (real CPU work, not sleep)
  -> RenewLease: killed:false, Lease extended
  chunk 4/5: found 216816 primes in 2.24s (real CPU work, not sleep)
  -> RenewLease: killed:false, Lease extended
  chunk 5/5: found 216816 primes in 2.2s (real CPU work, not sleep)
  -> RenewLease: killed:false, Lease extended
Worker[worker-heavy-2]: Ack -> 200 {}
```

Circa 11 secondi di CPU reale contro un `timeoutSeconds` di 60s che, senza
`RenewLease`, sarebbe comunque bastato — il punto è che la Lease viene
davvero estesa a ogni chiamata (`GetStats` dopo l'Ack mostra `processed`
incrementato, e `GetJob` sullo stesso `jid` torna `job_not_found`: un Job
`SUCCEEDED` non viene retenuto, Sezione 4.3).

> **Nota su ambienti con CPU condivisa/virtualizzata**: preparando questo
> test, un primo tentativo con `timeoutSeconds:5` è stato *davvero* reclamato
> dal `LeaseReaper` prima che il primo `RenewLease` arrivasse a destinazione
> — non per un bug, ma perché sotto contesa di CPU il tempo reale tra "il
> worker finisce di calcolare" e "la richiesta HTTP arriva al Broker" può
> essere molto più lungo del tempo di CPU misurato internamente dal worker.
> È esattamente la ragione per cui la RFC raccomanda di chiamare
> `RenewLease` a un intervallo *significativamente* più corto di
> `timeoutSeconds` (Sezione 7.6: "e.g. half of it") invece di ridurre i
> margini all'osso.

## 7. Test end-to-end: un worker che non rinnova mai la Lease

`worker_no_renew.cr` fa l'opposto apposta: prende in carico un Job e poi
resta zitto per `STUCK_SILENT_SECONDS` (default 20) — nessun `RenewLease`,
nessun `Beat`, nessun `Ack`/`Fail` — per simulare un worker davvero bloccato
o crashato dopo aver già rivendicato il Job.

```bash
crystal build src/worker_no_renew.cr -o bin/worker_no_renew

curl -s -X POST http://localhost:7420/jqcp/v1/worker/enqueue \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"job":{"type":"SendEmailJob","queue":"jqcp-demo","args":[{"to":"dave@example.com","subject":"reminder"}],"timeoutSeconds":5}}' | jq -c '.jid, .timeoutSeconds'
# "ead8483c-...", 5

curl -s -X POST http://localhost:7420/jqcp/v1/worker/hello \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"worker-stuck-1","queues":["jqcp-demo"],"concurrency":1}' > /dev/null
curl -s -X POST http://localhost:7420/jqcp/v1/worker/fetch \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"worker-stuck-1"}' > /dev/null

export JQCP_BROKER_URL=http://localhost:7420
export JQCP_WORKER_TOKEN=worker-secret
export STUCK_SILENT_SECONDS=20

./bin/worker_no_renew worker-stuck-1 ead8483c-9f99-4945-884c-13212330bf4b
```

```
Worker[worker-stuck-1]: holding Lease on jid=ead8483c-..., going silent for 20s (no RenewLease, no Beat, no Ack/Fail)
Worker[worker-stuck-1]: done being silent, exiting without ever reporting back
```

Mentre il worker tace, il `LeaseReaper` del Broker (gira già dentro
`bin/broker`, nessun passo extra richiesto) lo reclama da solo dopo i 5
secondi di `timeoutSeconds`:

```bash
JID=ead8483c-9f99-4945-884c-13212330bf4b

curl -s -X POST http://localhost:7420/jqcp/v1/operator/get_job \
  -H "Authorization: Bearer read-secret" -H "Content-Type: application/json" \
  -d "{\"jid\":\"$JID\"}" | jq '.state, .retry.count'
```
```
"JOB_STATE_ENQUEUED"
0
```

Tornato in coda da solo, e `retry.count` è rimasto a 0: un recupero per
scadenza della Lease non conta come un fallimento (Sezione 8.9). Un secondo
Worker può rivendicarlo e completarlo senza intoppi:

```bash
curl -s -X POST http://localhost:7420/jqcp/v1/worker/hello \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"worker-rescue-1","queues":["jqcp-demo"],"concurrency":1}' > /dev/null
curl -s -X POST http://localhost:7420/jqcp/v1/worker/fetch \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d '{"wid":"worker-rescue-1"}' | jq -c '.jid, .state'
# "ead8483c-...", "JOB_STATE_ACTIVE"

curl -s -X POST http://localhost:7420/jqcp/v1/worker/ack \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d "{\"wid\":\"worker-rescue-1\",\"jid\":\"$JID\"}"
# {}

# il worker "stuck" originale prova un Ack tardivo: rifiutato
curl -s -X POST http://localhost:7420/jqcp/v1/worker/ack \
  -H "Authorization: Bearer worker-secret" -H "Content-Type: application/json" \
  -d "{\"wid\":\"worker-stuck-1\",\"jid\":\"$JID\"}" | jq .
```
```json
{"reason": "job_not_found", "domain": "jqcp.morganite", "metadata": {"jid": "ead8483c-..."}}
```

Nessuno ha dovuto intervenire manualmente: la sola assenza di `RenewLease`
(indipendente da `Beat`, Sezione 7.6/7.7) è bastata al Broker per recuperare
il Job in autonomia e renderlo di nuovo disponibile.

## Bonus: un Worker HTTP/3 con push reale (quic.cr)

Tutto il tutorial finora usa il transport JSON-over-HTTP/1.1, quello
predefinito. Morganite offre anche un transport **sperimentale** per il
solo `Fetch`, che usa [quic.cr](https://github.com/eltony81/quic.cr) per
fare vero HTTP/3 Server Push (RFC 9114 §4.6) invece del polling — vedi
["HTTP/3 Fetch (experimental)"](jqcp_conformance.md#http3-fetch-experimental)
per il design completo. Qui lo mettiamo davvero in funzione.

**Chi ha bisogno del flag di compilazione, e chi no** — è una distinzione
importante, non simmetrica:

- **Il Broker** sì: `quic.cr` è `require`-ato da Morganite solo dietro
  `-Dmorganite_http3` (senza questo flag il binario non ha nemmeno il
  codice dell'HTTP/3 listener, indipendentemente dalle env var).
- **Il Worker HTTP/3** no: `worker_http3.cr` non `require`a mai
  `"morganite"` — usa `quic.cr` direttamente, si compila con un `crystal
  build` normale. Gli serve comunque OpenSSL >= 3.5 sulla macchina di
  build (la stessa dipendenza nativa di `quic.cr`, indipendente da qualsiasi
  flag di Morganite — vedi `docs/jqcp_conformance.md`).

```bash
# Broker, con l'HTTP/3 Fetch compilato E abilitato a runtime
crystal build -Dmorganite_http3 src/broker.cr -o bin/broker_http3

export MORGANITE_JQCP_HTTP3_ENABLED=true
export MORGANITE_JQCP_HTTP3_PORT=7444
export MORGANITE_JQCP_HTTP3_FETCH_WINDOW_SECONDS=3
# (più le stesse env var JQCP del passo 1)
./bin/broker_http3
```

```
jqcp: experimental HTTP/3 Fetch listening on udp/7444
🚀 HTTP/3 Server listening on udp://0.0.0.0:7444
```

```bash
# Worker HTTP/3 -- nessun flag, build normale
crystal build src/worker_http3.cr -o bin/worker_http3

export JQCP_HTTP3_HOST=127.0.0.1
export JQCP_HTTP3_PORT=7444
export JQCP_WORKER_HTTP3_WINDOWS=4   # quante finestre di push apre prima di uscire

./bin/worker_http3 w-push-1
```

```
Worker[w-push-1]: Hello (queues=[jqcp-demo]) over JSON-HTTP
Worker[w-push-1]: opening 4 HTTP/3 Fetch window(s) on udp/7444
```

Ora, mentre il Worker HTTP/3 ha una finestra aperta, il Producer (invariato,
stesso binario del passo 2) invia dei Job via JSON-HTTP:

```bash
./bin/producer 3
```

Sul terminale del Worker HTTP/3, i Job arrivano push-ati in tempo reale,
mentre la finestra è ancora aperta — non al prossimo poll:

```
Worker[w-push-1]: window 1/4 ended ({"windowEnded":true})
Worker[w-push-1]: window 2/4 ended ({"windowEnded":true})
  [push] SendEmailJob jid=3b2cf233-a7a7-4ee0-a18c-0e9dc87d46bf
  [push] SendEmailJob jid=3c2dbfde-a6aa-4161-a471-6b754c8a3380
  [push] SendEmailJob jid=e748c8e0-0bc2-410b-8c8f-a3406dd44909
  [push] GenerateReportJob jid=214cfc18-f2b1-4cc7-b4d2-545ee9c7f66e
  -> unknown job type GenerateReportJob, failing it
  -> sent to carol@example.com, Ack
  -> sent to alice@example.com, Ack
  -> sent to carol@example.com, Ack
Worker[w-push-1]: window 3/4 ended ({"windowEnded":true})
Worker[w-push-1]: window 4/4 ended ({"windowEnded":true})
Worker[w-push-1]: exiting
```

(`worker_http3.cr` gestisce solo `SendEmailJob`, per restare focalizzato sul
meccanismo di push — non è un limite del transport: il `GenerateReportJob`
viene correttamente fallito e tornerà in coda per il retry, esattamente come
qualsiasi tipo non riconosciuto.) `Ack`/`Fail`/`Hello` restano JSON-HTTP
puro, invariati — solo `Fetch` è passato a HTTP/3.

**Perché resta sperimentale, non il default**: solo un client basato su
quic.cr può consumarlo (nessuna storia di interoperabilità con un client
gRPC/JQCP reale oggi), il certificato TLS è self-signed e auto-generato, e
al momento della scrittura non esiste una validazione incrociata
indipendente per il Server Push (quic-go v0.60.0, usato per verificare la
conformità di base di quic.cr, non ha alcuna API di Server Push). Dettagli
completi in `docs/jqcp_conformance.md`.

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
