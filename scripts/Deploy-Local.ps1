# Run from any directory. Requires Windows PowerShell 5.1+ or PowerShell 7.
[CmdletBinding()]
param(
    [ValidateRange(60, 1800)]
    [int]$TimeoutSeconds = 600,
    [ValidateNotNullOrEmpty()][string]$VersionsFile
)

$ErrorActionPreference = 'Stop'
$chart = Join-Path $PSScriptRoot '../booking-platform'
$secrets = Join-Path $chart 'values.secrets.yaml'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$resultDir = Join-Path $workspace ('_local-results/deploy-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$report = [ordered]@{
    startedUtc = [DateTime]::UtcNow.ToString('o')
    context = 'minikube'; namespace = 'booking'; release = 'booking'
    status = 'failed'; stage = 'prerequisites'
    verification = 'Kubernetes readiness only; browser business tests are separate.'
}

# PowerShell does not automatically throw when a native program fails.
function Invoke-Tool {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed (exit $LASTEXITCODE) during $($report.stage)."
    }
}

try {
    $versionArgs = @()
    if ($PSBoundParameters.ContainsKey('VersionsFile')) {
        if (-not (Test-Path -LiteralPath $VersionsFile -PathType Leaf)) { throw "Missing versions file: $VersionsFile" }
        $report.versionsFile = (Resolve-Path -LiteralPath $VersionsFile).ProviderPath
        $versionArgs = @('-f', $report.versionsFile)
    }
    foreach ($tool in 'docker', 'minikube', 'kubectl', 'helm') {
        Get-Command $tool -CommandType Application -ErrorAction Stop | Out-Null
    }
    if (-not (Test-Path -LiteralPath $secrets -PathType Leaf)) {
        throw 'Create booking-platform/values.secrets.yaml as described in README first.'
    }

    $dockerOS = Invoke-Tool docker @('info', '--format', '{{.OSType}}')
    if ($dockerOS.Trim() -ne 'linux') { throw 'Docker Desktop must use Linux containers.' }
    $report.helmVersion = (Invoke-Tool helm @('version', '--short')) -join ''
    $waitFlag = if ($report.helmVersion -match '^v4\.') { '--wait=legacy' } else { '--wait' }
    $report.minikubeVersion = (Invoke-Tool minikube @('version', '--short')) -join ''
    Invoke-Tool helm (@('lint', $chart, '--strict', '-f', $secrets) + $versionArgs)

    $report.stage = 'cluster'
    $null = & minikube status -p minikube --output=json
    $report.clusterWasRunning = ($LASTEXITCODE -eq 0)
    if ($report.clusterWasRunning) {
        Write-Host 'Minikube is already running.'
    }
    else {
        Write-Host 'Starting local Minikube (2 CPUs, 8000 MiB)...'
        Invoke-Tool minikube @('start', '-p', 'minikube', '--cpus=2', '--memory=8000')
    }
    $limits = ((Invoke-Tool docker @('inspect', 'minikube', '--format', '{{json .HostConfig}}')) -join "`n") | ConvertFrom-Json
    $report.dockerLimits = [ordered]@{ nanoCpus = $limits.NanoCpus; memoryBytes = $limits.Memory }
    Invoke-Tool minikube @('addons', 'enable', 'ingress', '-p', 'minikube')

    $report.stage = 'helm'
    Write-Host 'Installing/upgrading booking...'
    $helmTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Tool helm (@('upgrade', '--install', 'booking', $chart,
        '--kube-context', 'minikube', '-n', 'booking', '--create-namespace',
        '-f', (Join-Path $chart 'values.yaml'), '-f', $secrets,
        $waitFlag, '--timeout', "${TimeoutSeconds}s") + $versionArgs)
    $report.helmSeconds = [math]::Round($helmTimer.Elapsed.TotalSeconds, 2)

    # The develop tag stays the same after a build. Recreate application pods
    # so imagePullPolicy: Always checks GHCR for the current image.
    $report.stage = 'refresh-applications'
    Invoke-Tool kubectl @('--context', 'minikube', '-n', 'booking', 'rollout', 'restart',
        'deployment/user-service', 'deployment/accommodation-service',
        'deployment/reservation-service', 'deployment/search-service',
        'deployment/rating-service', 'deployment/notification-service', 'deployment/frontend')

    $report.stage = 'readiness'
    Invoke-Tool kubectl @('--context', 'minikube', '-n', 'booking', 'rollout', 'status', 'deployment', '--timeout', "${TimeoutSeconds}s")
    Invoke-Tool kubectl @('--context', 'minikube', '-n', 'booking', 'rollout', 'status', 'daemonset', '--timeout', "${TimeoutSeconds}s")
    Invoke-Tool kubectl @('--context', 'minikube', '-n', 'ingress-nginx', 'rollout', 'status', 'deployment/ingress-nginx-controller', '--timeout', "${TimeoutSeconds}s")

    $report.stage = 'evidence'
    $pods = ((Invoke-Tool kubectl @('--context', 'minikube', '-n', 'booking', 'get', 'pods', '-o', 'json')) -join "`n") | ConvertFrom-Json
    $report.pods = @($pods.items | ForEach-Object {
        [ordered]@{ name = $_.metadata.name; uid = $_.metadata.uid; phase = $_.status.phase
            deletionTimestamp = $_.metadata.deletionTimestamp
            containers = @($_.status.containerStatuses | Select-Object name, ready, restartCount, image, imageID) }
    })
    $pvcs = ((Invoke-Tool kubectl @('--context', 'minikube', '-n', 'booking', 'get', 'pvc', '-o', 'json')) -join "`n") | ConvertFrom-Json
    $report.pvcs = @($pvcs.items | ForEach-Object {
        [ordered]@{ name = $_.metadata.name; uid = $_.metadata.uid; phase = $_.status.phase; volume = $_.spec.volumeName }
    })
    $report.helmRelease = ((Invoke-Tool helm @('list', '--kube-context', 'minikube', '-n', 'booking', '--filter', '^booking$', '-o', 'json')) -join "`n") | ConvertFrom-Json
    $report.status = 'succeeded'
    Write-Host 'Deployment ready. For browser access, use the existing README instructions.'
}
catch {
    # Do not dump Helm values, secrets or full manifests into the report.
    Write-Host "Deployment stopped during $($report.stage): $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    $report.elapsedSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resultDir 'result.json') -Encoding UTF8
    Write-Host "Result: $resultDir/result.json"
}
