[CmdletBinding()]
param(
    [ValidateRange(60, 1800)][int]$TimeoutSeconds = 600,
    [ValidateNotNullOrEmpty()][string]$VersionsFile,
    [switch]$AzureSql,
    [switch]$AzureMongo,
    [ValidateNotNullOrEmpty()][string]$SubscriptionId = 'bff6a774-701a-4987-b913-5288d9ef784e',
    [ValidateNotNullOrEmpty()][string]$ResourceGroup = 'booking-aks-lab',
    [ValidateNotNullOrEmpty()][string]$ClusterName = 'booking-aks',
    [ValidateNotNullOrEmpty()][string]$VaultName = 'kv-booking-bff6a774'
)

$ErrorActionPreference = 'Stop'
$chart = Join-Path $PSScriptRoot '../booking-platform'
$values = Join-Path $chart 'values.azure.yaml'

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

$sqlArgs = if ($AzureSql) { @('-f', (Join-Path $chart 'values.azure-sql.yaml')) } else { @() }
$mongoArgs = if ($AzureMongo) { @('-f', (Join-Path $chart 'values.azure-mongo.yaml')) } else { @() }
if ($AzureMongo) {
    $mongoSecret = (Invoke-Tool az @('keyvault', 'secret', 'show', '--subscription', $SubscriptionId,
        '--vault-name', $VaultName, '--name', 'mongo-conn-search-azure', '--query', 'id', '-o', 'tsv')) -join ''
    if (-not $mongoSecret) { throw 'Run infra/azure-mongo first. Azure Mongo connection secret is missing.' }
}
if ($AzureSql) {
    $aksLocation = (Invoke-Tool az @('aks', 'show', '--subscription', $SubscriptionId,
        '-g', $ResourceGroup, '-n', $ClusterName, '--query', 'location', '-o', 'tsv')) -join ''
    if ($aksLocation -ne 'italynorth') { throw 'AzureSql requires AKS in italynorth. Use infra/azure/azure-sql.tfvars when creating the cluster.' }
}

$clientId = (Invoke-Tool az @('aks', 'show', '--subscription', $SubscriptionId,
    '-g', $ResourceGroup, '-n', $ClusterName, '--query', 'addonProfiles.azureKeyvaultSecretsProvider.identity.clientId', '-o', 'tsv')) -join ''
$tenantId = (Invoke-Tool az @('keyvault', 'show', '--subscription', $SubscriptionId,
    '-g', $ResourceGroup, '-n', $VaultName, '--query', 'properties.tenantId', '-o', 'tsv')) -join ''
if (-not $clientId -or -not $tenantId) { throw 'Missing CSI identity or Key Vault tenant. Check the Azure infrastructure setup.' }
$vaultArgs = @('--set', 'keyVault.enabled=true', '--set-string', "keyVault.name=$VaultName",
    '--set-string', "keyVault.tenantId=$tenantId", '--set-string', "keyVault.clientId=$clientId")

Invoke-Tool az @('aks', 'get-credentials', '--subscription', $SubscriptionId,
    '-g', $ResourceGroup, '-n', $ClusterName, '--context', $ClusterName, '--overwrite-existing')
if ($AzureSql) {
    $existingSql = (Invoke-Tool kubectl @('--context', $ClusterName, '-n', 'booking', 'get',
        'deployment', 'devops-sql', '--ignore-not-found', '-o', 'name')) -join ''
    if ($existingSql) { throw 'AzureSql is for a fresh install. Existing devops-sql data must be migrated before removing its deployment/PVC.' }
}
Invoke-Tool kubectl @('--context', $ClusterName, '-n', 'ingress-nginx', 'rollout', 'status',
    'deployment/ingress-nginx-controller', '--timeout', "${TimeoutSeconds}s")

$helmVersion = (Invoke-Tool helm @('version', '--short')) -join ''
$waitFlag = if ($helmVersion -match '^v4\.') { '--wait=legacy' } else { '--wait' }
Invoke-Tool helm (@('lint', $chart, '--strict', '-f', $values) + $versionArgs + $sqlArgs + $mongoArgs + $vaultArgs)
Invoke-Tool helm (@('upgrade', '--install', 'booking', $chart, '--kube-context', $ClusterName,
    '-n', 'booking', '--create-namespace', '-f', $values,
    $waitFlag, '--timeout', "${TimeoutSeconds}s") + $versionArgs + $sqlArgs + $mongoArgs + $vaultArgs)

Invoke-Tool kubectl @('--context', $ClusterName, '-n', 'booking', 'rollout', 'restart',
    'deployment/user-service', 'deployment/accommodation-service', 'deployment/reservation-service',
    'deployment/search-service', 'deployment/rating-service', 'deployment/notification-service', 'deployment/frontend')
foreach ($kind in 'deployment', 'daemonset') {
    Invoke-Tool kubectl @('--context', $ClusterName, '-n', 'booking', 'rollout', 'status', $kind, '--timeout', "${TimeoutSeconds}s")
}
try {
    $appHost = (Invoke-Tool kubectl @('--context', $ClusterName, '-n', 'booking', 'get', 'ingress',
        'booking-ingress', '-o', 'jsonpath={.spec.rules[0].host}')) -join ''
    if (-not $appHost) { throw 'Application ingress host not found.' }
    Write-Host 'Opening Chrome for the smoke test. Please leave the browser open until it finishes.'
    Invoke-Tool python @((Join-Path $PSScriptRoot 'smoke.py'), "http://$appHost", '--headed')
}
catch {
    throw "Deployment was applied, but verification failed. No rollback was performed. $($_.Exception.Message)"
}
Write-Host "Deployment verified: http://$appHost (Selenium browser smoke passed)."
