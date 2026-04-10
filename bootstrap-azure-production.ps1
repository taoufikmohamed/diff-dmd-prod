<#
.SYNOPSIS
    Production bootstrap for DMD Cloud on Azure AKS + ACR using .env values.

.DESCRIPTION
    End-to-end bootstrap that:
    1) Loads required configuration from .env
    2) Ensures Azure Resource Group, ACR, and AKS exist
    3) Builds and pushes images to ACR (local Docker or ACR remote build)
    4) Deploys production manifests to AKS
    5) Creates required Kubernetes secrets (DeepSeek + GitHub)
    6) Configures/updates GitHub webhook for push events

.PARAMETER EnvFile
    Path to .env file. Defaults to ./.env

.PARAMETER Environment
    Environment suffix for naming convention. Defaults to prod.

.PARAMETER Location
    Azure region (for new RG/ACR/AKS).

.PARAMETER Namespace
    Kubernetes namespace for production deployment.

.PARAMETER ForceHttpWebhook
    Allow HTTP webhook URL if no domain/HTTPS URL is provided.

.PARAMETER SkipWebhook
    Skip GitHub webhook create/update step.

.EXAMPLE
    .\bootstrap-azure-production.ps1

.EXAMPLE
    .\bootstrap-azure-production.ps1 -EnvFile ./.env -Environment prod -Location westeurope
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$EnvFile = ".env",

    [Parameter(Mandatory=$false)]
    [string]$Environment = "prod",

    [Parameter(Mandatory=$false)]
    [string]$Location = "westeurope",

    [Parameter(Mandatory=$false)]
    [string]$Namespace = "dmd-production",

    [Parameter(Mandatory=$false)]
    [switch]$SkipImageBuild,

    [Parameter(Mandatory=$false)]
    [switch]$ForceHttpWebhook,

    [Parameter(Mandatory=$false)]
    [switch]$SkipWebhook
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Gray
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory=$true)][string]$Description,
        [Parameter(Mandatory=$true)][scriptblock]$Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Require-Tool {
    param([string]$Tool)
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Required tool not found: $Tool"
    }
}

function Test-DockerDaemon {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        docker info *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Parse-DotEnv {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Missing env file: $Path"
    }

    $map = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith("#")) { continue }

        $eq = $trimmed.IndexOf("=")
        if ($eq -lt 1) { continue }

        $k = $trimmed.Substring(0, $eq).Trim()
        $v = $trimmed.Substring($eq + 1).Trim()

        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }

        $map[$k] = $v
    }

    return $map
}

function Get-RequiredEnv {
    param(
        [Parameter(Mandatory=$true)][hashtable]$EnvMap,
        [Parameter(Mandatory=$true)][string]$Key
    )

    if (-not $EnvMap.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace($EnvMap[$Key])) {
        throw "Required key '$Key' is missing in .env"
    }
    return $EnvMap[$Key]
}

function Get-OptionalEnv {
    param(
        [Parameter(Mandatory=$true)][hashtable]$EnvMap,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$false)][string]$Default = ""
    )

    if ($EnvMap.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($EnvMap[$Key])) {
        return $EnvMap[$Key]
    }
    return $Default
}

function Resolve-RepoFromGit {
    $remote = (git config --get remote.origin.url)
    if ([string]::IsNullOrWhiteSpace($remote)) {
        throw "Cannot infer repository from git remote origin. Set GITHUB_REPO_OWNER and GITHUB_REPO_NAME in .env"
    }

    if ($remote -match "github\.com[:/]([^/]+)/([^/]+?)(\.git)?$") {
        return @{ Owner = $matches[1]; Name = $matches[2] }
    }

    throw "Could not parse GitHub owner/repo from remote URL: $remote"
}

