[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RunRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'
$PSNativeCommandUseErrorActionPreference = $false

$logPath = Join-Path $RunRoot 'auth.log'
$transcriptPath = Join-Path $RunRoot 'auth-transcript.log'
$resultPath = Join-Path $RunRoot 'result.json'
$errorPath = Join-Path $RunRoot 'error.json'
$environmentPath = Join-Path $RunRoot 'environment.json'
$processesPath = Join-Path $RunRoot 'processes.json'
$processLogRoot = Join-Path $RunRoot 'process-logs'
$configPath = Join-Path $RunRoot 'config.json'
$keyPath = Join-Path $RunRoot 'password.key'
$secretPath = Join-Path $RunRoot 'password.clixml'
$azureConfigPath = Join-Path $RunRoot '.azure-cli'

$script:CurrentStage = 'Initialization'
$script:ProcessSequence = 0
$script:ProcessRecords = [System.Collections.Generic.List[object]]::new()
$script:TranscriptStarted = $false
$script:User1Password = $null
$script:AzCommand = $null

foreach ($directory in @($RunRoot, $processLogRoot, $azureConfigPath)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

function Write-AuthLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'PASS', 'FAIL')][string]$Level = 'INFO',
        [string]$Stage = $script:CurrentStage
    )

    $safeMessage = $Message
    if (-not [string]::IsNullOrEmpty($script:User1Password)) {
        $safeMessage = $safeMessage.Replace($script:User1Password, '<redacted>')
    }

    $line = '[{0}] [{1}] [{2}] {3}' -f [DateTime]::UtcNow.ToString('o'), $Level, $Stage, $safeMessage
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

function ConvertTo-SafeText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    $safeText = [string]$Text
    if (-not [string]::IsNullOrEmpty($script:User1Password)) {
        $safeText = $safeText.Replace($script:User1Password, '<redacted>')
    }

    return $safeText
}

function Invoke-AzLogged {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string[]]$DisplayArguments = $Arguments,
        [switch]$SensitiveStandardOutput,
        [int]$TimeoutSeconds = 180
    )

    $script:ProcessSequence++
    $sequence = $script:ProcessSequence
    $safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '-')
    $stdoutPath = Join-Path $processLogRoot ('{0:D3}-{1}.stdout.log' -f $sequence, $safeLabel)
    $stderrPath = Join-Path $processLogRoot ('{0:D3}-{1}.stderr.log' -f $sequence, $safeLabel)
    $displayLine = ($DisplayArguments | ForEach-Object { [string]$_ }) -join ' '
    $started = [DateTime]::UtcNow

    Write-AuthLog -Message "PROCESS START: label='$Label'; command='az $displayLine'."

    $timedOut = $false
    $exitCode = $null
    $standardOutput = ''
    $standardError = ''

    try {
        Push-Location -LiteralPath $RunRoot
        & $script:AzCommand @Arguments 1> $stdoutPath 2> $stderrPath
        $exitCode = [int]$LASTEXITCODE
    }
    catch {
        $exitCode = 9001
        $caughtMessage = ConvertTo-SafeText -Text $_.Exception.Message
        Set-Content -LiteralPath $stderrPath -Value $caughtMessage -Encoding utf8 -Force
    }
    finally {
        Pop-Location -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
        $standardOutput = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        $standardError = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
    }

    $standardOutput = ConvertTo-SafeText -Text $standardOutput
    $standardError = ConvertTo-SafeText -Text $standardError

    if ($SensitiveStandardOutput) {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        $preservedStdoutPath = $null
    }
    else {
        Set-Content -LiteralPath $stdoutPath -Value $standardOutput -Encoding utf8 -Force
        $preservedStdoutPath = $stdoutPath
    }

    Set-Content -LiteralPath $stderrPath -Value $standardError -Encoding utf8 -Force

    $completed = [DateTime]::UtcNow
    $duration = [math]::Round(($completed - $started).TotalSeconds, 3)
    $record = [pscustomobject]@{
        Sequence = $sequence
        Label = $Label
        DisplayCommand = "az $displayLine"
        StartedUtc = $started.ToString('o')
        CompletedUtc = $completed.ToString('o')
        DurationSeconds = $duration
        TimedOut = $timedOut
        ExitCode = $exitCode
        StandardOutputBytes = [Text.Encoding]::UTF8.GetByteCount($standardOutput)
        StandardErrorBytes = [Text.Encoding]::UTF8.GetByteCount($standardError)
        StandardOutputPath = $preservedStdoutPath
        StandardErrorPath = $stderrPath
    }
    $script:ProcessRecords.Add($record)
    $script:ProcessRecords | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $processesPath -Encoding utf8 -Force

    Write-AuthLog -Message "PROCESS END: label='$Label'; exitCode=$exitCode; timedOut=$timedOut; duration=${duration}s; stdoutBytes=$($record.StandardOutputBytes); stderrBytes=$($record.StandardErrorBytes)."

    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        StandardOutput = $standardOutput
        StandardError = $standardError
        StandardOutputPath = $preservedStdoutPath
        StandardErrorPath = $stderrPath
    }
}

