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

### 2. Provision your secrets into CipherTrust Secrets Manager

You need admin credentials for this one-time setup. The script prompts interactively for any keys you want to store:

```bash
# Clone the repo for the provisioning script
git clone https://github.com/sanyambassi/thales-csm-openclaw.git
cd thales-csm-openclaw

# Run the provisioning script (prompts for credentials + API keys + gateway token)
.\scripts\provision-secrets.ps1          # Windows (PowerShell)
./scripts/provision-secrets.sh           # Linux/macOS (bash)
```

Secrets are created under `/openclaw/` in CipherTrust. You only need to provision the providers you actually use — skip the rest. The gateway auth token (`gateway/auth-token`) is required.

### 3. Create a `.env` file

```bash
# CipherTrust Secrets Manager endpoint
AKEYLESS_GATEWAY_URL=https://your-ciphertrust-host/akeyless-api

# Read-only credentials (NOT the admin ones — create a separate read-only role)
AKEYLESS_ACCESS_ID=p-xxxxxxxxxx
AKEYLESS_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxx
```

That's it — no API keys or gateway tokens in the `.env` file. They come from CipherTrust.

### 4. Run the container

```bash
docker run -d \
  --name openclaw \
  --env-file .env \
  -p 18789:18789 \
  sanyambassi/thales-csm-openclaw:latest
```

Or use the included `docker-compose.yml`:

```bash
docker compose up -d
```

### 5. Verify

```bash
docker logs openclaw

# You should see:
#   [entrypoint] Resolved N web search key(s) from CipherTrust
#   [secrets] [SECRETS_GATEWAY_AUTH_SURFACE] gateway.auth.token is active
#   [gateway] listening on ...
```

---

## Option B: Build your own image

### 1. Clone this repo

```bash
git clone https://github.com/sanyambassi/thales-csm-openclaw.git
cd thales-csm-openclaw
```

### 2. Provision secrets

```bash
.\scripts\provision-secrets.ps1          # Windows (PowerShell)
./scripts/provision-secrets.sh           # Linux/macOS (bash)
```

### 3. Copy and fill in env vars

```bash
cp .env.example .env            # Linux/macOS
copy .env.example .env          # Windows
# Edit .env with your CipherTrust endpoint and read-only credentials
```

### 4. Build locally

```bash
docker build --build-arg OPENCLAW_TAG=latest -f Dockerfile.akeyless -t thales-csm-openclaw:latest .
```

### 5. Run

```bash
docker compose up -d
```

> **Pushing to a registry** (optional — only if deploying to remote machines or Kubernetes):
> ```bash
> ./scripts/build-and-push.sh --user yourusername        # Linux/macOS
> .\scripts\build-and-push.ps1 -DockerHubUser yourusername  # Windows
> ```

---

## How it works

Secrets are resolved from CipherTrust at startup through two complementary mechanisms:

- **Gateway auth token** — resolved via the `akeyless` exec provider (OpenClaw SecretRef), stored in OpenClaw's in-memory snapshot. Never in env vars or on disk.
- **LLM API keys** — each provider in `models.providers` has an `apiKey` SecretRef pointing to CipherTrust. Resolved at startup and stored in the in-memory snapshot. Never in env vars or on disk.
- **Web search API keys** (Brave, Firecrawl, Tavily, Perplexity) — resolved from CipherTrust by `entrypoint.sh` and exported as **in-memory env vars**. OpenClaw's web search plugins auto-detect these from the environment (e.g., `PERPLEXITY_API_KEY`). The plugins are explicitly enabled in the shipped config. Gemini, Grok, and Kimi web search reuse their LLM provider keys (already in the snapshot).

> **Why env vars for web search?** OpenClaw's plugin system does not currently support SecretRef objects in `plugins.entries.<plugin>.config.webSearch.apiKey`. Web search keys are lower-value (no billing risk for most providers) and are only held as in-memory env vars — never written to disk.

Unprovisioned providers are silently skipped.

```
CipherTrust Appliance
├── CipherTrust Secrets Manager (Akeyless Gateway)
│   ├── /v2/auth
│   └── /v2/get-secret-value
│
└── OpenClaw Container (this image)
    ├── entrypoint.sh
    │   └── Fetches web search keys → in-memory env vars
    ├── akeyless-resolver (exec SecretRef provider)
    │   ├── Authenticates with CipherTrust Secrets Manager
    │   └── Returns secrets via OpenClaw exec protocol
    └── OpenClaw Runtime
        ├── Gateway token   → SecretRef → in-memory snapshot
        ├── LLM API keys    → SecretRef → in-memory snapshot
        └── Web search keys → env vars (auto-detected by plugins)
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
| `providers/perplexity-api-key` | Perplexity (web search) |
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
| `websearch/brave-api-key` | Brave Search |
| `websearch/firecrawl-api-key` | Firecrawl Search |
| `websearch/tavily-api-key` | Tavily Search |
| `websearch/perplexity-api-key` | Perplexity Search |
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

> Providers not in the pre-configured list (VolcEngine, BytePlus, Qianfan, Xiaomi, etc.) can be added by mounting a custom `openclaw.json` or by setting the corresponding `<PROVIDER>_BASE_URL` env var alongside a matching entry in the config.

## Environment variables

Only CipherTrust connection credentials are needed as env vars — everything else comes from SecretRefs:

| Variable | Required | Description |
|----------|----------|-------------|
| `AKEYLESS_GATEWAY_URL` | Yes | CipherTrust Secrets Manager endpoint |
| `AKEYLESS_ACCESS_ID` | Yes | Read-only access ID for the resolver |
| `AKEYLESS_ACCESS_KEY` | Yes | Corresponding access key |
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
