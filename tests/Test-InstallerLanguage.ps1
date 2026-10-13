#Requires -Version 5.1
# Localization checks only: no network, installed runner, SQL, service or SDK installation.
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapqio-language-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-Placeholders([string]$Text) {
    return (@([regex]::Matches($Text, '\{(\d+)(?:[^}]*)\}') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',')
}

function Invoke-MissingInstallation([string]$Script, [string[]]$Arguments, [string]$Name) {
    $log = Join-Path $testRoot ($Name + '.log')
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments *> $log
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    Assert-True ($code -ne 0) "Missing installation must fail: $Name"
    return [IO.File]::ReadAllText($log)
}

foreach ($file in 'install-nexo.ps1', 'install-nexo-build.ps1', 'update-nexo-sdk.ps1') {
    & {
        param($File, $Repository, $TestRoot)
        $path = Join-Path $Repository $File
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "Parse errors in $($File): $parseErrors"
        # Also support the documented irm + ScriptBlock entry point without a physical script path.
        [void][Management.Automation.Language.Parser]::ParseInput(
            [IO.File]::ReadAllText($path).TrimStart([char]0xFEFF), [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "Downloaded scriptblock does not parse: $File"

        $supported = (Get-Command -Name $path).Parameters['Language'].Attributes |
            Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues }
        Assert-True (($supported -join ',') -eq 'pl,en,de') "Invalid -Language contract: $File"

        # Load only translations and functions, without executing installation operations.
        $declarations = $ast.EndBlock.Statements | Where-Object {
            ($_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$messages') -or
            ($_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $_.Name -in 'Get-InstallText', 'Resolve-InstallLanguage', 'Get-InstallerLanguageArguments', 'Read-Value')
        }
        . ([scriptblock]::Create(($declarations | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine))
        Assert-True ((@($messages.Keys | Sort-Object) -join ',') -eq 'de,en,pl') "Incomplete languages: $File"
        $keys = @($messages.pl.Keys | Sort-Object)
        $calls = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-InstallText'
        }, $true)
        foreach ($call in $calls) {
            $key = $call.CommandElements[1].Value
            Assert-True ($messages.pl.ContainsKey($key)) "Missing message $File/$key"
        }

        foreach ($Language in 'pl', 'en', 'de') {
            Assert-True ((@($messages[$Language].Keys | Sort-Object) -join ',') -eq ($keys -join ',')) "Incomplete catalog: $File/$Language"
            foreach ($key in $keys) {
                $text = $messages[$Language][$key]
                Assert-True (-not [string]::IsNullOrWhiteSpace($text)) "Empty translation: $File/$Language/$key"
                Assert-True ((Get-Placeholders $text) -eq (Get-Placeholders $messages.pl[$key])) "Placeholder mismatch: $File/$Language/$key"
                $formatted = Get-InstallText $key @(10, 20, 30, 40, 50, 60)
                Assert-True (-not [string]::IsNullOrWhiteSpace($formatted)) "Cannot format: $File/$Language/$key"
            }
            # Values containing braces, apostrophes and dollar signs must remain literal.
            $sample = 'C:\O''Neil\{tenant}\$name'
            $key = if ($File -eq 'install-nexo.ps1') { 'SummaryConfig' } elseif ($File -eq 'install-nexo-build.ps1') { 'MissingEntry' } else { 'MissingModules' }
            Assert-True ((Get-InstallText $key @($sample)).Contains($sample)) "Value interpolation changed user data: $File/$Language"

            # Exercise each public script entry point against an absent path inside our temporary directory.
            $missing = Join-Path $TestRoot 'absent runner'
            Assert-True ([IO.Path]::GetFullPath($missing).StartsWith([IO.Path]::GetFullPath($TestRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) 'Fixture path escaped the test directory.'
            Assert-True (-not (Test-Path -LiteralPath $missing)) 'The missing-installation fixture must not exist.'
            if ($File -eq 'update-nexo-sdk.ps1') {
                $arguments = @('-RunnerDir', $missing, '-Version', '61.1.1', '-NoRestart', '-Language', $Language)
                $expected = Get-InstallText 'MissingModules' @((Join-Path $missing 'Modules'))
            }
            elseif ($File -eq 'install-nexo-build.ps1') {
                $arguments = @('-InstallDir', $missing, '-NoRestart', '-Language', $Language)
                $expected = Get-InstallText 'MissingRuntime' @('Zapqio.Runner.exe', $missing)
            }
            else {
                $arguments = @('-InstallDir', $missing, '-NoRestart', '-Language', $Language)
                $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                $expected = if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                    Get-InstallText 'MissingRunner' @($missing)
                } else { Get-InstallText 'AdminRequired' }
            }
            $output = Invoke-MissingInstallation $path $arguments "$File-$Language"
            # PowerShell may wrap exception output across lines; compare a stable localized phrase.
            $prefix = ($expected -split [regex]::Escape($missing))[0].Trim()
            Assert-True ($output.Contains($prefix)) "Wrong CLI language: $File/$Language. See $TestRoot."
            Assert-True (-not (Test-Path -LiteralPath $missing)) "Validation created an installation directory: $File/$Language"
        }

        if ($File -eq 'install-nexo.ps1') {
            foreach ($case in @(@('pl-PL', 'pl'), @('de-DE', 'de'), @('en-GB', 'en'), @('fr-FR', 'en'))) {
                Assert-True ((Resolve-InstallLanguage -CultureName $case[0]) -eq $case[1]) "Incorrect culture default: $($case[0])"
            }
            $script:promptCalls = 0
            $script:answers = New-Object 'Collections.Generic.Queue[string]'
            function Read-Host {
                param([string]$Prompt, [switch]$AsSecureString)
                $script:promptCalls++
                if ($script:answers.Count -eq 0) { throw 'Simulated noninteractive host' }
                $answer = $script:answers.Dequeue()
                if ($AsSecureString) { return ConvertTo-SecureString -String $answer -AsPlainText -Force }
                return $answer
            }
            Assert-True ((Resolve-InstallLanguage -RequestedLanguage 'DE' -CultureName 'pl-PL' -Prompt) -eq 'de') 'Explicit language must override culture.'
            Assert-True ($script:promptCalls -eq 0) 'Explicit language must not prompt.'
            foreach ($case in @(@('1', 'pl'), @('2', 'en'), @('3', 'de'), @(' EN ', 'en'), @('', 'de'))) {
                $script:answers.Enqueue($case[0])
                $selected = Resolve-InstallLanguage -CultureName 'de-DE' -Prompt 6>$null
                Assert-True ($selected -eq $case[1]) "Incorrect menu selection: $($case[0])"
            }
            $script:answers.Enqueue('unsupported')
            $script:answers.Enqueue('pl')
            $before = $script:promptCalls
            $selected = Resolve-InstallLanguage -CultureName 'en-US' -Prompt 3>$null 6>$null
            Assert-True ($selected -eq 'pl' -and $script:promptCalls -eq $before + 2) 'Invalid menu input must retry.'
            $selected = Resolve-InstallLanguage -CultureName 'de-DE' -Prompt 6>$null
            Assert-True ($selected -eq 'de') 'Noninteractive prompt must use the culture default.'

            foreach ($Language in 'pl', 'en', 'de') {
                foreach ($helper in 'install-nexo-build.ps1', 'update-nexo-sdk.ps1') {
                    $forwarded = @(Get-InstallerLanguageArguments (Join-Path $Repository $helper))
                    Assert-True (($forwarded -join ',') -eq "-Language,$Language") "Language not forwarded to $helper"
                }
                $script:answers.Enqueue('secret {value}')
                $password = Read-Value (Get-InstallText 'OperatorPasswordPrompt' @('test')) '' -Secret
                Assert-True ($password -eq 'secret {value}') "Password input changed in $Language"
            }
            $legacy = Join-Path $TestRoot 'legacy helper.ps1'
            [IO.File]::WriteAllText($legacy, 'param([string]$RunnerDir) throw "This fixture must never run."')
            $Language = 'de'
            $forwarded = @(Get-InstallerLanguageArguments $legacy 3>$null)
            Assert-True ($forwarded.Count -eq 0) 'Legacy helpers must not receive an unsupported parameter.'
        }
        Write-Host "PASS $File : pl/en/de catalogs, formatting and CLI"
    } $file $repository $testRoot
}
Write-Host "PASS language selection, noninteractive fallback, password input and child script compatibility"
Write-Host "Logs: $testRoot"
