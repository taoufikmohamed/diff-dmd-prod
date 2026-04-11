# Production Deployment Script
# This script automates the deployment of DMD Cloud to Azure AKS

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DeepSeekApiKey,
    
    [Parameter(Mandatory=$false)]
    [string]$AzureSubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$Environment = "prod",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "WESTEUROPE"
)

$ErrorActionPreference = "Stop"

Write-Host "=== DMD Cloud Production Deployment ===" -ForegroundColor Cyan
Write-Host "Environment: $Environment" -ForegroundColor Yellow
Write-Host "Location: $Location" -ForegroundColor Yellow

# Phase 1: Verify Prerequisites
Write-Host "`n[Phase 1] Verifying Prerequisites..." -ForegroundColor Green

$tools = @("az", "kubectl", "docker", "helm")
foreach ($tool in $tools) {
    if (!(Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool is not installed. Please install it first."
        exit 1
    }
    Write-Host "  ✓ $tool found" -ForegroundColor Gray
}

# Phase 2: Azure Login and Setup
Write-Host "`n[Phase 2] Azure Authentication..." -ForegroundColor Green

if ($AzureSubscriptionId) {
    az account set --subscription $AzureSubscriptionId
}

$currentAccount = az account show | ConvertFrom-Json
Write-Host "  Using subscription: $($currentAccount.name)" -ForegroundColor Gray

# Phase 3: Provision Core Infrastructure (RG -> ACR -> AKS)
Write-Host "`n[Phase 3] Provisioning Core Infrastructure (RG -> ACR -> AKS)..." -ForegroundColor Green

$rgName = "dmd-$Environment-rg"
$acrName = "dmdacr$Environment"
$aksName = "dmd-aks-$Environment"
$preferredAksVmSizes = @("Standard_B2s")
$effectiveLocation = $Location.ToLower()

function Ensure-AksAcrPullAccess {
    param(
        [Parameter(Mandatory = $true)][string]$AksName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AcrName
    )

    Write-Host "  Ensuring AKS can pull from ACR..." -ForegroundColor Gray

    $attachOutput = az aks update --name $AksName --resource-group $ResourceGroupName --attach-acr $AcrName --output none 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ AKS attached to ACR via az aks update" -ForegroundColor Green
        return $true
    }

    Write-Host "  Unable to attach ACR using az aks update. Trying direct AcrPull role assignment..." -ForegroundColor Yellow

    $acrId = az acr show --name $AcrName --resource-group $ResourceGroupName --query "id" -o tsv 2>$null
    $kubeletObjectId = az aks show --name $AksName --resource-group $ResourceGroupName --query "identityProfile.kubeletidentity.objectId" -o tsv 2>$null

    if (!$acrId -or !$kubeletObjectId) {
        Write-Host "  Warning: Could not determine ACR resource ID or AKS kubelet identity object ID." -ForegroundColor Yellow
        Write-Host "  Deployment continues, but image pulls may fail until AcrPull is granted." -ForegroundColor Yellow
        return $false
    }

    $existingAssignmentCount = az role assignment list --assignee-object-id $kubeletObjectId --scope $acrId --query "[?roleDefinitionName=='AcrPull'] | length(@)" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and [int]$existingAssignmentCount -gt 0) {
        Write-Host "  ✓ AcrPull role assignment already exists for AKS kubelet identity" -ForegroundColor Green
        return $true
    }

    $roleOutput = az role assignment create --assignee-object-id $kubeletObjectId --assignee-principal-type ServicePrincipal --role AcrPull --scope $acrId --output none 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Granted AcrPull role on ACR to AKS kubelet identity" -ForegroundColor Green
        return $true
    }

    Write-Host "  Warning: Failed to grant AcrPull role automatically." -ForegroundColor Yellow
    Write-Host "  Required privileges: Owner or User Access Administrator on scope '$acrId'." -ForegroundColor Yellow
    Write-Host "  AKS may fail to pull images until this role assignment is completed." -ForegroundColor Yellow
    return $false
}

