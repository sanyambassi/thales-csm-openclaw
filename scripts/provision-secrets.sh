#!/usr/bin/env bash
#
# Provisions LLM provider API keys into CipherTrust Secrets Manager (powered by Akeyless).
# Run this once during initial setup, or when rotating keys.
#
# Credentials are resolved in this order (first non-empty wins):
#   1. Admin-specific flags/env vars (--admin-access-id / AKEYLESS_ADMIN_ACCESS_ID)
#   2. General flags/env vars (--access-id / AKEYLESS_ACCESS_ID)
#   3. .env file in the repo root (auto-loaded if present)
#   4. Interactive prompts
#
# Usage:
#   # Interactive - prompts for credentials and each provider key
#   ./provision-secrets.sh
#
#   # With admin credentials (recommended when using separate read-only + admin roles)
#   ./provision-secrets.sh \
#     --gateway-url "https://host/akeyless-api" \
#     --admin-access-id "p-admin-..." --admin-access-key "..." \
#     --openai "sk-..." --no-prompt
#
#   # Falls back to read-only credentials from .env if no admin creds given
#   ./provision-secrets.sh --openai "sk-..." --no-prompt
#
#   # Only create/update the OpenClaw gateway token (required for gateway to start)
#   ./provision-secrets.sh --generate-gateway-token --no-prompt

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults & arg parsing
# ---------------------------------------------------------------------------

GATEWAY_URL="${AKEYLESS_GATEWAY_URL:-${GATEWAY_URL:-}}"
ADMIN_ACCESS_ID="${AKEYLESS_ADMIN_ACCESS_ID:-}"
ADMIN_ACCESS_KEY="${AKEYLESS_ADMIN_ACCESS_KEY:-}"
ACCESS_ID="${AKEYLESS_ACCESS_ID:-${ACCESS_ID:-}}"
ACCESS_KEY="${AKEYLESS_ACCESS_KEY:-${ACCESS_KEY:-}}"
SECRET_PREFIX="${AKEYLESS_SECRET_PREFIX:-${SECRET_PREFIX:-/openclaw}}"
NO_PROMPT=false

declare -A KEY_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway-url)       GATEWAY_URL="$2"; shift 2;;
    --admin-access-id)   ADMIN_ACCESS_ID="$2"; shift 2;;
    --admin-access-key)  ADMIN_ACCESS_KEY="$2"; shift 2;;
    --access-id)         ACCESS_ID="$2"; shift 2;;
    --access-key)        ACCESS_KEY="$2"; shift 2;;
    --secret-prefix)     SECRET_PREFIX="$2"; shift 2;;
    --no-prompt)     NO_PROMPT=true; shift;;
    --generate-gateway-token)
      KEY_ARGS[gateway/auth-token]="$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || openssl rand -hex 32 2>/dev/null)"
      if [[ -z "${KEY_ARGS[gateway/auth-token]}" ]]; then
        echo "Need python3 or openssl for --generate-gateway-token"; exit 1
      fi
      shift;;
    --openai)        KEY_ARGS[providers/openai-api-key]="$2"; shift 2;;
    --google)        KEY_ARGS[providers/google-api-key]="$2"; shift 2;;
    --anthropic)     KEY_ARGS[providers/anthropic-api-key]="$2"; shift 2;;
    --xai)           KEY_ARGS[providers/xai-api-key]="$2"; shift 2;;
    --perplexity)    KEY_ARGS[providers/perplexity-api-key]="$2"; shift 2;;
    --mistral)       KEY_ARGS[providers/mistral-api-key]="$2"; shift 2;;
    --groq)          KEY_ARGS[providers/groq-api-key]="$2"; shift 2;;
    --openrouter)    KEY_ARGS[providers/openrouter-api-key]="$2"; shift 2;;
    --together)      KEY_ARGS[providers/together-api-key]="$2"; shift 2;;
    --cerebras)      KEY_ARGS[providers/cerebras-api-key]="$2"; shift 2;;
    --nvidia)        KEY_ARGS[providers/nvidia-api-key]="$2"; shift 2;;
    --huggingface)   KEY_ARGS[providers/huggingface-api-key]="$2"; shift 2;;
    --minimax)       KEY_ARGS[providers/minimax-api-key]="$2"; shift 2;;
    --moonshot)      KEY_ARGS[providers/moonshot-api-key]="$2"; shift 2;;
    --kimi)          KEY_ARGS[providers/kimi-api-key]="$2"; shift 2;;
    --venice)        KEY_ARGS[providers/venice-api-key]="$2"; shift 2;;
    --zai)           KEY_ARGS[providers/zai-api-key]="$2"; shift 2;;
    --opencode)      KEY_ARGS[providers/opencode-api-key]="$2"; shift 2;;
    --kilocode)      KEY_ARGS[providers/kilocode-api-key]="$2"; shift 2;;
    --vercel-ai-gw)  KEY_ARGS[providers/vercel-ai-gateway-api-key]="$2"; shift 2;;
    --cloudflare-ai-gw) KEY_ARGS[providers/cloudflare-ai-gateway-api-key]="$2"; shift 2;;
    --volcengine)    KEY_ARGS[providers/volcengine-api-key]="$2"; shift 2;;
    --byteplus)      KEY_ARGS[providers/byteplus-api-key]="$2"; shift 2;;
    --synthetic)     KEY_ARGS[providers/synthetic-api-key]="$2"; shift 2;;
    --qianfan)       KEY_ARGS[providers/qianfan-api-key]="$2"; shift 2;;
    --modelstudio)   KEY_ARGS[providers/modelstudio-api-key]="$2"; shift 2;;
    --xiaomi)        KEY_ARGS[providers/xiaomi-api-key]="$2"; shift 2;;
    --brave)         KEY_ARGS[websearch/brave-api-key]="$2"; shift 2;;
    --firecrawl)     KEY_ARGS[websearch/firecrawl-api-key]="$2"; shift 2;;
    --tavily)        KEY_ARGS[websearch/tavily-api-key]="$2"; shift 2;;
    --gateway-token) KEY_ARGS[gateway/auth-token]="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ---------------------------------------------------------------------------