function Test-AcrTagExists {
    param(
        [Parameter(Mandatory=$true)][string]$Registry,
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][string]$Tag
    )

    $matches = az acr repository show-tags --name $Registry --repository $Repository --query "[?@=='$Tag']" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return -not [string]::IsNullOrWhiteSpace($matches)
}

function Get-WebhookUrl {
    param(
        [Parameter(Mandatory=$true)][hashtable]$EnvMap,
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][switch]$AllowHttp
    )

    $explicit = Get-OptionalEnv -EnvMap $EnvMap -Key "WEBHOOK_URL"
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        return $explicit
    }

    $domain = Get-OptionalEnv -EnvMap $EnvMap -Key "WEBHOOK_DOMAIN"
    if (-not [string]::IsNullOrWhiteSpace($domain)) {
        return "https://$domain/webhook/github"
    }

    $ip = ""
    for ($i = 0; $i -lt 30; $i++) {
        $ip = (kubectl get service webhook-service -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null)
        if (-not [string]::IsNullOrWhiteSpace($ip)) { break }
        Start-Sleep -Seconds 10
    }

    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw "No webhook URL provided and LoadBalancer IP is not available yet. Set WEBHOOK_URL or WEBHOOK_DOMAIN in .env"
    }

    if (-not $AllowHttp) {
        throw "Only HTTP URL could be derived from LoadBalancer IP. Set WEBHOOK_URL/WEBHOOK_DOMAIN for HTTPS, or rerun with -ForceHttpWebhook"
    }

    return "http://$ip/webhook/github"
}

function Get-RestErrorMessage {
    param([Parameter(Mandatory=$true)]$ErrorRecord)

    $msg = $ErrorRecord.Exception.Message
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $resp.GetResponseStream) {
            $stream = $resp.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    $msg = "$msg | $body"
                }
            }
        }
    } catch {
        # Keep base message when response body is unavailable.
    }

    return $msg
}

function Test-GitHubToken {
    param([Parameter(Mandatory=$true)][string]$GitHubToken)

    $headers = @{
        Authorization = "Bearer $GitHubToken"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "dmd-bootstrap-script"
    }

    try {
        $user = Invoke-RestMethod -Method GET -Uri "https://api.github.com/user" -Headers $headers
        if ([string]::IsNullOrWhiteSpace($user.login)) {
            throw "GitHub token is valid but no user identity was returned."
        }
        Write-Info "GitHub token validated for user: $($user.login)"
    } catch {
        $details = Get-RestErrorMessage -ErrorRecord $_
        if ($details -match "401" -or $details -match "Bad credentials") {
            throw "GitHub token in .env is invalid or expired. Generate a new token and update GITHUB_TOKEN. For classic PAT include 'repo' and 'admin:repo_hook'. For fine-grained PAT grant repository access and enable Webhooks (Read/Write), Contents (Read), and Metadata (Read)."
        }
        throw "Failed to validate GitHub token: $details"
    }
}

