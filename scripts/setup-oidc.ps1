# Secrets-free CI/CD with GitHub OIDC
# How the GitHub Actions workflows in this repo authenticate to Azure without a
# single stored credential. Run once per repository.

$ErrorActionPreference = 'Stop'

$appName       = 'gh-azure-self-healing-webapp'
$repo          = 'priyanshu-dhaliwal/azure-self-healing-webapp'
$subscription  = (az account show --query id -o tsv)
$tenant        = (az account show --query tenantId -o tsv)
$rg            = 'rg-dev-selfhealing-dev01'

Write-Host "==> Creating app registration: $appName"
$appId = az ad app create --display-name $appName --query appId -o tsv

Write-Host "==> Creating service principal"
$spId = az ad sp create --id $appId --query id -o tsv

Write-Host "==> Adding federated credential (main branch pushes)"
$fic = @{
    name        = "github-main"
    issuer      = "https://token.actions.githubusercontent.com"
    subject     = "repo:${repo}:ref:refs/heads/main"
    description = "GitHub Actions on main"
    audiences   = @("api://AzureADTokenExchange")
} | ConvertTo-Json

$fic | Out-File -FilePath "$env:TEMP\fic.json" -Encoding utf8
az ad app federated-credential create --id $appId --parameters "$env:TEMP\fic.json"

Write-Host "==> Adding federated credential (pull requests, what-if only)"
$ficPr = @{
    name  = "github-pr"
    issuer = "https://token.actions.githubusercontent.com"
    subject = "repo:${repo}:pull_request"
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json
$ficPr | Out-File -FilePath "$env:TEMP\ficpr.json" -Encoding utf8
az ad app federated-credential create --id $appId --parameters "$env:TEMP\ficpr.json"

Write-Host "==> Granting Contributor on the resource group (NOT the subscription)"
az role assignment create --assignee $spId --role Contributor `
    --scope "/subscriptions/$subscription/resourceGroups/$rg"

Write-Host "==> Granting User Access Administrator on the RG (needed for the runbook role assignments)"
az role assignment create --assignee $spId --role "User Access Administrator" `
    --scope "/subscriptions/$subscription/resourceGroups/$rg"

Write-Host ""
Write-Host "Set these as GitHub repository VARIABLES (not secrets — they are not sensitive):"
Write-Host "  AZURE_CLIENT_ID       = $appId"
Write-Host "  AZURE_TENANT_ID       = $tenant"
Write-Host "  AZURE_SUBSCRIPTION_ID = $subscription"
Write-Host ""
Write-Host "Because these are OIDC, there is NO client secret to rotate or leak."