# Auto-load .env if present (look in script dir parent or cwd)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

load_env_file() {
  local envfile="$1"
  if [[ -f "$envfile" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line// /}"
      [[ -z "$line" ]] && continue
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        local key="${BASH_REMATCH[1]}"
        local val="${BASH_REMATCH[2]}"
        val="${val%\"}" ; val="${val#\"}"
        val="${val%\'}" ; val="${val#\'}"
        if [[ -z "${!key:-}" ]]; then
          export "$key=$val"
        fi
      fi
    done < "$envfile"
  fi
}

for candidate in "$REPO_ROOT/.env" "$PWD/.env"; do
  load_env_file "$candidate"
done

# Re-read after .env load (env vars might have been set)
GATEWAY_URL="${GATEWAY_URL:-${AKEYLESS_GATEWAY_URL:-}}"
ADMIN_ACCESS_ID="${ADMIN_ACCESS_ID:-${AKEYLESS_ADMIN_ACCESS_ID:-}}"
ADMIN_ACCESS_KEY="${ADMIN_ACCESS_KEY:-${AKEYLESS_ADMIN_ACCESS_KEY:-}}"
ACCESS_ID="${ACCESS_ID:-${AKEYLESS_ACCESS_ID:-}}"
ACCESS_KEY="${ACCESS_KEY:-${AKEYLESS_ACCESS_KEY:-}}"

# Admin credentials take priority over read-only ones
EFFECTIVE_ID="${ADMIN_ACCESS_ID:-$ACCESS_ID}"
EFFECTIVE_KEY="${ADMIN_ACCESS_KEY:-$ACCESS_KEY}"

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

prompt_value() {
  local label="$1" default="$2"
  if [[ -n "$default" ]]; then echo "$default"; return; fi
  if $NO_PROMPT; then echo ""; return; fi
  read -rp "  $label: " val
  echo "$val"
}

prompt_secret() {
  local label="$1" default="$2"
  if [[ -n "$default" ]]; then echo "$default"; return; fi
  if $NO_PROMPT; then echo ""; return; fi
  read -rsp "  $label: " val
  if [[ -n "$val" ]]; then
    echo -e " ********" >&2
  else
    echo "" >&2
  fi
  echo "$val"
}

# ---------------------------------------------------------------------------
# Prompt for missing credentials
# ---------------------------------------------------------------------------

if [[ -z "$GATEWAY_URL" ]]; then
  GATEWAY_URL=$(prompt_value "CipherTrust Secrets Manager URL (e.g. https://host/akeyless-api)" "")
fi
GATEWAY_URL="${GATEWAY_URL%/}"

if [[ -z "$EFFECTIVE_ID" ]]; then
  EFFECTIVE_ID=$(prompt_value "Admin Access ID (or read-only if same role)" "")
fi
if [[ -z "$EFFECTIVE_KEY" ]]; then
  EFFECTIVE_KEY=$(prompt_secret "Admin Access Key" "")
fi

if [[ -z "$GATEWAY_URL" || -z "$EFFECTIVE_ID" || -z "$EFFECTIVE_KEY" ]]; then
  echo -e "\n  ${RED}Error: CipherTrust URL, Access ID, and Access Key are all required.${NC}"
  exit 1
fi

# ---------------------------------------------------------------------------
# curl helper
# ---------------------------------------------------------------------------

api_post() {
  local endpoint="$1" body="$2"
  curl -sS --max-time 30 \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${GATEWAY_URL}${endpoint}" 2>&1
}

# ---------------------------------------------------------------------------
# Authenticate
# ---------------------------------------------------------------------------

echo -e "\n${CYAN}[1/3] Authenticating with CipherTrust Secrets Manager...${NC}"
if [[ -n "$ADMIN_ACCESS_ID" ]]; then
  echo -e "  Using admin credentials"
fi
AUTH_RESP=$(api_post "/v2/auth" "{\"access-id\":\"${EFFECTIVE_ID}\",\"access-key\":\"${EFFECTIVE_KEY}\",\"access-type\":\"access_key\"}" || true)
# Parse token with JSON (API may return "token": "..." with spaces — grep '"token":"' misses that)
TOKEN=$(printf '%s' "$AUTH_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("token") or "")' 2>/dev/null || true)
if [[ -z "$TOKEN" ]]; then
  TOKEN=$(printf '%s' "$AUTH_RESP" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi

if [[ -z "$TOKEN" ]]; then
  echo -e "  ${RED}Authentication failed${NC}"
  echo "$AUTH_RESP"
  exit 1
fi
echo -e "  ${GREEN}Authenticated (token prefix: ${TOKEN:0:12}...)${NC}"

# ---------------------------------------------------------------------------
# Collect keys
# ---------------------------------------------------------------------------

echo -e "\n${CYAN}[2/3] Collecting API keys (Gateway token first — required for OpenClaw; press Enter to skip optional providers)...${NC}"

PROVIDERS=(
  "gateway/auth-token|OpenClaw Gateway Auth Token (required)|OPENCLAW_GATEWAY_TOKEN"
  "providers/openai-api-key|OpenAI API Key|OPENAI_API_KEY"
  "providers/google-api-key|Google/Gemini Key|GEMINI_API_KEY"
  "providers/anthropic-api-key|Anthropic API Key|ANTHROPIC_API_KEY"
  "providers/xai-api-key|xAI/Grok API Key|XAI_API_KEY"
  "providers/perplexity-api-key|Perplexity API Key|PERPLEXITY_API_KEY"
  "providers/mistral-api-key|Mistral API Key|MISTRAL_API_KEY"
  "providers/groq-api-key|Groq API Key|GROQ_API_KEY"
  "providers/openrouter-api-key|OpenRouter API Key|OPENROUTER_API_KEY"
  "providers/together-api-key|Together API Key|TOGETHER_API_KEY"
  "providers/cerebras-api-key|Cerebras API Key|CEREBRAS_API_KEY"
  "providers/nvidia-api-key|NVIDIA API Key|NVIDIA_API_KEY"
  "providers/huggingface-api-key|Hugging Face Token|HF_TOKEN"
  "providers/minimax-api-key|MiniMax API Key|MINIMAX_API_KEY"
  "providers/moonshot-api-key|Moonshot API Key|MOONSHOT_API_KEY"
  "providers/kimi-api-key|Kimi API Key|KIMI_API_KEY"
  "providers/venice-api-key|Venice API Key|VENICE_API_KEY"
  "providers/zai-api-key|Z.AI API Key|ZAI_API_KEY"
  "providers/opencode-api-key|OpenCode API Key|OPENCODE_API_KEY"
  "providers/kilocode-api-key|KiloCode API Key|KILOCODE_API_KEY"
  "providers/vercel-ai-gateway-api-key|Vercel AI Gateway Key|AI_GATEWAY_API_KEY"
  "providers/cloudflare-ai-gateway-api-key|Cloudflare AI Gateway Key|CLOUDFLARE_AI_GATEWAY_API_KEY"
  "providers/volcengine-api-key|VolcEngine API Key|VOLCANO_ENGINE_API_KEY"
  "providers/byteplus-api-key|BytePlus API Key|BYTEPLUS_API_KEY"
  "providers/synthetic-api-key|Synthetic API Key|SYNTHETIC_API_KEY"
  "providers/qianfan-api-key|Qianfan API Key|QIANFAN_API_KEY"
  "providers/modelstudio-api-key|ModelStudio API Key|MODELSTUDIO_API_KEY"
  "providers/xiaomi-api-key|Xiaomi API Key|XIAOMI_API_KEY"
  "websearch/brave-api-key|Brave Search Key|BRAVE_API_KEY"
  "websearch/firecrawl-api-key|Firecrawl Search Key|FIRECRAWL_API_KEY"
  "websearch/tavily-api-key|Tavily Search Key|TAVILY_API_KEY"
)

declare -A SECRETS=()

for entry in "${PROVIDERS[@]}"; do
  IFS='|' read -r path name hint <<< "$entry"
  existing="${KEY_ARGS[$path]:-}"
  val=$(prompt_value "$name [$hint]" "$existing")
  if [[ -n "$val" ]]; then
    SECRETS[$path]="$val"
  fi
done

if [[ ${#SECRETS[@]} -eq 0 ]]; then
  echo -e "\n  ${YELLOW}No keys provided - nothing to provision.${NC}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Provision
# ---------------------------------------------------------------------------

echo -e "\n${CYAN}[3/3] Provisioning ${#SECRETS[@]} secret(s) in CipherTrust Secrets Manager...${NC}"

created=0; updated=0; failed=0

for path in "${!SECRETS[@]}"; do
  full_path="${SECRET_PREFIX}/${path}"
  value="${SECRETS[$path]}"
  printf "  %s ... " "$full_path"

  json_value=$(printf '%s' "$value" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$value")
  body="{\"name\":\"${full_path}\",\"value\":${json_value},\"token\":\"${TOKEN}\"}"

  resp=$(api_post "/v2/create-secret" "$body" || true)
  if echo "$resp" | grep -qi "already exists\|AlreadyExists"; then
    resp=$(api_post "/v2/update-secret-val" "$body" || true)
    if echo "$resp" | grep -qi "error\|fail"; then
      echo -e "${RED}FAILED (update)${NC}"
      ((failed++))
    else
      echo -e "${YELLOW}UPDATED${NC}"
      ((updated++))
    fi
  elif echo "$resp" | grep -qi "error\|fail"; then
    echo -e "${RED}FAILED${NC}"
    echo "    $resp" >&2
    ((failed++))
  else
    echo -e "${GREEN}CREATED${NC}"
    ((created++))
  fi
done

echo -e "\n${CYAN}Done: $created created, $updated updated, $failed failed.${NC}"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo -e "\n${CYAN}Verification - retrieving all provisioned secrets...${NC}"

for path in "${!SECRETS[@]}"; do
  full_path="${SECRET_PREFIX}/${path}"
  body="{\"names\":[\"${full_path}\"],\"token\":\"${TOKEN}\"}"
  resp=$(api_post "/v2/get-secret-value" "$body" || true)
  val=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('${full_path}',''))" 2>/dev/null || echo "")
  if [[ -n "$val" ]]; then
    masked="${val:0:8}..."
    echo -e "  ${GREEN}${full_path} = ${masked}${NC}"
  else
    echo -e "  ${RED}${full_path} = (empty/null)${NC}"
  fi
done

echo -e "\n${CYAN}Provisioning complete.${NC}"
