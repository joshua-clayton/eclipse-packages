#!/usr/bin/env bash
# Render the helm chart for a given env and compare against a golden snapshot.
# Usage:
#   render-test.sh <env>          — render and diff against golden file
#   render-test.sh <env> --update — render and update golden file
#
# Env values: devops | int
set -euo pipefail

cd "$(dirname "$0")/.."

ARGOCD_VALUES="$HOME/src/argocd/values/infrastructure/hawkbit"

ENV="${1:-}"
UPDATE=0
[[ "${2:-}" == "--update" ]] && UPDATE=1

if [[ -z "$ENV" ]]; then
  echo "Usage: $0 <env> [--update]  (env: devops | int)" >&2
  exit 1
fi

case "$ENV" in
  devops|int) ;;
  *)
    echo "Unknown env: $ENV. Must be 'devops' or 'int'." >&2
    exit 1
    ;;
esac

GOLDEN="test/golden/$ENV.yaml"

echo "=== hawkbit-$ENV render test ==="

RENDERED=$(helm template "hawkbit-$ENV" . \
  -f "$ARGOCD_VALUES/common.yaml" \
  -f "$ARGOCD_VALUES/$ENV.yaml" 2>&1)

if [[ $? -ne 0 ]]; then
  echo "❌ helm template failed:"
  echo "$RENDERED"
  exit 1
fi

if [[ "$UPDATE" -eq 1 ]]; then
  echo "$RENDERED" > "$GOLDEN"
  echo "✅ Golden file updated: $GOLDEN"
  exit 0
fi

if [[ ! -f "$GOLDEN" ]]; then
  echo "No golden file found at $GOLDEN."
  echo "Run with --update to create it:"
  echo "  $0 $ENV --update"
  exit 1
fi

DIFF=$(diff <(echo "$RENDERED") "$GOLDEN" || true)

if [[ -z "$DIFF" ]]; then
  echo "✅ Rendered output matches golden file"
else
  echo "❌ Rendered output differs from golden file:"
  echo ""
  echo "$DIFF"
  echo ""
  echo "If these changes are intentional, run:"
  echo "  $0 $ENV --update"
  exit 1
fi
