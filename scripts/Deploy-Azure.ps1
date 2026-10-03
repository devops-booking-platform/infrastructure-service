# Requires az login and existing AKS + ingress (see docs/azure-public-access.md).
[CmdletBinding()]
param(
    [ValidateRange(60, 1800)][int]$TimeoutSeconds = 600,
    [ValidateNotNullOrEmpty()][string]$VersionsFile
)

$ErrorActionPreference = 'Stop'
$subscription = 'bff6a774-701a-4987-b913-5288d9ef784e'
$group = 'booking-aks-lab'
$context = 'booking-aks'
$chart = Join-Path $PSScriptRoot '../booking-platform'
$values = Join-Path $chart 'values.azure.yaml'
$terraformDir = Join-Path $PSScriptRoot '../infra/azure'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$resultDir = Join-Path $workspace ('_local-results/deploy-azure-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$report = [ordered]@{ startedUtc = [DateTime]::UtcNow.ToString('o'); context = $context
    status = 'failed'; stage = 'prerequisites'; verification = 'Kubernetes readiness; browser tests remain manual.' }

function Invoke-Tool {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed during $($report.stage) (exit $LASTEXITCODE)." }
}

try {
    $versionArgs = @()
    if ($PSBoundParameters.ContainsKey('VersionsFile')) {
        if (-not (Test-Path -LiteralPath $VersionsFile -PathType Leaf)) { throw "Missing versions file: $VersionsFile" }
        $report.versionsFile = (Resolve-Path -LiteralPath $VersionsFile).ProviderPath
        $versionArgs = @('-f', $report.versionsFile)
    }
    foreach ($tool in 'az', 'kubectl', 'helm', 'terraform') {
        Get-Command $tool -CommandType Application -ErrorAction Stop | Out-Null
    }
    foreach ($file in @($values)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing file: $file" }
    }
    $report.helmVersion = (Invoke-Tool helm @('version', '--short')) -join ''
    $waitFlag = if ($report.helmVersion -match '^v4\.') { '--wait=legacy' } else { '--wait' }

    $vault = ((Invoke-Tool terraform @("-chdir=$terraformDir", 'output', '-json', 'key_vault')) -join "`n") | ConvertFrom-Json
    if (-not $vault.name -or -not $vault.tenantId -or -not $vault.clientId) { throw 'Apply the updated AKS Terraform first: Key Vault output is missing.' }
    $vaultArgs = @('--set', 'keyVault.enabled=true', '--set-string', "keyVault.name=$($vault.name)",
        '--set-string', "keyVault.tenantId=$($vault.tenantId)", '--set-string', "keyVault.clientId=$($vault.clientId)")

    $report.stage = 'cluster'
    Invoke-Tool az @('aks', 'get-credentials', '--subscription', $subscription,
        '--resource-group', $group, '--name', $context, '--context', $context, '--overwrite-existing')
    $nodes = ((Invoke-Tool kubectl @('--context', $context, 'get', 'nodes', '-o', 'json', '--request-timeout=30s')) -join "`n") | ConvertFrom-Json
    if (-not $nodes.items) { throw 'AKS has no nodes.' }
    foreach ($node in $nodes.items) {
        if ($node.spec.providerID -notlike "azure:///subscriptions/$subscription/resourceGroups/$group-nodes/*") {
            throw 'Unexpected node provider ID. Refusing to deploy to another cluster.'
        }
        if (-not ($node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })) {
            throw 'AKS nodes are not all Ready.'
        }
    }

    $report.stage = 'ingress'
    Invoke-Tool kubectl @('--context', $context, '-n', 'ingress-nginx', 'rollout', 'status',
        'deployment/ingress-nginx-controller', '--timeout', "${TimeoutSeconds}s")
    $service = ((Invoke-Tool kubectl @('--context', $context, '-n', 'ingress-nginx', 'get',
        'service', 'ingress-nginx-controller', '-o', 'json', '--request-timeout=30s')) -join "`n") | ConvertFrom-Json
    $publicIps = @(((Invoke-Tool az @('network', 'public-ip', 'list', '--subscription', $subscription,
        '--resource-group', "$group-nodes", '--query', "[?dnsSettings.domainNameLabel=='booking-aks-bff6a774']", '-o', 'json')) -join "`n") | ConvertFrom-Json)
    if ($publicIps.Count -ne 1 -or -not $publicIps[0].dnsSettings.fqdn -or
        -not $publicIps[0].ipAddress -or $publicIps[0].ipAddress -notin @($service.status.loadBalancer.ingress.ip)) {
        throw 'Azure DNS label and ingress external IP do not match. Check the ingress Terraform deployment.'
    }
    $report.url = 'http://' + $publicIps[0].dnsSettings.fqdn
    $hostOverride = 'ingress.hosts.app=' + $publicIps[0].dnsSettings.fqdn

    $report.stage = 'helm'
    Invoke-Tool helm (@('lint', $chart, '--strict', '-f', $values, '--set-string', $hostOverride) + $versionArgs + $vaultArgs)
    Invoke-Tool helm (@('upgrade', '--install', 'booking', $chart, '--kube-context', $context,
        '-n', 'booking', '--create-namespace', '-f', $values,
        '--set-string', $hostOverride, $waitFlag, '--timeout', "${TimeoutSeconds}s") + $versionArgs + $vaultArgs)

    $report.stage = 'readiness'
    Invoke-Tool kubectl @('--context', $context, '-n', 'booking', 'rollout', 'restart',
        'deployment/user-service', 'deployment/accommodation-service', 'deployment/reservation-service',
        'deployment/search-service', 'deployment/rating-service', 'deployment/notification-service', 'deployment/frontend')
    foreach ($kind in 'deployment', 'daemonset') {
        Invoke-Tool kubectl @('--context', $context, '-n', 'booking', 'rollout', 'status', $kind, '--timeout', "${TimeoutSeconds}s")
    }

    $report.stage = 'evidence'
    $pods = ((Invoke-Tool kubectl @('--context', $context, '-n', 'booking', 'get', 'pods', '-o', 'json', '--request-timeout=30s')) -join "`n") | ConvertFrom-Json
    $report.pods = @($pods.items | ForEach-Object {
        [ordered]@{ name = $_.metadata.name; phase = $_.status.phase
            containers = @($_.status.containerStatuses | Select-Object name, ready, restartCount, image, imageID) }
    })
    $report.status = 'succeeded'
    Write-Host "Deployment ready: $($report.url) - verify login, reservations and notifications in the browser."
}
finally {
    $report.elapsedSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resultDir 'result.json') -Encoding UTF8
    Write-Host "Result: $resultDir/result.json (status: $($report.status), stage: $($report.stage))"
}
