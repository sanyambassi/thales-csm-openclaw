#!/bin/sh

# CipherTrust Secrets Manager entrypoint for OpenClaw.
#
# LLM API keys and the gateway auth token are resolved natively by
# OpenClaw's SecretRef system (in-memory snapshot, no env vars).
#
# Web search provider keys (Brave, Firecrawl, Tavily, Perplexity) are
# resolved from CipherTrust at startup and exported as env vars, since
# OpenClaw's web search subsystem reads them from the environment.
#
# This entrypoint handles three tasks before handing off to OpenClaw:
#   1. Resolve web search API keys from CipherTrust → env vars
#   2. Apply per-provider baseUrl overrides from env vars
#   3. Start the rotation webhook (if enabled)

CONFIG="/home/node/.openclaw/openclaw.json"

# ---------------------------------------------------------------------------
# 1. Resolve web search API keys from CipherTrust
#    Stored under /openclaw/websearch/ — exported as env vars for OpenClaw's
#    web search subsystem. Only provisioned keys are exported; missing keys
#    are silently skipped.
# ---------------------------------------------------------------------------

if [ -n "$AKEYLESS_GATEWAY_URL" ] && [ -n "$AKEYLESS_ACCESS_ID" ] && [ -n "$AKEYLESS_ACCESS_KEY" ]; then
  eval "$(node -e '
    const https = require("https");
    const http = require("http");
    const GW = (process.env.AKEYLESS_GATEWAY_URL || "").replace(/\/+$/, "");
    const ID = process.env.AKEYLESS_ACCESS_ID;
    const KEY = process.env.AKEYLESS_ACCESS_KEY;

    const WS_SECRETS = {
      "websearch/brave-api-key":      "BRAVE_API_KEY",
      "websearch/firecrawl-api-key":  "FIRECRAWL_API_KEY",
      "websearch/tavily-api-key":     "TAVILY_API_KEY",
      "websearch/perplexity-api-key": "PERPLEXITY_API_KEY",
    };

    function post(url, body) {
      return new Promise((resolve, reject) => {
        const u = new URL(url);
        const mod = u.protocol === "https:" ? https : http;
        const payload = JSON.stringify(body);
        const req = mod.request({
          hostname: u.hostname, port: u.port || (u.protocol === "https:" ? 443 : 80),
          path: u.pathname + u.search, method: "POST",
          headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) },
          timeout: 15000,
        }, (res) => {
          let data = "";
          res.on("data", c => data += c);
          res.on("end", () => {
            if (res.statusCode >= 200 && res.statusCode < 300) {
              try { resolve(JSON.parse(data)); } catch { reject(new Error("bad json")); }
            } else { reject(new Error("HTTP " + res.statusCode)); }
          });
        });
        req.on("error", reject);
        req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
        req.write(payload);
        req.end();
      });
    }

    (async () => {
      try {
        const auth = await post(GW + "/v2/auth", {
          "access-id": ID, "access-key": KEY, "access-type": "access_key"
        });
        const token = auth.token;
        if (!token) { process.exit(0); }

        const prefix = "/openclaw";
        const paths = Object.keys(WS_SECRETS).map(k => prefix + "/" + k);
        let secretMap = {};
        try { secretMap = await post(GW + "/v2/get-secret-value", { names: paths, token }); } catch {}

        let count = 0;
        for (const [shortId, envVar] of Object.entries(WS_SECRETS)) {
          const fullPath = prefix + "/" + shortId;
          const val = secretMap[fullPath];
          if (val) {
            const safe = String(val).replace(/[\x27\x5c]/g, "");
            process.stdout.write("export " + envVar + "=\x27" + safe + "\x27\n");
            count++;
          }
        }
        if (count > 0) {
          process.stderr.write("[entrypoint] Resolved " + count + " web search key(s) from CipherTrust\n");
        }
      } catch (err) {
        process.stderr.write("[entrypoint] Web search key resolution skipped: " + err.message + "\n");
      }
    })();
  ')"
fi

# ---------------------------------------------------------------------------
# 2. Apply baseUrl overrides from env vars
#    Set <PROVIDER>_BASE_URL to override the default baseUrl for any provider.
# ---------------------------------------------------------------------------

if [ -f "$CONFIG" ]; then
  node -e '
    const fs = require("fs");
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const providers = (cfg.models && cfg.models.providers) || {};
    const map = {
      openai:      "OPENAI_BASE_URL",
      anthropic:   "ANTHROPIC_BASE_URL",
      google:      "GOOGLE_BASE_URL",
      xai:         "XAI_BASE_URL",
      mistral:     "MISTRAL_BASE_URL",
      groq:        "GROQ_BASE_URL",
      openrouter:  "OPENROUTER_BASE_URL",
      together:    "TOGETHER_BASE_URL",
      cerebras:    "CEREBRAS_BASE_URL",
      nvidia:      "NVIDIA_BASE_URL",
      huggingface: "HUGGINGFACE_BASE_URL",
      minimax:     "MINIMAX_BASE_URL",
      moonshot:    "MOONSHOT_BASE_URL",
      venice:      "VENICE_BASE_URL",
      modelstudio: "MODELSTUDIO_BASE_URL",
    };
    let changed = 0;
    for (const [name, envVar] of Object.entries(map)) {
      const url = process.env[envVar];
      if (url && providers[name]) {
        providers[name].baseUrl = url;
        changed++;
      }
    }
    if (changed > 0) {
      fs.writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2));
      process.stderr.write("[entrypoint] Applied " + changed + " baseUrl override(s)\n");
    }
  ' "$CONFIG" 2>&1
fi

# ---------------------------------------------------------------------------
# 3. Start the rotation webhook in the background (if enabled)
# ---------------------------------------------------------------------------

if [ "$ROTATION_WEBHOOK_ENABLED" = "true" ]; then
  node /usr/local/bin/rotation-webhook.js &
  echo "[entrypoint] Rotation webhook started on port ${ROTATION_WEBHOOK_PORT:-9090}"
fi

# Hand off to the original OpenClaw entrypoint
exec "$@"
