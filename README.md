# gitops-delivery-demo

Implementazione dimostrativa del processo di **rilascio standard** guidato da Change Request (CR)
con approccio GitOps: lo stato desiderato di ogni ambiente vive in questo repository, ogni
modifica passa da una Pull Request approvata, e il merge su `main` avvia il deploy.

Ambienti, in ordine di promozione: **sviluppo → addestramento → produzione**.
Ogni ambiente può avere una versione diversa dell'artefatto.

## Struttura

```
environments/
  <ambiente>/
    release.yaml            # FILE GUIDA: nome e versione dell'artefatto da installare + CR
    config/
      application.yaml      # configurazione applicativa dell'ambiente
      awx.yaml              # parametri del job AWX (job template, inventory, limit)
calendar/
  release-calendar.yaml     # finestre di freeze per ambiente
.github/
  CODEOWNERS                # Team Approvatori per cartella d'ambiente
  workflows/
    promote.yml             # Pipeline CD: aggiorna il file guida e apre la PR (step 2-3)
    deploy.yml              # Pipeline di deploy: trigger su main, AWX + CR simulati (step 7-9)
scripts/
  gitops.sh                 # simula gli attori via API (CR, referente, approvatori)
  scenarios.sh              # storia completa di scenari end-to-end
```

### Convenzione del file guida

```yaml
environment: produzione
application: orders-service
artifact:
  name: orders-service          # nome dell'artefatto sul repository binari
  version: 1.1.0                # semver
  repository: https://nexus.example.local/repository/releases/it/example/orders-service
change_request: CR-1007         # CR che ha richiesto lo stato attuale
requested_by: ref.bianchi
requested_at: "2026-11-26T10:00:00Z"
```

## Il processo, passo per passo

| Step | Diagramma | Implementazione |
|---|---|---|
| 1 | Referente richiede promozione ad ambiente X (CR *Promote*) | Il sistema di change management invoca l'API `workflow_dispatch` di `promote.yml` |
| 2 | Pipeline CD aggiorna il file guida dell'ambiente X | `promote.yml` valida input e **politica di promozione**, aggiorna `environments/X/release.yaml` |
| 3 | Prepara delivery per ambiente X | branch `promote/X/<artefatto>-<versione>-<CR>` + PR con label `env:X`, `promotion`. Le PR precedenti ancora aperte sullo stesso ambiente vengono chiuse come *superseded* |
| 4 | (opzionale) modifica configurazioni ambiente X | commit del referente su `environments/X/config/` nello stesso branch della PR |
| 5 | Team Approvatori approva delivery (*Approve + Freeze*) | review/merge della PR (CODEOWNERS per ambiente) + **gate di ambiente**: calendario freeze e approvazione GitHub Environment per addestramento e produzione |
| 6 | Merge della PR su main | squash merge: `main` = stato desiderato di tutti gli ambienti |
| 7 | Trigger da commit su main (ambiente X modificato) | `deploy.yml` su `push` a `main` con `paths: environments/**`, rileva solo gli ambienti cambiati |
| 8 | Carica file su AWX | `POST https://httpbin.org/anything/awx/api/v2/job_templates/<jt>/launch/` con file guida + config come `extra_vars` |
| 9 | Completa passaggio CR ad ambiente X | `POST https://httpbin.org/anything/itsm/api/change_requests/<CR>/transitions` |

### Regole applicate

- **Politica di promozione**: una versione entra in `addestramento` solo se è già stata consegnata
  (mergiata su `main`) in `sviluppo`; in `produzione` solo se già consegnata in `addestramento`.
  Verificata sulla storia git del file guida dell'ambiente precedente.
- **Calendario rilasci**: il job `calendar-gate` blocca il deploy se oggi l'ambiente è in freeze.
- **Approvazione di ambiente**: GitHub Environments `addestramento` e `produzione` hanno *required
  reviewers*; il job di deploy resta in `waiting` finché un approvatore non approva o rifiuta.
- **Concorrenza**: una sola promozione e un solo deploy alla volta per ambiente.

## Uso via API

Promozione (quello che farebbe il sistema CR):

```bash
curl -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/iron87/gitops-delivery-demo/actions/workflows/promote.yml/dispatches \
  -d '{"ref":"main","inputs":{"environment":"sviluppo","version":"1.3.0","cr_id":"CR-2001","requested_by":"dev.rossi"}}'
```

Approvazione di un deploy in attesa:

