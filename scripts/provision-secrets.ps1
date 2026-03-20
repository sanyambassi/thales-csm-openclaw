# provision-secrets.ps1
#
# Provisions LLM provider API keys into CipherTrust Secrets Manager (powered by Akeyless).
# Run this once during initial setup, or when rotating keys.
#
# Credentials: auto-loads repo .env (AKEYLESS_* , OPENCLAW_GATEWAY_TOKEN, AKEYLESS_ADMIN_*).
# Gateway token is prompted in step [2/4] after CipherTrust auth (or use env / flags below).
#
# Usage:
#   # Interactive
#   .\provision-secrets.ps1
#
#   # Non-interactive — gateway + providers (OpenClaw requires gateway/auth-token in CSM)
#   .\provision-secrets.ps1 -NoPrompt `
#     -GatewayToken (New-Guid).Guid `
#     -OpenAIKey "sk-..." -AnthropicKey "sk-ant-..."
#
#   # Auto-generate gateway token only
#   .\provision-secrets.ps1 -GenerateGatewayToken -NoPrompt
#
#   # Same as bash: admin role separate from read-only .env
#   .\provision-secrets.ps1 -AdminAccessId "p-..." -AdminAccessKey "..."

param(
  [string]$GatewayUrl,
  [string]$AdminAccessId,
  [string]$AdminAccessKey,
  [string]$AccessId,
  [string]$AccessKey,
  [string]$OpenAIKey,
  [string]$GoogleKey,
  [string]$AnthropicKey,
  [string]$XAIKey,
  [string]$PerplexityKey,
  [string]$MistralKey,
  [string]$GroqKey,
  [string]$OpenRouterKey,
  [string]$TogetherKey,
  [string]$CerebrasKey,
  [string]$NvidiaKey,
  [string]$HuggingFaceKey,
  [string]$MiniMaxKey,
  [string]$MoonshotKey,
  [string]$KimiKey,
  [string]$VeniceKey,
  [string]$ZaiKey,
  [string]$OpenCodeKey,
  [string]$KiloCodeKey,
  [string]$VercelAIGatewayKey,
  [string]$CloudflareAIGatewayKey,
  [string]$VolcEngineKey,
  [string]$BytePlusKey,
  [string]$SyntheticKey,
  [string]$QianfanKey,
  [string]$ModelStudioKey,
  [string]$XiaomiKey,
  [string]$BraveKey,
  [string]$FirecrawlKey,
  [string]$TavilyKey,
  [string]$GatewayToken,
  [string]$SecretPrefix = "/openclaw",
  [switch]$NoPrompt,
  [switch]$GenerateGatewayToken
)

$ErrorActionPreference = "Stop"

# ---- Auto-load .env if present (before gateway token / generate) ----
$scriptDir = Split-Path -Parent $PSScriptRoot
foreach ($candidate in @("$scriptDir\.env", "$PWD\.env")) {
  if (Test-Path $candidate) {
    Get-Content $candidate | ForEach-Object {
      if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$' -and $_ -notmatch '^\s*#') {
        $k = $Matches[1]; $v = $Matches[2].Trim('"').Trim("'")
        if (-not [Environment]::GetEnvironmentVariable($k)) {
          [Environment]::SetEnvironmentVariable($k, $v)
        }
      }
    }
    break
  }
}

if (-not $GatewayToken) { $GatewayToken = $env:OPENCLAW_GATEWAY_TOKEN }

