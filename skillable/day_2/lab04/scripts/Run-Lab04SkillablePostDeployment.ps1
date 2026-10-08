param(
    [Parameter(Mandatory)][string]$subscriptionId,
    [AllowEmptyString()][string]$tenantId,
    [Parameter(Mandatory)][string]$labInstanceId,
    [Parameter(Mandatory)][string]$user1Upn,
    [Parameter(Mandatory)][string]$user1Password
)

# =====================================================================

# RUN LAB04 POST-DEPLOYMENT - v5.2 (Skillable Repeat-aware / resilient)

# Skillable Event: First Displayable

# Action: Execute Script in Cloud Platform

#

# This wrapper preserves the customer's post-deployment script, but provides

# a small Azure CLI compatibility layer backed by the authenticated Az

# PowerShell context. It also pre-stages Microsoft's self-contained SqlPackage

# so the LCA does not require Azure CLI, curl/wget, or a .NET SDK.

# =====================================================================

# Skillable settings for this v5.2 wrapper:
#   Event: First Displayable
#   Delay: 1800 seconds
#   Timeout: 1 hour
#   Repeat: every 300 seconds until true for up to 40 minutes
#   Retries: 0
#   Error Action: Log

Set-StrictMode -Version Latest

# Keep cmdlet errors terminating inside each guarded step so they can be caught.
# Retryable runtime failures are converted to $false at the post-deployment
# boundaries below. A syntax error in THIS wrapper cannot be caught because
# PowerShell must parse the wrapper before execution starts.
$ErrorActionPreference = 'Stop'

$ProgressPreference = 'SilentlyContinue'

$VerbosePreference = 'SilentlyContinue'

$DebugPreference = 'SilentlyContinue'

$InformationPreference = 'SilentlyContinue'

$WarningPreference = 'SilentlyContinue'

$ConfirmPreference = 'None'

function Assert-LabValue {

    param(

        [Parameter(Mandatory)][string]$Name,

        [AllowEmptyString()][string]$Value

    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Trim().StartsWith('@lab.')) {

        throw "Required Skillable value '$Name' did not resolve."

    }

}

Assert-LabValue -Name 'CloudSubscription.Id' -Value $subscriptionId

Assert-LabValue -Name 'LabInstance.Id' -Value $labInstanceId

Assert-LabValue -Name 'CloudPortalCredential(User1).Username' -Value $user1Upn

Assert-LabValue -Name 'CloudPortalCredential(User1).Password' -Value $user1Password

Import-Module Az.Accounts -ErrorAction Stop

Import-Module Az.Resources -ErrorAction Stop

if (-not (Get-AzContext)) {

    throw 'No authenticated Az context exists. Use Execute Script in Cloud Platform for this LCA.'

}

Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null

$currentContext = Get-AzContext

if ($currentContext.Subscription.Id -ne $subscriptionId) {

    throw "The active Azure subscription '$($currentContext.Subscription.Id)' does not match '$subscriptionId'."

}

if ([string]::IsNullOrWhiteSpace($tenantId) -or $tenantId.StartsWith('@lab.')) {

    $tenantId = [string]$currentContext.Tenant.Id

}

Write-Host "Lab04 post-deployment starting for lab instance $labInstanceId."

Write-Host "Using Skillable's authenticated Az PowerShell context for Azure control-plane operations."

function Get-Lab04FoundationDeployment {

    $candidate = @(

        Get-AzDeployment -ErrorAction Stop |

            Where-Object { $_.DeploymentName -like "*$labInstanceId*" } |

            Sort-Object Timestamp -Descending

    ) | Select-Object -First 1

    return $candidate

}

function Get-Lab04FoundationFailureText {

    param([Parameter(Mandatory)][object]$Deployment)

    $details = ''

    if ($Deployment.Error) {

        try {

            $details = $Deployment.Error | ConvertTo-Json -Depth 30 -Compress

        }

        catch {

            $details = [string]$Deployment.Error

        }

    }

    return $details

}

function Assert-Lab04FoundationNotFailed {

    $candidate = Get-Lab04FoundationDeployment

    if (-not $candidate) {

        return

    }

    $state = [string]$candidate.ProvisioningState

    if ($state -in @('Failed', 'Canceled', 'Cancelled')) {

        $details = Get-Lab04FoundationFailureText -Deployment $candidate

        throw "Foundation deployment '$($candidate.DeploymentName)' is '$state'. Post-deployment cannot continue. ARM error: $details"

    }

}

# ---------------------------------------------------------------------
# Repeat-aware foundation readiness gate.
# Skillable handles the waiting. This invocation checks once and returns
# $false when Azure is still deploying.
# ---------------------------------------------------------------------

$foundationDeployment = Get-Lab04FoundationDeployment

if (-not $foundationDeployment) {
    Write-Host "Foundation subscription deployment for lab instance '$labInstanceId' has not appeared yet. Returning false so Skillable can retry."
    return $false
}

$foundationState = [string]$foundationDeployment.ProvisioningState

if ($foundationState -in @('Failed', 'Canceled', 'Cancelled')) {
    $details = Get-Lab04FoundationFailureText -Deployment $foundationDeployment
    throw "Foundation deployment '$($foundationDeployment.DeploymentName)' is '$foundationState'. Post-deployment cannot continue. ARM error: $details"
}

