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
while IFS= read -r line; do
  POD=$(echo "$line" | awk '{print $1}')
  CONTAINER=$(echo "$line" | awk '{print $2}')
  RESTARTS=$(echo "$line" | awk '{print $3}')
  STATE=$(echo "$line" | awk '{print $4}')

  if [[ "$RESTARTS" -gt "$MAX_RESTARTS" ]]; then
    fail "$POD/$CONTAINER: $RESTARTS restarts (state: $STATE)"
  elif [[ "$RESTARTS" -gt 0 ]]; then
    warn "$POD/$CONTAINER: $RESTARTS restarts (state: $STATE)"
  else
    pass "$POD/$CONTAINER: 0 restarts (state: $STATE)"
  fi
done < <($KUBECTL get pods -l "app.kubernetes.io/instance=$RELEASE" \
  -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{..name} {.name} {.restartCount} {.state..reason}{"\n"}{end}{end}' 2>/dev/null || true)

# Check DB pod separately (may have different label)
while IFS= read -r line; do
  POD=$(echo "$line" | awk '{print $1}')
  CONTAINER=$(echo "$line" | awk '{print $2}')
  RESTARTS=$(echo "$line" | awk '{print $3}')
  STATE=$(echo "$line" | awk '{print $4}')

  if [[ "$RESTARTS" -gt "$MAX_RESTARTS" ]]; then
    fail "DB $POD/$CONTAINER: $RESTARTS restarts (state: $STATE)"
  elif [[ "$RESTARTS" -gt 0 ]]; then
    warn "DB $POD/$CONTAINER: $RESTARTS restarts (state: $STATE)"
  else
    pass "DB $POD/$CONTAINER: 0 restarts (state: $STATE)"
  fi
done < <($KUBECTL get pods -l "app.kubernetes.io/name=mariadb" \
  -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{..name} {.name} {.restartCount} {.state..reason}{"\n"}{end}{end}' 2>/dev/null || true)

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
while IFS= read -r line; do
  POD=$(echo "$line" | awk '{print $1}')
  CONTAINER=$(echo "$line" | awk '{print $2}')
  EXIT_CODE=$(echo "$line" | awk '{print $3}')
  REASON=$(echo "$line" | awk '{print $4}')
  if [[ -n "$EXIT_CODE" && "$EXIT_CODE" != "0" && "$EXIT_CODE" != "<no" ]]; then
    FOUND_FATAL=1
    if [[ "$EXIT_CODE" == "137" ]]; then
      fail "$POD/$CONTAINER: last exit $EXIT_CODE (OOMKill/SIGKILL — check startup probe and memory limits)"
    else
      warn "$POD/$CONTAINER: last exit $EXIT_CODE reason=$REASON"
    fi
  fi
done < <($KUBECTL get pods \
  -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{..name} {.name} {.lastState.terminated.exitCode} {.lastState.terminated.reason}{"\n"}{end}{end}' 2>/dev/null || true)
[[ "$FOUND_FATAL" -eq 0 ]] && pass "No fatal exits in last pod state"

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "All checks passed ✅"
else
  echo "One or more checks failed ❌"
  exit 1
fi
