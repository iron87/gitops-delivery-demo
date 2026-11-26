#!/usr/bin/env bash
# Simula gli attori del processo usando solo le API di GitHub (via gh).
#
#   Referente applicativo / sistema CR:
#     scripts/gitops.sh promote <ambiente> <versione> <CR> [artefatto] [richiedente]
#     scripts/gitops.sh config  <pr> <file-in-config> <yq-expr> [messaggio]    # step 4 opzionale
#   Team Approvatori:
#     scripts/gitops.sh approve-pr <pr>              # step 5-6: merge della PR su main
#     scripts/gitops.sh reject-pr  <pr> <motivo>     # PR chiusa senza merge
#     scripts/gitops.sh approve-deploy <ambiente> [commento]   # gate GitHub Environment
#     scripts/gitops.sh reject-deploy  <ambiente> [commento]
#   Osservazione:
#     scripts/gitops.sh wait-deploy <sha>
#     scripts/gitops.sh status
#
# Richiede: gh autenticato, jq. REPO=<owner>/<repo> per sovrascrivere il repo corrente.
set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
ENVS=(sviluppo addestramento produzione)

log() { printf '\033[1;34m▶ %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

# Attende che compaia un run del workflow dato che soddisfa il filtro jq, ne restituisce l'id.
find_run() {
  local workflow="$1" filter="$2" id=""
  for _ in $(seq 1 60); do
    id="$(gh run list -R "$REPO" --workflow "$workflow" --limit 20 \
      --json databaseId,displayTitle,headSha,createdAt,status \
      --jq "[.[] | select($filter)] | first | .databaseId // empty")"
    [[ -n "$id" ]] && { echo "$id"; return; }
    sleep 3
  done
  die "Nessun run di $workflow trovato con filtro: $filter"
}

cmd_promote() {
  local env="$1" version="$2" cr="$3" artifact="${4:-orders-service}" by="${5:-referente-applicativo}"
  local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "CR $cr: richiesta promozione $artifact $version -> $env (API workflow_dispatch)"
  gh api -X POST "repos/$REPO/actions/workflows/promote.yml/dispatches" \
    -f ref=main -f "inputs[environment]=$env" -f "inputs[version]=$version" \
    -f "inputs[cr_id]=$cr" -f "inputs[artifact]=$artifact" -f "inputs[requested_by]=$by"
  local run; run="$(find_run promote.yml ".createdAt >= \"$since\" and (.displayTitle | contains(\"($cr)\"))")"
  log "Run promote: https://github.com/$REPO/actions/runs/$run"
  if ! gh run watch -R "$REPO" "$run" --exit-status >/dev/null 2>&1; then
    gh run view -R "$REPO" "$run" --log-failed | grep -E '::error::|##\[error\]' | sed 's/.*##\[error\]/  /' >&2 || true
    die "Promozione rifiutata dalla pipeline (run $run)"
  fi
  local pr
  pr="$(gh pr list -R "$REPO" --head "promote/$env/$artifact-$version-$cr" --state open --json number --jq '.[0].number')"
  log "PR di delivery aperta: https://github.com/$REPO/pull/$pr"
  echo "$pr"
}

cmd_config() {
  local pr="$1" file="$2" expr="$3" msg="${4:-config: $2}"
  local branch; branch="$(gh pr view -R "$REPO" "$pr" --json headRefName --jq .headRefName)"
  local env; env="$(cut -d/ -f2 <<< "$branch")"
  local path="environments/$env/config/$file"
  log "Referente: modifica $path sul branch $branch ($expr)"
  local tmp; tmp="$(mktemp -d)"
  gh api "repos/$REPO/contents/$path?ref=$branch" > "$tmp/meta.json"
  jq -r .content "$tmp/meta.json" | base64 --decode > "$tmp/file.yaml"
  if command -v yq >/dev/null; then
    yq -i "$expr" "$tmp/file.yaml"
  else
    # fallback senza yq: solo espressioni semplici '.chiave.foglia = valore' su foglia univoca nel file
    local key="${expr%%=*}" val="${expr#*=}" leaf
    key="${key// /}"; val="${val# }"
    leaf="${key##*.}"
    sed -i.bak -E "s|^([[:space:]]*${leaf}:).*|\1 ${val}|" "$tmp/file.yaml"
  fi
  diff -u <(jq -r .content "$tmp/meta.json" | base64 --decode) "$tmp/file.yaml" >&2 || true
  gh api -X PUT "repos/$REPO/contents/$path" -f branch="$branch" -f message="$msg" \
    -f sha="$(jq -r .sha "$tmp/meta.json")" -f content="$(base64 < "$tmp/file.yaml" | tr -d '\n')" >/dev/null
  rm -rf "$tmp"
}

