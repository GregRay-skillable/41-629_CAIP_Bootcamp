# =====================================================================
# DEPLOY AZURE MODERNIZE BOOTCAMP DAY 2
#
# Source:
#   https://github.com/Azure-Samples/modernize-bootcamp
#
# Authentication:
#   Skillable-provided Azure context
#
# Design:
#   - No AppId / AppSecret
#   - No Azure CLI
#   - No translated ARM templates
#   - Deploy client's current main.bicep directly
#   - Use Skillable Lab Instance ID as the resource suffix
#   - Resolve User1 as SQL / Key Vault Entra administrator
#
# Nothing is written back to the client GitHub repository.
# All Bicep modifications occur in a temporary workspace.
# =====================================================================

param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$EnvironmentName,

    [Parameter(Mandatory)]
    [string]$User1Upn,

    [Parameter(Mandatory)]
    [string]$VmAdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------
# Runtime values supplied by the tiny Skillable LCA loader
# ---------------------------------------------------------------------

$vmAdminUsername = 'labadmin'

$primaryLocation     = 'centralus'
$secondaryLocation   = 'centralus'
$applicationLocation = 'westus2'

# ---------------------------------------------------------------------
# Client repository
# ---------------------------------------------------------------------

$repositoryArchiveUrl =
    'https://codeload.github.com/Azure-Samples/modernize-bootcamp/zip/refs/heads/main'

$customerRelativePath =
    'skillable/day_2/bootcamp_deployment'

# ---------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------

$workingDirectory = $null
$originalPath = $env:PATH
$user1ObjectId = $null
$deploymentName = $null

# ---------------------------------------------------------------------
# Per-step diagnostics
#
# This LCA runs in the Skillable Cloud Platform, not on W11-Workstation.
# Diagnostic files therefore live under the Cloud runner temporary path.
# On failure, the useful summary, exception details, deployment operations,
# and the tail of the active step transcript are printed into the LCA output.
# ---------------------------------------------------------------------

$diagnosticInstance = [string]$environmentName

if (
    [string]::IsNullOrWhiteSpace($diagnosticInstance) -or
    $diagnosticInstance -like '@lab.*'
) {
    $diagnosticInstance = 'unresolved'
}

$diagnosticInstance =
    [regex]::Replace($diagnosticInstance, '[^A-Za-z0-9._-]', '_')

$diagnosticRunId = Get-Date -Format 'yyyyMMdd-HHmmssfff'

$diagnosticRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("ModernizeBootcampDiagnostics-{0}-{1}" -f `
        $diagnosticInstance, `
        $diagnosticRunId)

New-Item `
    -ItemType Directory `
    -Path $diagnosticRoot `
    -Force `
    -ErrorAction Stop |
    Out-Null

$stepSummaryPath = Join-Path $diagnosticRoot 'step-summary.log'
$failurePath = Join-Path $diagnosticRoot 'failure.json'
$runtimeInfoPath = Join-Path $diagnosticRoot 'runtime-info.json'
$providerSnapshotPath = Join-Path $diagnosticRoot 'provider-states-before-deploy.json'
$preDeploymentSnapshotPath = Join-Path $diagnosticRoot 'pre-deployment-snapshot.json'
$deploymentResultPath = Join-Path $diagnosticRoot 'deployment-result.json'
$deploymentOperationsPath = Join-Path $diagnosticRoot 'deployment-operations.json'
$sourceFingerprintsPath = Join-Path $diagnosticRoot 'source-fingerprints.json'

$script:activeStepNumber = $null
$script:activeStepName = $null
$script:activeTranscriptPath = $null
$script:activeStepStopwatch = $null
$script:transcriptActive = $false

function Write-StepSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $line = '[{0}] {1}' -f `
        (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK'), `
        $Message

    Add-Content `
        -LiteralPath $stepSummaryPath `
        -Value $line `
        -Encoding UTF8
}

function Start-DiagnosticStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($script:transcriptActive) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        $script:transcriptActive = $false
    }

    $safeName = [regex]::Replace($Name, '[^A-Za-z0-9._-]', '-')

    $script:activeStepNumber = $Number
    $script:activeStepName = $Name
    $script:activeTranscriptPath = Join-Path `
        $diagnosticRoot `
        ('{0:D2}-{1}.transcript.log' -f $Number, $safeName)

    $script:activeStepStopwatch = [Diagnostics.Stopwatch]::StartNew()

    Start-Transcript `
        -Path $script:activeTranscriptPath `
        -Force `
        -ErrorAction Stop |
        Out-Null

    $script:transcriptActive = $true

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ("STEP {0:D2} START: {1}" -f $Number, $Name)
    Write-Host "Timestamp : $(Get-Date -Format o)"
    Write-Host "Transcript: $($script:activeTranscriptPath)"
    Write-Host '============================================================'

    Write-StepSummary `
        -Message ("STEP {0:D2} START: {1}" -f $Number, $Name)
}

function Complete-DiagnosticStep {
    [CmdletBinding()]
    param()

    if ($null -ne $script:activeStepStopwatch) {
        $script:activeStepStopwatch.Stop()
    }

    $elapsed = if ($null -ne $script:activeStepStopwatch) {
        [math]::Round($script:activeStepStopwatch.Elapsed.TotalSeconds, 3)
    }
    else {
        0
    }

    Write-Host (
        "STEP {0:D2} SUCCESS: {1} ({2} seconds)" -f `
            $script:activeStepNumber, `
            $script:activeStepName, `
            $elapsed
    )

    Write-StepSummary `
        -Message (
            "STEP {0:D2} SUCCESS: {1} ({2} seconds)" -f `
                $script:activeStepNumber, `
                $script:activeStepName, `
                $elapsed
        )

    if ($script:transcriptActive) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        $script:transcriptActive = $false
    }
}