if ($foundationState -ne 'Succeeded') {
    Write-Host "Foundation deployment '$($foundationDeployment.DeploymentName)' is '$foundationState'. Returning false so Skillable can retry."
    return $false
}

Write-Host "Foundation deployment '$($foundationDeployment.DeploymentName)' succeeded. Continuing with post-deployment."

$workRoot = Join-Path ([IO.Path]::GetTempPath()) "lab04-postdeploy-$labInstanceId"

New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

# ---------------------------------------------------------------------

# Pre-stage the customer's pinned SqlPackage as Microsoft's standalone,

# self-contained ZIP package.

#

# This intentionally avoids BOTH Azure CLI and the .NET SDK on the Skillable

# LCA worker. The customer's script checks its SqlPackage cache first; when

# the expected executable is already present and reports version 170.5.96,

# Resolve-Lab04SqlPackage returns it without running "dotnet tool install".

# ---------------------------------------------------------------------

$customerSqlPackageVersion = '170.5.96'

$sqlPackageVersion = $customerSqlPackageVersion

function Get-Lab04StandaloneToolCacheRoot {

    $basePath = [Environment]::GetFolderPath(

        [Environment+SpecialFolder]::LocalApplicationData

    )

    if ([string]::IsNullOrWhiteSpace($basePath)) {

        $basePath = Join-Path $HOME '.cache'

    }

    return Join-Path $basePath 'modernize-bootcamp'

}

function Get-Lab04SqlPackageVersion {

    param([Parameter(Mandatory)][string]$ExecutablePath)

    $previousErrorActionPreference = $ErrorActionPreference

    $ErrorActionPreference = 'Continue'

    try {

        $versionOutput = @(& $ExecutablePath /Version 2>&1)

        $exitCode = $LASTEXITCODE

    }

    finally {

        $ErrorActionPreference = $previousErrorActionPreference

    }

    if ($exitCode -ne 0) {

        return $null

    }

    return (($versionOutput | Select-Object -First 1) | Out-String).Trim()

}

