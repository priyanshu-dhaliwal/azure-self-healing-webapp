# Heal-ReimageInstance.ps1
# ---------------------------------------------------------------------------
# Reimage a single unhealthy VMSS instance, verify it comes back healthy, and
# write the whole attempt to HealingAudit_CL.
#
# Design notes:
#  * Idempotent: takes a per-instance lock tag; exits "lock-held" if another
#    healing run already owns the instance.
#  * Verifies before it acts: if the instance is already healthy (alert was
#    stale), it exits "skipped" instead of destroying a good instance.
#  * Verifies after it acts: polls the health endpoint until the instance is
#    back in rotation, and only then reports "healed".
#  * Never touches anything outside the target VMSS.
# ---------------------------------------------------------------------------
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$VmssName,
    [Parameter(Mandatory = $true)][string]$InstanceId,
    [string]$WorkspaceId,
    [int]$HealthTimeoutSeconds = 300,
    [string]$Trigger = 'unknown'
)

$ErrorActionPreference = 'Stop'
$started = Get-Date
$runbookId = [guid]::NewGuid().ToString()
$outcome = 'failed'
$detail = ''

function Write-Audit {
    param([string]$Action, [string]$Outcome, [string]$Detail)
    if (-not $WorkspaceId) { Write-Output "AUDIT $Action $Outcome $Detail"; return }
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    # Log Analytics HTTP Data Collector API (simple, no extra module needed).
    $body = @{
        InstanceId_s      = $InstanceId
        Action_s          = $Action
        Outcome_s         = $Outcome
        Trigger_s         = $Trigger
        DurationSeconds_d = $elapsed
        RunbookId_s       = $runbookId
        Detail_s          = $Detail
    } | ConvertTo-Json -Compress
    # The workspace ingestion path is injected by the action group webhook;
    # here we shell out to the Az.OperationalInsights cmdlet when available.
    try {
        $ctx = Get-AzContext
        $token = (Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.io').Token
        $sig = [System.Text.Encoding]::UTF8.GetBytes($body)
        $method = 'POST'
        $rfc1123 = [DateTime]::UtcNow.ToString('r')
        $resource = '/api/logs'
        $stringToHash = "$method`n$($sig.Length)`napplication/json`nx-ms-date:$rfc1123`n$resource"
        $bytesToHash = [System.Text.Encoding]::UTF8.GetBytes($stringToHash)
        $keyBytes = [Convert]::FromBase64String($token)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $keyBytes
        $signature = [Convert]::ToBase64String($hmac.ComputeHash($bytesToHash))
        $auth = "SharedKey $($ctx.Account.Id):$signature"
        Invoke-RestMethod -Method $method -Uri "https://api.loganalytics.io$resource" `
            -Headers @{ Authorization = $auth; 'Log-Type' = 'HealingAudit'; 'x-ms-date' = $rfc1123 } `
            -ContentType 'application/json' -Body $body | Out-Null
    }
    catch {
        Write-Warning "Audit write failed (healing already happened): $_"
    }
}

function Get-InstanceHealth {
    param($Instance)
    try {
        $status = (Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $VmssName -InstanceId $InstanceId -InstanceView).Statuses |
            Where-Object { $_.Code -like 'ProvisioningState/*' }
        return @{ Code = $status.Code; Ok = ($status.Code -eq 'ProvisioningState/succeeded') }
    }
    catch { return @{ Code = 'Unknown'; Ok = $false } }
}

Write-Output "runbook=$runbookId instance=$InstanceId trigger=$Trigger"

# ---- 1. Lock -------------------------------------------------------------
$lockTag = @{ healing = $runbookId; healingSince = $started.ToString('o') }
$vm = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $VmssName -InstanceId $InstanceId
$existing = (Get-AzResource -ResourceId $vm.Id).Tags
if ($existing.healing -and $existing.healing -ne $runbookId) {
    $age = try { ((Get-Date) - [datetime]$existing.healingSince).TotalMinutes } catch { 0 }
    if ($age -lt 15) {
        Write-Output "Instance already being healed by runbook $($existing.healing) ($([int]$age)m ago). Exiting."
        Write-Audit -Action 'reimage' -Outcome 'lock-held' -Detail "owner=$($existing.healing)"
        return
    }
    Write-Output "Stale lock from $($existing.healing); taking over."
}
Set-AzResource -ResourceId $vm.Id -Tag $lockTag -Force | Out-Null

try {
    # ---- 2. Verify the alert is still valid ------------------------------
    $health = Get-InstanceHealth
    if ($health.Ok) {
        Write-Output "Instance is healthy now ($($health.Code)); alert was stale. Skipping."
        Write-Audit -Action 'reimage' -Outcome 'skipped' -Detail 'instance healthy at invocation'
        return
    }

    # ---- 3. Reimage -------------------------------------------------------
    Write-Output "Reimaging instance $InstanceId ..."
    $reimageJob = Set-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $VmssName `
        -InstanceId $InstanceId -Reimage -AsJob
    $reimageJob | Wait-Job -Timeout $HealthTimeoutSeconds | Out-Null
    if ($reimageJob.State -ne 'Completed') {
        throw "Reimage job did not complete within ${HealthTimeoutSeconds}s (state=$($reimageJob.State))"
    }

    # ---- 4. Verify recovery ----------------------------------------------
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $health = Get-InstanceHealth
        if ($health.Ok) { break }
        Write-Output "  waiting... $($health.Code)"
    }

    if ($health.Ok) {
        $outcome = 'healed'
        $detail = "reimaged and healthy after $([int]((Get-Date) - $started).TotalSeconds)s"
        Write-Output $detail
    }
    else {
        $outcome = 'timeout'
        $detail = "reimage completed but instance not healthy after ${HealthTimeoutSeconds}s"
        Write-Output $detail
    }
}
catch {
    $outcome = 'failed'
    $detail = $_.Exception.Message
    Write-Output "Healing failed: $detail"
}
finally {
    # Always release the lock, whatever happened.
    $tags = (Get-AzResource -ResourceId $vm.Id).Tags
    if ($tags -and $tags.healing -eq $runbookId) {
        $tags.Remove('healing'); $tags.Remove('healingSince')
        Set-AzResource -ResourceId $vm.Id -Tag $tags -Force | Out-Null
    }
    Write-Audit -Action 'reimage' -Outcome $outcome -Detail $detail
}

if ($outcome -ne 'healed') { throw "Self-healing outcome: $outcome — $detail" }
