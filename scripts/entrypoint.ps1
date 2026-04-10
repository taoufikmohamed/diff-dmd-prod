[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$deepSeekApiKey = $env:INPUT_DEEPSEEK_API_KEY
$azureSubscriptionId = $env:INPUT_AZURE_SUBSCRIPTION_ID
$environment = if ([string]::IsNullOrWhiteSpace($env:INPUT_ENVIRONMENT)) { "prod" } else { $env:INPUT_ENVIRONMENT }
$location = if ([string]::IsNullOrWhiteSpace($env:INPUT_LOCATION)) { "westeurope" } else { $env:INPUT_LOCATION }

if ([string]::IsNullOrWhiteSpace($deepSeekApiKey)) {
    throw "Input 'deepseek_api_key' is required."
}

Write-Host "Starting deploy-production.ps1 for environment '$environment' in '$location'..."
if (-not [string]::IsNullOrWhiteSpace($azureSubscriptionId)) {
    & "$repoRoot/deploy-production.ps1" `
        -DeepSeekApiKey $deepSeekApiKey `
        -AzureSubscriptionId $azureSubscriptionId `
        -Environment $environment `
        -Location $location
} else {
    & "$repoRoot/deploy-production.ps1" `
        -DeepSeekApiKey $deepSeekApiKey `
        -Environment $environment `
        -Location $location
}

if ($LASTEXITCODE -ne 0) {
    throw "deploy-production.ps1 failed with exit code $LASTEXITCODE"
}

if ($env:GITHUB_OUTPUT) {
    "status=success" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
