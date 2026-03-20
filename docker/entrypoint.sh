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
# This entrypoint handles four tasks before handing off to OpenClaw:
#   1. Prune providers whose secrets are not provisioned in CipherTrust
#   2. Resolve web search API keys from CipherTrust → env vars
#   3. Apply per-provider baseUrl overrides from env vars
#   4. Start the rotation webhook (if enabled)

CONFIG="/home/node/.openclaw/openclaw.json"

# ---------------------------------------------------------------------------
# 1 & 2. Authenticate once, prune unprovisioned providers, resolve web search keys
# ---------------------------------------------------------------------------

if [ -n "$AKEYLESS_GATEWAY_URL" ] && [ -n "$AKEYLESS_ACCESS_ID" ] && [ -n "$AKEYLESS_ACCESS_KEY" ]; then
  eval "$(node -e '
    const https = require("https");
    const http = require("http");
    const fs = require("fs");
    const GW = (process.env.AKEYLESS_GATEWAY_URL || "").replace(/\/+$/, "");
    const ID = process.env.AKEYLESS_ACCESS_ID;
    const KEY = process.env.AKEYLESS_ACCESS_KEY;
    const CONFIG = process.argv[1];
    const PREFIX = process.env.AKEYLESS_SECRET_PREFIX || "/openclaw";

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

        // --- Prune unprovisioned LLM providers from config ---
        let cfg;
        try { cfg = JSON.parse(fs.readFileSync(CONFIG, "utf8")); } catch { cfg = null; }
        if (cfg && cfg.models && cfg.models.providers) {
          const providerNames = Object.keys(cfg.models.providers);
          const providerPaths = providerNames.map(n => {
            const ref = cfg.models.providers[n].apiKey;
            if (ref && ref.id) return PREFIX + "/" + ref.id;
            return null;
          });
          const allPaths = providerPaths.filter(Boolean);
          if (allPaths.length > 0) {
            let secretMap = {};
            try { secretMap = await post(GW + "/v2/get-secret-value", { names: allPaths, token }); } catch {}
            const removed = [];
            for (let i = 0; i < providerNames.length; i++) {
              const path = providerPaths[i];
              if (path && !secretMap[path]) {
                delete cfg.models.providers[providerNames[i]];
                removed.push(providerNames[i]);
              }
            }
            if (removed.length > 0) {
              fs.writeFileSync(CONFIG, JSON.stringify(cfg, null, 2));
              process.stderr.write("[entrypoint] Pruned " + removed.length + " unprovisioned provider(s): " + removed.join(", ") + "\n");
            } else {
              process.stderr.write("[entrypoint] All " + providerNames.length + " provider(s) verified in CipherTrust\n");
            }
          }
        }

        // --- Resolve web search keys → env vars ---
        const wsPaths = Object.keys(WS_SECRETS).map(k => PREFIX + "/" + k);
        let wsMap = {};
        try { wsMap = await post(GW + "/v2/get-secret-value", { names: wsPaths, token }); } catch {}
        let wsCount = 0;
        for (const [shortId, envVar] of Object.entries(WS_SECRETS)) {
          const fullPath = PREFIX + "/" + shortId;
          const val = wsMap[fullPath];
          if (val) {
            const safe = String(val).replace(/[\x27\x5c]/g, "");
            process.stdout.write("export " + envVar + "=\x27" + safe + "\x27\n");
            wsCount++;
          }
        }
        if (wsCount > 0) {
          process.stderr.write("[entrypoint] Resolved " + wsCount + " web search key(s) from CipherTrust\n");
        }
      } catch (err) {
        process.stderr.write("[entrypoint] CipherTrust preflight skipped: " + err.message + "\n");
      }
    })();
  ' "$CONFIG")"
fi

# ---------------------------------------------------------------------------
# 3. Apply baseUrl overrides from env vars
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
# 4. Start the rotation webhook in the background (if enabled)
# ---------------------------------------------------------------------------

if [ "$ROTATION_WEBHOOK_ENABLED" = "true" ]; then
  node /usr/local/bin/rotation-webhook.js &
  echo "[entrypoint] Rotation webhook started on port ${ROTATION_WEBHOOK_PORT:-9090}"
fi

# Hand off to the original OpenClaw entrypoint
exec "$@"
