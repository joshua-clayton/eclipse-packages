#!/usr/bin/env bash
# Test a live hawkbit instance.
# Usage: live-test.sh <env>
#   env: devops | int
set -euo pipefail

cd "$(dirname "$0")/.."

ENV="${1:-}"
if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <env>  (devops | int)" >&2
  exit 1
fi

case "$ENV" in
  devops)
    BASE_URL="https://hawkbit.lvt-platform-ops.aws.lvt.cloud"
    VAULT_PASSWORD_PATH="apps/devops/infrastructure/hawkbit"
    VAULT_PASSWORD_FIELD="hawkbit-password"
    ;;
  int)
    BASE_URL="https://hawkbit.int.lvt.services"
    VAULT_PASSWORD_PATH="apps/int/hawkbit"
    VAULT_PASSWORD_FIELD="hawkbit-password"
    ;;
  *)
    echo "Unknown env: $ENV. Must be 'devops' or 'int'." >&2
    exit 1
    ;;
esac

ARGOCD_VALUES="$HOME/src/argocd/values/infrastructure/hawkbit"

# Detect which optional interfaces are deployed for this env by reading values files.
# Later file wins (env-specific overrides common).
GUI_ENABLED=$(yq eval-all '. as $item ireduce ({}; . * $item) | .hawkbitgui.enabled // false' \
  "$ARGOCD_VALUES/common.yaml" "$ARGOCD_VALUES/$ENV.yaml" 2>/dev/null || echo "false")

ADMIN_USER="admin"
ADMIN_PASS="$(vault kv get -field="$VAULT_PASSWORD_FIELD" "$VAULT_PASSWORD_PATH")"

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILED=1; }
FAILED=0

# Shared curl options: fail silently, 10s connect timeout, 30s max transfer
CURL_OPTS=(-sf --connect-timeout 10 --max-time 30)

# Timed curl: same as CURL_OPTS but captures response time
curl_timed() {
  curl "${CURL_OPTS[@]}" -w '\n%{time_total} %{http_code}' "$@"
}

echo "=== hawkbit-$ENV live tests ==="
echo "    URL: $BASE_URL"
echo ""

# Health check (unauthenticated)
echo "── Health"
STATUS=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" "$BASE_URL/actuator/health" || true)
HEALTH_TIME=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{time_total}" "$BASE_URL/actuator/health" || true)
if [[ "$STATUS" == "200" ]]; then
  pass "actuator/health → $STATUS (${HEALTH_TIME}s)"
  if awk "BEGIN { exit ($HEALTH_TIME < 5) ? 0 : 1 }"; then
    pass "Health response time acceptable (${HEALTH_TIME}s < 5s)"
  else
    fail "Health response slow (${HEALTH_TIME}s ≥ 5s) — possible DB trouble"
  fi
else
  fail "actuator/health → $STATUS (expected 200)"
fi

# Authenticated health — with show-details=when-authorized, this returns
# component-level status including the DB datasource health indicator.
HEALTH_BODY=$(curl "${CURL_OPTS[@]}" \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  "$BASE_URL/actuator/health" || true)
DB_STATUS=$(echo "$HEALTH_BODY" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('components',{}).get('db',{}).get('status','MISSING'))" \
  2>/dev/null || echo "PARSE_ERROR")
case "$DB_STATUS" in
  UP)      pass "DB health component → UP" ;;
  MISSING) pass "DB health component not exposed (show-details may not be active yet)" ;;
  *)       fail "DB health component → $DB_STATUS (expected UP)" ;;
esac

DISK_STATUS=$(echo "$HEALTH_BODY" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('components',{}).get('diskSpace',{}).get('status','MISSING'))" \
  2>/dev/null || echo "PARSE_ERROR")
DISK_FREE=$(echo "$HEALTH_BODY" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); \
   free=d.get('components',{}).get('diskSpace',{}).get('details',{}).get('free',0); \
   print(str(round(free/1024/1024/1024,1))+'GB')" \
  2>/dev/null || echo "unknown")
case "$DISK_STATUS" in
  UP)      pass "Disk space → UP (free: $DISK_FREE)" ;;
  MISSING) ;;  # not exposed, skip silently
  *)       fail "Disk space → $DISK_STATUS (free: $DISK_FREE)" ;;
esac

# Authenticated API
echo "── Auth"
STATUS=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  "$BASE_URL/rest/v1/targets?limit=1" || true)
if [[ "$STATUS" == "200" ]]; then
  pass "GET /rest/v1/targets → $STATUS"
else
  fail "GET /rest/v1/targets → $STATUS (expected 200)"
fi

# Wrong password should be rejected
STATUS=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
  -u "$ADMIN_USER:wrongpassword" \
  "$BASE_URL/rest/v1/targets?limit=1" || true)
if [[ "$STATUS" == "401" ]]; then
  pass "Wrong password rejected → $STATUS"
else
  fail "Wrong password not rejected → $STATUS (expected 401)"