```bash
curl -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/iron87/gitops-delivery-demo/actions/runs/<run_id>/pending_deployments \
  -d '{"environment_ids":[<env_id>],"state":"approved","comment":"CAB ok"}'
```

Con lo script di supporto:

```bash
scripts/gitops.sh promote addestramento 1.2.1 CR-2002 orders-service ref.bianchi   # -> numero PR
scripts/gitops.sh approve-pr <pr>                                                  # -> sha di merge
scripts/gitops.sh approve-deploy addestramento "CAB ok"
scripts/gitops.sh wait-deploy <sha>
scripts/gitops.sh status
```

## Scenari simulati

`scripts/scenarios.sh` esegue questa storia (eseguita su questo repo, vedi PR chiuse e run di Actions):

1. **1.1.0 in sviluppo** — PR approvata, deploy senza approvazione di ambiente.
2. **1.2.0 poi hotfix 1.2.1 in sviluppo** — la PR della 1.2.0 viene chiusa come superseded, la 1.2.1 rilasciata.
3. **Scorciatoie rifiutate** — 1.2.1 diretta in produzione e 9.9.9 in addestramento: la pipeline rifiuta, nessuna PR.
4. **1.1.0 in addestramento + modifica config** (step 4: `replicas: 3`) — PR approvata, deploy approvato sull'ambiente.
5. **1.2.1 in addestramento** — PR rifiutata dal Team Approvatori.
6. **1.1.0 in produzione** — PR approvata, deploy rifiutato fuori finestra, poi rieseguito manualmente e approvato.

Stato finale atteso: sviluppo `1.2.1`, addestramento `1.1.0`, produzione `1.1.0`.

## Simulare gli scenari da soli

Prerequisiti: `gh` autenticato con accesso al repo, `jq`. Clonare e posizionarsi nel repo:

```bash
gh repo clone iron87/gitops-delivery-demo && cd gitops-delivery-demo
```

Ogni `promote` stampa il numero della PR, ogni `approve-pr` lo sha del merge: passali ai comandi
successivi. Usa CR e versioni nuove (la policy rifiuta una versione uguale a quella già prevista).

```bash
scripts/gitops.sh status                                                     # stato di partenza
PR=$(scripts/gitops.sh promote sviluppo 1.3.0 CR-2001 orders-service dev.rossi)
SHA=$(scripts/gitops.sh approve-pr $PR)
scripts/gitops.sh wait-deploy $SHA                                           # sviluppo: niente gate

PR=$(scripts/gitops.sh promote addestramento 1.3.0 CR-2002 orders-service ref.bianchi)
scripts/gitops.sh config $PR application.yaml '.logging.level = DEBUG'      # step 4 opzionale
SHA=$(scripts/gitops.sh approve-pr $PR)
scripts/gitops.sh approve-deploy addestramento "CAB ok"                      # gate di ambiente
scripts/gitops.sh wait-deploy $SHA

scripts/gitops.sh promote produzione 1.4.0 CR-2003                           # rifiutata dalla policy

PR=$(scripts/gitops.sh promote produzione 1.3.0 CR-2004 orders-service ref.bianchi)
scripts/gitops.sh reject-pr $PR "CAB rinviato"                               # PR rifiutata
```

Il deploy si può approvare/rifiutare anche dalla UI di Actions (pulsante *Review deployments*),
e la PR mergiare dalla UI. Per rieseguire tutta la storia standard su un repo nuovo:
`scripts/scenarios.sh` (o `scripts/scenarios.sh 4` per partire dallo scenario 4).

## Setup del repository

- *Settings → Actions → General*: "Allow GitHub Actions to create and approve pull requests" (serve a `promote.yml`).
- *Settings → Environments*: `sviluppo` (nessuna regola), `addestramento` e `produzione` con *required reviewers*.
- In un contesto reale: branch protection su `main` con review obbligatoria dei CODEOWNERS e
  token del sistema CR limitato al solo `actions:write` su questo repository.

## Limiti della demo

- AWX e ITSM sono simulati con httpbin: le risposte sono l'eco della richiesta.
- "Consegnato in un ambiente" = mergiato su `main` per quell'ambiente. Una verifica più stretta
  userebbe lo stato dei GitHub Deployments o la conferma di AWX.
- Approvatori e referente sono lo stesso utente: GitHub non permette di approvare la propria PR,
  quindi l'approvazione della PR è rappresentata dal merge (con commento) del Team Approvatori.
