[CmdletBinding()]
param(
    [ValidateRange(60, 1800)][int]$TimeoutSeconds = 600,
    [ValidateNotNullOrEmpty()][string]$VersionsFile
)

$ErrorActionPreference = 'Stop'
$chart = Join-Path $PSScriptRoot '../booking-platform'
$secrets = Join-Path $chart 'values.secrets.yaml'

function Invoke-Tool {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed (exit $LASTEXITCODE)." }
}

Invoke-Tool python @('-c', 'import selenium, requests')
$versionArgs = @()
if ($PSBoundParameters.ContainsKey('VersionsFile')) {
    if (-not (Test-Path -LiteralPath $VersionsFile -PathType Leaf)) { throw "Missing versions file: $VersionsFile" }
    $versionArgs = @('-f', (Resolve-Path -LiteralPath $VersionsFile).ProviderPath)
}
if (-not (Test-Path -LiteralPath $secrets -PathType Leaf)) { throw "Create $secrets first (see README)." }

Invoke-Tool minikube @('status', '-p', 'minikube')
Invoke-Tool kubectl @('--context', 'minikube', '-n', 'ingress-nginx', 'rollout', 'status',
    'deployment/ingress-nginx-controller', '--timeout', "${TimeoutSeconds}s")
$helmVersion = (Invoke-Tool helm @('version', '--short')) -join ''
$waitFlag = if ($helmVersion -match '^v4\.') { '--wait=legacy' } else { '--wait' }
Invoke-Tool helm (@('lint', $chart, '--strict', '-f', $secrets) + $versionArgs)
Invoke-Tool helm (@('upgrade', '--install', 'booking', $chart,
    '--kube-context', 'minikube', '-n', 'booking', '--create-namespace', '-f', $secrets,
    $waitFlag, '--timeout', "${TimeoutSeconds}s") + $versionArgs)

Invoke-Tool kubectl @('--context', 'minikube', '-n', 'booking', 'rollout', 'restart',
    'deployment/user-service', 'deployment/accommodation-service', 'deployment/reservation-service',
    'deployment/search-service', 'deployment/rating-service', 'deployment/notification-service', 'deployment/frontend')
foreach ($kind in 'deployment', 'daemonset') {
    Invoke-Tool kubectl @('--context', 'minikube', '-n', 'booking', 'rollout', 'status', $kind, '--timeout', "${TimeoutSeconds}s")
}
try {
    $appHost = (Invoke-Tool kubectl @('--context', 'minikube', '-n', 'booking', 'get', 'ingress',
        'booking-ingress', '-o', 'jsonpath={.spec.rules[0].host}')) -join ''
    if (-not $appHost) { throw 'Application ingress host not found.' }
    Write-Host 'Opening Chrome for the smoke test. Please leave the browser open until it finishes.'
    Invoke-Tool python @((Join-Path $PSScriptRoot 'smoke.py'), "http://$appHost", '--headed')
}
catch {
    throw "Deployment was applied, but verification failed. No rollback was performed. Check hosts mapping and minikube tunnel. $($_.Exception.Message)"
}
Write-Host "Deployment verified: http://$appHost (Selenium browser smoke passed)."