function Save-FileFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Label  = $Label
            Path   = $Path
            Exists = $false
            Length = $null
            SHA256 = $null
        }
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop

    return [pscustomobject]@{
        Label  = $Label
        Path   = $Path
        Exists = $true
        Length = $item.Length
        SHA256 = $hash.Hash
    }
}

function Export-AzureDeploymentDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DeploymentName
    )

    if ([string]::IsNullOrWhiteSpace($DeploymentName)) {
        return
    }

    Write-Host ''
    Write-Host "Collecting Azure diagnostics for '$DeploymentName'..."

    try {
        $deploymentRecord = Get-AzSubscriptionDeployment `
            -Name $DeploymentName `
            -ErrorAction Stop

        $deploymentRecord |
            ConvertTo-Json -Depth 30 |
            Set-Content `
                -LiteralPath $deploymentResultPath `
                -Encoding UTF8

        Write-Host "Deployment state: $($deploymentRecord.ProvisioningState)"
    }
    catch {
        Write-Host (
            "Unable to read subscription deployment record: " +
            $_.Exception.Message
        )
    }

    try {
        $operations = @(
            Get-AzSubscriptionDeploymentOperation `
                -DeploymentName $DeploymentName `
                -ErrorAction Stop
        )

        $operations |
            ConvertTo-Json -Depth 50 |
            Set-Content `
                -LiteralPath $deploymentOperationsPath `
                -Encoding UTF8

        $failedOperations = @(
            $operations |
                Where-Object {
                    $_.ProvisioningState -eq 'Failed'
                }
        )

        Write-Host "Deployment operation count: $($operations.Count)"
        Write-Host "Failed operation count: $($failedOperations.Count)"

        foreach ($operation in $failedOperations) {
            Write-Host '------------------------------------------------------------'
            Write-Host "Operation ID : $($operation.OperationId)"
            Write-Host "State        : $($operation.ProvisioningState)"

            if ($null -ne $operation.TargetResource) {
                Write-Host "Resource     : $($operation.TargetResource.ResourceName)"
                Write-Host "Type         : $($operation.TargetResource.ResourceType)"
                Write-Host "Resource ID  : $($operation.TargetResource.Id)"
            }

            if ($null -ne $operation.StatusMessage) {
                Write-Host 'Status message:'
                Write-Host (
                    $operation.StatusMessage |
                        ConvertTo-Json -Depth 30
                )
            }
        }

        # Follow nested resource-group deployments when the subscription
        # operation exposes a Microsoft.Resources/deployments target.
        $nestedIndex = 0

        foreach ($operation in $failedOperations) {
            $targetId = [string]$operation.TargetResource.Id

            if (
                [string]::IsNullOrWhiteSpace($targetId) -or
                $targetId -notmatch `
                    '/resourceGroups/([^/]+)/providers/Microsoft.Resources/deployments/([^/]+)$'
            ) {
                continue
            }

            $nestedIndex++
            $resourceGroupName = $matches[1]
            $nestedDeploymentName = $matches[2]

            try {
                $nestedOperations = @(
                    Get-AzResourceGroupDeploymentOperation `
                        -ResourceGroupName $resourceGroupName `
                        -DeploymentName $nestedDeploymentName `
                        -ErrorAction Stop
                )

                $nestedPath = Join-Path `
                    $diagnosticRoot `
                    ('nested-deployment-{0:D2}-{1}.json' -f `
                        $nestedIndex, `
                        ([regex]::Replace(
                            $nestedDeploymentName,
                            '[^A-Za-z0-9._-]',
                            '_'
                        )))

                $nestedOperations |
                    ConvertTo-Json -Depth 50 |
                    Set-Content `
                        -LiteralPath $nestedPath `
                        -Encoding UTF8

                Write-Host (
                    "Nested deployment diagnostics: " +
                    "$resourceGroupName / $nestedDeploymentName"
                )

                foreach (
                    $nestedOperation in @(
                        $nestedOperations |
                            Where-Object {
                                $_.ProvisioningState -eq 'Failed'
                            }
                    )
                ) {
                    Write-Host '  ----------------------------------------------------------'
                    Write-Host "  Resource: $($nestedOperation.TargetResource.ResourceName)"
                    Write-Host "  Type    : $($nestedOperation.TargetResource.ResourceType)"

                    if ($null -ne $nestedOperation.StatusMessage) {
                        Write-Host (
                            $nestedOperation.StatusMessage |
                                ConvertTo-Json -Depth 30
                        )
                    }
                }
            }
            catch {
                Write-Host (
                    "Unable to collect nested deployment '$nestedDeploymentName': " +
                    $_.Exception.Message
                )
            }
        }
    }
    catch {
        Write-Host (
            "Unable to collect subscription deployment operations: " +
            $_.Exception.Message
        )
    }
}

# Runtime information that is safe to persist. Password values are excluded.
$runtimeInfo = [ordered]@{
    Timestamp        = Get-Date -Format o
    PowerShell       = $PSVersionTable.PSVersion.ToString()
    PSEdition        = $PSVersionTable.PSEdition
    OperatingSystem  = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    Architecture     = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    ProcessId        = $PID
    SubscriptionId   = $subscriptionId
    EnvironmentName  = $environmentName
    User1Upn         = $user1Upn
    DiagnosticRoot   = $diagnosticRoot
}

