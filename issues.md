# Morganite — Analisi bug e performance

Analisi del codice sorgente (`src/morganite/`) alla ricerca di bug di correttezza,
problemi di sicurezza e inefficienze. Riferimenti nel formato `file:riga`.

> **Stato:** i punti 1-7, 9, 10 e la nota sui Workflow sono stati corretti (vedi
> `git log`/`git diff`) e coperti da spec dedicate in `spec/morganite/`. Il punto
> 8 (indice secondario per il lookup per `jid`) resta aperto: è una modifica
> strutturale più ampia (toccherebbe `Client`, `Processor`, `Failures`) e non è
> stata affrontata in questo giro di fix.

## Bug di correttezza

### 1. Rate limiter rotto — permette solo 1 job per finestra, non `limit` — ✅ risolto
**File:** `src/morganite/rate_limiter.cr:12-23`

```crystal
tokens = current.is_a?(String) ? current.to_i : limit
if tokens > 0
  redis.decr(key)   # la chiave non esiste ancora in Redis!
  redis.expire(key, window) if current.nil?
```

Quando la chiave non esiste su Redis, `tokens` viene calcolato come `limit` solo
in memoria Crystal, ma quel valore non viene mai scritto su Redis. `DECR` su una
chiave inesistente la inizializza a `0` e poi decrementa a **-1** (comportamento
documentato anche nello shard `redis`: `redis.decr "counter" # => -1`). La
chiamata successiva legge quindi `"-1"`, che non è `> 0`, e blocca tutti i job
successivi fino alla scadenza della finestra.

**Effetto:** qualsiasi `rate_limit(N, window)` con `N > 1` si comporta come
`rate_limit(1, window)` — un solo job passa per finestra, indipendentemente dal
limite configurato.

**Fix suggerito:** inizializzare esplicitamente la chiave con
`SET key limit NX EX window` prima di decrementare, oppure usare un contatore
`INCR` confrontato con `limit` invece di un decremento da un valore mai scritto.

---

### 2. Race condition nei Batch — callback di completamento può scattare più volte — ✅ risolto
**File:** `src/morganite/batch.cr:49-73`

```crystal
redis.hincrby(key, "pending", -1)   # valore di ritorno atomico ignorato
...
pending = redis.hget(key, "pending")  # riletto separatamente, non atomico col decremento
```

