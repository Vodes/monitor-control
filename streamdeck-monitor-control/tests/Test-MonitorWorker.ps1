#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$workerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'pw.vodes.monitorcontrol.sdPlugin\worker\MonitorWorker.ps1'
. $workerPath -LogDirectory (Join-Path $PSScriptRoot '.logs')
Initialize-MonitorInterop
$script:capturedArguments = $null
$script:simulateFailure = $false
function Invoke-MonitorCommand {
    param($Arguments, $Caller)
    if (-not $Caller.ShouldProcess('Fake monitor', 'Fake apply')) { throw 'Unexpected WhatIf.' }
    $script:capturedArguments = $Arguments
    Write-Warning 'Fake depth fallback warning.'
    if ($script:simulateFailure) { throw 'RESTORATION FAILED: fake driver failure.' }
    [pscustomobject]@{ MonitorId = $Arguments.MonitorId; HdrEnabled = $Arguments.Hdr -eq 'On'; BitsPerColorChannel = 8 }
}
$request = [pscustomobject]@{ id = '1'; op = 'apply'; monitorId = 'id with spaces'; hdr = 'On'; refreshRate = '60000/1001'; colorRange = 'Full' }
$items = @(Invoke-WorkerRequest $request -Confirm:$false 3>&1)
if ($script:capturedArguments.RefreshRate -ne '60000/1001' -or $script:capturedArguments.Hdr -ne 'On' -or $script:capturedArguments.ColorRange -ne 'Full') { throw 'Apply did not bind script parameters correctly.' }
if ($items[0] -isnot [Management.Automation.WarningRecord] -or $items[1].BitsPerColorChannel -ne 8) { throw 'Warning/status records were not preserved.' }
$script:simulateFailure = $true
try { Invoke-WorkerRequest $request -Confirm:$false 3>&1 | Out-Null; throw 'Failure was not propagated.' }
catch { if ((Get-WorkerFailureMessage $_) -notmatch 'RESTORATION FAILED') { throw } }
$script:simulateFailure = $false
Invoke-WorkerRequest ([pscustomobject]@{ id = 'name'; op = 'apply'; monitorName = 'Panel'; hdr = 'Off'; colorRange = 'Keep' }) -Confirm:$false 3>&1 | Out-Null
if ($script:capturedArguments.MonitorName -ne 'Panel' -or $script:capturedArguments.ContainsKey('MonitorId')) { throw 'Name selector was not preserved for native resolution.' }
Invoke-WorkerRequest ([pscustomobject]@{ id = 'rates-name'; op = 'rates'; monitorName = 'Panel' }) -Confirm:$false 3>&1 | Out-Null
if ($script:capturedArguments.MonitorName -ne 'Panel' -or !$script:capturedArguments.ListRefreshRates) { throw 'Name rate query binding failed.' }
foreach ($bad in @(
    [pscustomobject]@{ id = 'mixed'; op = 'rates'; monitorName = 'Panel'; monitorId = 'id' },
    [pscustomobject]@{ id = 'missing'; op = 'rates' },
    [pscustomobject]@{ id = 'invalid'; op = 'rates'; monitorName = 42 },
    [pscustomobject]@{ id = '2'; op = 'exec' },
    [pscustomobject]@{ id = '3'; op = 'apply'; monitorId = 'id'; hdr = 'Invalid'; colorRange = 'Full' },
    [pscustomobject]@{ id = '4'; op = 'apply'; monitorId = 'id'; colorRange = 'Keep' }
)) {
    $script:capturedArguments = $null
    try { Invoke-WorkerRequest $bad | Out-Null; throw 'Invalid input accepted.' }
    catch { if ($_.Exception.Message -eq 'Invalid input accepted.') { throw } }
    if ($script:capturedArguments) { throw 'Invalid input reached fake command handler.' }
}
Write-Output 'PASS: worker apply parameter binding, warning/status separation, restoration report, and invalid-operation/no-op rejection. Only a fake command handler was called.'
