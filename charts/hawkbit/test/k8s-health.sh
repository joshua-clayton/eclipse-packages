#!/usr/bin/env bash
# Check hawkbit k8s deployment health — pod restarts, PVC status, probe config.
# Catches the class of problems where the DB crash-loops for hours unnoticed.
# Usage: k8s-health.sh <env>
#   env: devops | int
set -euo pipefail

cd "$(dirname "$0")/.."

ENV="${1:-}"
if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <env>  (devops | int)" >&2
  exit 1
fi

case "$ENV" in
  devops) NAMESPACE="hawkbit"; RELEASE="hawkbit-devops"; CONTEXT="devops" ;;
  int)    NAMESPACE="hawkbit"; RELEASE="hawkbit-int";    CONTEXT="int"    ;;
  *)
    echo "Unknown env: $ENV. Must be 'devops' or 'int'." >&2
    exit 1
    ;;
esac

# Max acceptable restart counts before we flag a problem
MAX_RESTARTS=5
# Max acceptable startup probe window (seconds) for DB — must be long enough for InnoDB crash recovery
MIN_DB_STARTUP_SECONDS=300

KUBECTL="kubectl --context=$CONTEXT -n $NAMESPACE"

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILED=1; }
warn() { echo "  ⚠️  $1"; }
FAILED=0

echo "=== hawkbit-$ENV k8s health ==="
echo "    namespace: $NAMESPACE  context: $CONTEXT"
echo ""

# ── Pod restarts ──────────────────────────────────────────────────────────────
echo "── Pod restarts (threshold: $MAX_RESTARTS)"

RESTART_SCRIPT='
import sys, json, os
data = json.load(sys.stdin)
max_r = int(os.environ.get("MAX_RESTARTS", "5"))
prefix = os.environ.get("POD_PREFIX", "")
for pod in data.get("items", []):
    pname = pod["metadata"]["name"]
    for c in pod["status"].get("containerStatuses", []):
        cname = c["name"]
        restarts = c.get("restartCount", 0)
        state = next(iter(c.get("state", {}).keys()), "unknown")
        lbl = prefix + pname + "/" + cname
        if restarts > max_r:
            print("FAIL " + lbl + ": " + str(restarts) + " restarts (state: " + state + ")")
        elif restarts > 0:
            print("WARN " + lbl + ": " + str(restarts) + " restarts (state: " + state + ")")
        else:
            print("PASS " + lbl + ": 0 restarts (state: " + state + ")")
'

process_restart_output() {
  while IFS= read -r line; do
    tag="${line%% *}"; msg="${line#* }"
    case "$tag" in
      FAIL) fail "$msg" ;;
      WARN) warn "$msg" ;;
      PASS) pass "$msg" ;;
    esac
  done
}

$KUBECTL get pods -l "app.kubernetes.io/instance=$RELEASE" -o json 2>/dev/null \
  | MAX_RESTARTS="$MAX_RESTARTS" python3 -c "$RESTART_SCRIPT" \
  | process_restart_output

$KUBECTL get pods -l "app.kubernetes.io/name=mariadb" -o json 2>/dev/null \
  | MAX_RESTARTS="$MAX_RESTARTS" POD_PREFIX="DB " python3 -c "$RESTART_SCRIPT" \
  | process_restart_output

# ── Pod readiness ─────────────────────────────────────────────────────────────
echo "── Pod readiness"
while IFS= read -r line; do
  POD=$(echo "$line" | awk '{print $1}')
  READY=$(echo "$line" | awk '{print $2}')
  STATUS=$(echo "$line" | awk '{print $3}')
  if [[ "$READY" == "True" && "$STATUS" == "Running" ]]; then
    pass "$POD: Ready ($STATUS)"
  else
    fail "$POD: NOT ready (ready=$READY, status=$STATUS)"
  fi
done < <($KUBECTL get pods -l "app.kubernetes.io/instance=$RELEASE" \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status} {.status.phase}{"\n"}{end}' 2>/dev/null || true)