function Test-ArmActionAllowed {
    param(
        [Parameter(Mandatory = $true)][string[]]$Actions,
        [Parameter(Mandatory = $false)][string[]]$NotActions,
        [Parameter(Mandatory = $true)][string]$TargetAction
    )

    $normalizedActions = @($Actions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($normalizedActions.Count -eq 0) {
        return $false
    }

    $isAllowed = $false
    foreach ($actionPattern in $normalizedActions) {
        if ($TargetAction -like $actionPattern) {
            $isAllowed = $true
            break
        }
    }

    if (-not $isAllowed) {
        return $false
    }

    foreach ($denyPattern in @($NotActions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($TargetAction -like $denyPattern) {
            return $false
        }
    }

    return $true
}

function Assert-AksWritePermissionPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AksName,
        [Parameter(Mandatory = $true)][string]$PrincipalIdentifier
    )

    $requiredAction = "Microsoft.ContainerService/managedClusters/write"
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

    Write-Host "  RBAC preflight: checking '$requiredAction' on '$scope' for '$PrincipalIdentifier'..." -ForegroundColor Gray

    $roleNamesJson = az role assignment list --assignee $PrincipalIdentifier --scope $scope --include-inherited --query "[].roleDefinitionName" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($roleNamesJson)) {
        throw "RBAC preflight failed: could not read role assignments for '$PrincipalIdentifier' at '$scope'. Ensure this identity can read role assignments and is in the correct subscription context."
    }

    $roleNames = @($roleNamesJson | ConvertFrom-Json | Select-Object -Unique)
    if ($roleNames.Count -eq 0) {
        throw "RBAC preflight failed: '$PrincipalIdentifier' has no role assignments at '$scope'. Required action: '$requiredAction'. Grant 'Azure Kubernetes Service Contributor' (recommended) or 'Contributor' on resource group '$ResourceGroupName', then re-authenticate and rerun."
    }

    $canWriteAks = $false
    foreach ($roleName in $roleNames) {
        $roleDefsJson = az role definition list --name $roleName -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($roleDefsJson)) {
            continue
        }

        $roleDefs = @($roleDefsJson | ConvertFrom-Json)
        foreach ($roleDef in $roleDefs) {
            foreach ($permissionBlock in @($roleDef.permissions)) {
                if (Test-ArmActionAllowed -Actions @($permissionBlock.actions) -NotActions @($permissionBlock.notActions) -TargetAction $requiredAction) {
                    $canWriteAks = $true
                    break
                }
            }

            if ($canWriteAks) {
                break
            }
        }

        if ($canWriteAks) {
            break
        }
    }

    if (-not $canWriteAks) {
        $assignedRoles = ($roleNames -join ", ")
        throw "RBAC preflight failed before AKS create. Identity '$PrincipalIdentifier' does not allow '$requiredAction' at '$scope'. Current roles: [$assignedRoles]. Fix: assign 'Azure Kubernetes Service Contributor' on resource group '$ResourceGroupName' (or equivalent custom role containing '$requiredAction'). If you use '--attach-acr', also grant 'User Access Administrator' or 'Owner' at the ACR scope for role-assignment operations. Then refresh credentials and rerun. AKS target: '$AksName'."
    }

    Write-Host "  ✓ RBAC preflight passed for AKS write" -ForegroundColor Green
}

# 3.1 Create Resource Group first
Write-Host "  Ensuring resource group exists: $rgName" -ForegroundColor Gray
$existingRgLocation = az group show --name $rgName --query "location" -o tsv 2>$null