if ($GenerateGatewayToken -and -not $GatewayToken) {
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $GatewayToken = -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

# ---- Resolve credentials (admin > read-only > env > prompt) ----
if (-not $GatewayUrl) { $GatewayUrl = $env:AKEYLESS_GATEWAY_URL }
if (-not $AdminAccessId)  { $AdminAccessId  = $env:AKEYLESS_ADMIN_ACCESS_ID }
if (-not $AdminAccessKey) { $AdminAccessKey = $env:AKEYLESS_ADMIN_ACCESS_KEY }
if (-not $AccessId)  { $AccessId  = $env:AKEYLESS_ACCESS_ID }
if (-not $AccessKey) { $AccessKey = $env:AKEYLESS_ACCESS_KEY }

$EffectiveId  = if ($AdminAccessId)  { $AdminAccessId }  else { $AccessId }
$EffectiveKey = if ($AdminAccessKey) { $AdminAccessKey } else { $AccessKey }

if (-not $GatewayUrl) {
  $GatewayUrl = Read-Host "CipherTrust Secrets Manager URL (e.g. https://host/akeyless-api)"
}
$GatewayUrl = $GatewayUrl.TrimEnd("/")

if (-not $EffectiveId)  { $EffectiveId  = Read-Host "Admin Access ID (or read-only if same role)" }
if (-not $EffectiveKey) {
  $secureKey = Read-Host "Admin Access Key" -AsSecureString
  $EffectiveKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey))
}

# ---- Authenticate ----
Write-Host "`n[1/4] Authenticating with CipherTrust Secrets Manager..." -ForegroundColor Cyan
if ($AdminAccessId) { Write-Host "  Using admin credentials" -ForegroundColor Yellow }
$authBody = @{
  "access-id"   = $EffectiveId
  "access-key"  = $EffectiveKey
  "access-type" = "access_key"
} | ConvertTo-Json

$authResp = Invoke-RestMethod -Uri "$GatewayUrl/v2/auth" `
  -Method POST -Body $authBody -ContentType "application/json" -TimeoutSec 30
$token = $authResp.token
Write-Host "  Authenticated (token prefix: $($token.Substring(0,12))...)" -ForegroundColor Green

# ---- Gateway token first (env OPENCLAW_GATEWAY_TOKEN, -GatewayToken, -GenerateGatewayToken, or prompt) ----
# Use [switch] -NoPrompt explicitly: unlike bash, there is no "false" string bug here;
# -NoPrompt.IsPresent is $false when the switch is omitted.
$secrets = @{}

$needsGatewayPrompt = [string]::IsNullOrWhiteSpace($GatewayToken) -and -not $NoPrompt.IsPresent
if ($needsGatewayPrompt) {
  Write-Host "`n[2/4] OpenClaw gateway auth token (required for gateway to start)" -ForegroundColor Cyan
  Write-Host "  Tip: set OPENCLAW_GATEWAY_TOKEN in .env or use -GenerateGatewayToken" -ForegroundColor Yellow
  $sec = Read-Host "  Gateway token [OPENCLAW_GATEWAY_TOKEN]" -AsSecureString
  if ($sec) {
    $GatewayToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    Write-Host "  ********" -ForegroundColor DarkGray
  }
}

if (-not [string]::IsNullOrWhiteSpace($GatewayToken)) {
  $secrets["gateway/auth-token"] = $GatewayToken.Trim()
}

function PromptKey($name, $param, $envHint) {
  if ($param) { return $param }
  if ($NoPrompt.IsPresent) { return $null }
  $val = Read-Host "  $name [$envHint]"
  if ($val) { return $val }
  return $null
}

Write-Host "`n[3/4] Other API keys (press Enter to skip each)..." -ForegroundColor Cyan