function Upsert-GitHubWebhook {
    param(
        [Parameter(Mandatory=$true)][string]$Owner,
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string]$GitHubToken,
        [Parameter(Mandatory=$true)][string]$WebhookUrl,
        [Parameter(Mandatory=$true)][string]$Secret
    )

    $headers = @{
        Authorization = "Bearer $GitHubToken"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "dmd-bootstrap-script"
    }

    $hooksUrl = "https://api.github.com/repos/$Owner/$Repo/hooks"
    try {
        $existing = Invoke-RestMethod -Method GET -Uri $hooksUrl -Headers $headers
    } catch {
        $details = Get-RestErrorMessage -ErrorRecord $_
        if ($details -match "401" -or $details -match "Bad credentials") {
            throw "GitHub webhook API authentication failed (401 Bad credentials). Update GITHUB_TOKEN in .env with a valid token."
        }
        if ($details -match "403" -or $details -match "Resource not accessible") {
            throw "GitHub token lacks permission to manage webhooks on $Owner/$Repo. Required permission is repository webhooks write access (classic PAT: admin:repo_hook)."
        }
        throw "Failed to list existing webhooks: $details"
    }
    $found = $existing | Where-Object { $_.config.url -eq $WebhookUrl }

    $body = @{
        name = "web"
        active = $true
        events = @("push")
        config = @{
            url = $WebhookUrl
            content_type = "json"
            secret = $Secret
            insecure_ssl = "0"
        }
    } | ConvertTo-Json -Depth 6

    if ($found) {
        $hookId = $found[0].id
        try {
            Invoke-RestMethod -Method PATCH -Uri "$hooksUrl/$hookId" -Headers $headers -Body $body -ContentType "application/json"
        } catch {
            $details = Get-RestErrorMessage -ErrorRecord $_
            if ($details -match "Hook url" -and $details -match "secure") {
                throw "GitHub rejected webhook URL '$WebhookUrl' because it is not HTTPS. Set WEBHOOK_URL or WEBHOOK_DOMAIN to an HTTPS endpoint, or use a TLS ingress/domain."
            }
            throw "Failed to update existing webhook ($hookId): $details"
        }
        Write-Success "Updated GitHub webhook ($hookId)"
    } else {
        try {
            Invoke-RestMethod -Method POST -Uri $hooksUrl -Headers $headers -Body $body -ContentType "application/json"
        } catch {
            $details = Get-RestErrorMessage -ErrorRecord $_
            if ($details -match "Hook url" -and $details -match "secure") {
                throw "GitHub rejected webhook URL '$WebhookUrl' because it is not HTTPS. Set WEBHOOK_URL or WEBHOOK_DOMAIN to an HTTPS endpoint, or use a TLS ingress/domain."
            }
            if ($details -match "422" -and $details -match "Validation Failed") {
                throw "GitHub webhook create failed due to validation. Check webhook URL format, repository permissions, and whether an equivalent webhook already exists. Details: $details"
            }
            throw "Failed to create webhook on $Owner/${Repo}: $details"
        }
        Write-Success "Created GitHub webhook"
    }
}

Write-Step "Validating prerequisites"
Require-Tool az
Require-Tool kubectl
Require-Tool git

Write-Step "Loading .env configuration"
$envMap = Parse-DotEnv -Path $EnvFile

$deepSeekApiKey = Get-RequiredEnv -EnvMap $envMap -Key "DEEPSEEK_API_KEY"
$subscriptionId = Get-RequiredEnv -EnvMap $envMap -Key "SUBSCRIPTION_ID"
$githubToken = Get-RequiredEnv -EnvMap $envMap -Key "GITHUB_TOKEN"
$githubWebhookSecret = Get-RequiredEnv -EnvMap $envMap -Key "GITHUB_WEBHOOK_SECRET"

Write-Step "Validating GitHub token"
Test-GitHubToken -GitHubToken $githubToken

$rgName = Get-OptionalEnv -EnvMap $envMap -Key "AZURE_RESOURCE_GROUP" -Default "dmd-$Environment-rg"
$acrName = Get-OptionalEnv -EnvMap $envMap -Key "ACR_NAME" -Default "dmdacr$Environment"
$aksName = Get-OptionalEnv -EnvMap $envMap -Key "AKS_CLUSTER_NAME" -Default "dmd-aks-$Environment"

$repoOwner = Get-OptionalEnv -EnvMap $envMap -Key "GITHUB_REPO_OWNER"
$repoName = Get-OptionalEnv -EnvMap $envMap -Key "GITHUB_REPO_NAME"
if ([string]::IsNullOrWhiteSpace($repoOwner) -or [string]::IsNullOrWhiteSpace($repoName)) {
    $repo = Resolve-RepoFromGit
    if ([string]::IsNullOrWhiteSpace($repoOwner)) { $repoOwner = $repo.Owner }
    if ([string]::IsNullOrWhiteSpace($repoName)) { $repoName = $repo.Name }
}

