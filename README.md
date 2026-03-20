# OpenClaw + Thales CipherTrust Secrets Manager

Docker image integration for [OpenClaw](https://openclaw.ai) with **Thales CipherTrust Secrets Manager** (powered by [Akeyless](https://www.akeyless.io/)), designed for Thales CipherTrust environments.

LLM API keys live in CipherTrust Secrets Manager — OpenClaw resolves them at startup via the exec SecretRef provider. No plaintext keys on disk.

## Base image

| | |
|---|---|
| **OpenClaw GA version** | `2026.3.13-1` |
| **Base image** | `ghcr.io/openclaw/openclaw:latest` (at time of build) |
| **Pre-built image** | `docker.io/sanyambassi/thales-csm-openclaw:latest` |

> Tags mirror the OpenClaw base version. For example, `2026.3.13-1` and `latest` both point to the same build.
> To pin: `.\build-and-push.ps1 -OpenClawTag "2026.3.13-1"`

---

## Option A: Pull the pre-built image

If you just want to use the image without building it yourself:

### 1. Pull the image

```bash
docker pull sanyambassi/thales-csm-openclaw:latest

# Or pin to a specific OpenClaw version:
docker pull sanyambassi/thales-csm-openclaw:2026.3.13-1
```

### 2. Provision your API keys into CipherTrust Secrets Manager

You need admin credentials for this one-time setup. The script prompts interactively for any keys you want to store:

```bash
# Clone the repo for the provisioning script
git clone https://github.com/sanyambassi/thales-csm-openclaw.git
cd thales-csm-openclaw

# Run the provisioning script (prompts for credentials + API keys)
.\scripts\provision-secrets.ps1          # Windows (PowerShell)
./scripts/provision-secrets.sh           # Linux/macOS (bash)
```

Secrets are created under `/openclaw/providers/` in CipherTrust Secrets Manager. You only need to provision the providers you actually use — skip the rest.

### 3. Create a `.env` file

```bash
# CipherTrust Secrets Manager endpoint
AKEYLESS_GATEWAY_URL=https://your-ciphertrust-host/akeyless-api

# Read-only credentials (NOT the admin ones — create a separate read-only role)
AKEYLESS_ACCESS_ID=p-xxxxxxxxxx
AKEYLESS_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxx

# OpenClaw gateway auth token (choose any strong token)
OPENCLAW_GATEWAY_TOKEN=your-gateway-token
```

### 4. Run the container

```bash
docker run -d \
  --name openclaw \
  --env-file .env \
  -p 3000:3000 \
  sanyambassi/thales-csm-openclaw:latest
```

Or use the included `docker-compose.yml`:

```bash
docker compose up -d
```

### 5. Verify

```bash
# Check container health
docker logs openclaw

# You should see:
#   [entrypoint] Resolved N API key(s) from CipherTrust Secrets Manager
#   OpenClaw gateway listening on port 3000
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
# Edit .env with your values
```

### 4. Build locally

```bash
docker build --build-arg OPENCLAW_TAG=latest -f Dockerfile.akeyless -t thales-csm-openclaw:latest .
```

### 5. Run

```bash
docker compose up -d
```

> **Pushing to a registry** (optional — only needed for remote/Kubernetes deployments):
>
> Set your Docker Hub username, then run the script. It auto-detects the OpenClaw base version and tags accordingly.
> ```bash
> # Via environment variable
> export DOCKERHUB_USER=yourusername          # Linux/macOS
> $env:DOCKERHUB_USER = "yourusername"        # Windows (PowerShell)
>
> # Build + push (auto-tags with version + latest)
> ./scripts/build-and-push.sh                 # Linux/macOS
> .\scripts\build-and-push.ps1                # Windows
>
> # Or pass username directly
> ./scripts/build-and-push.sh --user yourusername
> .\scripts\build-and-push.ps1 -DockerHubUser yourusername
> ```
> Then update your `.env` to point to your image:
> ```
> OPENCLAW_IMAGE=yourusername/thales-csm-openclaw
> ```

---

## What's included

| File | Purpose |
|------|---------|
| `Dockerfile.akeyless` | Layers the integration onto the official OpenClaw image |
| `docker-compose.yml` | Single-container deployment (CipherTrust appliance runs the gateway) |
| `docker/akeyless-resolver.js` | Exec SecretRef provider — authenticates with CipherTrust Secrets Manager and fetches secrets |
| `docker/openclaw-akeyless.json` | OpenClaw config with SecretRef exec provider and web search enabled |
| `docker/entrypoint.sh` | Custom entrypoint — resolves all API keys from CipherTrust as env vars before OpenClaw starts |
| `docker/rotation-webhook.js` | Optional webhook listener for CipherTrust rotation events |
| `scripts/provision-secrets.ps1` / `.sh` | Admin script to create/update secrets in CipherTrust Secrets Manager |
| `scripts/build-and-push.ps1` / `.sh` | Build the image and push to Docker Hub |
| `scripts/test-resolver.ps1` / `.sh` | End-to-end test suite for the resolver |

## Architecture

```
CipherTrust Appliance
├── CipherTrust Secrets Manager (Akeyless Gateway)
│   ├── /v2/auth
│   └── /v2/get-secret-value
│
└── OpenClaw Container (this image)
    ├── entrypoint.sh
    │   └── Resolves all API keys → exports as env vars
    ├── akeyless-resolver (exec provider)
    │   ├── Authenticates with CipherTrust Secrets Manager
    │   └── Returns secrets via OpenClaw exec protocol
    └── OpenClaw Runtime
        └── Built-in providers read keys from env vars
```

## Supported providers

The entrypoint resolves keys for all API-key-based providers. Provision only what you need:

| Secret path | Env var | Provider |
|-------------|---------|----------|
| `providers/openai-api-key` | `OPENAI_API_KEY` | OpenAI |
| `providers/google-api-key` | `GEMINI_API_KEY` | Google/Gemini |
| `providers/anthropic-api-key` | `ANTHROPIC_API_KEY` | Anthropic |
| `providers/xai-api-key` | `XAI_API_KEY` | xAI/Grok |
| `providers/perplexity-api-key` | `PERPLEXITY_API_KEY` | Perplexity |
| `providers/mistral-api-key` | `MISTRAL_API_KEY` | Mistral |
| `providers/groq-api-key` | `GROQ_API_KEY` | Groq |
| `providers/openrouter-api-key` | `OPENROUTER_API_KEY` | OpenRouter |
| `providers/together-api-key` | `TOGETHER_API_KEY` | Together AI |
| `providers/cerebras-api-key` | `CEREBRAS_API_KEY` | Cerebras |
| `providers/nvidia-api-key` | `NVIDIA_API_KEY` | NVIDIA NIM |
| `providers/huggingface-api-key` | `HF_TOKEN` | Hugging Face |
| `providers/minimax-api-key` | `MINIMAX_API_KEY` | MiniMax |
| `providers/moonshot-api-key` | `MOONSHOT_API_KEY` | Moonshot |
| `providers/kimi-api-key` | `KIMI_API_KEY` | Kimi |
| `providers/venice-api-key` | `VENICE_API_KEY` | Venice AI |
| `providers/zai-api-key` | `ZAI_API_KEY` | Z.AI |
| `providers/opencode-api-key` | `OPENCODE_API_KEY` | OpenCode |
| `providers/kilocode-api-key` | `KILOCODE_API_KEY` | KiloCode |
| `providers/vercel-ai-gateway-api-key` | `AI_GATEWAY_API_KEY` | Vercel AI Gateway |
| `providers/cloudflare-ai-gateway-api-key` | `CLOUDFLARE_AI_GATEWAY_API_KEY` | Cloudflare AI Gateway |
| `providers/volcengine-api-key` | `VOLCANO_ENGINE_API_KEY` | VolcEngine |
| `providers/byteplus-api-key` | `BYTEPLUS_API_KEY` | BytePlus |
| `providers/synthetic-api-key` | `SYNTHETIC_API_KEY` | Synthetic |
| `providers/qianfan-api-key` | `QIANFAN_API_KEY` | Qianfan |
| `providers/modelstudio-api-key` | `MODELSTUDIO_API_KEY` | ModelStudio |
| `providers/xiaomi-api-key` | `XIAOMI_API_KEY` | Xiaomi |

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `AKEYLESS_GATEWAY_URL` | Yes | CipherTrust Secrets Manager endpoint |
| `AKEYLESS_ACCESS_ID` | Yes | Read-only access ID for the resolver |
| `AKEYLESS_ACCESS_KEY` | Yes | Corresponding access key |
| `OPENCLAW_GATEWAY_TOKEN` | Yes | OpenClaw gateway auth token |
| `AKEYLESS_SECRET_PREFIX` | No | Secret prefix (default: `/openclaw`) |
| `ROTATION_WEBHOOK_ENABLED` | No | Set `true` to enable rotation webhook |
| `ROTATION_WEBHOOK_PORT` | No | Webhook port (default: 9090) |
| `ROTATION_WEBHOOK_TOKEN` | No | Shared secret for webhook auth |


## License

[MIT](https://github.com/sanyambassi/thales-csm-openclaw/blob/main/LICENSE)