if ($LASTEXITCODE -eq 0 -and $existingRgLocation) {
    $effectiveLocation = $existingRgLocation.ToLower()
    if ($effectiveLocation -ne $Location.ToLower()) {
        Write-Host "  Resource group already exists in '$effectiveLocation'. Using that location instead of requested '$Location'." -ForegroundColor Yellow
    } else {
        Write-Host "  Resource group already exists in '$effectiveLocation'." -ForegroundColor Gray
    }
} else {
    az group create --name $rgName --location $effectiveLocation --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create resource group '$rgName' in location '$effectiveLocation'."
    }
}

# 3.2 Create Container Registry second
$acrExists = az acr show --name $acrName --resource-group $rgName --query "name" -o tsv 2>$null
if (!$acrExists) {
    Write-Host "  Creating Azure Container Registry: $acrName" -ForegroundColor Yellow
    az acr create --name $acrName --resource-group $rgName --location $effectiveLocation --sku Standard --admin-enabled false --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create ACR '$acrName' in resource group '$rgName'."
    }
} else {
    Write-Host "  ACR already exists: $acrName" -ForegroundColor Gray
}

$acrServer = az acr show --name $acrName --resource-group $rgName --query "loginServer" -o tsv

$principalIdentifier = $currentAccount.user.name
Assert-AksWritePermissionPreflight -SubscriptionId $currentAccount.id -ResourceGroupName $rgName -AksName $aksName -PrincipalIdentifier $principalIdentifier