try {

$toolCacheRoot = Get-Lab04StandaloneToolCacheRoot

$sqlPackageCachePath = Join-Path `
    (Join-Path `
        (Join-Path `
            (Join-Path $toolCacheRoot '.azure') `
            'tools') `
        'sqlpackage') `
    $sqlPackageVersion

$isWindowsRuntime = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(

    [Runtime.InteropServices.OSPlatform]::Windows

)

$sqlPackageExecutableName = if ($isWindowsRuntime) { 'sqlpackage.exe' } else { 'sqlpackage' }

$sqlPackageExecutablePath = Join-Path $sqlPackageCachePath $sqlPackageExecutableName

$cachedVersion = $null

if (Test-Path -LiteralPath $sqlPackageExecutablePath -PathType Leaf) {

    if (-not $isWindowsRuntime) {

        try {

            & chmod 'a+x' $sqlPackageExecutablePath

            if ($LASTEXITCODE -ne 0) {

                throw "chmod returned exit code $LASTEXITCODE."

            }

        }

        catch {

            throw "Existing SqlPackage executable could not be made executable: $($_.Exception.Message)"

        }

    }

    $cachedVersion = Get-Lab04SqlPackageVersion -ExecutablePath $sqlPackageExecutablePath

}

if ($cachedVersion -notmatch "^$([regex]::Escape($sqlPackageVersion))(?:\.0)?$") {

    Write-Host "Preparing standalone SqlPackage $sqlPackageVersion for the customer post-deployment script."

    if (Test-Path -LiteralPath $sqlPackageCachePath) {

        Remove-Item -LiteralPath $sqlPackageCachePath -Recurse -Force -ErrorAction Stop

    }

    $sqlPackageParent = Split-Path -Parent $sqlPackageCachePath

    New-Item -ItemType Directory -Path $sqlPackageParent -Force | Out-Null

    $sqlPackageZip = Join-Path $workRoot 'sqlpackage.zip'

    $sqlPackageExtract = Join-Path $workRoot 'sqlpackage-extract'

    if (Test-Path -LiteralPath $sqlPackageZip) {

        Remove-Item -LiteralPath $sqlPackageZip -Force -ErrorAction SilentlyContinue

    }

    if (Test-Path -LiteralPath $sqlPackageExtract) {

        Remove-Item -LiteralPath $sqlPackageExtract -Recurse -Force -ErrorAction SilentlyContinue

    }

    New-Item -ItemType Directory -Path $sqlPackageExtract -Force | Out-Null

    $sqlPackageDownloadUrl = if ($isWindowsRuntime) {

        'https://aka.ms/sqlpackage-windows'

    }

    else {

        'https://aka.ms/sqlpackage-linux'

    }

    Invoke-WebRequest `
        -Uri $sqlPackageDownloadUrl `
        -OutFile $sqlPackageZip `
        -UseBasicParsing `
        -MaximumRedirection 10 `
        -TimeoutSec 300 `
        -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $sqlPackageZip -PathType Leaf)) {

        throw 'Standalone SqlPackage download did not produce a ZIP file.'

    }

    if ((Get-Item -LiteralPath $sqlPackageZip).Length -lt 1000000) {

        throw 'Standalone SqlPackage download is unexpectedly small.'

    }

    try {

        [IO.Compression.ZipFile]::ExtractToDirectory(

            $sqlPackageZip,

            $sqlPackageExtract

        )

    }

    catch {

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        [IO.Compression.ZipFile]::ExtractToDirectory(

            $sqlPackageZip,

            $sqlPackageExtract

        )

    }

    $candidate = Get-ChildItem `
        -LiteralPath $sqlPackageExtract `
        -Recurse `
        -File `
        -Filter $sqlPackageExecutableName `
        -ErrorAction Stop | Select-Object -First 1

    if (-not $candidate) {

        throw "Standalone SqlPackage ZIP did not contain '$sqlPackageExecutableName'."

    }

    # The official archive currently places the executable at its root, but copy

    # from the executable's directory so this remains safe if Microsoft adds a

    # single top-level folder in a later archive.

    New-Item -ItemType Directory -Path $sqlPackageCachePath -Force | Out-Null

    Get-ChildItem -LiteralPath $candidate.Directory.FullName -Force | ForEach-Object {

        Copy-Item `
            -LiteralPath $_.FullName `
            -Destination $sqlPackageCachePath `
            -Recurse `
            -Force

    }

    if (-not (Test-Path -LiteralPath $sqlPackageExecutablePath -PathType Leaf)) {

        throw "SqlPackage extraction did not produce '$sqlPackageExecutablePath'."

    }

    if (-not $isWindowsRuntime) {

        & chmod 'a+x' $sqlPackageExecutablePath

        if ($LASTEXITCODE -ne 0) {

            throw "chmod failed for SqlPackage with exit code $LASTEXITCODE."

        }

    }

    $cachedVersion = Get-Lab04SqlPackageVersion -ExecutablePath $sqlPackageExecutablePath

}

if ([string]::IsNullOrWhiteSpace($cachedVersion)) {

    throw 'Standalone SqlPackage did not report a version.'

}

if ($cachedVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {

    throw "Standalone SqlPackage reported an unexpected version string '$cachedVersion'."

}

# Microsoft's evergreen standalone link can lag the version advertised by the

# documentation / NuGet tool feed. Use the exact official standalone version

# actually returned by Microsoft, and align only the downloaded runtime copy of

# the customer script to that version. The customer repository is not modified.

if ($cachedVersion -notmatch "^$([regex]::Escape($sqlPackageVersion))(?:\.0)?$") {

    Write-Host "Microsoft standalone SqlPackage returned '$cachedVersion' while the customer script pins '$sqlPackageVersion'. Aligning the runtime copy to the official standalone version."

    $effectiveSqlPackageVersion = $cachedVersion

    $effectiveSqlPackageCachePath = Join-Path `
        (Join-Path `
            (Join-Path `
                (Join-Path $toolCacheRoot '.azure') `
                'tools') `
            'sqlpackage') `
        $effectiveSqlPackageVersion

    if (-not $sqlPackageCachePath.Equals($effectiveSqlPackageCachePath, [StringComparison]::OrdinalIgnoreCase)) {

        if (Test-Path -LiteralPath $effectiveSqlPackageCachePath) {

            Remove-Item -LiteralPath $effectiveSqlPackageCachePath -Recurse -Force -ErrorAction Stop

        }

        Move-Item -LiteralPath $sqlPackageCachePath -Destination $effectiveSqlPackageCachePath -Force

        $sqlPackageCachePath = $effectiveSqlPackageCachePath

        $sqlPackageVersion = $effectiveSqlPackageVersion

        $sqlPackageExecutablePath = Join-Path $sqlPackageCachePath $sqlPackageExecutableName

    }

}

Write-Host "Standalone SqlPackage ready: $cachedVersion"

}
catch {

    Write-Host "SqlPackage preparation hit an error: $($_.Exception.Message)"
    Write-Host 'Returning false so Skillable Repeat can retry instead of terminating the lifecycle action.'
    return $false

}

# ---------------------------------------------------------------------

# Helpers used by the Azure CLI compatibility function.

# ---------------------------------------------------------------------

$global:Lab04LcaSubscriptionId = $subscriptionId

$global:Lab04LcaTenantId = $tenantId

$global:Lab04LcaUser1Upn = $user1Upn

$global:Lab04LcaUser1Password = $user1Password

$global:Lab04LcaControlContext = Get-AzContext

function global:Get-Lab04CliOption {

    param(

        [Parameter(Mandatory)][object[]]$Arguments,

        [Parameter(Mandatory)][string]$Name

    )

    for ($i = 0; $i -lt $Arguments.Count; $i++) {

        if ([string]$Arguments[$i] -eq $Name) {

            if ($i + 1 -ge $Arguments.Count) {

                throw "Missing value after CLI option '$Name'."

            }

            return [string]$Arguments[$i + 1]

        }

    }

    return $null

}

function global:Test-Lab04CliOption {

    param(

        [Parameter(Mandatory)][object[]]$Arguments,

        [Parameter(Mandatory)][string]$Name

    )

    return (@($Arguments | Where-Object { [string]$_ -eq $Name }).Count -gt 0)

}

function global:Invoke-Lab04ArmJson {

    param(

        [Parameter(Mandatory)][ValidateSet('GET','PUT','PATCH','POST','DELETE')][string]$Method,

        [Parameter(Mandatory)][string]$Path,

        [AllowNull()][object]$Body

    )

    $invokeArgs = @{

        Method      = $Method

        Path        = $Path

        ErrorAction = 'Stop'

    }

    if ($null -ne $Body) {

        $invokeArgs.Payload = ConvertTo-Json -InputObject $Body -Depth 100 -Compress

    }

    $response = Invoke-AzRestMethod @invokeArgs

    if ($null -eq $response -or [string]::IsNullOrWhiteSpace([string]$response.Content)) {

        return $null

    }

    return ($response.Content | ConvertFrom-Json -Depth 100)

}

function global:ConvertFrom-Lab04SecureToken {

    param([Parameter(Mandatory)][object]$Token)

    if ($Token -is [Security.SecureString]) {

        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)

        try {

            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)

        }

        finally {

            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)

        }

    }

    return [string]$Token

}

function global:Get-Lab04UserSqlToken {

    $originalContext = Get-AzContext

    $contextName = "Lab04PostDeployUser-$([guid]::NewGuid().ToString('N'))"

    $securePassword = ConvertTo-SecureString `
        -String $global:Lab04LcaUser1Password `
        -AsPlainText `
        -Force

    $credential = [pscredential]::new(

        $global:Lab04LcaUser1Upn,

        $securePassword

    )

    try {

        Write-Host 'Acquiring Azure SQL token as User1 for the BACPAC import.'

        Connect-AzAccount `
            -Tenant $global:Lab04LcaTenantId `
            -Subscription $global:Lab04LcaSubscriptionId `
            -Credential $credential `
            -Scope Process `
            -ContextName $contextName `
            -ErrorAction Stop | Out-Null

        $tokenResult = Get-AzAccessToken `
            -ResourceUrl 'https://database.windows.net/' `
            -ErrorAction Stop

        $token = ConvertFrom-Lab04SecureToken -Token $tokenResult.Token

        if ([string]::IsNullOrWhiteSpace($token)) {

            throw 'User1 authentication succeeded, but Azure SQL returned an empty access token.'

        }

        return $token

    }

    finally {

        if ($null -ne $originalContext) {

            Set-AzContext -Context $originalContext -ErrorAction SilentlyContinue | Out-Null

        }

        else {

            Set-AzContext -SubscriptionId $global:Lab04LcaSubscriptionId -ErrorAction SilentlyContinue | Out-Null

        }

    }

}