$keys = @(
  @{ name = "OpenAI API Key";           path = "providers/openai-api-key";                  param = $OpenAIKey;      hint = "OPENAI_API_KEY" },
  @{ name = "Google/Gemini Key";        path = "providers/google-api-key";                  param = $GoogleKey;      hint = "GEMINI_API_KEY" },
  @{ name = "Anthropic API Key";        path = "providers/anthropic-api-key";               param = $AnthropicKey;   hint = "ANTHROPIC_API_KEY" },
  @{ name = "xAI/Grok API Key";        path = "providers/xai-api-key";                     param = $XAIKey;         hint = "XAI_API_KEY" },
  @{ name = "Perplexity API Key";       path = "providers/perplexity-api-key";              param = $PerplexityKey;  hint = "PERPLEXITY_API_KEY" },
  @{ name = "Mistral API Key";          path = "providers/mistral-api-key";                 param = $MistralKey;     hint = "MISTRAL_API_KEY" },
  @{ name = "Groq API Key";            path = "providers/groq-api-key";                    param = $GroqKey;        hint = "GROQ_API_KEY" },
  @{ name = "OpenRouter API Key";       path = "providers/openrouter-api-key";              param = $OpenRouterKey;  hint = "OPENROUTER_API_KEY" },
  @{ name = "Together API Key";         path = "providers/together-api-key";                param = $TogetherKey;    hint = "TOGETHER_API_KEY" },
  @{ name = "Cerebras API Key";         path = "providers/cerebras-api-key";                param = $CerebrasKey;    hint = "CEREBRAS_API_KEY" },
  @{ name = "NVIDIA API Key";           path = "providers/nvidia-api-key";                  param = $NvidiaKey;      hint = "NVIDIA_API_KEY" },
  @{ name = "Hugging Face Token";       path = "providers/huggingface-api-key";             param = $HuggingFaceKey; hint = "HF_TOKEN" },
  @{ name = "MiniMax API Key";          path = "providers/minimax-api-key";                 param = $MiniMaxKey;     hint = "MINIMAX_API_KEY" },
  @{ name = "Moonshot API Key";         path = "providers/moonshot-api-key";                param = $MoonshotKey;    hint = "MOONSHOT_API_KEY" },
  @{ name = "Kimi API Key";            path = "providers/kimi-api-key";                    param = $KimiKey;        hint = "KIMI_API_KEY" },
  @{ name = "Venice API Key";           path = "providers/venice-api-key";                  param = $VeniceKey;      hint = "VENICE_API_KEY" },
  @{ name = "Z.AI API Key";            path = "providers/zai-api-key";                     param = $ZaiKey;         hint = "ZAI_API_KEY" },
  @{ name = "OpenCode API Key";       path = "providers/opencode-api-key";                param = $OpenCodeKey;    hint = "OPENCODE_API_KEY" },
  @{ name = "KiloCode API Key";       path = "providers/kilocode-api-key";                param = $KiloCodeKey;    hint = "KILOCODE_API_KEY" },
  @{ name = "Vercel AI Gateway Key";  path = "providers/vercel-ai-gateway-api-key";       param = $VercelAIGatewayKey; hint = "AI_GATEWAY_API_KEY" },
  @{ name = "Cloudflare AI GW Key";   path = "providers/cloudflare-ai-gateway-api-key";   param = $CloudflareAIGatewayKey; hint = "CLOUDFLARE_AI_GATEWAY_API_KEY" },
  @{ name = "VolcEngine API Key";     path = "providers/volcengine-api-key";              param = $VolcEngineKey;  hint = "VOLCANO_ENGINE_API_KEY" },
  @{ name = "BytePlus API Key";       path = "providers/byteplus-api-key";                param = $BytePlusKey;    hint = "BYTEPLUS_API_KEY" },
  @{ name = "Synthetic API Key";      path = "providers/synthetic-api-key";               param = $SyntheticKey;   hint = "SYNTHETIC_API_KEY" },
  @{ name = "Qianfan API Key";        path = "providers/qianfan-api-key";                 param = $QianfanKey;     hint = "QIANFAN_API_KEY" },
  @{ name = "ModelStudio API Key";    path = "providers/modelstudio-api-key";             param = $ModelStudioKey; hint = "MODELSTUDIO_API_KEY" },
  @{ name = "Xiaomi API Key";         path = "providers/xiaomi-api-key";                  param = $XiaomiKey;      hint = "XIAOMI_API_KEY" },
  @{ name = "Brave Search Key";     path = "websearch/brave-api-key";                   param = $BraveKey;       hint = "BRAVE_API_KEY" },
  @{ name = "Firecrawl Search Key"; path = "websearch/firecrawl-api-key";               param = $FirecrawlKey;   hint = "FIRECRAWL_API_KEY" },
  @{ name = "Tavily Search Key";    path = "websearch/tavily-api-key";                  param = $TavilyKey;      hint = "TAVILY_API_KEY" }
)

