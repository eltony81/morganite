# Decision Log (ADR minimale)

Usare questo file per registrare decisioni tecniche non ovvie.

## Template

```markdown
### YYYY-MM-DD – Titolo decisione

- **Contesto**: perché dovevamo decidere
- **Opzioni**: elenco opzioni considerate
- **Decisione**: cosa abbiamo scelto
- **Conseguenze**: trade-off
- **Reversibilità**: alta/media/bassa
```

## Decisioni

### 2026-07-18 – Scelta del client Redis

- **Contesto**: la libreria `stefanwille/crystal-redis` non compila con Crystal 1.20.2 (errore interno su `String#each`).
- **Opzioni**: cercare un fork compatibile, usare `jgaskins/redis`, scrivere un client ad-hoc.
- **Decisione**: adottare `jgaskins/redis` (`~> 0.13.0`).
- **Conseguenze**:
  - Client puro Crystal con connection pool integrato.
  - API leggermente diversa (`Redis::Client.new(URI)`, `brpop(key, timeout:)`).
  - Immagine Docker può restare su `crystallang/crystal:1.15.0-alpine` (codice compatibile).
- **Reversibilità**: alta – il client è incapsulato in una sottile astrazione di Morganite.
