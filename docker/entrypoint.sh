#!/bin/sh

# Resolve provisioned API keys from CipherTrust Secrets Manager as env vars.
# 
# Flow:
#   1. List what secrets exist under /openclaw/providers/ (one API call)
#   2. Match against known provider→env-var mappings
#   3. Batch-fetch only the matching secrets (one API call)
#   4. Export each as an env var
#
# Total: 3 API calls (auth + list + batch) regardless of how many providers are supported.

SECRET_PREFIX="${AKEYLESS_SECRET_PREFIX:-/openclaw}"

# Map: secret-id=ENV_VAR_NAME
PROVIDER_MAP="
providers/openai-api-key=OPENAI_API_KEY
providers/anthropic-api-key=ANTHROPIC_API_KEY
providers/google-api-key=GEMINI_API_KEY
providers/xai-api-key=XAI_API_KEY
providers/perplexity-api-key=PERPLEXITY_API_KEY
providers/mistral-api-key=MISTRAL_API_KEY
providers/groq-api-key=GROQ_API_KEY
providers/openrouter-api-key=OPENROUTER_API_KEY
providers/together-api-key=TOGETHER_API_KEY
providers/cerebras-api-key=CEREBRAS_API_KEY
providers/nvidia-api-key=NVIDIA_API_KEY
providers/huggingface-api-key=HF_TOKEN
providers/minimax-api-key=MINIMAX_API_KEY
providers/moonshot-api-key=MOONSHOT_API_KEY
providers/kimi-api-key=KIMI_API_KEY
providers/venice-api-key=VENICE_API_KEY
providers/zai-api-key=ZAI_API_KEY
providers/opencode-api-key=OPENCODE_API_KEY
providers/kilocode-api-key=KILOCODE_API_KEY
providers/vercel-ai-gateway-api-key=AI_GATEWAY_API_KEY
providers/cloudflare-ai-gateway-api-key=CLOUDFLARE_AI_GATEWAY_API_KEY
providers/volcengine-api-key=VOLCANO_ENGINE_API_KEY
providers/byteplus-api-key=BYTEPLUS_API_KEY
providers/synthetic-api-key=SYNTHETIC_API_KEY
providers/qianfan-api-key=QIANFAN_API_KEY
providers/modelstudio-api-key=MODELSTUDIO_API_KEY
providers/xiaomi-api-key=XIAOMI_API_KEY
"

if [ -n "$AKEYLESS_GATEWAY_URL" ] && [ -n "$AKEYLESS_ACCESS_ID" ]; then

  # Step 1: List provisioned secrets (auth + list-items = 2 API calls)
  AVAILABLE=$(node /usr/local/bin/akeyless-resolver --secret-prefix "$SECRET_PREFIX" --list 2>/dev/null)

  if [ -n "$AVAILABLE" ] && [ "$AVAILABLE" != "[]" ]; then

    # Step 2: Build request with only secrets that exist AND whose env var isn't already set
    IDS_JSON="["
    MATCH_MAP=""
    FIRST=true
    for ENTRY in $PROVIDER_MAP; do
      [ -z "$ENTRY" ] && continue
      SECRET_ID="${ENTRY%%=*}"
      ENV_NAME="${ENTRY#*=}"

      # printenv is safer than eval for checking existing env vars
      if printenv "$ENV_NAME" >/dev/null 2>&1; then continue; fi

      case "$AVAILABLE" in
        *"\"$SECRET_ID\""*)
          if [ "$FIRST" = true ]; then FIRST=false; else IDS_JSON="$IDS_JSON,"; fi
          IDS_JSON="$IDS_JSON\"$SECRET_ID\""
          MATCH_MAP="$MATCH_MAP $SECRET_ID=$ENV_NAME"
          ;;
      esac
    done
    IDS_JSON="$IDS_JSON]"

    if [ "$IDS_JSON" != "[]" ]; then
      # Step 3: Batch-fetch (1 API call) and extract all values in a single node invocation
      RESOLVED=$(printf '{"protocolVersion":1,"provider":"akeyless","ids":%s}' "$IDS_JSON" \
        | node /usr/local/bin/akeyless-resolver --secret-prefix "$SECRET_PREFIX" 2>/dev/null)

      if [ -n "$RESOLVED" ]; then
        RESOLVED_COUNT=0
        EXPORTS=$(echo "$RESOLVED" | node -e "
          let d='';process.stdin.on('data',c=>d+=c);
          process.stdin.on('end',()=>{
            try{
              const v=JSON.parse(d).values||{};
              const map='$MATCH_MAP'.trim().split(' ');
              for(const m of map){
                const [sid,env]=m.split('=');
                if(v[sid])console.log(env+'='+v[sid]);
              }
            }catch{}
          })
        " 2>/dev/null)

        IFS_OLD="$IFS"; IFS="
"
        for LINE in $EXPORTS; do
          ENV_NAME="${LINE%%=*}"
          VAL="${LINE#*=}"
          if [ -n "$VAL" ]; then
            export "$ENV_NAME=$VAL"
            RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
          fi
        done
        IFS="$IFS_OLD"

        echo "[entrypoint] Resolved $RESOLVED_COUNT API key(s) from CipherTrust Secrets Manager"
      fi
    else
      echo "[entrypoint] All provisioned keys already set via env — skipping"
    fi
  else
    echo "[entrypoint] No secrets found under ${SECRET_PREFIX}/providers/ — skipping"
  fi
fi

# Start the rotation webhook in the background (if enabled)
if [ "$ROTATION_WEBHOOK_ENABLED" = "true" ]; then
  node /usr/local/bin/rotation-webhook.js &
  echo "[entrypoint] Rotation webhook started on port ${ROTATION_WEBHOOK_PORT:-9090}"
fi

# Hand off to the original OpenClaw entrypoint
exec "$@"