`HINCRBY` è atomico e restituisce già il nuovo valore univoco per la chiamata,
ma il codice scarta quel valore ed esegue una `HGET` separata subito dopo. Con
job concorrenti che completano lo stesso batch, due fiber/processi possono
entrambi osservare `pending == 0` nella propria `HGET` (perché nel frattempo
l'altro ha già decrementato), causando la doppia esecuzione di
`success_callback` e/o `complete_callback`.

**Fix suggerito:** usare direttamente il valore restituito da `hincrby` come
`pending` invece di rileggerlo con `hget`.

---

### 3. `UniqueJobs.unlock` esegue un `DEL` incondizionato (non compare-and-delete) — ✅ risolto
**File:** `src/morganite/unique_jobs.cr:42-47`

```crystal
def self.unlock(job_or_key : Job | String, redis : Redis::Client? = nil)
  key = ...
  client.del(key)
```

Se un job con strategia `while_executing`/`until_executed` supera il TTL del
lock, un secondo job con la stessa chiave di unicità può acquisire
legittimamente un nuovo lock. Quando il primo job (più lento) termina, il suo
`unlock()` cancella incondizionatamente la chiave — che a quel punto appartiene
al *secondo* job — rompendo la garanzia di mutua esclusione che il meccanismo
dovrebbe fornire.

**Fix suggerito:** cancellare il lock solo se il valore corrisponde al proprio
`jid`, tramite uno script Lua (compare-and-delete), analogo a quanto già fatto
per l'acquisizione in `Client::UNIQUE_ENQUEUE_SCRIPT`.

---

### 4. Dashboard web: azioni "Retry"/"Delete" non funzionano per job Scheduled/Retry — ✅ risolto
**File:** `src/morganite/web.cr:243-251` (`actions_for`), `src/morganite/failures.cr`

`actions_for` genera sempre le stesse tre form (retry-da-dead, delete-da-dead,
delete-da-retry) per **qualsiasi** job mostrato, indipendentemente dalla lista
Redis in cui si trova realmente (coda normale, scheduled, retry o dead).

- Non esiste un `Failures.delete_scheduled`: il bottone "Delete" per un job
  nella sezione **Scheduled** invoca `Failures.delete_retry`, che cerca in
  `morganite:retry` invece che in `morganite:scheduled` — l'eliminazione fallisce
  silenziosamente (nessun errore, nessun effetto).
- Il bottone "Retry" chiama sempre `Failures.retry_dead`, che cerca solo in
  `morganite:dead`: su un job ancora nella coda **Retry** (non ancora morto) è
  un no-op silenzioso.

**Fix suggerito:** rendere `actions_for` consapevole della sezione/lista di
provenienza del job (passare un parametro `location`) e implementare
`Failures.delete_scheduled` per la coda scheduled.

## Sicurezza

### 5. XSS memorizzata/riflessa nella Web UI — ✅ risolto
**File:** `src/morganite/web.cr` (es. righe 124, 142, 188-204, 233-235)

Classe worker, nome coda, argomenti (`job.args.to_json`), messaggio d'errore,
backtrace e persino il parametro URL `:name` (`render_queue`) vengono
interpolati direttamente nell'HTML tramite `String.build`/`#{...}` senza alcun
escaping. Poiché args/errori/nome-coda derivano spesso da input applicativo o
indirettamente da input utente, chi riesce a far passare un payload con
`<script>...</script>` in un argomento di job (o in un messaggio d'eccezione)
ottiene esecuzione di codice nel browser di chi consulta la dashboard. Il nome
coda passato via URL rende inoltre possibile un attacco reflected diretto.

**Fix suggerito:** HTML-escape sistematico (es. `HTML.escape`) di tutti i
valori dinamici interpolati nelle viste.

---

### 6. Confronti non a tempo costante per password Basic Auth e token CSRF — ✅ risolto
**File:** `src/morganite/web.cr:376` (`authorized?`), `web.cr:390` (`csrf_valid?`)

```crystal
parts.size == 2 && parts[0] == username && parts[1] == password
...
submitted == token
```

Confronti con `==` standard sono vulnerabili, in teoria, a timing attack.
Gravità bassa (richiede rete a bassa latenza/molte richieste), ma facilmente
corretta con un confronto a tempo costante (es. `Crypto::Subtle.constant_time_compare`).

## Inefficienze / problemi di scalabilità

### 7. Istogrammi delle metriche crescono senza limite (memory leak) — ✅ risolto
**File:** `src/morganite/metrics.cr:18-23`

```crystal
def self.observe(name : String, value : Float64)
  @@histograms[name] ||= [] of Float64
  @@histograms[name] << value
```

Ogni job completato chiama `Metrics.observe("#{job.class}_duration", ...)`
(`processor.cr:65`), che accoda il valore all'array per quella classe worker
senza mai troncarlo o resettarlo (a parte una `reset` mai chiamata
automaticamente). In un processo long-running che elabora milioni di job,
questi array crescono indefinitamente, e ogni scrape `/metrics` ricalcola
`count`/`sum` su array sempre più grandi (costo O(n) crescente nel tempo).

**Fix suggerito:** usare bucket incrementali (contatori per bucket, come un
vero istogramma Prometheus) invece di conservare ogni singolo valore osservato.

---

### 8. Lookup per `jid` è O(n) con deserializzazione JSON completa — ⏳ non risolto in questo giro
**File:** `src/morganite/failures.cr:118-128` (`find_by_jid`), `src/morganite/web.cr:330-355` (`find_job`)

Ogni retry/delete di un job morto o in coda di retry, così come ogni
visualizzazione del dettaglio job dalla dashboard, esegue una scansione
lineare (`ZRANGE key 0 -1`) dell'intero sorted set (fino a `dead_max_jobs`,
default 10.000, per la coda dead; illimitato per retry/scheduled) e
deserializza ogni elemento in JSON solo per confrontare il `jid`.

**Fix suggerito:** mantenere un indice secondario (es. hash `jid -> posizione`
o `jid -> job JSON`) per lookup O(1)/O(log n).

---

### 9. `web.cr` usa il comando bloccante `KEYS` invece di `SCAN` — ✅ risolto
**File:** `src/morganite/web.cr:277, 318, 332`

`redis.keys("morganite:queue:*")` (e simili per `processing:*`) usa `KEYS`,
che è O(N) sull'intero keyspace e blocca il server Redis per tutti i client
mentre esegue. Su un'installazione con molte code/chiavi questo può causare
latenza percepibile su tutto il sistema, inclusi i worker in produzione.

**Fix suggerito:** sostituire con `SCAN` (cursore incrementale) per queste
operazioni di enumerazione usate dalla dashboard.

---

### 10. `CronExpression#next` può iterare fino a ~5,2M minuti ad ogni poll — ✅ risolto
**File:** `src/morganite/cron.cr:11-23`

```crystal
5_257_600.times do
  return t if matches?(t)
  t += 1.minute
end
```

Un'espressione cron sintatticamente valida ma con combinazione impossibile
(es. `0 0 31 2 *`, 31 febbraio, che non esiste mai) fa scansionare l'intero
range di ~10 anni di minuti ogni volta che viene chiamata. `CronScheduler`
esegue il poll ogni 30 secondi (`cron_scheduler.cr:9`) per sempre, quindi
un'espressione di questo tipo consuma CPU ripetutamente e indefinitamente
senza mai risolversi.

**Fix suggerito:** validare a registrazione (`Cron.register`) che
l'espressione possa effettivamente produrre un'occorrenza valida, oppure
mettere in cache/loggare un warning e disabilitare il job dopo il primo
fallimento di ricerca.

## Nota minore (non bug) — ✅ risolta

**Doppia serializzazione JSON nei Workflow** — `src/morganite/workflow.cr:48-53`
serializza ogni step in una stringa JSON e poi serializza di nuovo l'array di
stringhe (`@steps.map { ... .to_json }.to_json`). Funziona correttamente ma è
ridondante rispetto a serializzare direttamente l'array di oggetti
(`@steps.to_json` con un `Array(Hash(...))`, o struct con `JSON::Serializable`).