# 3.3 Create AKS cluster third
$aksExists = az aks show --name $aksName --resource-group $rgName --query "name" -o tsv 2>$null
if (!$aksExists) {
    Write-Host "  Creating AKS cluster: $aksName" -ForegroundColor Yellow
    $aksCreated = $false
    $triedVmSizes = @()
    $allowedVmSizes = @()
    $lastAksCreateError = ""
    $aksNodeCount = if ($Environment -eq "prod") { 2 } else { 1 }

    function Invoke-AksCreate([string]$vmSize) {
        Write-Host "  Trying AKS VM size: $vmSize (node count: $aksNodeCount)" -ForegroundColor Gray
        $script:triedVmSizes += $vmSize
        $createOutput = az aks create `
            --name $aksName `
            --resource-group $rgName `
            --location $effectiveLocation `
            --node-count $aksNodeCount `
            --node-vm-size $vmSize `
            --enable-managed-identity `
            --attach-acr $acrName `
            --generate-ssh-keys `
            --output none 2>&1 | Out-String

        if ($LASTEXITCODE -ne 0 -and $createOutput -match "Could not create a role assignment for ACR|Are you an Owner on this subscription|AuthorizationFailed") {
            Write-Host "  AKS create failed while attaching ACR. Retrying AKS create without --attach-acr..." -ForegroundColor Yellow
            $createOutput = az aks create `
                --name $aksName `
                --resource-group $rgName `
                --location $effectiveLocation `
                --node-count $aksNodeCount `
                --node-vm-size $vmSize `
                --enable-managed-identity `
                --generate-ssh-keys `
                --output none 2>&1 | Out-String
        }

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  AKS cluster created using VM size: $vmSize" -ForegroundColor Green
            return @{ Success = $true; Output = $createOutput }
        }

        $allowedMatch = [regex]::Match($createOutput, "available VM sizes are '([^']+)'", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($allowedMatch.Success) {
            $parsedAllowed = $allowedMatch.Groups[1].Value.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            $script:allowedVmSizes = $parsedAllowed | Select-Object -Unique
        }

        return @{ Success = $false; Output = $createOutput }
    }

    foreach ($vmSize in $preferredAksVmSizes) {
        $result = Invoke-AksCreate -vmSize $vmSize
        if ($result.Success) {
            $aksCreated = $true
            break
        }

        $lastAksCreateError = $result.Output

        Write-Host "  VM size '$vmSize' is not available/allowed. Trying next option..." -ForegroundColor Yellow
    }

    if (!$aksCreated -and $allowedVmSizes.Count -gt 0) {
        Write-Host "  Retrying with VM sizes allowed by subscription/region..." -ForegroundColor Yellow
        $smallAllowedVmSizes = $allowedVmSizes |
            Where-Object {
                ($_ -match '^(?i)standard_(b|d2|d4|e2|e4|f2|f4)') -and
                ($_ -notmatch '^(?i)standard_(dc|ec|fx|hb|hc|hx|m|nc|nd|nv)')
            }

        if ($smallAllowedVmSizes.Count -eq 0) {
            $smallAllowedVmSizes = $allowedVmSizes | Where-Object { $_ -notmatch '^(?i)standard_(dc|ec|fx|hb|hc|hx|m|nc|nd|nv)' }
        }

        $retryVmSizes = $smallAllowedVmSizes | Where-Object { $triedVmSizes -notcontains $_ } | Select-Object -First 8

        if ($retryVmSizes.Count -eq 0) {
            $retryVmSizes = $allowedVmSizes | Where-Object { $triedVmSizes -notcontains $_ } | Select-Object -First 8
        }

        foreach ($vmSize in $retryVmSizes) {
            $result = Invoke-AksCreate -vmSize $vmSize
            if ($result.Success) {
                $aksCreated = $true
                break
            }
            $lastAksCreateError = $result.Output

            $quotaMatch = [regex]::Match($lastAksCreateError, 'left\s+regional\s+vcpu\s+quota\s+(\d+),\s+requested\s+quota\s+(\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($quotaMatch.Success -and $aksNodeCount -gt 1) {
                $aksNodeCount = 1
                Write-Host "  Quota is constrained. Retrying with node count 1..." -ForegroundColor Yellow
            }
        }
    }

    if (!$aksCreated) {
        throw "Failed to create AKS '$aksName'. Tried preferred and allowed fallback sizes in '$effectiveLocation'. Last error: $lastAksCreateError"
    }

    $acrAccessReady = Ensure-AksAcrPullAccess -AksName $aksName -ResourceGroupName $rgName -AcrName $acrName
    if (!$acrAccessReady) {
        Write-Host "  Continuing deployment without blocking on ACR role assignment." -ForegroundColor Yellow
    }
} else {
    Write-Host "  AKS already exists: $aksName" -ForegroundColor Gray
    $acrAccessReady = Ensure-AksAcrPullAccess -AksName $aksName -ResourceGroupName $rgName -AcrName $acrName
    if (!$acrAccessReady) {
        Write-Host "  Continuing deployment without blocking on ACR role assignment." -ForegroundColor Yellow
    }
}

Write-Host "  ✓ Core infrastructure provisioned successfully" -ForegroundColor Green
Write-Host "    - Resource Group: $rgName" -ForegroundColor Gray
Write-Host "    - ACR: $acrServer" -ForegroundColor Gray
Write-Host "    - AKS: $aksName" -ForegroundColor Gray

# Phase 4: Connect to AKS
Write-Host "`n[Phase 4] Connecting to AKS..." -ForegroundColor Green

az aks get-credentials --resource-group $rgName --name $aksName --overwrite-existing
if ($LASTEXITCODE -ne 0) {
    throw "Failed to get AKS credentials for '$aksName' in resource group '$rgName'."
}

kubectl config use-context $aksName
if ($LASTEXITCODE -ne 0) {
    throw "Failed to switch kubectl context to '$aksName'."
}

$nodes = kubectl get nodes --no-headers | Measure-Object
if ($LASTEXITCODE -ne 0) {
    throw "kubectl cannot reach AKS cluster '$aksName'."
}

Write-Host "  ✓ Connected to AKS ($($nodes.Count) nodes ready)" -ForegroundColor Green

# Phase 5: Build and Push Images
Write-Host "`n[Phase 5] Building and Pushing Docker Images..." -ForegroundColor Green

$repoRoot = (Get-Location).Path
$webhookServicePath = Join-Path $repoRoot "webhook_service"
$aiServicePath = Join-Path $repoRoot "ai_service"

$requiredBuildFiles = @(
    (Join-Path $webhookServicePath "Dockerfile"),
    (Join-Path $webhookServicePath "requirements.txt"),
    (Join-Path $webhookServicePath "main.py"),
    (Join-Path $aiServicePath "Dockerfile"),
    (Join-Path $aiServicePath "requirements.txt"),
    (Join-Path $aiServicePath "main.py")
)

foreach ($requiredFile in $requiredBuildFiles) {
    if (-not (Test-Path $requiredFile)) {
        throw "Missing required container build file: '$requiredFile'. If running via marketplace action tag (for example @v1), update the tag to include latest files."
    }
}

docker info *> $null
$dockerAvailable = ($LASTEXITCODE -eq 0)

if ($dockerAvailable) {
    az acr login --name $acrName
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to authenticate Docker to ACR '$acrName'. Ensure Docker Desktop is running."
    }

    Write-Host "  Building webhook-service..." -ForegroundColor Gray
    docker build -f (Join-Path $webhookServicePath "Dockerfile") -t "${acrServer}/webhook-service:latest" -t "${acrServer}/webhook-service:$(Get-Date -Format 'yyyyMMdd-HHmmss')" $webhookServicePath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build webhook-service image. Ensure Docker daemon is running."
    }

    docker push "${acrServer}/webhook-service:latest"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to push webhook-service image to ACR '$acrName'."
    }

    Write-Host "  Building ai-service..." -ForegroundColor Gray
    docker build -f (Join-Path $aiServicePath "Dockerfile") -t "${acrServer}/ai-service:latest" -t "${acrServer}/ai-service:$(Get-Date -Format 'yyyyMMdd-HHmmss')" $aiServicePath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build ai-service image. Ensure Docker daemon is running."
    }

    docker push "${acrServer}/ai-service:latest"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to push ai-service image to ACR '$acrName'."
    }
} else {
    Write-Host "  Docker daemon not available. Falling back to Azure Container Registry remote builds..." -ForegroundColor Yellow

    Write-Host "  Remote building webhook-service in ACR..." -ForegroundColor Gray
    az acr build --registry $acrName --image webhook-service:latest $webhookServicePath --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remotely build webhook-service image in ACR '$acrName'."
    }

    Write-Host "  Remote building ai-service in ACR..." -ForegroundColor Gray
    az acr build --registry $acrName --image ai-service:latest $aiServicePath --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remotely build ai-service image in ACR '$acrName'."
    }
}