cmd_approve_pr() {
  local pr="$1"
  gh pr comment -R "$REPO" "$pr" --body "✅ Team Approvatori: delivery approvata (step 5). Merge su main (step 6)." >/dev/null
  local title; title="$(gh pr view -R "$REPO" "$pr" --json title --jq .title)"
  gh pr merge -R "$REPO" "$pr" --squash --delete-branch --subject "$title (#$pr)" --body "" >/dev/null
  local sha; sha="$(gh pr view -R "$REPO" "$pr" --json mergeCommit --jq .mergeCommit.oid)"
  log "PR #$pr approvata e mergiata: $sha"
  echo "$sha"
}

cmd_reject_pr() {
  local pr="$1" reason="$2"
  gh pr close -R "$REPO" "$pr" --delete-branch --comment "❌ Team Approvatori: delivery NON approvata. Motivo: $reason" >/dev/null
  log "PR #$pr rifiutata: $reason"
}

pending_deploy() { # <ambiente> <approved|rejected> <commento>
  local env="$1" state="$2" comment="$3" run="" env_id=""
  for _ in $(seq 1 60); do
    for r in $(gh run list -R "$REPO" --workflow deploy.yml --status waiting --json databaseId --jq '.[].databaseId'); do
      env_id="$(gh api "repos/$REPO/actions/runs/$r/pending_deployments" \
        --jq ".[] | select(.environment.name == \"$env\") | .environment.id")"
      [[ -n "$env_id" ]] && { run="$r"; break 2; }
    done
    sleep 3
  done
  [[ -n "$run" ]] || die "Nessun deploy in attesa di approvazione su $env"
  gh api -X POST "repos/$REPO/actions/runs/$run/pending_deployments" \
    -F "environment_ids[]=$env_id" -f state="$state" -f comment="$comment" >/dev/null
  log "Deploy $env (run $run): $state"
}

cmd_wait_deploy() {
  local sha="$1"
  local run; run="$(find_run deploy.yml ".headSha == \"$sha\"")"
  log "Run deploy: https://github.com/$REPO/actions/runs/$run"
  if gh run watch -R "$REPO" "$run" --exit-status >/dev/null 2>&1; then
    log "Deploy completato"
  else
    log "Deploy NON completato: $(gh run view -R "$REPO" "$run" --json conclusion --jq .conclusion)"
    return 1
  fi
}

cmd_status() {
  printf '%-14s %-24s %-10s %-12s %s\n' AMBIENTE "ATTESO (main)" CR DEPLOY ULTIMO_DEPLOY
  for env in "${ENVS[@]}"; do
    local guide dep state
    guide="$(gh api "repos/$REPO/contents/environments/$env/release.yaml" --jq .content | base64 --decode)"
    dep="$(gh api "repos/$REPO/deployments?environment=$env&per_page=1" --jq '.[0] | "\(.id) \(.sha[0:7]) \(.created_at)"')"
    state="$(gh api "repos/$REPO/deployments/${dep%% *}/statuses?per_page=1" --jq '.[0].state' 2>/dev/null || echo n/a)"
    printf '%-14s %-24s %-10s %-12s %s\n' "$env" \
      "$(grep -A2 '^artifact:' <<< "$guide" | awk '/name:/{n=$2} /version:/{v=$2} END{print n"@"v}')" \
      "$(awk '/^change_request:/{print $2}' <<< "$guide")" "$state" "$(cut -d' ' -f2- <<< "$dep")"
  done
  echo
  echo "PR di delivery aperte:"
  gh pr list -R "$REPO" --label promotion --state open --json number,title --jq '.[] | "  #\(.number) \(.title)"'
}

case "${1:-}" in
  promote)        shift; cmd_promote "$@" ;;
  config)         shift; cmd_config "$@" ;;
  approve-pr)     shift; cmd_approve_pr "$@" ;;
  reject-pr)      shift; cmd_reject_pr "$@" ;;
  approve-deploy) shift; pending_deploy "$1" approved "${2:-Approvato dal Team Approvatori}" ;;
  reject-deploy)  shift; pending_deploy "$1" rejected "${2:-Rifiutato dal Team Approvatori}" ;;
  wait-deploy)    shift; cmd_wait_deploy "$@" ;;
  status)         cmd_status ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
