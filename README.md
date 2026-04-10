# DMD Cloud

DMD Cloud receives GitHub push webhooks, sends code diffs to DeepSeek, and generates a CI workflow file automatically.

## What End Users Need

- Push code to GitHub.
- DMD updates `.github/workflows/ci-cd.yml` from your latest diff.

## Repository Contents

- `webhook_service/`: Receives webhook events and coordinates generation.
- `ai_service/`: Calls DeepSeek and returns workflow YAML.
- `k8s/production/`: Kubernetes manifests for production deployment.
- `bootstrap-azure-production.ps1`: End-to-end production bootstrap on Azure.
- `action.yml`: Reusable GitHub Action for production deploy workflows.

## Quick Start (Azure Production)

### 1. Prerequisites

- PowerShell
- `az`, `kubectl`, `git`
- Azure access to create/use RG, ACR, and AKS
- DeepSeek API key
- GitHub token with webhook management permissions

### 2. Create `.env` in repo root

```dotenv
DEEPSEEK_API_KEY=sk-your-deepseek-key
SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000
GITHUB_TOKEN=ghp_or_fine_grained_pat
GITHUB_WEBHOOK_SECRET=replace-with-random-secret

# Optional
AZURE_RESOURCE_GROUP=dmd-prod-rg
ACR_NAME=dmdacrprod
AKS_CLUSTER_NAME=dmd-aks-prod
GITHUB_REPO_OWNER=taoufikmohamed
GITHUB_REPO_NAME=diff-dmd-prod
WEBHOOK_DOMAIN=webhook.example.com
# WEBHOOK_URL=https://webhook.example.com/webhook/github
```

### 3. Bootstrap infrastructure and deploy

```powershell
az login
.\bootstrap-azure-production.ps1 -EnvFile .env -Environment prod -Location westeurope
```

### 4. Verify

```powershell
kubectl get pods -n dmd-production
kubectl logs -l app=webhook-service -n dmd-production --tail=50
kubectl logs -l app=ai-service -n dmd-production --tail=50
```

## Safe First Run (Recommended)

Run once without webhook registration:

```powershell
.\bootstrap-azure-production.ps1 -EnvFile .env -Environment prod -Location westeurope -SkipWebhook
```

After services are healthy, set `WEBHOOK_DOMAIN` or `WEBHOOK_URL` in `.env` and rerun without `-SkipWebhook`.

## Trigger Flow

1. Push code to your repo.
2. GitHub sends push webhook to DMD.
3. DMD generates/updates `.github/workflows/ci-cd.yml`.

## Use as a GitHub Action

Example workflow usage:

```yaml
name: Deploy DMD via Marketplace Action

on:
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - name: Azure login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Deploy DMD Cloud
        uses: taoufikmohamed/diff-dmd-prod@v1
        with:
          deepseek_api_key: ${{ secrets.DEEPSEEK_API_KEY }}
          azure_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          environment: prod
          location: westeurope
```

## Publish to GitHub Marketplace

1. Ensure repository is public and contains `action.yml`.
2. Create and push a version tag:

```bash
git tag -a v1.0.0 -m "Marketplace release"
git push origin v1.0.0
```

3. Confirm release workflow runs: `.github/workflows/publish-action.yml`.
4. In GitHub Releases, verify the release exists.
5. Publish listing in GitHub Marketplace.
6. Keep major tag updated:

```bash
git tag -f v1
git push origin v1 --force
```

## Troubleshooting

- Missing tools: install `az`, `kubectl`, and `git`.
- Webhook rejected: use HTTPS URL (`WEBHOOK_DOMAIN` or `WEBHOOK_URL`).
- If you intentionally want to use HTTP from the AKS LoadBalancer IP, run:

```powershell
.\bootstrap-azure-production.ps1 -EnvFile .env -SkipImageBuild -ForceHttpWebhook
```

- GitHub auth errors: regenerate token and ensure webhook permissions.
- Image build issues:
  - If Docker is running, script uses local build/push.
  - If Docker is unavailable, script uses `az acr build`.
  - Use `-SkipImageBuild` only when `:latest` images already exist in ACR.

## Security Notes

- Do not commit `.env`.
- Keep keys and tokens in secure secret stores in CI/CD.
- Rotate `GITHUB_WEBHOOK_SECRET` and tokens regularly.