# ── DB startup probe ──────────────────────────────────────────────────────────
# A too-short startup probe window is what caused the crash-loop incident.
# Total window = initialDelaySeconds + (periodSeconds * failureThreshold)
echo "── DB startup probe window"
DB_STS=$($KUBECTL get statefulset -l "app.kubernetes.io/name=mariadb" -o name 2>/dev/null | head -1)
if [[ -n "$DB_STS" ]]; then
  PROBE_JSON=$($KUBECTL get "$DB_STS" \
    -o jsonpath='{.spec.template.spec.containers[0].startupProbe}' 2>/dev/null || echo "{}")
  if [[ "$PROBE_JSON" != "{}" && -n "$PROBE_JSON" ]]; then
    DELAY=$(echo "$PROBE_JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('initialDelaySeconds',0))")
    PERIOD=$(echo "$PROBE_JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('periodSeconds',10))")
    THRESHOLD=$(echo "$PROBE_JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('failureThreshold',3))")
    WINDOW=$(( DELAY + PERIOD * THRESHOLD ))
    if [[ "$WINDOW" -ge "$MIN_DB_STARTUP_SECONDS" ]]; then
      pass "DB startup probe window: ${WINDOW}s (delay=${DELAY} period=${PERIOD} threshold=${THRESHOLD}) ≥ ${MIN_DB_STARTUP_SECONDS}s"
    else
      fail "DB startup probe window too short: ${WINDOW}s (delay=${DELAY} period=${PERIOD} threshold=${THRESHOLD}) < ${MIN_DB_STARTUP_SECONDS}s — risks killing DB during InnoDB recovery"
    fi
  else
    warn "DB StatefulSet has no startupProbe configured — DB may be killed before it finishes starting"
  fi
else
  warn "No MariaDB StatefulSet found (may be using external DB)"
fi

# ── PVC status ────────────────────────────────────────────────────────────────
echo "── PVC status"
while IFS= read -r line; do
  PVC=$(echo "$line" | awk '{print $1}')
  PHASE=$(echo "$line" | awk '{print $2}')
  if [[ "$PHASE" == "Bound" ]]; then
    pass "PVC $PVC: $PHASE"
  else
    fail "PVC $PVC: $PHASE (expected Bound)"
  fi
done < <($KUBECTL get pvc \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null || true)

# ── Recent OOMKill / exit 137 ────────────────────────────────────────────────
echo "── Recent fatal exits"
FOUND_FATAL=0

FATAL_SCRIPT='
import sys, json
data = json.load(sys.stdin)
for pod in data.get("items", []):
    pname = pod["metadata"]["name"]
    for c in pod["status"].get("containerStatuses", []):
        last = c.get("lastState", {}).get("terminated")
        if last and last.get("exitCode", 0) != 0:
            code = last["exitCode"]
            reason = last.get("reason", "")
            cname = c["name"]
            print(pname + "/" + cname + " " + str(code) + " " + reason)
'
FATAL_OUTPUT=$($KUBECTL get pods -o json 2>/dev/null | python3 -c "$FATAL_SCRIPT" || true)

if [[ -n "$FATAL_OUTPUT" ]]; then
  while IFS= read -r line; do
    POD=$(echo "$line" | awk '{print $1}')
    EXIT_CODE=$(echo "$line" | awk '{print $2}')
    REASON=$(echo "$line" | awk '{print $3}')
    FOUND_FATAL=1
    if [[ "$EXIT_CODE" == "137" ]]; then
      fail "$POD: last exit $EXIT_CODE (OOMKill/SIGKILL — check startup probe and memory limits)"
    else
      warn "$POD: last exit $EXIT_CODE reason=$REASON"
    fi
  done <<< "$FATAL_OUTPUT"
fi
[[ "$FOUND_FATAL" -eq 0 ]] && pass "No fatal exits in last pod state"


echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "All checks passed ✅"
else
  echo "One or more checks failed ❌"
  exit 1
fi
