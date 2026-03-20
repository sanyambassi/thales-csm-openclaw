# OpenClaw + Thales CipherTrust Secrets Manager

Docker image integration for [OpenClaw](https://openclaw.ai) with **Thales CipherTrust Secrets Manager** (powered by [Akeyless](https://www.akeyless.io/)), designed for Thales CipherTrust environments.

LLM API keys and the gateway auth token are resolved natively via OpenClaw's SecretRef system — keys live in OpenClaw's in-memory snapshot, never in environment variables or on disk. Web search provider keys (Brave, Firecrawl, Tavily, Perplexity) are resolved from CipherTrust at startup and exported as env vars for OpenClaw's web search subsystem.

## Base image

| | |
|---|---|
| **OpenClaw GA version** | `2026.3.13-1` (at time of build) |
| **Base image** | `ghcr.io/openclaw/openclaw:latest` |
| **Pre-built image** | `docker.io/sanyambassi/thales-csm-openclaw:latest` |

> Tags mirror the OpenClaw base version. For example, `2026.3.13-1` and `latest` both point to the same build.

---

## Option A: Pull the pre-built image

If you just want to use the image without building it yourself:

### 1. Pull the image

```bash
docker pull sanyambassi/thales-csm-openclaw:latest

# Or pin to a specific OpenClaw version:
docker pull sanyambassi/thales-csm-openclaw:2026.3.13-1
```

### 2. Create a `.env` file

```bash
# CipherTrust Secrets Manager endpoint
AKEYLESS_GATEWAY_URL=https://your-ciphertrust-host/akeyless-api

# Read-only credentials (NOT the admin ones — create a separate read-only role)
AKEYLESS_ACCESS_ID=p-xxxxxxxxxx
AKEYLESS_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxx
```

That's it — no AI provider/LLM API keys or gateway tokens in the `.env` file. They come from CipherTrust.

### 3. Provision your secrets into CipherTrust Secrets Manager

You need admin credentials for this one-time setup. The script prompts interactively for the CipherTrust URL, admin credentials, and each API key you want to store:

```bash
# Clone the repo for the provisioning script
git clone https://github.com/sanyambassi/thales-csm-openclaw.git
cd thales-csm-openclaw

# Linux/macOS — make scripts executable first
chmod +x scripts/*.sh

# Run the provisioning script (prompts for everything — no files needed)
./scripts/provision-secrets.sh           # Linux/macOS (bash)
.\scripts\provision-secrets.ps1          # Windows (PowerShell)
```

Secrets are created under `/openclaw/` in CipherTrust. You only need to provision the providers you actually use. **Interactive mode:** at any provider prompt, type **`done`**, **`skip`**, **`q`**, or **`end`** to skip all remaining provider prompts and go straight to provisioning (same in `provision-secrets.sh` and `provision-secrets.ps1`). Press Enter on a line to skip only that provider.

**Gateway auth token (`/openclaw/gateway/auth-token`) is required** — without it OpenClaw fails with `gateway.auth.token resolved to a non-string or empty value`. The provision script asks for it first. To create only that secret (e.g. after fixing a failed deploy):

```bash
./scripts/provision-secrets.sh --generate-gateway-token --no-prompt
```

(PowerShell: `.\scripts\provision-secrets.ps1 -GenerateGatewayToken -NoPrompt`)

### 4. Run the container

```bash
docker run -d \
  --name openclaw \
  --env-file .env \
  -p 18789:18789 \
  sanyambassi/thales-csm-openclaw:latest

docker logs -f openclaw   # follow startup; Ctrl+C to stop (container keeps running)
```

Or use the included `docker-compose.yml`:

```bash
docker compose up -d
docker logs -f openclaw   # follow startup; Ctrl+C to stop (container keeps running)
```

### 5. Verify

```bash
docker logs openclaw

# You should see:
#   [entrypoint] Resolved N web search key(s) from CipherTrust
#   [secrets] [SECRETS_GATEWAY_AUTH_SURFACE] gateway.auth.token is active
#   [gateway] listening on ...
```

**Logs say `N provider(s) verified in CipherTrust` but you only provisioned one?**  
The entrypoint probes each provider path in the config. **Any secret that still exists** in CipherTrust from an earlier run counts as verified — delete unused secrets in CSM if you want fewer active providers.

**`gateway.auth.token` empty or unresolved?**  
Ensure `/openclaw/gateway/auth-token` exists in CipherTrust (provision step **[2/4]**), or set **`OPENCLAW_GATEWAY_TOKEN`** for the container (see [Environment variables](#environment-variables)).

**Gateway healthy but chat / agent calls fail?**  
OpenClaw often defaults the agent model to **Anthropic (e.g. Claude Opus)**. If you did not provision **`/openclaw/providers/anthropic-api-key`**, either add an Anthropic API key in CipherTrust or change the default model to a provider you did provision (the provision scripts print a reminder when Anthropic was skipped).

**Control UI from another machine / browser?** See [Control UI (browser origins)](#control-ui-browser-origins) — same behavior for pulled images and local builds.

---

## Option B: Build your own image

### 1. Clone this repo

```bash
git clone https://github.com/sanyambassi/thales-csm-openclaw.git
cd thales-csm-openclaw
```

### 2. Copy and fill in env vars

```bash
cp .env.example .env            # Linux/macOS
copy .env.example .env          # Windows
# Edit .env with your CipherTrust endpoint and read-only credentials
```

### 3. Provision secrets

The script prompts for the CipherTrust URL, admin credentials, and each API key — it does not read from `.env`:

```bash
# Linux/macOS — make scripts executable first
chmod +x scripts/*.sh

# Run the provisioning script (prompts for everything — no files needed)
./scripts/provision-secrets.sh           # Linux/macOS (bash)
.\scripts\provision-secrets.ps1          # Windows (PowerShell)
```

### 4. Build locally

```bash
docker build --build-arg OPENCLAW_TAG=latest -f Dockerfile.akeyless -t thales-csm-openclaw:latest .
```

### 5. Run

```bash
docker compose up -d
docker logs -f openclaw   # follow startup; Ctrl+C to stop (container keeps running)
```

> **Pushing to a registry** (optional — only if deploying to remote machines or Kubernetes):
> ```bash
> ./scripts/build-and-push.sh --user yourusername        # Linux/macOS
> .\scripts\build-and-push.ps1 -DockerHubUser yourusername  # Windows
> ```

**Control UI from another machine / browser?** See [Control UI (browser origins)](#control-ui-browser-origins).

---

## Control UI (browser origins)

**Pre-built image (Option A) and local `docker build` (Option B) are the same:** `Dockerfile.akeyless` copies [`docker/openclaw-akeyless.json`](docker/openclaw-akeyless.json) into the image as `openclaw.json`, including **`gateway.controlUi.allowedOrigins`: `["*"]`**. That allows the Control UI to connect from **any browser origin** when the gateway is reachable on the network (e.g. `http://your-server:18789`).

This is convenient for remote access but **less strict than an explicit allowlist**. Keep **gateway token auth** enabled, and avoid exposing port **18789** to the public internet unless you understand the risk.

**To restrict origins:** edit `docker/openclaw-akeyless.json` **before** `docker build`, or mount a custom `openclaw.json`, and set e.g. `["https://control.example.com"]`. See [OpenClaw gateway configuration](https://docs.openclaw.ai/gateway/configuration-reference).

---

## How it works

At container startup, the custom entrypoint authenticates with CipherTrust once and performs two key operations before handing off to OpenClaw:

1. **Provider pruning** — checks which LLM provider secrets are actually provisioned in CipherTrust and removes any unprovisioned providers from the config. This lets the image ship with 15 pre-configured providers while only activating the ones you've provisioned.
2. **Web search key resolution** — fetches the four web-search secrets from CipherTrust (`websearch/…`) and exports **`BRAVE_API_KEY`**, **`FIRECRAWL_API_KEY`**, **`TAVILY_API_KEY`**, **`PERPLEXITY_API_KEY`** as in-memory env vars.

Once OpenClaw starts, it resolves the remaining secrets natively:

- **Gateway auth token** — resolved via the `akeyless` exec provider (OpenClaw SecretRef), stored in OpenClaw's in-memory snapshot. Never in env vars or on disk.
- **LLM API keys** — each remaining provider has an `apiKey` SecretRef pointing to CipherTrust. Resolved at startup into the in-memory snapshot. Never in env vars or on disk.
- **Web search API keys** — auto-detected from the **four** in-process env vars the entrypoint sets (all web search only): `BRAVE_API_KEY`, `FIRECRAWL_API_KEY`, `TAVILY_API_KEY`, `PERPLEXITY_API_KEY`. Gemini, Grok, and Kimi web search reuse their LLM provider keys (already in the snapshot).

> **Why env vars for web search?** OpenClaw's plugin system does not currently support SecretRef objects for web search API keys. These keys are only held as in-memory env vars — never written to disk.

```
CipherTrust Appliance
├── CipherTrust Secrets Manager (Akeyless Gateway)
│   ├── /v2/auth
│   └── /v2/get-secret-value
│
└── OpenClaw Container (this image)
    ├── entrypoint.sh (runs before OpenClaw)
    │   ├── Authenticates with CipherTrust
    │   ├── Prunes unprovisioned providers from config
    │   └── Fetches web search keys → in-memory env vars
    ├── akeyless-resolver (exec SecretRef provider)
    │   ├── Called by OpenClaw at startup for each SecretRef
    │   └── Returns secrets via OpenClaw exec protocol
    └── OpenClaw Runtime
        ├── Gateway token   → SecretRef → in-memory snapshot
        ├── LLM API keys    → SecretRef → in-memory snapshot
        └── Web search keys → env vars (auto-detected)
```

## Pre-configured providers

The image ships with 15 providers pre-configured. Provision only the ones you need — the rest stay inactive:

| Provider | Config key | Default base URL |
|----------|-----------|-----------------|
| OpenAI | `openai` | `https://api.openai.com/v1` |
| Anthropic | `anthropic` | `https://api.anthropic.com` |
| Google/Gemini | `google` | `https://generativelanguage.googleapis.com/v1beta` |
| xAI/Grok | `xai` | `https://api.x.ai/v1` |
| Mistral | `mistral` | `https://api.mistral.ai/v1` |
| Groq | `groq` | `https://api.groq.com/openai/v1` |
| OpenRouter | `openrouter` | `https://openrouter.ai/api/v1` |
| Together AI | `together` | `https://api.together.xyz/v1` |
| Cerebras | `cerebras` | `https://api.cerebras.ai/v1` |
| NVIDIA NIM | `nvidia` | `https://integrate.api.nvidia.com/v1` |
| Hugging Face | `huggingface` | `https://api-inference.huggingface.co/v1` |
| MiniMax | `minimax` | `https://api.minimax.chat/v1` |
| Moonshot/Kimi | `moonshot` | `https://api.moonshot.cn/v1` |
| Venice AI | `venice` | `https://api.venice.ai/api/v1` |
| ModelStudio | `modelstudio` | `https://dashscope.aliyuncs.com/compatible-mode/v1` |

### Overriding a base URL

To point any provider at a proxy or custom endpoint, set a `<PROVIDER>_BASE_URL` environment variable:

```bash
docker run -d \
  --env-file .env \
  -e OPENAI_BASE_URL=https://my-openai-proxy.example.com/v1 \
  -e ANTHROPIC_BASE_URL=https://my-anthropic-proxy.example.com \
  sanyambassi/thales-csm-openclaw:latest
```

### Adding a provider not in the list

Mount your own `openclaw.json` with additional providers:

```bash
docker run -d \
  --env-file .env \
  -v ./my-openclaw.json:/home/node/.openclaw/openclaw.json \
  sanyambassi/thales-csm-openclaw:latest
```

## Supported secrets

Provision only what you need. Unprovisioned providers are inactive — they don't block startup.

| Secret path | Provider |
|-------------|----------|
| `gateway/auth-token` | **OpenClaw gateway auth** (required) |
| `providers/openai-api-key` | OpenAI |
| `providers/google-api-key` | Google/Gemini |
| `providers/anthropic-api-key` | Anthropic |
| `providers/xai-api-key` | xAI/Grok |
| `providers/mistral-api-key` | Mistral |
| `providers/groq-api-key` | Groq |
| `providers/openrouter-api-key` | OpenRouter |
| `providers/together-api-key` | Together AI |
| `providers/cerebras-api-key` | Cerebras |
| `providers/nvidia-api-key` | NVIDIA NIM |
| `providers/huggingface-api-key` | Hugging Face |
| `providers/minimax-api-key` | MiniMax |
| `providers/moonshot-api-key` | Moonshot/Kimi |
| `providers/venice-api-key` | Venice AI |
| `providers/modelstudio-api-key` | ModelStudio (Alibaba) |
| `providers/volcengine-api-key` | VolcEngine |
| `providers/byteplus-api-key` | BytePlus |
| `providers/qianfan-api-key` | Qianfan (Baidu) |
| `providers/xiaomi-api-key` | Xiaomi |
| `providers/zai-api-key` | Z.AI |
| `providers/opencode-api-key` | OpenCode |
| `providers/kilocode-api-key` | KiloCode |
| `providers/synthetic-api-key` | Synthetic |
| `providers/vercel-ai-gateway-api-key` | Vercel AI Gateway |
| `providers/cloudflare-ai-gateway-api-key` | Cloudflare AI Gateway |

### Web search (CipherTrust → in-memory env)

These four are **only** for OpenClaw’s web search tools. They are **not** LLM provider keys. Store them under **`websearch/…`** in CipherTrust; the entrypoint fetches them at startup and exports the matching env vars (nothing to put in `.env` for these):

| CipherTrust path (under your prefix) | Runtime env var (web search) |
|-------------------------------------|------------------------------|
| `websearch/brave-api-key` | `BRAVE_API_KEY` |
| `websearch/firecrawl-api-key` | `FIRECRAWL_API_KEY` |
| `websearch/tavily-api-key` | `TAVILY_API_KEY` |
| `websearch/perplexity-api-key` | `PERPLEXITY_API_KEY` |

> Providers not in the pre-configured list (VolcEngine, BytePlus, Qianfan, Xiaomi, etc.) can be added by mounting a custom `openclaw.json` or by setting the corresponding `<PROVIDER>_BASE_URL` env var alongside a matching entry in the config.

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `AKEYLESS_GATEWAY_URL` | Yes | CipherTrust Secrets Manager endpoint |
| `AKEYLESS_ACCESS_ID` | Yes | Read-only access ID for the resolver |
| `AKEYLESS_ACCESS_KEY` | Yes | Corresponding access key |
| `OPENCLAW_GATEWAY_TOKEN` | No | If set on the **container**, entrypoint writes it to `openclaw.json` and **overrides** the CipherTrust SecretRef (plaintext on disk inside the container — prefer CSM for production). Same var in **`.env`** is read by the provision script to pre-fill or upload the gateway secret. |
| `<PROVIDER>_BASE_URL` | No | Override a provider's default API endpoint (e.g., `OPENAI_BASE_URL`) |
| `ROTATION_WEBHOOK_ENABLED` | No | Set `true` to enable rotation webhook |
| `ROTATION_WEBHOOK_PORT` | No | Webhook port (default: 9090) |
| `ROTATION_WEBHOOK_TOKEN` | No | Shared secret for webhook auth |

## What's included

| File | Purpose |
|------|---------|
| `Dockerfile.akeyless` | Layers the integration onto the official OpenClaw image |
| `docker-compose.yml` | Single-container deployment |
| `docker/akeyless-resolver.js` | Exec SecretRef provider — authenticates with CipherTrust and fetches secrets |
| `docker/openclaw-akeyless.json` | OpenClaw config with SecretRef-based API keys and gateway token |
| `docker/entrypoint.sh` | Custom entrypoint — resolves web search keys, applies baseUrl overrides, optional rotation webhook |
| `docker/rotation-webhook.js` | Optional webhook listener for CipherTrust rotation events |
| `scripts/provision-secrets.ps1` / `.sh` | Admin script to create/update secrets in CipherTrust |
| `scripts/build-and-push.ps1` / `.sh` | Build the image and push to a registry |
| `scripts/test-resolver.ps1` / `.sh` | End-to-end test suite for the resolver |

## License

[MIT](https://github.com/sanyambassi/thales-csm-openclaw/blob/main/LICENSE)