Write-Host "  ✓ Images pushed to ACR" -ForegroundColor Green

# Phase 6: Update Kubernetes Manifests
Write-Host "`n[Phase 6] Updating Kubernetes Manifests..." -ForegroundColor Green

$manifestFiles = @(
    "k8s/production/webhook-deployment.yaml",
    "k8s/production/ai-deployment.yaml"
)

foreach ($file in $manifestFiles) {
    $content = Get-Content $file -Raw
    $content = $content -replace 'dmdacrprod\.azurecr\.io', $acrServer
    Set-Content $file -Value $content
    Write-Host "  ✓ Updated $file" -ForegroundColor Gray
}

# Phase 7: Deploy to Kubernetes
Write-Host "`n[Phase 7] Deploying to Kubernetes..." -ForegroundColor Green

# Create namespace
Write-Host "  Creating namespace..." -ForegroundColor Gray
kubectl apply -f k8s/production/namespace.yaml

# Create secrets
Write-Host "  Creating secrets..." -ForegroundColor Gray
kubectl create secret generic ai-service-secrets `
    --from-literal=DEEPSEEK_API_KEY="$DeepSeekApiKey" `
    --namespace=dmd-production `
    --dry-run=client -o yaml | kubectl apply -f -

# Deploy AI service first
Write-Host "  Deploying AI service..." -ForegroundColor Yellow
kubectl apply -f k8s/production/ai-deployment.yaml

Write-Host "  Waiting for AI service to be ready..." -ForegroundColor Gray
kubectl wait --for=condition=available --timeout=300s deployment/ai-service -n dmd-production

# Deploy webhook service
Write-Host "  Deploying webhook service..." -ForegroundColor Yellow
kubectl apply -f k8s/production/webhook-deployment.yaml

Write-Host "  Waiting for webhook service to be ready..." -ForegroundColor Gray
kubectl wait --for=condition=available --timeout=300s deployment/webhook-service -n dmd-production

Write-Host "  ✓ All services deployed" -ForegroundColor Green

# Phase 8: Setup Ingress
Write-Host "`n[Phase 8] Setting up Ingress..." -ForegroundColor Green