foreach ($k in $keys) {
  $val = PromptKey $k.name $k.param $k.hint
  if ($val) { $secrets[$k.path] = $val }
}

if ($secrets.Count -eq 0) {
  Write-Host "`n  No keys provided - nothing to provision." -ForegroundColor Yellow
  exit 0
}

if ($NoPrompt.IsPresent -and -not $secrets.ContainsKey("gateway/auth-token")) {
  Write-Warning "This run did not include a gateway token. OpenClaw needs /openclaw/gateway/auth-token in CSM or OPENCLAW_GATEWAY_TOKEN on the container (see README)."
}

# ---- Provision ----
Write-Host "`n[4/4] Provisioning $($secrets.Count) secret(s) in CipherTrust Secrets Manager..." -ForegroundColor Cyan

$created = 0
$updated = 0
$failed  = 0

foreach ($entry in $secrets.GetEnumerator()) {
  $fullPath = "$SecretPrefix/$($entry.Key)"
  Write-Host "  $fullPath ... " -NoNewline

  $createBody = @{
    name  = $fullPath
    value = $entry.Value
    token = $token
  } | ConvertTo-Json

  try {
    Invoke-RestMethod -Uri "$GatewayUrl/v2/create-secret" `
      -Method POST -Body $createBody -ContentType "application/json" -TimeoutSec 30 | Out-Null
    Write-Host "CREATED" -ForegroundColor Green
    $created++
  } catch {
    $errMsg = ""
    if ($_.ErrorDetails) { $errMsg = $_.ErrorDetails.Message }
    if ($errMsg -match "already exists" -or $errMsg -match "AlreadyExists") {
      $updateBody = @{
        name  = $fullPath
        value = $entry.Value
        token = $token
      } | ConvertTo-Json
      try {
        Invoke-RestMethod -Uri "$GatewayUrl/v2/update-secret-val" `
          -Method POST -Body $updateBody -ContentType "application/json" -TimeoutSec 30 | Out-Null
        Write-Host "UPDATED" -ForegroundColor Yellow
        $updated++
      } catch {
        Write-Host "FAILED (update: $($_.Exception.Message))" -ForegroundColor Red
        $failed++
      }
    } else {
      Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Red
      $failed++
    }
  }
}

Write-Host "`nDone: $created created, $updated updated, $failed failed." -ForegroundColor Cyan

# ---- Verify ----
Write-Host "`nVerification - retrieving all provisioned secrets..." -ForegroundColor Cyan
foreach ($entry in $secrets.GetEnumerator()) {
  $fullPath = "$SecretPrefix/$($entry.Key)"
  $getBody = @{
    names = @($fullPath)
    token = $token
  } | ConvertTo-Json

  try {
    $resp = Invoke-RestMethod -Uri "$GatewayUrl/v2/get-secret-value" `
      -Method POST -Body $getBody -ContentType "application/json" -TimeoutSec 30
    $retrieved = $resp.$fullPath
    if ($retrieved) {
      $masked = $retrieved.Substring(0, [Math]::Min(8, $retrieved.Length)) + "..."
      Write-Host "  $fullPath = $masked" -ForegroundColor Green
    } else {
      Write-Host "  $fullPath = (empty/null)" -ForegroundColor Yellow
    }
  } catch {
    Write-Host "  $fullPath = RETRIEVE FAILED" -ForegroundColor Red
  }
}

Write-Host "`nProvisioning complete." -ForegroundColor Cyan
