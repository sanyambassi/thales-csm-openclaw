#!/usr/bin/env bash
#
# End-to-end test suite for akeyless-resolver.js against a live CipherTrust Secrets Manager.
#
# Usage:
#   # With env vars
#   export AKEYLESS_ACCESS_ID="p-..." AKEYLESS_ACCESS_KEY="..."
#   ./test-resolver.sh
#
#   # With flags
#   ./test-resolver.sh --gateway-url "https://host/akeyless-api" --access-id "p-..." --access-key "..."

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults & arg parsing
# ---------------------------------------------------------------------------

GATEWAY_URL="${GATEWAY_URL:-${AKEYLESS_GATEWAY_URL:-}}"
ACCESS_ID="${AKEYLESS_ACCESS_ID:-}"
ACCESS_KEY="${AKEYLESS_ACCESS_KEY:-}"
SECRET_PREFIX="${SECRET_PREFIX:-/openclaw}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway-url)   GATEWAY_URL="$2"; shift 2;;
    --access-id)     ACCESS_ID="$2"; shift 2;;
    --access-key)    ACCESS_KEY="$2"; shift 2;;
    --secret-prefix) SECRET_PREFIX="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/../docker/akeyless-resolver.js"

export AKEYLESS_ACCESS_ID="$ACCESS_ID"
export AKEYLESS_ACCESS_KEY="$ACCESS_KEY"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

PASSED=0; FAILED=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

assert() {
  local name="$1" condition="$2"
  if [[ "$condition" == "true" ]]; then
    echo -e "  ${GREEN}PASS: ${name}${NC}"
    ((PASSED++))
  else
    echo -e "  ${RED}FAIL: ${name}${NC}"
    ((FAILED++))
  fi
}

run_resolver() {
  local input="$1"; shift
  echo "$input" | node "$RESOLVER" --gateway-url "$GATEWAY_URL" --secret-prefix "$SECRET_PREFIX" "$@" 2>/dev/null || true
}

run_resolver_no_stdin() {
  node "$RESOLVER" --gateway-url "$GATEWAY_URL" "$@" 2>/dev/null || true
}

api_post() {
  local endpoint="$1" body="$2"
  curl -sS --max-time 30 -H "Content-Type: application/json" -d "$body" "${GATEWAY_URL}${endpoint}"
}

# ---------------------------------------------------------------------------
# Setup: create a test secret
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}=== Setup ===${NC}"
AUTH_RESP=$(api_post "/v2/auth" "{\"access-id\":\"${ACCESS_ID}\",\"access-key\":\"${ACCESS_KEY}\",\"access-type\":\"access_key\"}")
TOKEN=$(echo "$AUTH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
  echo -e "  ${RED}Authentication failed${NC}"
  exit 1
fi
echo -e "  ${GREEN}Authenticated${NC}"

TEST_PATH="${SECRET_PREFIX}/test/resolver-e2e"
TEST_VALUE="e2e-value-${RANDOM}"

# Clean up any existing test secret
api_post "/v2/delete-item" "{\"name\":\"${TEST_PATH}\",\"token\":\"${TOKEN}\"}" >/dev/null 2>&1 || true

# Create test secret
api_post "/v2/create-secret" "{\"name\":\"${TEST_PATH}\",\"value\":\"${TEST_VALUE}\",\"token\":\"${TOKEN}\"}" >/dev/null
echo -e "  ${GREEN}Created: ${TEST_PATH}${NC}"

# ---------------------------------------------------------------------------
# Test 1: Health check
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}=== Test 1: Health Check ===${NC}"
RESULT=$(run_resolver_no_stdin --health-check)
assert "stdout contains ok" "$(echo "$RESULT" | grep -q '"ok"' && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 2: Single secret
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}=== Test 2: Single Secret ===${NC}"
RESULT=$(run_resolver '{"protocolVersion":1,"provider":"akeyless","ids":["test/resolver-e2e"]}')
PROTO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('protocolVersion',''))" 2>/dev/null || echo "")
RESOLVED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('values',{}).get('test/resolver-e2e',''))" 2>/dev/null || echo "")
assert "protocolVersion is 1" "$([ "$PROTO" = "1" ] && echo true || echo false)"
assert "value matches" "$([ "$RESOLVED" = "$TEST_VALUE" ] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 3: Batch with one missing
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}=== Test 3: Batch (1 valid + 1 missing) ===${NC}"
RESULT=$(run_resolver '{"protocolVersion":1,"provider":"akeyless","ids":["test/resolver-e2e","test/nonexistent-xyz"]}')
VAL3=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('values',{}).get('test/resolver-e2e',''))" 2>/dev/null || echo "")
ERR3=$(echo "$RESULT" | python3 -c "import sys,json; e=json.load(sys.stdin).get('errors',{}).get('test/nonexistent-xyz'); print('yes' if e else 'no')" 2>/dev/null || echo "no")
assert "valid secret resolved" "$([ "$VAL3" = "$TEST_VALUE" ] && echo true || echo false)"
assert "missing secret reported in errors" "$([ "$ERR3" = "yes" ] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 4: Empty IDs
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}=== Test 4: Empty IDs ===${NC}"
RESULT=$(run_resolver '{"protocolVersion":1,"provider":"akeyless","ids":[]}')
PROTO4=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('protocolVersion',''))" 2>/dev/null || echo "")
assert "protocolVersion is 1" "$([ "$PROTO4" = "1" ] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 5: List mode
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}=== Test 5: List Mode ===${NC}"
RESULT=$(run_resolver_no_stdin --secret-prefix "$SECRET_PREFIX" --list)
HAS_TEST=$(echo "$RESULT" | python3 -c "import sys,json; items=json.load(sys.stdin); print('yes' if 'test/resolver-e2e' in items else 'no')" 2>/dev/null || echo "no")
assert "list includes test secret" "$([ "$HAS_TEST" = "yes" ] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}=== Cleanup ===${NC}"
api_post "/v2/delete-item" "{\"name\":\"${TEST_PATH}\",\"token\":\"${TOKEN}\"}" >/dev/null 2>&1 || true
echo -e "  ${GREEN}Deleted test secret${NC}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}=== Results ===${NC}"
echo -e "  ${GREEN}Passed: ${PASSED}${NC}"
if [[ $FAILED -gt 0 ]]; then
  echo -e "  ${RED}Failed: ${FAILED}${NC}"
  exit 1
else
  echo -e "  ${GREEN}Failed: ${FAILED}${NC}"
  exit 0
fi