Write-Info "Using subscription: $subscriptionId"
Write-Info "Resource group: $rgName"
Write-Info "ACR: $acrName"
Write-Info "AKS: $aksName"
Write-Info "GitHub repo: $repoOwner/$repoName"

Write-Step "Azure authentication and subscription selection"
Invoke-Checked -Description "Select Azure subscription" -Command {
    az account set --subscription $subscriptionId
}

Write-Step "Ensuring Azure infrastructure exists"
Invoke-Checked -Description "Create/ensure resource group" -Command {
    az group create --name $rgName --location $Location --output none
}

$acrExists = az acr show --name $acrName --resource-group $rgName --query name -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($acrExists)) {
    Invoke-Checked -Description "Create ACR" -Command {
        az acr create --name $acrName --resource-group $rgName --location $Location --sku Standard --admin-enabled false --output none
    }
} else {
    Write-Info "ACR already exists"
}

$acrServer = az acr show --name $acrName --resource-group $rgName --query loginServer -o tsv

$aksExists = az aks show --name $aksName --resource-group $rgName --query name -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($aksExists)) {
    Invoke-Checked -Description "Create AKS" -Command {
        az aks create --name $aksName --resource-group $rgName --location $Location --node-count 2 --node-vm-size Standard_B2s --enable-managed-identity --attach-acr $acrName --generate-ssh-keys --output none
    }
} else {
    Write-Info "AKS already exists"
    Invoke-Checked -Description "Ensure AKS attached to ACR" -Command {
        az aks update --name $aksName --resource-group $rgName --attach-acr $acrName --output none
    }
}

Write-Step "Connecting kubectl to AKS"
Invoke-Checked -Description "Get AKS credentials" -Command {
    az aks get-credentials --resource-group $rgName --name $aksName --overwrite-existing
}

Write-Step "Building and pushing container images"
$imageTag = (Get-Date -Format "yyyyMMdd-HHmmss")

$dockerReady = Test-DockerDaemon
if ($SkipImageBuild) {
    Write-Info "Skipping image build as requested. Verifying existing ':latest' images in ACR."

    $webhookLatestExists = Test-AcrTagExists -Registry $acrName -Repository "webhook-service" -Tag "latest"
    $aiLatestExists = Test-AcrTagExists -Registry $acrName -Repository "ai-service" -Tag "latest"

    if (-not $webhookLatestExists -or -not $aiLatestExists) {
        throw "-SkipImageBuild was used but required image tags are missing in ACR. Ensure both '$acrServer/webhook-service:latest' and '$acrServer/ai-service:latest' exist."
    }
} elseif ($dockerReady) {
    Write-Info "Docker daemon detected. Using local build + push flow."

    # Use token-based ACR auth to avoid daemon-dependent 'az acr login' behavior.
    $acrAccessToken = az acr login --name $acrName --expose-token --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrAccessToken)) {
        throw "Failed to get ACR access token via 'az acr login --expose-token'."
    }

    Invoke-Checked -Description "Docker login to ACR" -Command {
        $acrAccessToken | docker login $acrServer --username "00000000-0000-0000-0000-000000000000" --password-stdin
    }

    Invoke-Checked -Description "Build webhook-service image" -Command {
        docker build -t "$acrServer/webhook-service:latest" -t "$acrServer/webhook-service:$imageTag" ./webhook_service
    }
    Invoke-Checked -Description "Push webhook-service image latest" -Command {
        docker push "$acrServer/webhook-service:latest"
    }

    Invoke-Checked -Description "Build ai-service image" -Command {
        docker build -t "$acrServer/ai-service:latest" -t "$acrServer/ai-service:$imageTag" ./ai_service
    }
    Invoke-Checked -Description "Push ai-service image latest" -Command {
        docker push "$acrServer/ai-service:latest"
    }
} else {
    Write-Info "Docker not available. Using ACR remote build flow (no local Docker required)."

    $remoteBuildError = $null
    try {
        Invoke-Checked -Description "Remote build webhook-service latest" -Command {
            az acr build --registry $acrName --image "webhook-service:latest" --image "webhook-service:$imageTag" ./webhook_service --output none
        }

        Invoke-Checked -Description "Remote build ai-service latest" -Command {
            az acr build --registry $acrName --image "ai-service:latest" --image "ai-service:$imageTag" ./ai_service --output none
        }
    } catch {
        $remoteBuildError = $_.Exception.Message
    }

    if ($remoteBuildError) {
        if ($remoteBuildError -match "TasksOperationsNotAllowed") {
            throw "ACR remote builds are blocked for this subscription (TasksOperationsNotAllowed). Options: 1) Start Docker Desktop and rerun for local build/push, 2) Rerun with -SkipImageBuild if ':latest' images already exist in ACR, 3) Open Azure support to enable ACR Tasks for this subscription."
        }
        throw $remoteBuildError
    }
}