function Get-TokenProbe {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Resource,
        [string]$SubscriptionId = ''
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @('account', 'get-access-token', '--resource', $Resource, '--tenant', $script:TenantId)) {
        $arguments.Add($value)
    }
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $arguments.Add('--subscription')
        $arguments.Add($SubscriptionId)
    }
    foreach ($value in @('--query', 'accessToken', '--output', 'tsv', '--only-show-errors')) {
        $arguments.Add($value)
    }

    $probe = Invoke-AzLogged -Label $Label -Arguments $arguments.ToArray() -SensitiveStandardOutput
    $tokenText = [string]$probe.StandardOutput
    $tokenLength = $tokenText.Trim().Length
    $tokenAcquired = (-not $probe.TimedOut) -and ($probe.ExitCode -eq 0) -and ($tokenLength -gt 100)
    $tokenText = $null

    return [pscustomobject]@{
        Success = $tokenAcquired
        ExitCode = $probe.ExitCode
        TimedOut = $probe.TimedOut
        TokenLength = $tokenLength
        StandardErrorPath = $probe.StandardErrorPath
    }
}

try {
    try {
        Start-Transcript -Path $transcriptPath -Force | Out-Null
        $script:TranscriptStarted = $true
    }
    catch {
    }

    Write-AuthLog -Message 'SYSTEM scheduled-task Azure authentication POC started.'
    Write-AuthLog -Message "Execution account: $([Environment]::UserDomainName)\$([Environment]::UserName)"
    Write-AuthLog -Message "PowerShell version: $($PSVersionTable.PSVersion); edition=$($PSVersionTable.PSEdition)"

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Configuration file was not found: $configPath"
    }
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        throw "Password key file was not found: $keyPath"
    }
    if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
        throw "Encrypted password file was not found: $secretPath"
    }

    $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $script:SubscriptionId = [string]$config.SubscriptionId
    $script:TenantId = [string]$config.TenantId
    $script:User1Upn = [string]$config.User1Upn

    $key = [IO.File]::ReadAllBytes($keyPath)
    $encryptedPassword = (Get-Content -LiteralPath $secretPath -Raw -ErrorAction Stop).Trim()
    $securePassword = ConvertTo-SecureString -String $encryptedPassword -Key $key
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $script:User1Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }

    if ([string]::IsNullOrWhiteSpace($script:User1Password)) {
        throw 'The decrypted User1 password was empty.'
    }

    $environment = [ordered]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        RunRoot = $RunRoot
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PowerShellEdition = $PSVersionTable.PSEdition
        ExecutionAccount = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
        OS = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        OSArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        ProcessArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        SubscriptionId = $script:SubscriptionId
        TenantId = $script:TenantId
        User1Upn = $script:User1Upn
        AzureConfigDirectory = $azureConfigPath
    }
    $environment | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $environmentPath -Encoding utf8 -Force

    $azCommandInfo = Get-Command az -ErrorAction SilentlyContinue
    if ($null -eq $azCommandInfo) {
        throw "Azure CLI command 'az' was not found on PATH for the SYSTEM task."
    }
    $script:AzCommand = $azCommandInfo.Source
    if ([string]::IsNullOrWhiteSpace($script:AzCommand)) {
        $script:AzCommand = $azCommandInfo.Definition
    }
    Write-AuthLog -Message "Azure CLI command: $script:AzCommand"

    $script:CurrentStage = 'Validate Azure CLI'
    $versionResult = Invoke-AzLogged -Label 'az-version' -Arguments @('version', '--output', 'json', '--only-show-errors')
    if ($versionResult.TimedOut -or $versionResult.ExitCode -ne 0) {
        throw "Azure CLI version check failed. Raw stderr: $($versionResult.StandardErrorPath)"
    }
    Write-AuthLog -Level 'PASS' -Message 'Azure CLI is available to the SYSTEM scheduled task.'

    $script:CurrentStage = 'Configure isolated Azure CLI profile'
    $configResult = Invoke-AzLogged -Label 'az-config-noninteractive' -Arguments @(
        'config', 'set',
        'core.login_experience_v2=off',
        'core.only_show_errors=true',
        'core.collect_telemetry=false',
        '--only-show-errors'
    )
    if ($configResult.TimedOut -or $configResult.ExitCode -ne 0) {
        Write-AuthLog -Message "Azure CLI config command returned exit code $($configResult.ExitCode); continuing because the isolated profile and per-command suppression remain in effect. Raw stderr: $($configResult.StandardErrorPath)"
    }

    $cloudResult = Invoke-AzLogged -Label 'az-cloud-set-AzureCloud' -Arguments @('cloud', 'set', '--name', 'AzureCloud', '--only-show-errors')
    if ($cloudResult.TimedOut -or $cloudResult.ExitCode -ne 0) {
        throw "Unable to select AzureCloud. Raw stderr: $($cloudResult.StandardErrorPath)"
    }
    Write-AuthLog -Level 'PASS' -Message "Isolated Azure CLI profile created at '$azureConfigPath'."

    $script:CurrentStage = 'Authenticate User1 under SYSTEM'
    $loginExitCode = $null
    $sqlTokenProbe = $null
    $loginUsable = $false

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-AuthLog -Message "User1 login attempt $attempt of 3."
        $loginArguments = @(
            'login',
            '--username', $script:User1Upn,
            '--password', $script:User1Password,
            '--tenant', $script:TenantId,
            '--allow-no-subscriptions',
            '--output', 'json',
            '--only-show-errors'
        )
        $displayArguments = @(
            'login',
            '--username', $script:User1Upn,
            '--password', '<redacted>',
            '--tenant', $script:TenantId,
            '--allow-no-subscriptions',
            '--output', 'json',
            '--only-show-errors'
        )
        $loginResult = Invoke-AzLogged -Label "az-login-attempt-$attempt" -Arguments $loginArguments -DisplayArguments $displayArguments -TimeoutSeconds 180
        $loginExitCode = $loginResult.ExitCode

        $sqlTokenProbe = Get-TokenProbe -Label "sql-token-probe-attempt-$attempt" -Resource 'https://database.windows.net/'
        if ($sqlTokenProbe.Success) {
            $loginUsable = $true
            Write-AuthLog -Level 'PASS' -Message "User1 login is usable under SYSTEM. Azure SQL token length=$($sqlTokenProbe.TokenLength). Login exit code=$loginExitCode (not treated as authoritative)."
            break
        }

        Write-AuthLog -Level 'INFO' -Message "Login attempt $attempt did not produce a usable Azure SQL token. Login exit code=$loginExitCode; token exit code=$($sqlTokenProbe.ExitCode). Raw stderr files remain under '$processLogRoot'."
        if ($attempt -lt 3) {
            Start-Sleep -Seconds 15
        }
    }

    $script:CurrentStage = 'Verify target subscription access'
    $subscriptionVisible = $false
    $subscriptionSelected = $false
    $subscriptionReadSucceeded = $false
    $managementTokenProbe = $null
    $accountListExitCode = $null

    for ($attempt = 1; $attempt -le 8; $attempt++) {
        $accountListResult = Invoke-AzLogged -Label "account-list-refresh-$attempt" -Arguments @('account', 'list', '--all', '--refresh', '--output', 'json', '--only-show-errors') -TimeoutSeconds 180
        $accountListExitCode = $accountListResult.ExitCode

        if (-not $accountListResult.TimedOut -and $accountListResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($accountListResult.StandardOutput)) {
            try {
                $accounts = @($accountListResult.StandardOutput | ConvertFrom-Json -ErrorAction Stop)
                $matchingAccount = @($accounts | Where-Object { [string]$_.id -eq $script:SubscriptionId })
                if ($matchingAccount.Count -gt 0) {
                    $subscriptionVisible = $true
                    Write-AuthLog -Level 'PASS' -Message "Target subscription '$script:SubscriptionId' is visible to User1 under SYSTEM."
                    break
                }
            }
            catch {
                Write-AuthLog -Level 'INFO' -Message "Account-list JSON could not be parsed on attempt $attempt. Raw stdout: $($accountListResult.StandardOutputPath)"
            }
        }

        Write-AuthLog -Message "Target subscription is not visible yet (attempt $attempt of 8)."
        if ($attempt -lt 8) {
            Start-Sleep -Seconds 15
        }
    }

    if ($subscriptionVisible) {
        $accountSetResult = Invoke-AzLogged -Label 'account-set-target-subscription' -Arguments @('account', 'set', '--subscription', $script:SubscriptionId, '--only-show-errors')
        if (-not $accountSetResult.TimedOut -and $accountSetResult.ExitCode -eq 0) {
            $accountShowResult = Invoke-AzLogged -Label 'account-show-target-subscription' -Arguments @('account', 'show', '--subscription', $script:SubscriptionId, '--query', 'id', '--output', 'tsv', '--only-show-errors')
            if (-not $accountShowResult.TimedOut -and $accountShowResult.ExitCode -eq 0 -and $accountShowResult.StandardOutput.Trim() -eq $script:SubscriptionId) {
                $subscriptionSelected = $true
                Write-AuthLog -Level 'PASS' -Message 'Azure CLI selected the expected Skillable subscription.'
            }
        }

        $managementTokenProbe = Get-TokenProbe -Label 'management-token-probe' -Resource 'https://management.azure.com/' -SubscriptionId $script:SubscriptionId
        if ($managementTokenProbe.Success) {
            Write-AuthLog -Level 'PASS' -Message "Management token acquired for the target subscription. Token length=$($managementTokenProbe.TokenLength)."
        }

        $subscriptionUrl = "https://management.azure.com/subscriptions/$script:SubscriptionId?api-version=2020-01-01"
        $restResult = Invoke-AzLogged -Label 'management-subscription-read' -Arguments @('rest', '--method', 'get', '--url', $subscriptionUrl, '--output', 'json', '--only-show-errors')
        if (-not $restResult.TimedOut -and $restResult.ExitCode -eq 0) {
            $subscriptionReadSucceeded = $true
            Write-AuthLog -Level 'PASS' -Message 'User1 can read the target subscription through Azure Resource Manager.'
        }
    }

    $sqlAuthReady = $loginUsable -and $sqlTokenProbe.Success
    $fullPostDeployAuthReady = $sqlAuthReady -and $subscriptionVisible -and $subscriptionSelected -and ($null -ne $managementTokenProbe) -and $managementTokenProbe.Success -and $subscriptionReadSucceeded

    $result = [ordered]@{
        RunId = Split-Path -Leaf $RunRoot
        Completed = $true
        Success = $fullPostDeployAuthReady
        SqlDataPlaneAuthReady = $sqlAuthReady
        FullPostDeploymentAuthReady = $fullPostDeployAuthReady
        LoginExitCode = $loginExitCode
        SqlTokenAcquired = $sqlTokenProbe.Success
        SqlTokenLength = $sqlTokenProbe.TokenLength
        SubscriptionVisible = $subscriptionVisible
        SubscriptionSelected = $subscriptionSelected
        ManagementTokenAcquired = if ($null -ne $managementTokenProbe) { $managementTokenProbe.Success } else { $false }
        SubscriptionReadSucceeded = $subscriptionReadSucceeded
        SubscriptionId = $script:SubscriptionId
        TenantId = $script:TenantId
        User1Upn = $script:User1Upn
        ExecutionAccount = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
        LogPath = $logPath
        ProcessesPath = $processesPath
        ProcessLogDirectory = $processLogRoot
    }
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding utf8 -Force

    if ($fullPostDeployAuthReady) {
        Write-AuthLog -Level 'PASS' -Stage 'Final result' -Message 'AUTH POC PASS: SYSTEM can authenticate User1, obtain an Azure SQL token, select the Skillable subscription, obtain a management token, and read the subscription.'
        exit 0
    }

    if ($sqlAuthReady) {
        Write-AuthLog -Level 'FAIL' -Stage 'Final result' -Message 'AUTH POC PARTIAL: User1 SQL data-plane authentication works under SYSTEM, but target-subscription control-plane access is not fully available. See result.json and process logs.'
    }
    else {
        Write-AuthLog -Level 'FAIL' -Stage 'Final result' -Message 'AUTH POC FAIL: User1 could not obtain a usable Azure SQL token under SYSTEM. See result.json and process logs.'
    }
    exit 2
}
catch {
    $safeMessage = ConvertTo-SafeText -Text $_.Exception.Message
    $errorRecord = [ordered]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Stage = $script:CurrentStage
        Message = $safeMessage
        ExceptionType = $_.Exception.GetType().FullName
        FullyQualifiedErrorId = $_.FullyQualifiedErrorId
        Position = if ($null -ne $_.InvocationInfo) { $_.InvocationInfo.PositionMessage } else { $null }
        ScriptStackTrace = $_.ScriptStackTrace
        LogPath = $logPath
        ProcessesPath = $processesPath
        ProcessLogDirectory = $processLogRoot
    }
    $errorRecord | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $errorPath -Encoding utf8 -Force
    Write-AuthLog -Level 'FAIL' -Stage $script:CurrentStage -Message "AUTH POC EXCEPTION: $safeMessage. Detailed records: '$errorPath'."
    exit 3
}
finally {
    try {
        if ($null -ne $script:AzCommand) {
            Invoke-AzLogged -Label 'az-logout-cleanup' -Arguments @('logout', '--only-show-errors') -TimeoutSeconds 60 | Out-Null
        }
    }
    catch {
    }

    $script:User1Password = $null
    $securePassword = $null
    $encryptedPassword = $null
    $key = $null

    Remove-Item -LiteralPath $secretPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $keyPath -Force -ErrorAction SilentlyContinue

    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
        }
    }
}