# Check if nginx-ingress is installed
$nginxInstalled = helm list -n ingress-nginx | Select-String "nginx-ingress"

if (!$nginxInstalled) {
    Write-Host "  Installing NGINX Ingress Controller..." -ForegroundColor Yellow
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    helm install nginx-ingress ingress-nginx/ingress-nginx `
        --namespace ingress-nginx `
        --create-namespace `
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz `
        --wait
}

# Check if cert-manager is installed
$certManagerInstalled = kubectl get namespace cert-manager -o jsonpath='{.metadata.name}' 2>$null

if (!$certManagerInstalled) {
    Write-Host "  Installing cert-manager..." -ForegroundColor Yellow
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
    Start-Sleep -Seconds 30
}

Write-Host "  ✓ Ingress controller ready" -ForegroundColor Green

# Phase 9: Get Status
Write-Host "`n[Phase 9] Deployment Status..." -ForegroundColor Green

Write-Host "`nPods:" -ForegroundColor Yellow
kubectl get pods -n dmd-production

Write-Host "`nServices:" -ForegroundColor Yellow
kubectl get svc -n dmd-production

Write-Host "`nHorizontal Pod Autoscalers:" -ForegroundColor Yellow
kubectl get hpa -n dmd-production

# Get external IP
Write-Host "`nGetting External IP address..." -ForegroundColor Yellow
$externalIP = $null
$maxRetries = 30

for ($i = 0; $i -lt $maxRetries; $i++) {
    $externalIP = kubectl get service webhook-service -n dmd-production -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
    if ($externalIP) {
        break
    }
    Write-Host "  Waiting for external IP... ($i/$maxRetries)" -ForegroundColor Gray
    Start-Sleep -Seconds 10
}

if ($externalIP) {
    Write-Host "`n✓ External IP: $externalIP" -ForegroundColor Green
} else {
    Write-Host "`n⚠ External IP not yet assigned. It may take a few more minutes." -ForegroundColor Yellow
}

# Phase 10: Final Instructions
Write-Host "`n=== DEPLOYMENT COMPLETE ===" -ForegroundColor Cyan

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Configure DNS A record pointing to: $externalIP"
Write-Host "2. Update domain in k8s/production/ingress.yaml"
Write-Host "3. Apply ingress: kubectl apply -f k8s/production/ingress.yaml"
Write-Host "4. Configure GitHub webhook to: https://your-domain.com/webhook/github"
Write-Host "5. Monitor logs: kubectl logs -f -l app=webhook-service -n dmd-production"

Write-Host "`nUseful Commands:" -ForegroundColor Yellow
Write-Host "  View logs:     kubectl logs -f -l app=webhook-service -n dmd-production"
Write-Host "  Get pods:      kubectl get pods -n dmd-production"
Write-Host "  Scale up:      kubectl scale deployment webhook-service --replicas=5 -n dmd-production"
Write-Host "  Get metrics:   kubectl top pods -n dmd-production"
Write-Host "  Port-forward:  kubectl port-forward svc/webhook-service 8001:8001 -n dmd-production"

Write-Host "`n✓ Production deployment successful!" -ForegroundColor Green
