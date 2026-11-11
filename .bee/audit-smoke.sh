#!/usr/bin/env bash
# Acceptance smoke for AUDIT_LOG_STDOUT (beecreatorstudio#498).
#
# Runs against the compose stack that CI started (the upstream compose the production
# stack is built on, with our builder+worker images and AUDIT_LOG_STDOUT=true).
# Exercises a REAL audited action over HTTP -- a Public API write with a workspace
# token -- and fails unless the builder prints the `AUDIT <action>` line with the agreed
# field set and WITHOUT `detail`.
#
# Required env: DC  (the `docker compose -p ... -f ... -f ...` prefix, exported by CI)
# Optional env: BASE (default http://127.0.0.1:3123)
set -euo pipefail

: "${DC:?DC must hold the docker compose command prefix}"
BASE="${BASE:-http://127.0.0.1:3123}"
UA="bee-audit-smoke/1"
resp="$(mktemp)"
trap 'rm -f "$resp"' EXIT

psql_q() { $DC exec -T postgres psql -U chatbotx -d chatbotx -v ON_ERROR_STOP=1 -Atq "$@"; }

echo "== seeded workspace"
workspace_id="$(psql_q -c 'SELECT id FROM "Workspace" ORDER BY "createdAt" LIMIT 1')"
test -n "$workspace_id" || { echo "no seeded workspace (RUN_DB_SEED?)"; exit 1; }
echo "workspace id: $workspace_id"

# A throwaway workspace API token (only its SHA-256 is stored, as the app does).
# The plaintext lives in this process only and the stack is torn down after the job.
token="cbx_ws_smoke$(openssl rand -hex 24)"
token_hash="$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)"
psql_q -c "INSERT INTO \"WorkspaceApiToken\" (id, \"workspaceId\", name, permission, \"tokenHash\", \"tokenPrefix\")
           VALUES ((extract(epoch from clock_timestamp()) * 1000000)::bigint, ${workspace_id}, 'audit-smoke', 'full', '${token_hash}', '${token:0:12}')" >/dev/null

api() { # method path [json]
  local method="$1" path="$2" body="${3:-}"
  curl -sS -o "$resp" -w '%{http_code}' -X "$method" "${BASE}${path}" \
    -H "Authorization: Bearer ${token}" -H "User-Agent: ${UA}" \
    -H 'X-Forwarded-For: 203.0.113.7' -H 'Content-Type: application/json' \
    ${body:+--data "$body"}
}

echo "== audited action 1: create working-hours schedule"
code="$(api POST /api/v1/working-hours '{"name":"audit-smoke-schedule"}')"
echo "HTTP $code"; cat "$resp"; echo
[ "$code" = "201" ] || { echo "create did not return 201"; exit 1; }
sched_id="$(jq -r .id "$resp")"

echo "== audited action 2: delete it"
code="$(api DELETE "/api/v1/working-hours/${sched_id}")"
echo "HTTP $code"
case "$code" in 200|204) ;; *) cat "$resp"; echo "delete failed"; exit 1 ;; esac

echo "== waiting for AUDIT lines in builder logs"
lines=""
for _ in $(seq 1 20); do
  lines="$($DC logs --no-color --no-log-prefix builder 2>&1 | grep -F 'AUDIT ' || true)"
  [ "$(printf '%s\n' "$lines" | grep -c 'AUDIT ')" -ge 2 ] && break
  sleep 1
done
echo "---- $DC logs builder | grep AUDIT"
printf '%s\n' "$lines"
echo "----"

n="$(printf '%s\n' "$lines" | grep -c 'AUDIT ' || true)"
[ "$n" -ge 2 ] || { echo "expected >=2 AUDIT lines, got $n"; exit 1; }

# Contract checks on every emitted line.
fail=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # structured JSON from pino, `msg` = "AUDIT <action>", fields under `audit`
  if ! printf '%s' "$line" | jq -e '
        (.msg | startswith("AUDIT "))
        and (.audit.auditLogId | type == "string" and length > 0)
        and (.audit.action | type == "string" and length > 0)
        and (.audit.userId | type == "string" and length > 0)
        and (.audit.workspaceId == "'"${workspace_id}"'")
        and (.audit.userAgent == "'"${UA}"'")
        and ((.audit | has("detail")) | not)
        and (has("detail") | not)' >/dev/null; then
    echo "contract violation: $line"; fail=1
  fi
  if printf '%s' "$line" | grep -q 'audit-smoke-schedule'; then
    # `detail` carries free text such as the schedule name; it must never be logged.
    echo "free-text detail leaked into the AUDIT line: $line"; fail=1
  fi
done <<<"$lines"
[ "$fail" = "0" ] || exit 1

printf '%s\n' "$lines" | jq -r '.audit | "\(.action)\tip=\(.ipAddress // "-") source=\(.source // "-")"' || true

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo '### AUDIT proof (compose, `logs builder | grep AUDIT`)'
    echo '```'
    printf '%s\n' "$lines"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo "AUDIT smoke OK"