Write-Step "Creating namespace and Kubernetes secrets"
Invoke-Checked -Description "Apply namespace" -Command {
    kubectl apply -f k8s/production/namespace.yaml
}

Invoke-Checked -Description "Create/update ai-service secret" -Command {
    kubectl create secret generic ai-service-secrets --from-literal=DEEPSEEK_API_KEY="$deepSeekApiKey" -n $Namespace --dry-run=client -o yaml | kubectl apply -f -
}

Invoke-Checked -Description "Create/update webhook-service secret" -Command {
    kubectl create secret generic webhook-service-secrets --from-literal=GITHUB_TOKEN="$githubToken" --from-literal=GITHUB_WEBHOOK_SECRET="$githubWebhookSecret" -n $Namespace --dry-run=client -o yaml | kubectl apply -f -
}

Write-Step "Deploying application manifests"
Invoke-Checked -Description "Apply ai-service manifest" -Command {
    kubectl apply -f k8s/production/ai-deployment.yaml
}
Invoke-Checked -Description "Apply webhook-service manifest" -Command {
    kubectl apply -f k8s/production/webhook-deployment.yaml
}

Invoke-Checked -Description "Update ai-service image to ACR" -Command {
    kubectl set image deployment/ai-service ai-service="$acrServer/ai-service:latest" -n $Namespace
}
Invoke-Checked -Description "Update webhook-service image to ACR" -Command {
    kubectl set image deployment/webhook-service webhook-service="$acrServer/webhook-service:latest" -n $Namespace
}

Invoke-Checked -Description "Wait for ai-service rollout" -Command {
    kubectl rollout status deployment/ai-service -n $Namespace --timeout=300s
}
Invoke-Checked -Description "Wait for webhook-service rollout" -Command {
    kubectl rollout status deployment/webhook-service -n $Namespace --timeout=300s
}

Write-Step "Resolving webhook URL"
if ($SkipWebhook) {
    Write-Info "Skipping GitHub webhook setup as requested (-SkipWebhook)."
} else {
    $webhookUrl = Get-WebhookUrl -EnvMap $envMap -Namespace $Namespace -AllowHttp:$ForceHttpWebhook
    Write-Info "Webhook URL: $webhookUrl"

    Write-Step "Configuring GitHub webhook"
    Upsert-GitHubWebhook -Owner $repoOwner -Repo $repoName -GitHubToken $githubToken -WebhookUrl $webhookUrl -Secret $githubWebhookSecret
}

Write-Step "Deployment summary"
Write-Success "Production bootstrap completed successfully"
Write-Host ""
Write-Host "Next checks:" -ForegroundColor Yellow
Write-Host "1) kubectl get pods -n $Namespace"
Write-Host "2) kubectl logs -l app=webhook-service -n $Namespace --tail=50"
Write-Host "3) Push code to GitHub and verify .github/workflows/ci-cd.yml is updated"
