#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param([string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'MonitorControlStreamDeck\logs'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# Dot-sourcing loads definitions only. No native getter or setter runs here.
. (Join-Path $PSScriptRoot 'Set-Monitor.ps1')
$logFile = Join-Path $LogDirectory 'monitor-actions.log'

function Get-WorkerFailureMessage($Record) {
    if ($Record.Exception.Message -match 'restored|RESTORATION FAILED') {
        return $Record.Exception.Message
    }
    return $Record.Exception.GetBaseException().Message
}

function Invoke-WorkerRequest {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param($Request)
    if ($null -eq $Request -or $Request.id -isnot [string] -or $Request.id.Length -gt 128) {
        throw 'Request must have a string id.'
    }
    $operations = @('status', 'rates', 'validateRate', 'apply')
    if ($Request.op -notin $operations) {
        throw 'Unknown worker operation.'
    }
    $selector = @{}
    if ($Request.op -in @('rates', 'apply')) {
        foreach ($key in @('monitorName', 'monitorId')) {
            if ($null -ne $Request.$key) {
                $value = $Request.$key
                if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 512 -or $value -match '[\x00-\x1f]') {
                    throw 'Invalid monitor selector.'
                }
                $selector[$key] = $value
            }
        }
        if ($selector.Count -ne 1) {
            throw 'Select exactly one monitor name or device ID.'
        }
    }
    if ($Request.op -eq 'apply') {
        if ($Request.hdr -notin @($null, 'On', 'Off')) {
            throw 'HDR must be On, Off, or omitted.'
        }
        if ($Request.colorRange -notin @('Full', 'Limited', 'Keep')) {
            throw 'Range must be Full, Limited, or Keep.'
        }
        if (!$Request.hdr -and !$Request.refreshRate -and $Request.colorRange -eq 'Keep') {
            throw 'Preset requests no changes.'
        }
    }
    Initialize-MonitorInterop
    if ([Environment]::OSVersion.Version.Build -lt 22000) {
        throw 'Monitor Control requires Windows 11.'
    }
    switch ($Request.op) {
        'validateRate' {
            $rate = [MonitorControl.Rate]::Parse([string]$Request.refreshRate)
            @{ fraction = $rate.Numerator.ToString() + '/' + $rate.Denominator.ToString(); hz = $rate.Hz }
        }
        'status' {
            Invoke-MonitorCommand -Arguments @{ ListMonitors = $true } -Caller $PSCmdlet
        }
        'rates' {
            $selector.ListRefreshRates = $true; Invoke-MonitorCommand -Arguments $selector -Caller $PSCmdlet
        }
        'apply' {
            $arguments = $selector
            $arguments.ColorRange = [string]$Request.colorRange
            $arguments.LogPath = $logFile
            if ($Request.hdr) {
                $arguments.Hdr = [string]$Request.hdr
            }
            if ($Request.refreshRate) {
                $arguments.RefreshRate = [string]$Request.refreshRate
            }
            Invoke-MonitorCommand -Arguments $arguments -Caller $PSCmdlet
        }
    }
}

# All stdout is protocol JSON. Capture warnings, even when an apply throws;
# diagnostics are written by the existing handler directly to its log file.
if ($MyInvocation.InvocationName -eq '.') {
    return
}
while ($null -ne ($line = [Console]::ReadLine())) {
    $request = $null
    $warnings = [Collections.Generic.List[string]]::new()
    try {
        if ($line.Length -gt 1048576) {
            throw 'Request is too large.'
        }
        $request = ConvertFrom-Json -InputObject $line
        $data = [Collections.Generic.List[object]]::new()
        Invoke-WorkerRequest $request -Confirm:$false 3>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.WarningRecord]) {
                $warnings.Add($_.Message)
            }
            else {
                $data.Add($_)
            }
        }
        $result = $null
        if ($request.op -in @('status', 'rates')) {
            $result = $data.ToArray()
        }
        elseif ($data.Count) {
            $result = $data[0]
        }
        $response = @{ id = $request.id; ok = $true; result = $result; warnings = @($warnings.ToArray()) }
    }
    catch {
        $message = Get-WorkerFailureMessage $_
        try {
            Write-MonitorLog $logFile 'ERROR' $message
        }
        catch {
        }
        $response = @{ id = $request.id; ok = $false; error = $message; warnings = @($warnings.ToArray()) }
    }
    [Console]::WriteLine((ConvertTo-Json -InputObject $response -Depth 16 -Compress))
}