fi

# Default credentials must not work (configuration failure if they do)
STATUS=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
  -u "admin:admin" \
  "$BASE_URL/rest/v1/targets?limit=1" || true)
if [[ "$STATUS" == "401" ]]; then
  pass "Default admin:admin rejected → $STATUS"
else
  fail "Default admin:admin accepted → $STATUS (CONFIGURATION FAILURE: default credentials work)"
fi

STATUS=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
  -u "hawkbit:isAwesome" \
  "$BASE_URL/rest/v1/targets?limit=1" || true)
if [[ "$STATUS" == "401" ]]; then
  pass "Default hawkbit:isAwesome rejected → $STATUS"
else
  fail "Default hawkbit:isAwesome accepted → $STATUS (CONFIGURATION FAILURE: default credentials work)"
fi

# Tenant API
echo "── API"
BODY=$(curl "${CURL_OPTS[@]}" \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  "$BASE_URL/rest/v1/targets?limit=1" || true)
if echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'total' in d" 2>/dev/null; then
  TOTAL=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['total'])")
  pass "Target list response valid (total: $TOTAL)"
else
  fail "Target list response invalid or unparseable"
fi

# API response time — slow responses indicate DB contention or recovery
API_TIME=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{time_total}" \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  "$BASE_URL/rest/v1/targets?limit=1" || true)
if awk "BEGIN { exit ($API_TIME < 3) ? 0 : 1 }"; then
  pass "API response time acceptable (${API_TIME}s < 3s)"
else
  fail "API response slow (${API_TIME}s ≥ 3s) — possible DB trouble"
fi

# Write persistence — verifies DB is writable, not just readable.
# Creates a distribution set, reads it back, then deletes it.
echo "── DB write persistence"
DS_BODY=$(curl "${CURL_OPTS[@]}" -X POST \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  -H "Content-Type: application/json" \
  -d '[{"name":"live-test-ds","version":"0.0.0-test","type":"app"}]' \
  "$BASE_URL/rest/v1/distributionsets" || true)
DS_ID=$(echo "$DS_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null || true)
if [[ -n "$DS_ID" ]]; then
  pass "Distribution set created (id: $DS_ID)"
  # Read it back to confirm write persisted
  READ_STATUS=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
    -u "$ADMIN_USER:$ADMIN_PASS" \
    "$BASE_URL/rest/v1/distributionsets/$DS_ID" || true)
  if [[ "$READ_STATUS" == "200" ]]; then
    pass "Write persisted — read back succeeded"
  else
    fail "Write not persisted — read back → $READ_STATUS"
  fi
  # Clean up
  curl "${CURL_OPTS[@]}" -X DELETE \
    -u "$ADMIN_USER:$ADMIN_PASS" \
    "$BASE_URL/rest/v1/distributionsets/$DS_ID" > /dev/null 2>&1 || true
else
  fail "Distribution set creation failed — DB may be down or read-only"
fi

# Swagger UI (served by mgmt in microservices mode, monolith otherwise)
echo "── Swagger UI"
STATUS=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
  "$BASE_URL/swagger-ui/index.html" || true)
if [[ "$STATUS" == "200" ]]; then
  pass "swagger-ui/index.html → $STATUS"
else
  fail "swagger-ui/index.html → $STATUS (expected 200)"
fi

# DDI controller endpoint — 200 = anonymous OK, 401 = auth required; either confirms correct routing
echo "── DDI"
DDI_STATUS=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
  "$BASE_URL/DEFAULT/controller/v1/live-test-probe" || true)
if [[ "$DDI_STATUS" == "200" || "$DDI_STATUS" == "401" ]]; then
  pass "DDI /DEFAULT/controller/v1/live-test-probe → $DDI_STATUS"
else
  fail "DDI /DEFAULT/controller/v1/live-test-probe → $DDI_STATUS (expected 200 or 401)"
fi
# Clean up auto-registered device if DDI access succeeded
if [[ "$DDI_STATUS" == "200" ]]; then
  curl "${CURL_OPTS[@]}" -X DELETE \
    -u "$ADMIN_USER:$ADMIN_PASS" \
    "$BASE_URL/rest/v1/targets/live-test-probe" > /dev/null 2>&1 || true
fi

