#!/usr/bin/env bash
# Simulazione end-to-end del processo di promozione su sviluppo -> addestramento -> produzione.
# Ogni scenario usa solo le API GitHub tramite scripts/gitops.sh.
# Uso: scripts/scenarios.sh [numero-scenario-iniziale]
set -euo pipefail
cd "$(dirname "$0")/.."
export REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
G=scripts/gitops.sh
START="${1:-1}"
title() { printf '\n\033[1;33m══════ Scenario %s ══════\033[0m\n' "$*"; }
run() { [[ "$1" -ge "$START" ]]; }

if run 1; then
  title "1 — nuova versione 1.1.0 in sviluppo (nessuna approvazione di ambiente)"
  pr=$($G promote sviluppo 1.1.0 CR-1001 orders-service dev.rossi)
  sha=$($G approve-pr "$pr")
  $G wait-deploy "$sha"
fi

if run 2; then
  title "2 — 1.2.0 in sviluppo, poi hotfix 1.2.1 che la rende obsoleta (PR superseded)"
  $G promote sviluppo 1.2.0 CR-1002 orders-service dev.rossi >/dev/null
  pr=$($G promote sviluppo 1.2.1 CR-1003 orders-service dev.rossi)   # chiude in automatico la PR della 1.2.0
  sha=$($G approve-pr "$pr")
  $G wait-deploy "$sha"
fi

if run 3; then
  title "3 — tentativo di saltare addestramento: 1.2.1 direttamente in produzione (rifiutato dalla policy)"
  if $G promote produzione 1.2.1 CR-1004 orders-service dev.rossi; then
    echo "ERRORE: la promozione avrebbe dovuto essere rifiutata" >&2; exit 1
  fi
  title "3b — versione mai consegnata in sviluppo verso addestramento (rifiutata)"
  if $G promote addestramento 9.9.9 CR-1004 orders-service dev.rossi; then
    echo "ERRORE: la promozione avrebbe dovuto essere rifiutata" >&2; exit 1
  fi
fi

if run 4; then
  title "4 — 1.1.0 in addestramento + modifica configurazione (step 4) + approvazione deploy"
  pr=$($G promote addestramento 1.1.0 CR-1005 orders-service ref.bianchi)
  $G config "$pr" application.yaml '.server.replicas = 3' "addestramento: replicas 3 per test di carico (CR-1005)"
  sha=$($G approve-pr "$pr")
  $G approve-deploy addestramento "CR-1005 approvata in CAB"
  $G wait-deploy "$sha"
fi

if run 5; then
  title "5 — 1.2.1 in addestramento: PR rifiutata dal Team Approvatori"
  pr=$($G promote addestramento 1.2.1 CR-1006 orders-service ref.bianchi)
  $G reject-pr "$pr" "Test di regressione su 1.2.1 non ancora conclusi"
fi

if run 6; then
  title "6 — 1.1.0 in produzione: PR approvata, deploy rifiutato fuori finestra, poi ri-eseguito e approvato"
  pr=$($G promote produzione 1.1.0 CR-1007 orders-service ref.bianchi)
  sha=$($G approve-pr "$pr")
  $G reject-deploy produzione "Fuori dalla finestra di rilascio concordata: rieseguire alle 22:00"
  $G wait-deploy "$sha" || true
  echo "→ main dichiara 1.1.0 ma produzione non è allineata: riallineamento manuale nella finestra" >&2
  gh workflow run -R "$REPO" deploy.yml -f environment=produzione
  sleep 5
  $G approve-deploy produzione "Finestra di rilascio CR-1007 aperta"
  run_id=$(gh run list -R "$REPO" --workflow deploy.yml --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')
  gh run watch -R "$REPO" "$run_id" --exit-status >/dev/null && echo "Deploy produzione completato" >&2
fi

title "Stato finale"
$G status