# ---------------------------------------------------------------------

# Azure CLI compatibility layer.

#

# The customer's script is intentionally left unchanged. Its exact az calls

# are translated here to Az PowerShell / ARM REST calls using Skillable's

# already-authenticated cloud context.

# ---------------------------------------------------------------------

function global:az {

    param(

        [Parameter(ValueFromRemainingArguments = $true)]

        [object[]]$CliArguments

    )

    if ($CliArguments.Count -lt 2) {

        throw "Unsupported Azure CLI call: az $($CliArguments -join ' ')"

    }

    $group = [string]$CliArguments[0]

    $operation = [string]$CliArguments[1]

    # az group list --query '[].name' --output tsv

    if ($group -eq 'group' -and $operation -eq 'list') {

        $groups = @(Get-AzResourceGroup -ErrorAction Stop | Select-Object -ExpandProperty ResourceGroupName)

        $groups | ForEach-Object { Write-Output $_ }

        return

    }

    # az deployment group list/show

    if ($group -eq 'deployment' -and $operation -eq 'group') {

        $verb = [string]$CliArguments[2]

        $resourceGroup = Get-Lab04CliOption -Arguments $CliArguments -Name '--resource-group'

        if ([string]::IsNullOrWhiteSpace($resourceGroup)) {

            throw 'Azure CLI compatibility layer requires --resource-group for deployment group calls.'

        }

        $encodedRg = [Uri]::EscapeDataString($resourceGroup)

        $basePath = "/subscriptions/$global:Lab04LcaSubscriptionId/resourceGroups/$encodedRg/providers/Microsoft.Resources/deployments"

        if ($verb -eq 'show') {

            $name = Get-Lab04CliOption -Arguments $CliArguments -Name '--name'

            $encodedName = [Uri]::EscapeDataString($name)

            $deployment = Invoke-Lab04ArmJson `
                -Method GET `
                -Path "$basePath/$encodedName?api-version=2025-04-01"

            $deployment | ConvertTo-Json -Depth 100 -Compress

            return

        }

        if ($verb -eq 'list') {

            $result = Invoke-Lab04ArmJson `
                -Method GET `
                -Path "$basePath?api-version=2025-04-01"

            $deployments = @($result.value)

            $query = Get-Lab04CliOption -Arguments $CliArguments -Name '--query'

            if ($query -and $query -match 'provisioningState.*Succeeded') {

                $deployments = @($deployments | Where-Object { $_.properties.provisioningState -eq 'Succeeded' })

            }

            $deployments | ConvertTo-Json -Depth 100 -Compress

            return

        }

    }

    # az network private-endpoint-connection list/approve/show

    if ($group -eq 'network' -and $operation -eq 'private-endpoint-connection') {

        $verb = [string]$CliArguments[2]

        $id = Get-Lab04CliOption -Arguments $CliArguments -Name '--id'

        if ([string]::IsNullOrWhiteSpace($id)) {

            throw 'Azure CLI compatibility layer requires --id for private-endpoint-connection calls.'

        }

        if ($verb -eq 'list') {

            $result = Invoke-Lab04ArmJson `
                -Method GET `
                -Path "$id/privateEndpointConnections?api-version=2025-07-01"

            @($result.value) | ConvertTo-Json -Depth 100 -Compress

            return

        }

        if ($verb -eq 'approve') {

            $description = Get-Lab04CliOption -Arguments $CliArguments -Name '--description'

            $body = @{

                properties = @{

                    privateLinkServiceConnectionState = @{

                        status          = 'Approved'

                        description     = $description

                        actionsRequired = 'None'

                    }

                }

            }

            Invoke-Lab04ArmJson `
                -Method PUT `
                -Path "$id?api-version=2025-07-01" `
                -Body $body | Out-Null

            return

        }

        if ($verb -eq 'show') {

            $result = Invoke-Lab04ArmJson `
                -Method GET `
                -Path "$id?api-version=2025-07-01"

            $query = Get-Lab04CliOption -Arguments $CliArguments -Name '--query'

            $output = Get-Lab04CliOption -Arguments $CliArguments -Name '--output'

            if ($query -eq 'properties.privateLinkServiceConnectionState.status' -and $output -eq 'tsv') {

                Write-Output ([string]$result.properties.privateLinkServiceConnectionState.status)

                return

            }

            $result | ConvertTo-Json -Depth 100 -Compress

            return

        }

    }

    # az resource show --ids ... --api-version ... --query properties.hostName --output tsv

    if ($group -eq 'resource' -and $operation -eq 'show') {

        $id = Get-Lab04CliOption -Arguments $CliArguments -Name '--ids'

        $apiVersion = Get-Lab04CliOption -Arguments $CliArguments -Name '--api-version'

        $query = Get-Lab04CliOption -Arguments $CliArguments -Name '--query'

        $output = Get-Lab04CliOption -Arguments $CliArguments -Name '--output'

        $result = Invoke-Lab04ArmJson -Method GET -Path "$id?api-version=$apiVersion"

        if ($query -eq 'properties.hostName' -and $output -eq 'tsv') {

            Write-Output ([string]$result.properties.hostName)

            return

        }

        $result | ConvertTo-Json -Depth 100 -Compress

        return

    }

    # az containerapp update/show

    if ($group -eq 'containerapp') {

        $verb = $operation

        $resourceGroup = Get-Lab04CliOption -Arguments $CliArguments -Name '--resource-group'

        $name = Get-Lab04CliOption -Arguments $CliArguments -Name '--name'

        $encodedRg = [Uri]::EscapeDataString($resourceGroup)

        $encodedName = [Uri]::EscapeDataString($name)

        $path = "/subscriptions/$global:Lab04LcaSubscriptionId/resourceGroups/$encodedRg/providers/Microsoft.App/containerApps/$encodedName?api-version=2024-03-01"

        if ($verb -eq 'show') {

            $app = Invoke-Lab04ArmJson -Method GET -Path $path

            $query = Get-Lab04CliOption -Arguments $CliArguments -Name '--query'

            if ($query -eq 'properties.template.containers[0].env') {

                @($app.properties.template.containers[0].env) | ConvertTo-Json -Depth 100 -Compress

                return

            }

            $app | ConvertTo-Json -Depth 100 -Compress

            return

        }

        if ($verb -eq 'update') {

            $app = Invoke-Lab04ArmJson -Method GET -Path $path

            $setIndex = -1

            for ($i = 0; $i -lt $CliArguments.Count; $i++) {

                if ([string]$CliArguments[$i] -eq '--set-env-vars') {

                    $setIndex = $i

                    break

                }

            }

            if ($setIndex -lt 0) {

                throw 'containerapp update call did not include --set-env-vars.'

            }

            $assignments = [System.Collections.Generic.List[string]]::new()

            for ($i = $setIndex + 1; $i -lt $CliArguments.Count; $i++) {

                $value = [string]$CliArguments[$i]

                if ($value.StartsWith('--')) {

                    break

                }

                $assignments.Add($value)

            }

            $container = $app.properties.template.containers[0]

            $envItems = [System.Collections.Generic.List[object]]::new()

            foreach ($entry in @($container.env)) {

                $envItems.Add($entry)

            }

            foreach ($assignment in $assignments) {

                $pair = $assignment -split '=', 2

                if ($pair.Count -ne 2) {

                    throw "Invalid environment variable assignment '$assignment'."

                }

                $envName = $pair[0]

                $envValue = $pair[1]

                $existing = @($envItems | Where-Object { $_.name -eq $envName })

                if ($existing.Count -gt 0) {

                    foreach ($item in $existing) {

                        if ($item.PSObject.Properties['secretRef']) {

                            $item.PSObject.Properties.Remove('secretRef')

                        }

                        $item.value = $envValue

                    }

                }

                else {

                    $envItems.Add([pscustomobject]@{

                        name  = $envName

                        value = $envValue

                    })

                }

            }

            $container.env = @($envItems)

            $payload = @{

                properties = @{

                    template = @{

                        containers = @($app.properties.template.containers)

                    }

                }

            }

            Invoke-Lab04ArmJson -Method PATCH -Path $path -Body $payload | Out-Null

            return

        }

    }

    # az account show / get-access-token

    if ($group -eq 'account') {

        if ($operation -eq 'show') {

            $context = Get-AzContext

            $result = [ordered]@{

                id = [string]$global:Lab04LcaSubscriptionId

                user = [ordered]@{

                    name = [string]$context.Account.Id

                }

            }

            $result | ConvertTo-Json -Depth 10 -Compress

            return

        }

        if ($operation -eq 'get-access-token') {

            $resource = Get-Lab04CliOption -Arguments $CliArguments -Name '--resource'

            if ($resource -ne 'https://database.windows.net/') {

                throw "Unsupported token resource '$resource'."

            }

            $token = Get-Lab04UserSqlToken

            Write-Output $token

            return

        }

    }

    # az sql midb list/delete

    if ($group -eq 'sql' -and $operation -eq 'midb') {

        $verb = [string]$CliArguments[2]

        $resourceGroup = Get-Lab04CliOption -Arguments $CliArguments -Name '--resource-group'

        $managedInstance = Get-Lab04CliOption -Arguments $CliArguments -Name '--managed-instance'

        $encodedRg = [Uri]::EscapeDataString($resourceGroup)

        $encodedMi = [Uri]::EscapeDataString($managedInstance)

        $basePath = "/subscriptions/$global:Lab04LcaSubscriptionId/resourceGroups/$encodedRg/providers/Microsoft.Sql/managedInstances/$encodedMi/databases"

        if ($verb -eq 'list') {

            $result = Invoke-Lab04ArmJson -Method GET -Path "$basePath?api-version=2023-08-01"

            $databases = @($result.value)

            $query = Get-Lab04CliOption -Arguments $CliArguments -Name '--query'

            if ($query -match "\[\?name=='([^']+)'\] \| length\(@\)") {

                $databaseName = $Matches[1]

                Write-Output (@($databases | Where-Object { $_.name -eq $databaseName }).Count)

                return

            }

            $databases | ConvertTo-Json -Depth 100 -Compress

            return

        }

        if ($verb -eq 'delete') {

            $name = Get-Lab04CliOption -Arguments $CliArguments -Name '--name'

            $encodedDb = [Uri]::EscapeDataString($name)

            Invoke-Lab04ArmJson `
                -Method DELETE `
                -Path "$basePath/$encodedDb?api-version=2023-08-01" | Out-Null

            return

        }

    }

    # az network nsg rule create/delete

    if ($group -eq 'network' -and $operation -eq 'nsg' -and [string]$CliArguments[2] -eq 'rule') {

        $verb = [string]$CliArguments[3]

        $resourceGroup = Get-Lab04CliOption -Arguments $CliArguments -Name '--resource-group'

        $nsgName = Get-Lab04CliOption -Arguments $CliArguments -Name '--nsg-name'

        $ruleName = Get-Lab04CliOption -Arguments $CliArguments -Name '--name'

        $encodedRg = [Uri]::EscapeDataString($resourceGroup)

        $encodedNsg = [Uri]::EscapeDataString($nsgName)

        $encodedRule = [Uri]::EscapeDataString($ruleName)

        $path = "/subscriptions/$global:Lab04LcaSubscriptionId/resourceGroups/$encodedRg/providers/Microsoft.Network/networkSecurityGroups/$encodedNsg/securityRules/$encodedRule?api-version=2024-05-01"

        if ($verb -eq 'create') {

            $body = @{

                properties = @{

                    priority                     = [int](Get-Lab04CliOption -Arguments $CliArguments -Name '--priority')

                    access                       = Get-Lab04CliOption -Arguments $CliArguments -Name '--access'

                    direction                    = Get-Lab04CliOption -Arguments $CliArguments -Name '--direction'

                    protocol                     = Get-Lab04CliOption -Arguments $CliArguments -Name '--protocol'

                    sourceAddressPrefix          = Get-Lab04CliOption -Arguments $CliArguments -Name '--source-address-prefixes'

                    sourcePortRange              = Get-Lab04CliOption -Arguments $CliArguments -Name '--source-port-ranges'

                    destinationAddressPrefix     = Get-Lab04CliOption -Arguments $CliArguments -Name '--destination-address-prefixes'

                    destinationPortRange         = Get-Lab04CliOption -Arguments $CliArguments -Name '--destination-port-ranges'

                    description                  = Get-Lab04CliOption -Arguments $CliArguments -Name '--description'

                }

            }

            Invoke-Lab04ArmJson -Method PUT -Path $path -Body $body | Out-Null

            return

        }

        if ($verb -eq 'delete') {

            Invoke-Lab04ArmJson -Method DELETE -Path $path | Out-Null

            return

        }

    }

    throw "Unsupported Azure CLI call from customer script: az $($CliArguments -join ' ')"

}

# ---------------------------------------------------------------------

# Validate the downloaded/patched CHILD script before invoking it. This catches
# parser errors in the dynamic customer script and turns them into $false so
# Skillable Repeat can retry instead of terminating the LCA.

# ---------------------------------------------------------------------

function Test-Lab04PowerShellFileSyntax {

    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if (@($parseErrors).Count -eq 0) {
        return $true
    }

    Write-Host "PowerShell syntax validation failed for '$Path'."
    foreach ($parseError in @($parseErrors)) {
        Write-Host ("Line {0}, column {1}: {2}" -f $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
    }

    return $false

}

# ---------------------------------------------------------------------

# Download the customer's current script and BACPAC.

# ---------------------------------------------------------------------

$postDeployScript = Join-Path $workRoot 'Invoke-Lab04PostDeploymentFromResourceGroups.ps1'

$bacpacPath = Join-Path $workRoot 'eshop.bacpac'

$scriptUrl = 'https://raw.githubusercontent.com/Azure-Samples/modernize-bootcamp/main/skillable/day_2/bootcamp_deployment/assets/scripts/Invoke-Lab04PostDeploymentFromResourceGroups.ps1'

$bacpacUrl = 'https://raw.githubusercontent.com/Azure-Samples/modernize-bootcamp/main/data/eshop.bacpac'

try {

Write-Host 'Downloading customer post-deployment script.'

Invoke-WebRequest `
    -Uri $scriptUrl `
    -OutFile $postDeployScript `
    -UseBasicParsing `
    -Headers @{ 'Cache-Control' = 'no-cache' } `
    -TimeoutSec 180

Write-Host 'Downloading eShop BACPAC.'

Invoke-WebRequest `
    -Uri $bacpacUrl `
    -OutFile $bacpacPath `
    -UseBasicParsing `
    -Headers @{ 'Cache-Control' = 'no-cache' } `
    -TimeoutSec 180

}
catch {

    Write-Host "Customer script/BACPAC download hit an error: $($_.Exception.Message)"
    Write-Host 'Returning false so Skillable Repeat can retry instead of terminating the lifecycle action.'
    return $false

}

if (-not (Test-Path -LiteralPath $postDeployScript -PathType Leaf)) {

    Write-Host 'Customer post-deployment script was not downloaded. Returning false so Skillable Repeat can retry.'
    return $false

}

if (-not (Test-Path -LiteralPath $bacpacPath -PathType Leaf)) {

    Write-Host 'eShop BACPAC was not downloaded. Returning false so Skillable Repeat can retry.'
    return $false

}

# If Microsoft's evergreen standalone package is behind the customer's pinned

# NuGet-tool version, align the downloaded runtime copy of the customer script

# to the official standalone version that was actually staged above.

try {

$customerScriptText = [IO.File]::ReadAllText($postDeployScript)

$pinPattern = '(?m)^\s*\$script:Lab04SqlPackageVersion\s*=\s*''(?<version>[^'']+)''\s*$'

$pinMatch = [regex]::Match($customerScriptText, $pinPattern)

if (-not $pinMatch.Success) {

    throw 'Could not locate the SqlPackage version pin in the downloaded customer script.'

}

$downloadedCustomerPin = $pinMatch.Groups['version'].Value

if ($downloadedCustomerPin -ne $sqlPackageVersion) {

    Write-Host "Patching runtime customer script SqlPackage pin from '$downloadedCustomerPin' to '$sqlPackageVersion'. Repository source remains unchanged."

    $replacement = '$script:Lab04SqlPackageVersion = ''' + $sqlPackageVersion + ''''

    $customerScriptText = [regex]::Replace(

        $customerScriptText,

        $pinPattern,

        [Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement },

        1

    )

    [IO.File]::WriteAllText(

        $postDeployScript,

        $customerScriptText,

        [Text.UTF8Encoding]::new($false)

    )

}

# ---------------------------------------------------------------------
# Harden the runtime copy of the customer's Front Door Private Link logic.
# Repository source remains unchanged.
# ---------------------------------------------------------------------

$frontDoorFunctionPattern = '(?ms)^function Approve-FrontDoorPrivateLink \{.*?^function Set-ContainerAppDatabaseConfiguration \{'
$frontDoorFunction = @'
function Approve-FrontDoorPrivateLink {
    param(
        [Parameter(Mandatory)][string]$EnvironmentId,
        [Parameter(Mandatory)][string]$OriginId,
        [Parameter(Mandatory)][string]$RequestMessage,
        [Parameter(Mandatory)][string]$EndpointHostName
    )

    $connectionApproved = $false

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $connections = @(
            az network private-endpoint-connection list `
                --subscription $SubscriptionId `
                --id $EnvironmentId `
                --output json | ConvertFrom-Json
        )

        $eligible = @(
            $connections | Where-Object {
                $_.properties.privateLinkServiceConnectionState.status -in @('Pending', 'Approved')
            }
        )

        $candidates = @(
            $eligible | Where-Object {
                $_.properties.privateLinkServiceConnectionState.description -eq $RequestMessage
            }
        )

        if ($candidates.Count -eq 0) {
            $frontDoorLike = @(
                $eligible | Where-Object {
                    $description = [string]$_.properties.privateLinkServiceConnectionState.description
                    $description -match '(?i)front\s*door|origin'
                }
            )

            if ($frontDoorLike.Count -eq 1) {
                $candidates = $frontDoorLike
                Write-Host 'Using the single Front Door-like private endpoint connection because its description differs from the deployment output.'
            }
            elseif ($eligible.Count -eq 1) {
                $candidates = $eligible
                Write-Host 'Using the only pending/approved private endpoint connection on the Container Apps environment.'
            }
        }

        if ($candidates.Count -gt 1) {
            throw 'Multiple private endpoint connections could match the Front Door request. No connection was approved.'
        }

        if ($candidates.Count -eq 1) {
            $connection = $candidates[0]
            $status = [string]$connection.properties.privateLinkServiceConnectionState.status

            if ($status -eq 'Pending') {
                Write-Host "Approving Front Door private endpoint connection '$($connection.name)'."
                az network private-endpoint-connection approve `
                    --subscription $SubscriptionId `
                    --id $connection.id `
                    --description $RequestMessage `
                    --output none
            }

            $status = az network private-endpoint-connection show `
                --subscription $SubscriptionId `
                --id $connection.id `
                --query properties.privateLinkServiceConnectionState.status `
                --output tsv

            if ($status -eq 'Approved') {
                Write-Host "Front Door private endpoint connection '$($connection.name)' is Approved."
                $connectionApproved = $true
                break
            }
        }

        Write-Host "Front Door private endpoint connection is not ready yet (attempt $attempt/20)."
        Start-Sleep -Seconds 15
    }

    if (-not $connectionApproved) {
        throw 'The Front Door Private Link request was not approved within five minutes.'
    }

    $originHostName = az resource show `
        --subscription $SubscriptionId `
        --ids $OriginId `
        --api-version 2024-02-01 `
        --query properties.hostName `
        --output tsv

    if ([string]::IsNullOrWhiteSpace($originHostName)) {
        throw 'The expected Front Door origin could not be verified.'
    }

    $endpointUri = "https://$EndpointHostName/"
    $lastProbeFailure = 'No HTTP response was received.'

    # Bound this to 10 minutes so a single Skillable invocation stays well
    # inside the one-hour timeout. The wrapper returns $false on this specific
    # transient condition so Skillable Repeat can try again later.
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Uri $endpointUri `
                -Method Get `
                -TimeoutSec 15 `
                -UseBasicParsing

            if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400) {
                Write-Host "Front Door Private Link is approved and '$endpointUri' is ready."
                return
            }

            $lastProbeFailure = "HTTP $([int]$response.StatusCode)"
        }
        catch {
            $webResponse = $_.Exception.Response
            if ($webResponse) {
                $lastProbeFailure = "HTTP $([int]$webResponse.StatusCode)"
            }
            else {
                $lastProbeFailure = $_.Exception.Message
            }
        }

        Write-Host "Front Door endpoint is not healthy yet (attempt $attempt/20): $lastProbeFailure"
        Start-Sleep -Seconds 30
    }

    throw "Front Door endpoint '$endpointUri' did not become healthy within 10 minutes. Last probe: $lastProbeFailure"
}
function Set-ContainerAppDatabaseConfiguration {
'@

$frontDoorMatch = [regex]::Match($customerScriptText, $frontDoorFunctionPattern)
if (-not $frontDoorMatch.Success) {
    throw 'Could not locate the Front Door Private Link function in the downloaded customer script.'
}

$customerScriptText = [regex]::Replace(
    $customerScriptText,
    $frontDoorFunctionPattern,
    [Text.RegularExpressions.MatchEvaluator]{ param($m) $frontDoorFunction },
    1
)

[IO.File]::WriteAllText(
    $postDeployScript,
    $customerScriptText,
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'Patched runtime customer script with Repeat-safe Front Door Private Link handling.'

}
catch {

    Write-Host "Runtime customer-script patching hit an error: $($_.Exception.Message)"
    Write-Host 'Returning false so Skillable Repeat can retry instead of terminating the lifecycle action.'
    return $false

}

if (-not (Test-Lab04PowerShellFileSyntax -Path $postDeployScript)) {
    Write-Host 'Runtime customer script contains a parser error. Returning false so Skillable Repeat can retry instead of terminating the lifecycle action.'
    return $false
}

Write-Host 'Runtime customer script syntax validation passed.'

# ---------------------------------------------------------------------
# Child-deployment/output readiness gate.
# Check once; Skillable Repeat handles subsequent attempts.
# ---------------------------------------------------------------------

try {
    Write-Host 'Checking post-deployment resource discovery.'

    & $postDeployScript `
        -SubscriptionId $subscriptionId `
        -BacpacPath $bacpacPath `
        -DiscoveryOnly `
        -Confirm:$false | Out-Null

    Write-Host 'Customer post-deployment discovery succeeded.'
}
catch {
    $lastDiscoveryError = $_.Exception.Message
    Assert-Lab04FoundationNotFailed
    Write-Host "Post-deployment resources are not ready yet: $lastDiscoveryError"
    Write-Host 'Returning false so Skillable can retry.'
    return $false
}

# Verify the SQL data-plane credential before the customer script opens

# temporary NSG access or starts the import. The full run still reacquires

# the token at the exact point the customer script expects it.

try {

    $preflightSqlToken = Get-Lab04UserSqlToken

}
catch {

    Write-Host "User1 Azure SQL token preflight hit an error: $($_.Exception.Message)"
    Write-Host 'Returning false so Skillable Repeat can retry.'
    return $false

}

if ([string]::IsNullOrWhiteSpace($preflightSqlToken)) {

    Write-Host 'User1 Azure SQL token preflight returned an empty token. Returning false so Skillable Repeat can retry.'
    return $false

}

$preflightSqlToken = $null

Write-Host 'User1 Azure SQL token preflight succeeded.'

# ---------------------------------------------------------------------

# Full end-to-end customer post-deployment run.

# ---------------------------------------------------------------------

Write-Host 'Running the full Lab04 customer post-deployment automation.'

try {
    & $postDeployScript `
        -SubscriptionId $subscriptionId `
        -BacpacPath $bacpacPath `
        -Confirm:$false
}
catch {
    $message = $_.Exception.Message

    if ($message -like "Front Door endpoint * did not become healthy within 10 minutes*") {
        Write-Host "Front Door is approved but not healthy yet: $message"
        Write-Host 'Returning false so Skillable can retry the post-deployment action.'
        return $false
    }

    Write-Host "Post-deployment runtime error captured: $message"
    Write-Host 'Returning false so Skillable Repeat can retry instead of terminating the lifecycle action.'
    return $false
}

Write-Host 'Lab04 post-deployment completed successfully.'
return $true