# GUI (only if deployed for this env)
if [[ "$GUI_ENABLED" == "true" ]]; then
  GUI_URL="${BASE_URL/hawkbit./hawkbitgui.}"
  echo "── GUI"

  # Unauthenticated homepage — NextAuth redirects unauthenticated users (307) or shows login page (200)
  STATUS=$(curl "${CURL_OPTS[@]}" -o /dev/null -w "%{http_code}" \
    "$GUI_URL/" || true)
  if [[ "$STATUS" == "200" || "$STATUS" == "307" ]]; then
    pass "GUI $GUI_URL/ → $STATUS"
  else
    fail "GUI $GUI_URL/ → $STATUS (expected 200 or 307)"
  fi

  # NextAuth login flow: get CSRF token, then POST credentials
  COOKIE_JAR=$(mktemp)
  CSRF_TOKEN=$(curl "${CURL_OPTS[@]}" -c "$COOKIE_JAR" \
    "$GUI_URL/api/auth/csrf" | python3 -c "import sys,json; print(json.load(sys.stdin)['csrfToken'])" 2>/dev/null || true)

  if [[ -n "$CSRF_TOKEN" ]]; then
    pass "GUI CSRF token obtained"

    LOGIN_STATUS=$(curl "${CURL_OPTS[@]}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=${ADMIN_USER}&password=${ADMIN_PASS}&csrfToken=${CSRF_TOKEN}&callbackUrl=/" \
      "$GUI_URL/api/auth/callback/credentials" || true)
    # NextAuth redirects to callbackUrl on success (302) or to error page on failure
    if [[ "$LOGIN_STATUS" == "200" || "$LOGIN_STATUS" == "302" ]]; then
      pass "GUI login → $LOGIN_STATUS"

      # Authenticated request through GUI's hawkbit API proxy
      # The proxy route prepends /rest/v1/ internally, so omit it here
      PROXY_STATUS=$(curl "${CURL_OPTS[@]}" -b "$COOKIE_JAR" \
        -o /dev/null -w "%{http_code}" \
        "$GUI_URL/api/hawkbit/targets?limit=1" || true)
      if [[ "$PROXY_STATUS" == "200" ]]; then
        pass "GUI /api/hawkbit proxy → $PROXY_STATUS"
      else
        fail "GUI /api/hawkbit proxy → $PROXY_STATUS (expected 200)"
      fi
    else
      fail "GUI login → $LOGIN_STATUS (expected 200 or 302)"
    fi
  else
    fail "GUI CSRF token request failed"
  fi
  rm -f "$COOKIE_JAR"
fi

# Artifact upload/download lifecycle (verifies fileStorage is mounted and writable)
echo "── Artifact download"
TMP_FILE=$(mktemp)
echo "hawkbit-live-test-payload" > "$TMP_FILE"
TMP_SHA1=$(shasum -a 1 "$TMP_FILE" | awk '{print $1}')
TMP_MD5=$(md5 -q "$TMP_FILE" 2>/dev/null || md5sum "$TMP_FILE" | awk '{print $1}')

# Create software module
SM_BODY=$(curl "${CURL_OPTS[@]}" -X POST \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  -H "Content-Type: application/json" \
  -d '[{"name":"live-test-sm","version":"1.0.0","type":"os"}]' \
  "$BASE_URL/rest/v1/softwaremodules" || true)
SM_ID=$(echo "$SM_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null || true)

if [[ -n "$SM_ID" ]]; then
  pass "Software module created (id: $SM_ID)"

  # Upload artifact
  ARTIFACT_BODY=$(curl "${CURL_OPTS[@]}" --max-time 60 -X POST \
    -u "$ADMIN_USER:$ADMIN_PASS" \
    -F "file=@$TMP_FILE;filename=live-test.bin" \
    "$BASE_URL/rest/v1/softwaremodules/$SM_ID/artifacts" || true)
  ARTIFACT_ID=$(echo "$ARTIFACT_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)

  if [[ -n "$ARTIFACT_ID" ]]; then
    pass "Artifact uploaded (id: $ARTIFACT_ID)"

    # Download artifact and verify checksum
    DOWNLOAD_TMP=$(mktemp)
    DL_STATUS=$(curl "${CURL_OPTS[@]}" -o "$DOWNLOAD_TMP" -w "%{http_code}" \
      -u "$ADMIN_USER:$ADMIN_PASS" \
      "$BASE_URL/rest/v1/softwaremodules/$SM_ID/artifacts/$ARTIFACT_ID/download" || true)
    if [[ "$DL_STATUS" == "200" ]]; then
      DL_SHA1=$(shasum -a 1 "$DOWNLOAD_TMP" | awk '{print $1}')
      if [[ "$DL_SHA1" == "$TMP_SHA1" ]]; then
        pass "Artifact downloaded and checksum verified"
      else
        fail "Artifact download checksum mismatch (got $DL_SHA1, expected $TMP_SHA1)"
      fi
    else
      fail "Artifact download → $DL_STATUS (expected 200)"
    fi
    rm -f "$DOWNLOAD_TMP"
  else
    fail "Artifact upload failed"
  fi

  # Cleanup software module
  curl "${CURL_OPTS[@]}" -X DELETE \
    -u "$ADMIN_USER:$ADMIN_PASS" \
    "$BASE_URL/rest/v1/softwaremodules/$SM_ID" > /dev/null 2>&1 || true
else
  fail "Software module creation failed"
fi
rm -f "$TMP_FILE"

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "All tests passed ✅"
else
  echo "One or more tests failed ❌"
  exit 1
fi
