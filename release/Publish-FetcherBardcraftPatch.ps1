[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PatchDirectory,
    [string] $PatchVersion = "2.0.22",
    [string] $Repository = "Skooma-Breath/Fetcher-Bardcraft",
    [string] $ReleaseTag = "fetcher-bardcraft-mp-patch-v2",
    [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$payloadRoot = (Resolve-Path -LiteralPath $PatchDirectory).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot "dist\bardcraft-patch-v$PatchVersion"
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$required = @(
    "Apply-Fetcher-Bardcraft-MPPatch.ps1"
    "fetcher-bardcraft-mp-patch.json"
    "README.txt"
)
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $payloadRoot $name) -PathType Leaf)) {
        throw "Required Bardcraft patch payload is missing: $name"
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $payloadRoot "fetcher-bardcraft-mp-patch.json") -Raw | ConvertFrom-Json
if ([string]$manifest.patchVersion -ne $PatchVersion) {
    throw "Patch manifest version $($manifest.patchVersion) does not match requested version $PatchVersion."
}
if ([int]$manifest.formatVersion -notin @(1, 2)) {
    throw "Unsupported Bardcraft patch manifest format: $($manifest.formatVersion)"
}

Push-Location $repositoryRoot
try {
    $pending = @(git status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect the Fetcher-Bardcraft worktree." }
    if ($pending.Count -ne 0) { throw "Refusing to publish from a dirty worktree." }
    $sourceCommit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch "^[0-9a-f]{40}$") {
        throw "Could not resolve the Fetcher-Bardcraft source commit."
    }

    $archivePath = Join-Path $outputRoot "fetcher-bardcraft-mp-patch-v2.zip"
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    Compress-Archive -Path (Join-Path $payloadRoot "*") -DestinationPath $archivePath -CompressionLevel Optimal

    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $env:GH_TOKEN = (& gh auth token).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
            throw "GitHub authentication is required. Run 'gh auth login' first."
        }
    }

    $notes = @"
Fetcher Bardcraft multiplayer compatibility patch $PatchVersion.

This stable release is maintained independently from the Fetcher Simulator
client so Bardcraft patch updates do not require a complete client download.
"@
    & (Join-Path $PSScriptRoot "Publish-StableGitHubRelease.ps1") `
        -Repository $Repository `
        -Tag $ReleaseTag `
        -TargetCommit $sourceCommit `
        -Title "Fetcher Bardcraft Multiplayer Patch v2" `
        -Notes $notes `
        -Assets $archivePath
    if (-not $?) { throw "Fetcher Bardcraft release publication failed." }

    Write-Host "Published: $archivePath"
    Write-Host "SHA256: $((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant())"
}
finally {
    Pop-Location
}

