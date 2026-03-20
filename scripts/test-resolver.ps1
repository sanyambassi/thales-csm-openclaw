param(
  [string]$GatewayUrl = $env:AKEYLESS_GATEWAY_URL,
  [string]$AccessId = $env:AKEYLESS_ACCESS_ID,
  [string]$AccessKey = $env:AKEYLESS_ACCESS_KEY,
  [string]$SecretPrefix = "/openclaw"
)

$ErrorActionPreference = "Stop"
$script:passed = 0
$script:failed = 0
$resolverPath = Join-Path $PSScriptRoot "..\docker\akeyless-resolver.js"

function Assert($name, $condition) {
  if ($condition) {
    Write-Host ("  PASS: " + $name) -ForegroundColor Green
    $script:passed++
  } else {
    Write-Host ("  FAIL: " + $name) -ForegroundColor Red
    $script:failed++
  }
}

function RunResolver($inputObj, [string[]]$extraArgs = @()) {
  $tmpIn  = [System.IO.Path]::GetTempFileName()
  $tmpOut = [System.IO.Path]::GetTempFileName()
  $tmpErr = [System.IO.Path]::GetTempFileName()
  try {
    $json = $inputObj | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($tmpIn, $json)
    $allArgs = @($resolverPath, "--gateway-url", $GatewayUrl, "--secret-prefix", $SecretPrefix) + $extraArgs
    $proc = Start-Process -FilePath "node" -ArgumentList $allArgs -RedirectStandardInput $tmpIn -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -Wait -NoNewWindow -PassThru
    $stdout = [System.IO.File]::ReadAllText($tmpOut).Trim()
    return @{ ExitCode = $proc.ExitCode; Stdout = $stdout }
  } finally {
    Remove-Item $tmpIn,$tmpOut,$tmpErr -ErrorAction SilentlyContinue
  }
}

function RunResolverNoStdin([string[]]$extraArgs) {
  $tmpOut = [System.IO.Path]::GetTempFileName()
  $tmpErr = [System.IO.Path]::GetTempFileName()
  try {
    $allArgs = @($resolverPath, "--gateway-url", $GatewayUrl) + $extraArgs
    $proc = Start-Process -FilePath "node" -ArgumentList $allArgs -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -Wait -NoNewWindow -PassThru
    $stdout = [System.IO.File]::ReadAllText($tmpOut).Trim()
    return @{ ExitCode = $proc.ExitCode; Stdout = $stdout }
  } finally {
    Remove-Item $tmpOut,$tmpErr -ErrorAction SilentlyContinue
  }
}

$env:AKEYLESS_ACCESS_ID = $AccessId
$env:AKEYLESS_ACCESS_KEY = $AccessKey

Write-Host ""
Write-Host "=== Setup ===" -ForegroundColor Cyan
$authBody = @{ "access-id" = $AccessId; "access-key" = $AccessKey; "access-type" = "access_key" } | ConvertTo-Json
$authResp = Invoke-RestMethod -Uri ($GatewayUrl + "/v2/auth") -Method POST -Body $authBody -ContentType "application/json" -TimeoutSec 30
$token = $authResp.token
Write-Host "  Authenticated" -ForegroundColor Green

$testPath = $SecretPrefix + "/test/resolver-e2e"
$testValue = "e2e-value-" + (Get-Random)

try {
  $d = @{ name = $testPath; token = $token } | ConvertTo-Json
  Invoke-RestMethod -Uri ($GatewayUrl + "/v2/delete-item") -Method POST -Body $d -ContentType "application/json" -TimeoutSec 30 | Out-Null
} catch {}

$c = @{ name = $testPath; value = $testValue; token = $token } | ConvertTo-Json
Invoke-RestMethod -Uri ($GatewayUrl + "/v2/create-secret") -Method POST -Body $c -ContentType "application/json" -TimeoutSec 30 | Out-Null
Write-Host ("  Created: " + $testPath) -ForegroundColor Green

# ---- Test 1: Health check ----
Write-Host ""
Write-Host "=== Test 1: Health Check ===" -ForegroundColor Cyan
$r = RunResolverNoStdin @("--health-check")
Assert "exit code 0" ($r.ExitCode -eq 0)
Assert "stdout contains ok" ($r.Stdout -match "ok")

# ---- Test 2: Single secret ----
Write-Host ""
Write-Host "=== Test 2: Single Secret ===" -ForegroundColor Cyan
$r = RunResolver @{ protocolVersion = 1; provider = "akeyless"; ids = @("test/resolver-e2e") }
$resp = $r.Stdout | ConvertFrom-Json
Assert "protocolVersion is 1" ($resp.protocolVersion -eq 1)
$resolvedVal = $resp.values."test/resolver-e2e"
Assert "value matches" ($resolvedVal -eq $testValue)

# ---- Test 3: Batch with one missing ----
Write-Host ""
Write-Host "=== Test 3: Batch (1 valid + 1 missing) ===" -ForegroundColor Cyan
$r = RunResolver @{ protocolVersion = 1; provider = "akeyless"; ids = @("test/resolver-e2e", "test/nonexistent-xyz") }
$resp = $r.Stdout | ConvertFrom-Json
$val3 = $resp.values."test/resolver-e2e"
Assert "valid secret resolved" ($val3 -eq $testValue)
$errField = $resp.errors."test/nonexistent-xyz"
Assert "missing secret reported in errors" ($null -ne $errField)

# ---- Test 4: Empty ids ----
Write-Host ""
Write-Host "=== Test 4: Empty IDs ===" -ForegroundColor Cyan
$r = RunResolver @{ protocolVersion = 1; provider = "akeyless"; ids = @() }
Assert "exit code 0" ($r.ExitCode -eq 0)
$resp4 = $r.Stdout | ConvertFrom-Json
Assert "protocolVersion is 1" ($resp4.protocolVersion -eq 1)

# ---- Test 5: List mode ----
Write-Host ""
Write-Host "=== Test 5: List Mode ===" -ForegroundColor Cyan
$r = RunResolverNoStdin @("--secret-prefix", $SecretPrefix, "--list")
Assert "exit code 0" ($r.ExitCode -eq 0)
$listItems = $r.Stdout | ConvertFrom-Json
$hasTest = $listItems -contains "test/resolver-e2e"
Assert "list includes test secret" $hasTest

# ---- Cleanup ----
Write-Host ""
Write-Host "=== Cleanup ===" -ForegroundColor Cyan
try {
  $d2 = @{ name = $testPath; token = $token } | ConvertTo-Json
  Invoke-RestMethod -Uri ($GatewayUrl + "/v2/delete-item") -Method POST -Body $d2 -ContentType "application/json" -TimeoutSec 30 | Out-Null
  Write-Host "  Deleted test secret" -ForegroundColor Green
} catch {
  Write-Host "  Cleanup warning" -ForegroundColor Yellow
}

# ---- Summary ----
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
$p = $script:passed
$f = $script:failed
Write-Host ("  Passed: " + $p) -ForegroundColor Green
if ($f -gt 0) {
  Write-Host ("  Failed: " + $f) -ForegroundColor Red
  exit 1
} else {
  Write-Host ("  Failed: " + $f) -ForegroundColor Green
  exit 0
}
