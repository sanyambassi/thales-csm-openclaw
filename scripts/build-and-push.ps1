# build-and-push.ps1
#
# Builds the OpenClaw + CipherTrust Secrets Manager image and pushes to Docker Hub.
# Tags follow the OpenClaw base version — e.g., 2026.3.13-1 + latest.
#
# Usage (run from repo root or scripts/ directory):
#   .\scripts\build-and-push.ps1                                  # from repo root
#   .\build-and-push.ps1                                          # from scripts/
#   .\scripts\build-and-push.ps1 -OpenClawTag "2026.3.13-1"      # pin to a specific version

param(
  [string]$DockerHubUser = $env:DOCKERHUB_USER,
  [string]$OpenClawTag = "latest",
  [string]$ImageName = "thales-csm-openclaw"
)

$ErrorActionPreference = "Stop"

if (-not $DockerHubUser) {
  $DockerHubUser = Read-Host "Docker Hub username"
  if (-not $DockerHubUser) { throw "Docker Hub username is required. Pass -DockerHubUser or set DOCKERHUB_USER env var." }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Push-Location $repoRoot

$fullImage = "${DockerHubUser}/${ImageName}"
$baseImage = "ghcr.io/openclaw/openclaw:${OpenClawTag}"

Write-Host "=== Building OpenClaw + CipherTrust Secrets Manager ===" -ForegroundColor Cyan
Write-Host "  Base image:  $baseImage"
Write-Host ""

# Pull base
Write-Host "[1/5] Pulling base image..." -ForegroundColor Cyan
docker pull $baseImage
if ($LASTEXITCODE -ne 0) { throw "Failed to pull base image" }

# Detect the OpenClaw version from the base image labels/env
Write-Host "[2/5] Detecting OpenClaw version..." -ForegroundColor Cyan
$fmt = '{{ index .Config.Labels \"org.opencontainers.image.version\" }}'
$versionLabel = docker inspect --format $fmt $baseImage 2>$null
if (-not $versionLabel -or $versionLabel -eq '<no value>') {
  $fmt2 = '{{ index .Config.Labels \"version\" }}'
  $versionLabel = docker inspect --format $fmt2 $baseImage 2>$null
}
if ((-not $versionLabel -or $versionLabel -eq '<no value>') -and $OpenClawTag -ne "latest") {
  $versionLabel = $OpenClawTag
}
if (-not $versionLabel -or $versionLabel -eq '<no value>') {
  $versionLabel = docker inspect --format "{{ .Id }}" $baseImage
  $versionLabel = $versionLabel.Substring(7, 12)
  Write-Host "  Could not detect version label, using image hash: $versionLabel" -ForegroundColor Yellow
}
Write-Host "  OpenClaw version: $versionLabel" -ForegroundColor Green

# Build
Write-Host "[3/5] Building image..." -ForegroundColor Cyan
docker build `
  --build-arg "OPENCLAW_TAG=${OpenClawTag}" `
  --label "openclaw.base.version=${versionLabel}" `
  --label "openclaw.base.tag=${OpenClawTag}" `
  -f Dockerfile.akeyless `
  -t "${fullImage}:${versionLabel}" `
  -t "${fullImage}:latest" `
  .
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

Write-Host "  Tagged: ${fullImage}:${versionLabel}" -ForegroundColor Green
Write-Host "  Tagged: ${fullImage}:latest" -ForegroundColor Green

# Login check
Write-Host "[4/5] Checking Docker Hub login..." -ForegroundColor Cyan
$loginCheck = docker info 2>&1 | Select-String "Username"
if (-not $loginCheck) {
  Write-Host "  Not logged in. Run: docker login" -ForegroundColor Yellow
  docker login
  if ($LASTEXITCODE -ne 0) { throw "Docker login failed" }
}

# Push both tags
Write-Host "[5/5] Pushing to Docker Hub..." -ForegroundColor Cyan
docker push "${fullImage}:${versionLabel}"
if ($LASTEXITCODE -ne 0) { throw "Push failed for version tag" }

docker push "${fullImage}:latest"
if ($LASTEXITCODE -ne 0) { throw "Push failed for latest tag" }

Pop-Location

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "  Image:   ${fullImage}:${versionLabel}"
Write-Host "  Latest:  ${fullImage}:latest"
Write-Host "  Pull:    docker pull ${fullImage}:${versionLabel}"
Write-Host "           docker pull ${fullImage}:latest"