$runtimeInfo |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        -LiteralPath $runtimeInfoPath `
        -Encoding UTF8

Write-Host "Diagnostic root: $diagnosticRoot"
Write-StepSummary -Message "Diagnostic run initialized: $diagnosticRoot"

# ---------------------------------------------------------------------
# Download helper
# ---------------------------------------------------------------------

function Invoke-DownloadWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$OutFile,

        [int]$MaxAttempts = 3,

        [int]$DelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $attemptStarted = Get-Date

        Write-Host (
            "Download attempt $attempt of $MaxAttempts started at " +
            "$($attemptStarted.ToString('o'))."
        )
        Write-Host "URI: $Uri"
        Write-Host "OutFile: $OutFile"

        try {
            Invoke-WebRequest `
                -Uri $Uri `
                -OutFile $OutFile `
                -UseBasicParsing `
                -ErrorAction Stop

            if (
                -not (Test-Path -LiteralPath $OutFile -PathType Leaf) -or
                (Get-Item -LiteralPath $OutFile).Length -le 0
            ) {
                throw "Downloaded file is missing or empty: $OutFile"
            }

            $downloadItem = Get-Item `
                -LiteralPath $OutFile `
                -ErrorAction Stop

            $elapsed = (Get-Date) - $attemptStarted

            Write-Host (
                "Download attempt $attempt succeeded. " +
                "Bytes=$($downloadItem.Length); " +
                "Seconds=$([math]::Round($elapsed.TotalSeconds, 3))."
            )

            return
        }
        catch {
            $elapsed = (Get-Date) - $attemptStarted

            Write-Host (
                "Download attempt $attempt failed after " +
                "$([math]::Round($elapsed.TotalSeconds, 3)) seconds."
            )
            Write-Host "Exception type: $($_.Exception.GetType().FullName)"
            Write-Host "Message: $($_.Exception.Message)"

            if ($null -ne $_.Exception.InnerException) {
                Write-Host (
                    "Inner exception: " +
                    $_.Exception.InnerException.Message
                )
            }

            if ($attempt -eq $MaxAttempts) {
                throw
            }

            Write-Host (
                "Retrying in $DelaySeconds seconds..."
            )

            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

try {

    Start-DiagnosticStep `
        -Number 1 `
        -Name 'Validate Skillable values'

    # =================================================================
    # VALIDATE SKILLABLE VALUES
    # =================================================================

    $requiredValues = @{
        SubscriptionId  = $subscriptionId
        EnvironmentName = $environmentName
        User1Upn        = $user1Upn
        VmAdminPassword = $vmAdminPassword
    }

    foreach ($item in $requiredValues.GetEnumerator()) {

        if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
            throw "$($item.Key) is empty."
        }

        if ([string]$item.Value -like '@lab.*') {
            throw "$($item.Key) was not resolved by Skillable."
        }
    }

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 2 `
        -Name 'Validate Lab Instance ID naming'

    # =================================================================
    # VALIDATE LAB INSTANCE ID FOR AZURE RESOURCE NAMING
    # =================================================================

    $skillableSuffix = [string]$environmentName

    if ($skillableSuffix -notmatch '^[A-Za-z0-9]+$') {

        throw (
            "Skillable Lab Instance ID '$skillableSuffix' contains " +
            "characters that are not safe for all Azure resource names."
        )
    }

    # Key Vault naming is the tightest constraint in the client template.
    #
    # safePrefix = max 13 characters
    # suffix     = max 8 characters
    # "-kv"      = 3 characters
    #
    # Maximum Key Vault name = 24 characters.
    if ($skillableSuffix.Length -gt 8) {

        throw (
            "Skillable Lab Instance ID '$skillableSuffix' is longer " +
            "than 8 characters. The current client naming convention " +
            "supports a maximum 8-character suffix because of Azure " +
            "Key Vault naming limits."
        )
    }

    Write-Host (
        "Skillable Lab Instance ID '$skillableSuffix' will be used " +
        "as the Azure resource suffix."
    )

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 3 `
        -Name 'Validate Azure context'

    # =================================================================
    # VALIDATE AZURE CONTEXT
    # =================================================================

    Write-Host 'Validating Skillable Azure context...'

    $context = Get-AzContext -ErrorAction Stop

    if (
        $null -eq $context -or
        $null -eq $context.Subscription -or
        [string]::IsNullOrWhiteSpace(
            [string]$context.Subscription.Id
        )
    ) {
        throw 'Skillable did not provide an authenticated Azure context.'
    }

    Set-AzContext `
        -SubscriptionId $subscriptionId `
        -ErrorAction Stop |
        Out-Null

    $context = Get-AzContext -ErrorAction Stop

    if ($context.Subscription.Id -ne $subscriptionId) {

        throw (
            "Active Azure subscription '$($context.Subscription.Id)' " +
            "does not match Skillable subscription '$subscriptionId'."
        )
    }

    Write-Host 'Azure subscription context validated.'

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 4 `
        -Name 'Resolve User1 in Entra ID'

    # =================================================================
    # RESOLVE USER1 IN MICROSOFT ENTRA ID
    # =================================================================

    Write-Host "Resolving User1 '$user1Upn' in Microsoft Entra ID..."

    $user1 = Get-AzADUser `
        -UserPrincipalName $user1Upn `
        -ErrorAction Stop

    if (
        $null -eq $user1 -or
        [string]::IsNullOrWhiteSpace([string]$user1.Id)
    ) {
        throw "Unable to resolve User1 '$user1Upn' in Microsoft Entra ID."
    }

    $user1ObjectId = [string]$user1.Id

    if (
        $user1ObjectId -notmatch
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    ) {
        throw (
            "Resolved User1 object ID is not a valid GUID: " +
            "$user1ObjectId"
        )
    }

    Write-Host 'User1 resolved successfully.'

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 5 `
        -Name 'Create temporary workspace'

    # =================================================================
    # CREATE TEMPORARY WORKSPACE
    # =================================================================

    $workingDirectory = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ("ModernizeBootcamp-" + [guid]::NewGuid().ToString('N'))

    New-Item `
        -ItemType Directory `
        -Path $workingDirectory `
        -Force |
        Out-Null

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 6 `
        -Name 'Ensure Bicep CLI'

    # =================================================================
    # ENSURE BICEP CLI
    # =================================================================

    $bicepCommand =
        Get-Command bicep -ErrorAction SilentlyContinue

    if ($null -eq $bicepCommand) {

        Write-Host 'Bicep CLI not found. Installing temporary runtime copy...'

        $toolsDirectory = Join-Path `
            $workingDirectory `
            'tools'

        New-Item `
            -ItemType Directory `
            -Path $toolsDirectory `
            -Force |
            Out-Null

        $runtimeIsWindows =
            [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                [System.Runtime.InteropServices.OSPlatform]::Windows
            )

        $runtimeIsLinux =
            [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                [System.Runtime.InteropServices.OSPlatform]::Linux
            )

        $runtimeArchitecture =
            [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture

        if (
            $runtimeArchitecture -ne
            [System.Runtime.InteropServices.Architecture]::X64
        ) {
            throw (
                "Unsupported runtime architecture: " +
                "$runtimeArchitecture"
            )
        }

        if ($runtimeIsWindows) {

            $bicepAsset = 'bicep-win-x64.exe'

            $bicepPath = Join-Path `
                $toolsDirectory `
                'bicep.exe'
        }
        elseif ($runtimeIsLinux) {

            $bicepAsset = 'bicep-linux-x64'

            $bicepPath = Join-Path `
                $toolsDirectory `
                'bicep'
        }
        else {
            throw 'Unsupported Skillable Cloud Platform operating system.'
        }

        $bicepUri =
            "https://github.com/Azure/bicep/releases/latest/download/$bicepAsset"

        Invoke-DownloadWithRetry `
            -Uri $bicepUri `
            -OutFile $bicepPath

        if ($runtimeIsLinux) {

            & chmod +x $bicepPath

            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to mark temporary Bicep CLI executable.'
            }
        }

        $env:PATH =
            $toolsDirectory +
            [IO.Path]::PathSeparator +
            $env:PATH

        if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
            throw 'Bicep CLI was installed but could not be found on PATH.'
        }
    }

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 7 `
        -Name 'Validate Bicep CLI'

    # =================================================================
    # VALIDATE BICEP
    # =================================================================

    $bicepVersion = & bicep --version

    if ($LASTEXITCODE -ne 0) {
        throw "Bicep validation failed with exit code $LASTEXITCODE."
    }

    Write-Host "Bicep runtime: $bicepVersion"

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 8 `
        -Name 'Download client repository'

    # =================================================================
    # DOWNLOAD CLIENT REPOSITORY
    # =================================================================

    $archivePath = Join-Path `
        $workingDirectory `
        'modernize-bootcamp.zip'

    $extractPath = Join-Path `
        $workingDirectory `
        'source'

    Write-Host (
        'Downloading current ' +
        'Azure-Samples/modernize-bootcamp main branch...'
    )

    Invoke-DownloadWithRetry `
        -Uri $repositoryArchiveUrl `
        -OutFile $archivePath

    $downloadFingerprints = @(
        Save-FileFingerprint `
            -Label 'RepositoryArchive' `
            -Path $archivePath
    )

    $downloadFingerprints |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $sourceFingerprintsPath `
            -Encoding UTF8

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 9 `
        -Name 'Extract and inspect client repository'

    Write-Host 'Extracting client repository...' 

    Expand-Archive `
        -LiteralPath $archivePath `
        -DestinationPath $extractPath `
        -Force `
        -ErrorAction Stop

    $repositoryRoots = @(
        Get-ChildItem `
            -LiteralPath $extractPath `
            -Directory `
            -ErrorAction Stop
    )

    if ($repositoryRoots.Count -ne 1) {

        throw (
            "Expected one repository root but found " +
            "$($repositoryRoots.Count)."
        )
    }

    $repositoryRoot =
        $repositoryRoots[0].FullName

    $deploymentRoot = Join-Path `
        $repositoryRoot `
        $customerRelativePath

    if (
        -not (
            Test-Path `
                -LiteralPath $deploymentRoot `
                -PathType Container
        )
    ) {
        throw "Customer deployment directory not found: $deploymentRoot"
    }

    $infraRoot = Join-Path `
        $deploymentRoot `
        'infra'

    $templateFile = Join-Path `
        $infraRoot `
        'main.bicep'

    if (
        -not (
            Test-Path `
                -LiteralPath $templateFile `
                -PathType Leaf
        )
    ) {
        throw "Customer main.bicep was not found: $templateFile"
    }

    Write-Host 'Customer main.bicep located successfully.'

    $sourceFingerprints = @(
        Save-FileFingerprint `
            -Label 'RepositoryArchive' `
            -Path $archivePath

        Save-FileFingerprint `
            -Label 'SourceMainBicep' `
            -Path $templateFile
    )

    $sourceFingerprints |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $sourceFingerprintsPath `
            -Encoding UTF8

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 10 `
        -Name 'Apply Skillable naming adaptation'

    # =================================================================
    # SKILLABLE NAMING ADAPTATION
    #
    # Client default:
    #
    #   var suffix =
    #       take(uniqueString(subscription().id,
    #                         environmentName,
    #                         prefix), 8)
    #
    # Skillable:
    #
    #   var suffix = environmentName
    #
    # environmentName is passed in by the Skillable LCA loader.
    #
    # This causes the Lab Instance ID to propagate through all existing
    # client naming conventions without modifying the GitHub repository.
    # =================================================================

    Write-Host (
        "Applying Skillable Lab Instance ID suffix '$skillableSuffix'..."
    )

    $mainContent = Get-Content `
        -LiteralPath $templateFile `
        -Raw `
        -ErrorAction Stop

    $suffixExpressionPattern =
        'var\s+suffix\s*=\s*take\(\s*uniqueString\(\s*subscription\(\)\.id\s*,\s*environmentName\s*,\s*prefix\s*\)\s*,\s*8\s*\)'

    if ($mainContent -notmatch $suffixExpressionPattern) {

        throw (
            'Expected suffix expression was not found in the client ' +
            'main.bicep. The upstream repository may have changed.'
        )
    }

    $mainContent =
        [regex]::Replace(
            $mainContent,
            $suffixExpressionPattern,
            'var suffix = environmentName',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

    Set-Content `
        -LiteralPath $templateFile `
        -Value $mainContent `
        -Encoding utf8 `
        -NoNewline

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 11 `
        -Name 'Relax suffix validation in Bicep modules'

    # =================================================================
    # RELAX 8-CHARACTER SUFFIX VALIDATION
    #
    # Client modules currently contain:
    #
    #   @minLength(8)
    #   @maxLength(8)
    #   param suffix string
    #
    # Skillable Lab Instance IDs can be shorter than 8 characters.
    #
    # Change to:
    #
    #   @minLength(1)
    #   @maxLength(8)
    #   param suffix string
    # =================================================================

    $bicepFiles = @(
        Get-ChildItem `
            -LiteralPath $infraRoot `
            -Filter '*.bicep' `
            -File `
            -Recurse `
            -ErrorAction Stop
    )

    $suffixParameterPattern =
        '@minLength\(\s*8\s*\)\s*@maxLength\(\s*8\s*\)\s*param\s+suffix\s+string'

    $suffixParameterReplacement = @'
@minLength(1)
@maxLength(8)
param suffix string
'@

    $patchedModuleCount = 0

    foreach ($bicepFile in $bicepFiles) {

        $content = Get-Content `
            -LiteralPath $bicepFile.FullName `
            -Raw `
            -ErrorAction Stop

        if ($content -match $suffixParameterPattern) {

            $content =
                [regex]::Replace(
                    $content,
                    $suffixParameterPattern,
                    $suffixParameterReplacement
                )

            Set-Content `
                -LiteralPath $bicepFile.FullName `
                -Value $content `
                -Encoding utf8 `
                -NoNewline

            $patchedModuleCount++
        }
    }

    Write-Host (
        "Updated suffix validation in " +
        "$patchedModuleCount Bicep module(s)."
    )

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 12 `
        -Name 'Verify naming patch'

    # =================================================================
    # VERIFY NAMING PATCH
    # =================================================================

    $verifyMain = Get-Content `
        -LiteralPath $templateFile `
        -Raw `
        -ErrorAction Stop

    if (
        $verifyMain -notmatch
        'var\s+suffix\s*=\s*environmentName'
    ) {
        throw 'Skillable suffix adaptation verification failed.'
    }

    if (
        $verifyMain -match
        'take\(\s*uniqueString\(\s*subscription\(\)\.id\s*,\s*environmentName'
    ) {
        throw (
            'Original uniqueString suffix expression is still present ' +
            'after the Skillable patch.'
        )
    }

    Write-Host 'Skillable naming adaptation completed successfully.'

    $verifiedFingerprints = @(
        Save-FileFingerprint `
            -Label 'RepositoryArchive' `
            -Path $archivePath

        Save-FileFingerprint `
            -Label 'PatchedMainBicep' `
            -Path $templateFile
    )

    $verifiedFingerprints |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $sourceFingerprintsPath `
            -Encoding UTF8

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 13 `
        -Name 'Build deployment parameters'

    # =================================================================
    # DEPLOYMENT PARAMETERS
    #
    # Client defaults remain authoritative for:
    #
    #   prefix
    #   databaseMode
    #   sqlMiPricingModel
    #
    # Skillable explicitly supplies SQL Entra administrator values
    # because the Skillable deployment identity does not expose a UPN.
    # =================================================================

    $templateParameters = @{
        environmentName       = $environmentName
        primaryLocation       = $primaryLocation
        secondaryLocation     = $secondaryLocation
        applicationLocation   = $applicationLocation
        vmAdminUsername       = $vmAdminUsername
        vmAdminPassword       = $vmAdminPassword
        sqlEntraAdminObjectId = $user1ObjectId
        sqlEntraAdminLogin    = $user1Upn
    }

    $deploymentName =
        "$environmentName-deploy"

    Write-Host "Deployment name: $deploymentName"
    Write-Host "Primary location: $primaryLocation"
    Write-Host "Secondary location: $secondaryLocation"
    Write-Host "Application location: $applicationLocation"

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 14 `
        -Name 'Check existing deployment state'

    # Keep the pre-deployment path intentionally fast. The earlier provider
    # sweep added more than a minute before ARM deployment and changed the
    # lifecycle timing. Provider and policy diagnostics are collected only
    # after an actual deployment failure.
    $existingDeployment = Get-AzSubscriptionDeployment `
        -Name $deploymentName `
        -ErrorAction SilentlyContinue

    $preDeploymentSnapshot = [ordered]@{
        Timestamp          = Get-Date -Format o
        DeploymentName     = $deploymentName
        ExistingDeployment = $existingDeployment
    }

    $preDeploymentSnapshot |
        ConvertTo-Json -Depth 30 |
        Set-Content `
            -LiteralPath $preDeploymentSnapshotPath `
            -Encoding UTF8

    Write-Host "Existing deployment found: $($null -ne $existingDeployment)"

    if ($null -ne $existingDeployment) {
        Write-Host (
            "Existing deployment state: " +
            "$($existingDeployment.ProvisioningState)"
        )
    }

    Complete-DiagnosticStep

    Start-DiagnosticStep `
        -Number 15 `
        -Name 'Deploy Azure subscription template'

    # =================================================================
    # DEPLOY IMMEDIATELY
    #
    # Do not run a provider sweep or template validation before the normal
    # deployment call. Those diagnostics materially changed the lifecycle
    # timing. Validation is performed only after a non-transient failure.
    # =================================================================

    $deployment = $existingDeployment

    if (
        $null -eq $deployment -or
        $deployment.ProvisioningState -in @('Failed', 'Canceled')
    ) {
        $deployment = $null
        $deployDelays = @(15, 30, 60)
        $maximumDeployAttempts = 3

        for (
            $deployAttempt = 1;
            $deployAttempt -le $maximumDeployAttempts;
            $deployAttempt++
        ) {
            try {
                Write-Host (
                    "Starting subscription deployment '$deploymentName' " +
                    "(attempt $deployAttempt of $maximumDeployAttempts)..."
                )

                $deployment = New-AzSubscriptionDeployment `
                    -Name $deploymentName `
                    -Location $primaryLocation `
                    -TemplateFile $templateFile `
                    -TemplateParameterObject $templateParameters `
                    -ErrorAction Stop

                break
            }
            catch {
                $deploymentError = $_
                $combinedError = $deploymentError.Exception.Message

                if (
                    $null -ne $deploymentError.ErrorDetails -and
                    -not [string]::IsNullOrWhiteSpace(
                        [string]$deploymentError.ErrorDetails.Message
                    )
                ) {
                    $combinedError += (
                        ' ' +
                        $deploymentError.ErrorDetails.Message
                    )
                }

                if ($null -ne $deploymentError.Exception.InnerException) {
                    $combinedError += (
                        ' ' +
                        $deploymentError.Exception.InnerException.Message
                    )
                }

                # A top-level deployment exception can hide the deepest nested
                # resource failure. Read failed operations only after failure so
                # this diagnostic does not delay the normal deployment path.
                $failedOperationText = ''

                try {
                    $failedOperations = @(
                        Get-AzSubscriptionDeploymentOperation `
                            -DeploymentName $deploymentName `
                            -ErrorAction Stop |
                        Where-Object {
                            $_.ProvisioningState -eq 'Failed'
                        }
                    )

                    $failedOperationText = (
                        $failedOperations |
                            ForEach-Object {
                                if ($null -ne $_.StatusMessage) {
                                    $_.StatusMessage |
                                        ConvertTo-Json -Depth 50 -Compress
                                }
                            }
                    ) -join ' '
                }
                catch {
                    # A validation failure may not create a deployment record.
                    # Preserve the original exception when operations are absent.
                }

                $classificationText = (
                    $combinedError + ' ' + $failedOperationText
                )

                $isTransientTransportFailure = (
                    $classificationText -match 'Connection reset by peer' -or
                    $classificationText -match 'An error occurred while sending the request' -or
                    $classificationText -match 'transport connection' -or
                    $classificationText -match 'The operation has timed out' -or
                    $classificationText -match 'request was canceled' -or
                    $classificationText -match 'temporarily unavailable'
                )

                $isTransientFrontDoorOriginFailure = (
                    $classificationText -match '(?i)InternalError' -and
                    $classificationText -match `
                        '(?i)Microsoft\.Cdn/profiles/.+/originGroups/.+/origins/'
                )

                if ($isTransientTransportFailure) {
                    # The service may have accepted the deployment before the
                    # client connection reset. Check before submitting again.
                    $deployment = Get-AzSubscriptionDeployment `
                        -Name $deploymentName `
                        -ErrorAction SilentlyContinue

                    if ($null -ne $deployment) {
                        Write-Host (
                            "Deployment '$deploymentName' exists after the " +
                            "transport failure with state " +
                            "'$($deployment.ProvisioningState)'."
                        )
                        break
                    }

                    if ($deployAttempt -lt $maximumDeployAttempts) {
                        $delaySeconds = $deployDelays[$deployAttempt - 1]

                        Write-Host (
                            "Transient deployment transport failure: " +
                            "$combinedError"
                        )
                        Write-Host (
                            "Retrying in $delaySeconds seconds..."
                        )

                        Start-Sleep -Seconds $delaySeconds
                        continue
                    }

                    throw
                }

                if ($isTransientFrontDoorOriginFailure) {
                    # Azure Front Door occasionally returns InternalError while
                    # creating the Private Link origin. Most other resources are
                    # already provisioned, so an idempotent retry of the same
                    # subscription deployment is the safest recovery path.
                    $deployment = Get-AzSubscriptionDeployment `
                        -Name $deploymentName `
                        -ErrorAction SilentlyContinue

                    if (
                        $null -ne $deployment -and
                        $deployment.ProvisioningState -notin @(
                            'Failed',
                            'Canceled'
                        )
                    ) {
                        Write-Host (
                            "Deployment '$deploymentName' remains active after " +
                            "the Front Door origin error with state " +
                            "'$($deployment.ProvisioningState)'."
                        )
                        break
                    }

                    if ($deployAttempt -lt $maximumDeployAttempts) {
                        $frontDoorRetryDelaySeconds = 120

                        Write-Host (
                            'Transient Azure Front Door origin InternalError ' +
                            "detected on attempt $deployAttempt."
                        )
                        Write-Host (
                            'Retrying the same idempotent subscription ' +
                            "deployment in $frontDoorRetryDelaySeconds seconds..."
                        )

                        $deployment = $null
                        Start-Sleep -Seconds $frontDoorRetryDelaySeconds
                        continue
                    }

                    throw
                }

                # Preserve fast production timing. Only after the real
                # deployment call fails do we run explicit validation to
                # surface policy, quota, naming, or template details.
                try {
                    $validationResult = Test-AzSubscriptionDeployment `
                        -Location $primaryLocation `
                        -TemplateFile $templateFile `
                        -TemplateParameterObject $templateParameters `
                        -ErrorAction Stop

                    if ($null -ne $validationResult) {
                        $validationText = $validationResult |
                            ConvertTo-Json -Depth 50 -Compress

                        throw (
                            "ARM TEMPLATE VALIDATION FAILED for " +
                            "'$deploymentName'. " +
                            "ValidationResult=$validationText"
                        )
                    }
                }
                catch {
                    if (
                        $_.Exception.Message -like
                        'ARM TEMPLATE VALIDATION FAILED*'
                    ) {
                        throw
                    }

                    $validationDetails = $_.Exception.Message

                    if (
                        $null -ne $_.ErrorDetails -and
                        -not [string]::IsNullOrWhiteSpace(
                            [string]$_.ErrorDetails.Message
                        )
                    ) {
                        $validationDetails += (
                            ' | ErrorDetails=' +
                            $_.ErrorDetails.Message
                        )
                    }

                    throw (
                        "Deployment '$deploymentName' failed. " +
                        "OriginalError=$combinedError | " +
                        "ValidationError=$validationDetails"
                    )
                }

                throw $deploymentError
            }
        }
    }

    if ($null -eq $deployment) {
        throw 'Azure subscription deployment returned no result.'
    }

    if (
        $deployment.ProvisioningState -notin @(
            'Succeeded',
            'Failed',
            'Canceled'
        )
    ) {
        Write-Host (
            "Deployment '$deploymentName' is already active with state " +
            "'$($deployment.ProvisioningState)'. Waiting for completion..."
        )

        for ($attempt = 1; $attempt -le 240; $attempt++) {
            Start-Sleep -Seconds 30

            $deployment = Get-AzSubscriptionDeployment `
                -Name $deploymentName `
                -ErrorAction Stop

            Write-Host (
                "Existing deployment state: " +
                "$($deployment.ProvisioningState) " +
                "(check $attempt of 240)"
            )

            if ($deployment.ProvisioningState -eq 'Succeeded') {
                break
            }

            if (
                $deployment.ProvisioningState -in @(
                    'Failed',
                    'Canceled'
                )
            ) {
                break
            }
        }
    }
    elseif ($deployment.ProvisioningState -eq 'Succeeded') {
        Write-Host (
            "Deployment '$deploymentName' already succeeded. " +
            'Using the existing result.'
        )
    }

    if ($deployment.ProvisioningState -ne 'Succeeded') {
        throw (
            "Deployment '$deploymentName' completed with state " +
            "'$($deployment.ProvisioningState)'."
        )
    }

    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'DAY 2 DEPLOYMENT SUCCEEDED'
    Write-Host '============================================================'
    Write-Host "Lab Instance ID : $environmentName"
    Write-Host "Resource suffix : $skillableSuffix"
    Write-Host "Deployment      : $deploymentName"
    Write-Host '============================================================'

    $deployment |
        ConvertTo-Json -Depth 30 |
        Set-Content `
            -LiteralPath $deploymentResultPath `
            -Encoding UTF8

    Complete-DiagnosticStep

    Write-Host ''
    Write-Host '================ DIAGNOSTIC STEP SUMMARY ================'
    Get-Content -LiteralPath $stepSummaryPath -ErrorAction SilentlyContinue
    Write-Host '========================================================='
    Write-Host "Diagnostic root: $diagnosticRoot"

    return $true
}
catch {
    $capturedError = $_

    if ($null -ne $script:activeStepStopwatch) {
        $script:activeStepStopwatch.Stop()
    }

    $elapsed = if ($null -ne $script:activeStepStopwatch) {
        [math]::Round($script:activeStepStopwatch.Elapsed.TotalSeconds, 3)
    }
    else {
        0
    }

    Write-Host ''
    Write-Host '============================================================'
    Write-Host (
        "STEP {0:D2} FAILED: {1}" -f `
            $script:activeStepNumber, `
            $script:activeStepName
    )
    Write-Host "Elapsed seconds: $elapsed"
    Write-Host "Exception type: $($capturedError.Exception.GetType().FullName)"
    Write-Host "Message: $($capturedError.Exception.Message)"
    Write-Host "Category: $($capturedError.CategoryInfo)"
    Write-Host "Fully qualified error ID: $($capturedError.FullyQualifiedErrorId)"
    Write-Host "Position: $($capturedError.InvocationInfo.PositionMessage)"
    Write-Host "Script stack trace: $($capturedError.ScriptStackTrace)"

    if ($null -ne $capturedError.Exception.InnerException) {
        Write-Host (
            "Inner exception: " +
            $capturedError.Exception.InnerException.Message
        )
    }

    Write-Host '============================================================'

    Write-StepSummary `
        -Message (
            "STEP {0:D2} FAILED: {1}; Seconds={2}; Error={3}" -f `
                $script:activeStepNumber, `
                $script:activeStepName, `
                $elapsed, `
                $capturedError.Exception.Message
        )

    $failure = [ordered]@{
        Timestamp             = Get-Date -Format o
        StepNumber            = $script:activeStepNumber
        StepName              = $script:activeStepName
        ElapsedSeconds        = $elapsed
        ExceptionType         = $capturedError.Exception.GetType().FullName
        Message               = $capturedError.Exception.Message
        InnerException        = if ($null -ne $capturedError.Exception.InnerException) {
            $capturedError.Exception.InnerException.Message
        }
        else {
            $null
        }
        CategoryInfo          = [string]$capturedError.CategoryInfo
        FullyQualifiedErrorId = $capturedError.FullyQualifiedErrorId
        PositionMessage       = $capturedError.InvocationInfo.PositionMessage
        ScriptName            = $capturedError.InvocationInfo.ScriptName
        ScriptLineNumber      = $capturedError.InvocationInfo.ScriptLineNumber
        OffsetInLine          = $capturedError.InvocationInfo.OffsetInLine
        Line                  = $capturedError.InvocationInfo.Line
        ScriptStackTrace      = $capturedError.ScriptStackTrace
        ActiveTranscript      = $script:activeTranscriptPath
        DiagnosticRoot        = $diagnosticRoot
    }

    $failure |
        ConvertTo-Json -Depth 20 |
        Set-Content `
            -LiteralPath $failurePath `
            -Encoding UTF8

    if ($script:transcriptActive) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        $script:transcriptActive = $false
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$deploymentName)) {
        Export-AzureDeploymentDiagnostics `
            -DeploymentName $deploymentName
    }

    Write-Host ''
    Write-Host '================ DIAGNOSTIC STEP SUMMARY ================'
    Get-Content -LiteralPath $stepSummaryPath -ErrorAction SilentlyContinue
    Write-Host '========================================================='

    Write-Host ''
    Write-Host '================ FAILURE.JSON ============================'
    Get-Content -LiteralPath $failurePath -ErrorAction SilentlyContinue
    Write-Host '========================================================='

    if (
        -not [string]::IsNullOrWhiteSpace(
            [string]$script:activeTranscriptPath
        ) -and
        (Test-Path -LiteralPath $script:activeTranscriptPath -PathType Leaf)
    ) {
        Write-Host ''
        Write-Host '========== ACTIVE STEP TRANSCRIPT - LAST 250 LINES ======='
        Get-Content `
            -LiteralPath $script:activeTranscriptPath `
            -Tail 250 `
            -ErrorAction SilentlyContinue
        Write-Host '========================================================='
    }

    Write-Host "Diagnostic root: $diagnosticRoot"

    # =================================================================
    # SURFACE DIAGNOSTICS THROUGH SKILLABLE ERROR MESSAGE
    #
    # Skillable's LCA runner filesystem is isolated from the learner
    # Cloud Shell. The Errors table does expose the thrown exception
    # message, so build a compact failure transcript and throw that
    # instead of the original generic Azure wrapper error.
    # =================================================================

    $visibleLines = New-Object System.Collections.Generic.List[string]

    $visibleLines.Add((
        "STEP {0:D2} FAILED: {1}" -f `
            $script:activeStepNumber, `
            $script:activeStepName
    ))

    $visibleLines.Add("Exception: $($capturedError.Exception.Message)")

    if ($null -ne $capturedError.Exception.InnerException) {
        $visibleLines.Add(
            "Inner: $($capturedError.Exception.InnerException.Message)"
        )
    }

    $visibleLines.Add(
        "At line $($capturedError.InvocationInfo.ScriptLineNumber): " +
        "$($capturedError.InvocationInfo.Line)"
    )

    if (Test-Path -LiteralPath $stepSummaryPath -PathType Leaf) {
        $visibleLines.Add('Recent steps:')

        $recentSummary = @(
            Get-Content `
                -LiteralPath $stepSummaryPath `
                -Tail 20 `
                -ErrorAction SilentlyContinue
        )

        foreach ($summaryLine in $recentSummary) {
            $visibleLines.Add([string]$summaryLine)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$deploymentName)) {
        try {
            $failedOperationsForError = @(
                Get-AzSubscriptionDeploymentOperation `
                    -DeploymentName $deploymentName `
                    -ErrorAction Stop |
                Where-Object {
                    $_.ProvisioningState -eq 'Failed'
                }
            )

            if ($failedOperationsForError.Count -gt 0) {
                $visibleLines.Add('Failed Azure operations:')

                foreach ($operation in $failedOperationsForError) {
                    $resourceName = [string]$operation.TargetResource.ResourceName
                    $resourceType = [string]$operation.TargetResource.ResourceType
                    $statusText = ''

                    if ($null -ne $operation.StatusMessage) {
                        try {
                            $statusText = (
                                $operation.StatusMessage |
                                    ConvertTo-Json -Depth 12 -Compress
                            )
                        }
                        catch {
                            $statusText = [string]$operation.StatusMessage
                        }
                    }

                    $visibleLines.Add(
                        "Resource=$resourceName; Type=$resourceType; " +
                        "Message=$statusText"
                    )
                }
            }
        }
        catch {
            $visibleLines.Add(
                "Unable to query failed deployment operations: " +
                $_.Exception.Message
            )
        }
    }

    $visibleMessage = $visibleLines -join ' | '

    # Keep the thrown message compact enough for the Skillable Errors
    # table while retaining the most useful failure context.
    $maxVisibleLength = 12000

    if ($visibleMessage.Length -gt $maxVisibleLength) {
        $visibleMessage = `
            $visibleMessage.Substring(0, $maxVisibleLength) + `
            ' | [diagnostic message truncated]'
    }

    throw $visibleMessage
}
finally {

    if ($script:transcriptActive) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        $script:transcriptActive = $false
    }

    # =================================================================
    # CLEAR SENSITIVE / RUNTIME VALUES
    # =================================================================

    $vmAdminPassword = $null
    $user1ObjectId = $null

    # =================================================================
    # RESTORE PATH
    # =================================================================

    $env:PATH = $originalPath

    # =================================================================
    # CLEANUP TEMPORARY FILES
    # =================================================================

    if (
        -not [string]::IsNullOrWhiteSpace(
            [string]$workingDirectory
        ) -and
        (Test-Path -LiteralPath $workingDirectory)
    ) {

        Remove-Item `
            -LiteralPath $workingDirectory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
