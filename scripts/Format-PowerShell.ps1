#requires -Version 5.1
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$localModule = Join-Path $projectRoot '.tools\PSScriptAnalyzer\1.25.0\PSScriptAnalyzer.psd1'
if (Test-Path -LiteralPath $localModule) {
    Import-Module $localModule
}
else {
    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
}
$settings = Join-Path $projectRoot 'PSScriptAnalyzerSettings.psd1'

function Remove-TrailingWhitespace([string]$Text) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    $literals = @($tokens | Where-Object {
            $_.Kind -in @('StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable', 'Comment')
        })
    # PSScriptAnalyzer can leave spaces where a single-line block was expanded.
    # Remove these without stripping meaningful whitespace from literal strings.
    $spaces = [regex]::Matches($Text, '[ \t]+(?=\r?$)', [Text.RegularExpressions.RegexOptions]::Multiline)
    for ($index = $spaces.Count - 1; $index -ge 0; $index--) {
        $space = $spaces[$index]
        $insideLiteral = $false
        foreach ($literal in $literals) {
            if ($space.Index -ge $literal.Extent.StartOffset -and $space.Index -lt $literal.Extent.EndOffset) {
                $insideLiteral = $true
                break
            }
        }
        if (-not $insideLiteral) {
            $Text = $Text.Remove($space.Index, $space.Length)
        }
    }
    return $Text
}

function Get-CodeTokens([string]$Text) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) {
        throw "PowerShell parse error: $($parseErrors[0].Message)"
    }
    foreach ($token in $tokens) {
        if ($token.Kind -notin @('NewLine', 'LineContinuation', 'EndOfInput')) {
            # Compare literal contents too, including the embedded C# here-strings.
            $token.Kind.ToString() + ':' + $token.Text.Replace("`r`n", "`n")
        }
    }
}

$files = @(Get-Item -LiteralPath (Join-Path $projectRoot 'Set-Monitor.ps1'), $settings)
foreach ($directory in @('scripts', 'tests', 'streamdeck-monitor-control\worker', 'streamdeck-monitor-control\tests')) {
    $files += @(Get-ChildItem -LiteralPath (Join-Path $projectRoot $directory) -File -Filter '*.ps1' -Recurse)
}
$changed = @()
foreach ($file in $files) {
    $original = [IO.File]::ReadAllText($file.FullName)
    $formatted = Invoke-Formatter -ScriptDefinition $original -Settings $settings
    $formatted = Remove-TrailingWhitespace $formatted
    $formatted = $formatted.Replace("`r`n", "`n").Replace("`n", "`r`n").TrimEnd("`r", "`n") + "`r`n"
    $before = @(Get-CodeTokens $original)
    $after = @(Get-CodeTokens $formatted)
    if (Compare-Object $before $after -SyncWindow 0 -CaseSensitive) {
        throw "Formatting changed code tokens in $($file.FullName); file was not written."
    }
    if ($original -cne $formatted) {
        $changed += $file.FullName
        if (-not $Check) {
            [IO.File]::WriteAllText($file.FullName, $formatted, [Text.UTF8Encoding]::new($false))
        }
        Write-Output $file.FullName
    }
}
if ($Check -and $changed.Count) {
    throw "$($changed.Count) PowerShell files need formatting."
}
if ($Check) {
    Write-Output 'PowerShell formatting is current.'
}
else {
    Write-Output "Formatted $($changed.Count) PowerShell files."
}
