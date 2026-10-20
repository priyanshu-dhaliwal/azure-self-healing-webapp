# Heal-RestartVmss.ps1
# ---------------------------------------------------------------------------
# Cheap-first remediation: restart an unhealthy VMSS instance and verify.
# Used for "host is fine, agent/app is wedged" alerts, where a reimage is
# overkill and slow. Escalates to reimage by *failing*, which the
# healing-failed alert rule then catches.
# ---------------------------------------------------------------------------
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$VmssName,
    [Parameter(Mandatory = $true)][string]$InstanceId,
    [string]$WorkspaceId,
    [int]$HealthTimeoutSeconds = 180,
    [string]$Trigger = 'unknown'
)

$ErrorActionPreference = 'Stop'
$started = Get-Date
$runbookId = [guid]::NewGuid().ToString()
$outcome = 'failed'
$detail = ''

function Write-Audit {
    param([string]$Action, [string]$Outcome, [string]$Detail)
    Write-Output "AUDIT action=$Action outcome=$Outcome detail=$Detail instance=$InstanceId runbook=$runbookId"
    # Same Data Collector contract as Heal-ReimageInstance; kept inline so each
    # runbook is independently deployable.
    if (-not $WorkspaceId) { return }
    try {
        $ctx = Get-AzContext
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        $payload = @{
            InstanceId_s = $InstanceId; Action_s = $Action; Outcome_s = $Outcome
            Trigger_s = $Trigger; DurationSeconds_d = $elapsed
            RunbookId_s = $runbookId; Detail_s = $Detail
        } | ConvertTo-Json -Compress
        $token = (Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.io').Token
        $sig = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $rfc1123 = [DateTime]::UtcNow.ToString('r')
        $stringToHash = "POST`n$($sig.Length)`napplication/json`nx-ms-date:$rfc1123`n/api/logs"
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = [Convert]::FromBase64String($token)
        $signature = [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToHash)))
        Invoke-RestMethod -Method POST -Uri 'https://api.loganalytics.io/api/logs' `
            -Headers @{ Authorization = "SharedKey $($ctx.Account.Id):$signature"; 'Log-Type' = 'HealingAudit'; 'x-ms-date' = $rfc1123 } `
            -ContentType 'application/json' -Body $payload | Out-Null
    }
    catch { Write-Warning "Audit write failed: $_" }
}

Write-Output "restart runbook=$runbookId instance=$InstanceId"

try {
    $vm = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $VmssName -InstanceId $InstanceId
    Write-Output "Restarting $($vm.Name) ..."
    Restart-AzVmss -ResourceGroupName $ResourceGroupName -VMScaleSetName $VmssName `
        -InstanceId $InstanceId | Out-Null

    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $status = (Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $VmssName `
            -InstanceId $InstanceId -InstanceView).Statuses | Where-Object { $_.Code -like 'ProvisioningState/*' }
        if ($status.Code -eq 'ProvisioningState/succeeded') { $ok = $true; break }
    }

    if ($ok) {
        $outcome = 'healed'
        $detail = "restarted and healthy after $([int]((Get-Date) - $started).TotalSeconds)s"
    }
    else {
        $outcome = 'timeout'
        $detail = "restart did not restore health in ${HealthTimeoutSeconds}s — escalate to reimage"
    }
}
catch {
    $outcome = 'failed'; $detail = $_.Exception.Message
}
finally {
    Write-Audit -Action 'restart' -Outcome $outcome -Detail $detail
}

if ($outcome -ne 'healed') { throw "Restart healing outcome: $outcome — $detail" }
