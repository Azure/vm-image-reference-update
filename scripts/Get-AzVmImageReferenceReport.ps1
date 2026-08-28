#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
Inventories Azure VM image references and recommends compatible Marketplace images.

.DESCRIPTION
Scans standalone virtual machines in an Azure subscription, compares the running
guest operating system with a checked-in Marketplace image catalog, and writes
CSV and JSON reports. The script never changes a virtual machine.

Use -RefreshCatalog to rebuild the location-agnostic publisher, offer, and SKU
index consumed by normal scans.

DISCLAIMER

This script is not supported under any Microsoft standard support program or service.

This script is provided AS IS without warranty of any kind. Microsoft further disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose.

The entire risk arising out of the use or performance of the script and documentation remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the sample scripts or documentation, even if Microsoft has been advised of the possibility of such damages.

.PARAMETER ResourceGroupName
Limits the scan to virtual machines in one resource group. Required with VMName.

.PARAMETER VMName
Limits the scan to one virtual machine. ResourceGroupName must also be supplied.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Top-level parameters are consumed by the orchestration functions selected at the end of the script.'
)]
[CmdletBinding(DefaultParameterSetName = 'Scan')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [Parameter(ParameterSetName = 'Scan')]
    [string] $OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'output'),

    [Parameter(ParameterSetName = 'Scan')]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(ParameterSetName = 'Scan')]
    [ValidateNotNullOrEmpty()]
    [string] $VMName,

    [Parameter(ParameterSetName = 'Scan')]
    [switch] $UseRunCommandFallback,

    [Parameter(ParameterSetName = 'Scan')]
    [ValidateRange(1, 50)]
    [int] $CandidateLimit = 10,

    [Parameter(ParameterSetName = 'Scan')]
    [ValidatePattern('^20\d{2}-\d{2}-\d{2}$')]
    [string] $ComputeApiVersion = '2026-04-01',

    [Parameter(Mandatory, ParameterSetName = 'RefreshCatalog')]
    [switch] $RefreshCatalog,

    [Parameter(ParameterSetName = 'RefreshCatalog')]
    [ValidateNotNullOrEmpty()]
    [string] $CatalogBaseRegion = 'westus3',

    [Parameter(ParameterSetName = 'RefreshCatalog')]
    [switch] $AllowPartialCatalog,

    [Parameter(ParameterSetName = 'Scan')]
    [Parameter(ParameterSetName = 'RefreshCatalog')]
    [string] $CatalogPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data/vm-image-catalog.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CatalogSchemaVersion = 3
$script:ReportSchemaVersion = 2
$script:MarketplaceImageApiVersions = @('2026-03-01', '2025-04-01')
$script:SupportedPublishers = @(
    'MicrosoftWindowsServer'
    'MicrosoftWindowsDesktop'
    'Canonical'
    'RedHat'
    'SUSE'
)

function ConvertTo-NormalizedArchitecture {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $Architecture
    )

    if ([string]::IsNullOrWhiteSpace($Architecture)) {
        return $null
    }

    switch -Regex ($Architecture.Trim()) {
        '^(?i)(x64|x86_64|amd64|64-bit)$' { return 'x64' }
        '^(?i)(arm64|aarch64|arm64-based pc)$' { return 'Arm64' }
        default { return $Architecture.Trim() }
    }
}

function Get-WindowsBuildNumber {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $OSVersion
    )

    if ($OSVersion -match '(?<!\d)(\d{5})(?:\.\d+)?(?!\d)') {
        return [int] $Matches[1]
    }

    return $null
}

function Get-NormalizedGuestOS {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $OSName,

        [AllowNull()]
        [string] $OSVersion,

        [AllowNull()]
        [string] $Architecture,

        [AllowNull()]
        [Nullable[int]] $ProductType,

        [AllowNull()]
        [string] $CurrentPublisher,

        [AllowNull()]
        [string] $CurrentOffer,

        [AllowNull()]
        [string] $CurrentSku,

        [ValidateSet('InstanceView', 'RunCommand')]
        [string] $EvidenceSource = 'InstanceView'
    )

    $normalizedArchitecture = ConvertTo-NormalizedArchitecture -Architecture $Architecture
    $name = if ($null -eq $OSName) { '' } else { $OSName.Trim() }
    $version = if ($null -eq $OSVersion) { '' } else { $OSVersion.Trim() }
    $combined = "$name $version"

    $result = [ordered]@{
        IsSupported      = $false
        Publisher       = $null
        Family          = $null
        ProductType     = $null
        Release         = $null
        Version         = $version
        Build           = $null
        Codename        = $null
        ServicePack     = $null
        Architecture    = $normalizedArchitecture
        EditionTokens   = @()
        EvidenceSource  = $EvidenceSource
        RawOSName       = $name
        RawOSVersion    = $version
        ResolutionNotes = @()
    }

    $runningWindows = $combined -match '(?i)windows|microsoft windows nt' -or
        $CurrentPublisher -in @('MicrosoftWindowsServer', 'MicrosoftWindowsDesktop')

    if ($runningWindows) {
        $build = Get-WindowsBuildNumber -OSVersion $version
        $isServer = $name -match '(?i)server' -or
            ($null -ne $ProductType -and $ProductType -ne 1) -or
            $CurrentPublisher -eq 'MicrosoftWindowsServer'

        $result.IsSupported = $true
        $result.Publisher = if ($isServer) { 'MicrosoftWindowsServer' } else { 'MicrosoftWindowsDesktop' }
        $result.Family = if ($isServer) { 'Windows Server' } else { 'Windows' }
        $result.ProductType = if ($isServer) { 'Server' } else { 'Desktop' }
        $result.Build = $build

        if ($isServer) {
            if ($name -match '(?i)Windows Server\s+(2016|2019|2022|2025)') {
                $result.Release = $Matches[1]
            }
            else {
                $result.Release = switch ($build) {
                    14393 { '2016' }
                    17763 { '2019' }
                    20348 { '2022' }
                    26100 { '2025' }
                    default { $null }
                }
                if ($null -ne $result.Release) {
                    $result.ResolutionNotes += 'Release inferred from Windows build and server evidence.'
                }
            }
            if ([string]::IsNullOrWhiteSpace($result.Release) -and
                $CurrentPublisher -eq 'MicrosoftWindowsServer' -and
                "$CurrentOffer $CurrentSku" -match '(?<!\d)(2016|2019|2022|2025)(?!\d)') {
                $result.Release = $Matches[1]
                $result.ResolutionNotes += 'Release inferred from the current Marketplace image reference because guest version evidence was unavailable.'
            }
        }
        else {
            if ($name -match '(?i)Windows\s+(10|11)') {
                $result.Family = "Windows $($Matches[1])"
            }
            elseif ($null -ne $build) {
                $result.Family = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
                $result.ResolutionNotes += 'Desktop family inferred from Windows build.'
            }

            $result.Release = switch ($build) {
                19044 { '21H2' }
                19045 { '22H2' }
                22000 { '21H2' }
                22621 { '22H2' }
                22631 { '23H2' }
                26100 { '24H2' }
                26200 { '25H2' }
                28000 { '26H1' }
                default { $null }
            }
        }

        $editionTokens = [System.Collections.Generic.List[string]]::new()
        foreach ($token in @('Datacenter', 'Standard', 'Enterprise', 'Education', 'Professional', 'Core', 'Azure Edition', 'Multi-session')) {
            if ($name -match [regex]::Escape($token)) {
                $editionTokens.Add($token.ToLowerInvariant())
            }
        }
        $result.EditionTokens = @($editionTokens)
        return [pscustomobject] $result
    }

    if ($combined -match '(?i)ubuntu|canonical' -or $CurrentPublisher -eq 'Canonical') {
        $result.IsSupported = $true
        $result.Publisher = 'Canonical'
        $result.Family = 'Ubuntu'
        $result.ProductType = 'Server'
        if ($combined -match '(?<!\d)(\d{2}\.\d{2})(?!\d)') {
            $result.Release = $Matches[1]
        }
        if ($combined -match '(?i)\b(focal|jammy|noble|questing|resolute)\b') {
            $result.Codename = $Matches[1].ToLowerInvariant()
        }
        $result.EditionTokens = @('lts', 'pro', 'minimal') | Where-Object { $combined -match "(?i)\b$([regex]::Escape($_))\b" }
        return [pscustomobject] $result
    }

    if ($combined -match '(?i)red hat|rhel' -or $CurrentPublisher -eq 'RedHat') {
        $result.IsSupported = $true
        $result.Publisher = 'RedHat'
        $result.Family = 'Red Hat Enterprise Linux'
        $result.ProductType = 'Server'
        if ($combined -match '(?i)(?:rhel|release|linux)\D*(\d{1,2}(?:\.\d{1,2})?)') {
            $result.Release = $Matches[1]
        }
        $result.EditionTokens = @('byos', 'sap', 'ha', 'lvm', 'raw') | Where-Object { $combined -match "(?i)\b$([regex]::Escape($_))\b" }
        return [pscustomobject] $result
    }

    if ($combined -match '(?i)suse|sles' -or $CurrentPublisher -eq 'SUSE') {
        $result.IsSupported = $true
        $result.Publisher = 'SUSE'
        $result.Family = 'SUSE Linux Enterprise Server'
        $result.ProductType = 'Server'
        if ($combined -match '(?i)(?:sles|server|release)\D*(\d{1,2})(?:[ ._-]*(?:sp)?(\d{1,2}))?') {
            $result.Release = $Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($Matches[2])) {
                $result.ServicePack = "SP$($Matches[2])"
            }
        }
        $result.EditionTokens = @('byos', 'sap', 'hpc', 'chost') | Where-Object { $combined -match "(?i)\b$([regex]::Escape($_))\b" }
        return [pscustomobject] $result
    }

    return [pscustomobject] $result
}

function Import-VMImageCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Image catalog was not found at '$Path'. Run this script with -RefreshCatalog first."
    }

    try {
        $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20
    }
    catch {
        throw "Image catalog '$Path' is not valid JSON. $($_.Exception.Message)"
    }

    $requiredProperties = @('schemaVersion', 'scope', 'generatedAtUtc', 'baseRegion', 'publishers', 'entries')
    foreach ($property in $requiredProperties) {
        if ($catalog.PSObject.Properties.Name -notcontains $property) {
            throw "Image catalog '$Path' is missing required property '$property'."
        }
    }

    if ($catalog.schemaVersion -ne $script:CatalogSchemaVersion) {
        throw "Image catalog schema '$($catalog.schemaVersion)' is unsupported. Expected '$script:CatalogSchemaVersion'."
    }
    if ($catalog.scope -ne 'MarketplaceImageNames') {
        throw "Image catalog scope '$($catalog.scope)' is unsupported. Expected 'MarketplaceImageNames'."
    }

    $catalogPublishers = @($catalog.publishers)
    foreach ($publisher in $catalogPublishers) {
        if ($publisher -notin $script:SupportedPublishers) {
            throw "Image catalog '$Path' declares unsupported publisher '$publisher'."
        }
    }

    try {
        $generatedAt = [datetimeoffset] $catalog.generatedAtUtc
    }
    catch {
        throw "Image catalog '$Path' has an invalid generatedAtUtc value."
    }

    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($catalog.entries)) {
        foreach ($property in @('publisher', 'offer', 'sku')) {
            if ($entry.PSObject.Properties.Name -notcontains $property -or [string]::IsNullOrWhiteSpace($entry.$property)) {
                throw "Image catalog '$Path' contains an entry without '$property'."
            }
        }

        if ($entry.publisher -notin $script:SupportedPublishers) {
            throw "Image catalog '$Path' contains unsupported publisher '$($entry.publisher)'."
        }

        $key = "$($entry.publisher)|$($entry.offer)|$($entry.sku)"
        if (-not $seenKeys.Add($key)) {
            throw "Image catalog '$Path' contains duplicate entry '$key'."
        }
    }

    $catalog | Add-Member -NotePropertyName GeneratedAt -NotePropertyValue $generatedAt -Force
    $catalog | Add-Member -NotePropertyName AgeDays -NotePropertyValue ([math]::Floor(([datetimeoffset]::UtcNow - $generatedAt).TotalDays)) -Force
    return $catalog
}

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-NestedPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string[]] $Path
    )

    $value = $InputObject
    foreach ($segment in $Path) {
        $value = Get-ObjectPropertyValue -InputObject $value -Name $segment
        if ($null -eq $value) {
            return $null
        }
    }

    return $value
}

function Get-ValidatedAzContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TargetSubscriptionId
    )

    $parsedSubscriptionId = [guid]::Empty
    if (-not [guid]::TryParse($TargetSubscriptionId, [ref] $parsedSubscriptionId)) {
        throw "SubscriptionId '$TargetSubscriptionId' is not a valid GUID."
    }

    if ($null -eq (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No authenticated Azure context was found. Run Connect-AzAccount and try again.'
    }

    try {
        $subscription = Get-AzSubscription -SubscriptionId $parsedSubscriptionId.Guid -ErrorAction Stop
        return Set-AzContext -SubscriptionId $subscription.Id -TenantId $subscription.TenantId -Scope Process -ErrorAction Stop
    }
    catch {
        throw "Unable to access subscription '$TargetSubscriptionId'. $($_.Exception.Message)"
    }
}

function Get-CatalogItemName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string[]] $PreferredProperties
    )

    foreach ($propertyName in $PreferredProperties) {
        $value = Get-ObjectPropertyValue -InputObject $InputObject -Name $propertyName
        if (-not [string]::IsNullOrWhiteSpace([string] $value)) {
            return [string] $value
        }
    }

    return $null
}

function ConvertTo-CatalogSafeErrorMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return 'Azure catalog request failed without an error message.'
    }

    return $Message -replace '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b', '<redacted-guid>'
}

function Get-VMImageCatalogSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $AzContext,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $BaseRegion
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $baseRegion = $BaseRegion.Trim().ToLowerInvariant()
    Write-Verbose "Discovering Marketplace image names in '$baseRegion'."
    try {
        $availablePublishers = @(Get-AzVMImagePublisher -Location $baseRegion -DefaultProfile $AzContext)
    }
    catch {
        throw "Unable to list image publishers in base region '$baseRegion'. $($_.Exception.Message)"
    }

    for ($publisherIndex = 0; $publisherIndex -lt $script:SupportedPublishers.Count; $publisherIndex++) {
        $publisher = $script:SupportedPublishers[$publisherIndex]
        Write-Verbose "Discovering offers and SKUs for '$publisher' in '$baseRegion'."
        Write-Progress -Activity "Building image catalog from $baseRegion" -Status $publisher `
            -PercentComplete ((($publisherIndex + 1) / $script:SupportedPublishers.Count) * 100)
        $publisherExists = $availablePublishers | Where-Object {
            (Get-CatalogItemName -InputObject $_ -PreferredProperties @('PublisherName', 'Name')) -eq $publisher
        } | Select-Object -First 1
        if ($null -eq $publisherExists) {
            $errors.Add([pscustomobject]@{
                    publisher = $publisher
                    stage     = 'Publisher'
                    message   = "Publisher is not available in base region '$baseRegion'."
                })
            continue
        }

        try {
            $offers = @(Get-AzVMImageOffer -Location $baseRegion -PublisherName $publisher -DefaultProfile $AzContext)
            Write-Verbose "Found $($offers.Count) offers for '$publisher'."
        }
        catch {
            $errors.Add([pscustomobject]@{
                    publisher = $publisher
                    stage     = 'Offers'
                    message   = ConvertTo-CatalogSafeErrorMessage -Message $_.Exception.Message
                })
            continue
        }

        foreach ($offerObject in $offers) {
            $offer = Get-CatalogItemName -InputObject $offerObject -PreferredProperties @('Offer', 'Name')
            if ([string]::IsNullOrWhiteSpace($offer)) {
                continue
            }

            try {
                $skus = @(Get-AzVMImageSku -Location $baseRegion -PublisherName $publisher -Offer $offer -DefaultProfile $AzContext)
            }
            catch {
                $errors.Add([pscustomobject]@{
                        publisher = $publisher
                        stage     = "Skus:$offer"
                        message   = ConvertTo-CatalogSafeErrorMessage -Message $_.Exception.Message
                    })
                continue
            }

            foreach ($skuObject in $skus) {
                $sku = Get-CatalogItemName -InputObject $skuObject -PreferredProperties @('Skus', 'Sku', 'Name')
                if (-not [string]::IsNullOrWhiteSpace($sku)) {
                    $entries.Add([pscustomobject]@{
                            publisher = $publisher
                            offer     = $offer
                            sku       = $sku
                        })
                }
            }
        }
    }
    Write-Progress -Activity "Building image catalog from $baseRegion" -Completed

    $deduplicatedEntries = @($entries | Sort-Object publisher, offer, sku -Unique)
    $azComputeVersion = Get-Module -ListAvailable Az.Compute | Sort-Object Version -Descending | Select-Object -First 1

    return [ordered]@{
        schemaVersion       = $script:CatalogSchemaVersion
        scope               = 'MarketplaceImageNames'
        generatedAtUtc      = [datetimeoffset]::UtcNow.ToString('o')
        baseRegion          = $baseRegion
        publishers          = @($script:SupportedPublishers)
        generator           = [ordered]@{
            script           = 'Get-AzVmImageReferenceReport.ps1'
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
            azComputeVersion  = if ($null -eq $azComputeVersion) { $null } else { $azComputeVersion.Version.ToString() }
        }
        isPartial           = $errors.Count -gt 0
        entries             = $deduplicatedEntries
        errors              = @($errors)
    }
}

function Export-VMImageCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Catalog,

        [Parameter(Mandatory)]
        [string] $Path,

        [switch] $AllowPartial
    )

    if ($Catalog.isPartial -and -not $AllowPartial) {
        throw "Catalog refresh returned $(@($Catalog.errors).Count) errors. Use -AllowPartialCatalog to save it."
    }

    $parentDirectory = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parentDirectory)) {
        $parentDirectory = (Get-Location).Path
        $Path = Join-Path $parentDirectory $Path
    }
    [System.IO.Directory]::CreateDirectory($parentDirectory) | Out-Null

    $temporaryPath = "$Path.$([guid]::NewGuid().Guid).tmp"
    try {
        $json = $Catalog | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        Import-VMImageCatalog -Path $temporaryPath | Out-Null
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-VMResourceGroupName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VM
    )

    $resourceGroupName = Get-ObjectPropertyValue -InputObject $VM -Name 'ResourceGroupName'
    if (-not [string]::IsNullOrWhiteSpace([string] $resourceGroupName)) {
        return [string] $resourceGroupName
    }

    $resourceId = [string] (Get-ObjectPropertyValue -InputObject $VM -Name 'Id')
    if ($resourceId -match '(?i)/resourceGroups/([^/]+)') {
        return $Matches[1]
    }

    return $null
}

function Test-IsStandaloneVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VM
    )

    $vmScaleSetId = Get-NestedPropertyValue -InputObject $VM -Path @('VirtualMachineScaleSet', 'Id')
    $managedBy = [string] (Get-ObjectPropertyValue -InputObject $VM -Name 'ManagedBy')
    return [string]::IsNullOrWhiteSpace([string] $vmScaleSetId) -and
        ($managedBy -notmatch '(?i)/virtualMachineScaleSets/')
}

function Get-TargetVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $AzContext,

        [AllowNull()]
        [string] $TargetResourceGroupName,

        [AllowNull()]
        [string] $TargetVMName,

        [AllowNull()]
        [scriptblock] $VMLookup
    )

    if (-not [string]::IsNullOrWhiteSpace($TargetVMName) -and
        [string]::IsNullOrWhiteSpace($TargetResourceGroupName)) {
        throw 'ResourceGroupName is required when VMName is specified.'
    }

    if ($null -ne $VMLookup) {
        return @(& $VMLookup $TargetResourceGroupName $TargetVMName $AzContext)
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetVMName)) {
        return @(Get-AzVM -ResourceGroupName $TargetResourceGroupName -Name $TargetVMName `
                -DefaultProfile $AzContext)
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetResourceGroupName)) {
        return @(Get-AzVM -ResourceGroupName $TargetResourceGroupName -DefaultProfile $AzContext)
    }

    return @(Get-AzVM -DefaultProfile $AzContext)
}

function Get-VMImageReferenceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VM
    )

    $imageReference = Get-NestedPropertyValue -InputObject $VM -Path @('StorageProfile', 'ImageReference')
    $publisher = [string] (Get-ObjectPropertyValue -InputObject $imageReference -Name 'Publisher')
    $offer = [string] (Get-ObjectPropertyValue -InputObject $imageReference -Name 'Offer')
    $sku = [string] (Get-ObjectPropertyValue -InputObject $imageReference -Name 'Sku')
    if ([string]::IsNullOrWhiteSpace($sku)) {
        $sku = [string] (Get-ObjectPropertyValue -InputObject $imageReference -Name 'Skus')
    }
    $version = [string] (Get-ObjectPropertyValue -InputObject $imageReference -Name 'Version')
    $exactVersion = [string] (Get-ObjectPropertyValue -InputObject $imageReference -Name 'ExactVersion')
    $id = [string] (Get-ObjectPropertyValue -InputObject $imageReference -Name 'Id')
    $sharedGalleryImageId = [string] (Get-ObjectPropertyValue -InputObject $imageReference -Name 'SharedGalleryImageId')
    $communityGalleryImageId = [string] (Get-ObjectPropertyValue -InputObject $imageReference -Name 'CommunityGalleryImageId')

    $sourceType = if (-not [string]::IsNullOrWhiteSpace($publisher) -and
        -not [string]::IsNullOrWhiteSpace($offer) -and
        -not [string]::IsNullOrWhiteSpace($sku)) {
        'Marketplace'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($sharedGalleryImageId)) {
        'DirectSharedGallery'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($communityGalleryImageId)) {
        'CommunityGallery'
    }
    elseif ($id -match '(?i)/galleries/.+/images/') {
        'AzureComputeGallery'
    }
    elseif ($id -match '(?i)/providers/Microsoft\.Compute/images/') {
        'ManagedImage'
    }
    elseif ($null -eq $imageReference) {
        'Null'
    }
    else {
        'Unknown'
    }

    $plan = Get-ObjectPropertyValue -InputObject $VM -Name 'Plan'

    return [pscustomobject]@{
        SourceType              = $sourceType
        Publisher               = $publisher
        Offer                   = $offer
        Sku                     = $sku
        Version                 = $version
        ExactVersion            = $exactVersion
        Id                      = $id
        SharedGalleryImageId    = $sharedGalleryImageId
        CommunityGalleryImageId = $communityGalleryImageId
        PlanPublisher           = [string] (Get-ObjectPropertyValue -InputObject $plan -Name 'Publisher')
        PlanProduct             = [string] (Get-ObjectPropertyValue -InputObject $plan -Name 'Product')
        PlanName                = [string] (Get-ObjectPropertyValue -InputObject $plan -Name 'Name')
    }
}

function Invoke-AzRestReadWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $AzContext,

        [ValidateRange(1, 5)]
        [int] $MaximumAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return Invoke-AzRestMethod -Path $Path -Method GET -DefaultProfile $AzContext
        }
        catch {
            $statusCode = Get-NestedPropertyValue -InputObject $_.Exception -Path @('Response', 'StatusCode')
            $isTransient = $statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)
            if (-not $isTransient -or $attempt -eq $MaximumAttempts) {
                throw
            }

            Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1))
        }
    }
}

function Get-VMInstanceViewRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VM,

        [Parameter(Mandatory)]
        [object] $AzContext,

        [Parameter(Mandatory)]
        [string] $ApiVersion
    )

    $resourceId = [string] (Get-ObjectPropertyValue -InputObject $VM -Name 'Id')
    try {
        $response = Invoke-AzRestReadWithRetry -Path "$resourceId/instanceView?api-version=$ApiVersion" -AzContext $AzContext
        $statusCode = [int] (Get-ObjectPropertyValue -InputObject $response -Name 'StatusCode')
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            throw "Instance View returned HTTP $statusCode."
        }

        $content = [string] (Get-ObjectPropertyValue -InputObject $response -Name 'Content')
        $instanceView = $content | ConvertFrom-Json -Depth 20
        $statuses = @(Get-ObjectPropertyValue -InputObject $instanceView -Name 'Statuses')
        $powerStatus = $statuses | Where-Object {
            [string] (Get-ObjectPropertyValue -InputObject $_ -Name 'Code') -like 'PowerState/*'
        } | Select-Object -Last 1
        $agentStatuses = @(Get-NestedPropertyValue -InputObject $instanceView -Path @('VmAgent', 'Statuses'))
        $agentReady = $null -ne ($agentStatuses | Where-Object {
                (Get-ObjectPropertyValue -InputObject $_ -Name 'Code') -eq 'ProvisioningState/succeeded' -or
                (Get-ObjectPropertyValue -InputObject $_ -Name 'DisplayStatus') -eq 'Ready'
            } | Select-Object -First 1)

        return [pscustomobject]@{
            Succeeded        = $true
            OSName           = [string] (Get-ObjectPropertyValue -InputObject $instanceView -Name 'OsName')
            OSVersion        = [string] (Get-ObjectPropertyValue -InputObject $instanceView -Name 'OsVersion')
            Architecture     = $null
            ProductType      = $null
            HyperVGeneration = [string] (Get-ObjectPropertyValue -InputObject $instanceView -Name 'HyperVGeneration')
            PowerState       = [string] (Get-ObjectPropertyValue -InputObject $powerStatus -Name 'Code')
            VMAgentReady     = $agentReady
            EvidenceSource   = 'InstanceView'
            ErrorMessage     = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Succeeded        = $false
            OSName           = $null
            OSVersion        = $null
            Architecture     = $null
            ProductType      = $null
            HyperVGeneration = $null
            PowerState       = $null
            VMAgentReady     = $false
            EvidenceSource   = 'InstanceView'
            ErrorMessage     = $_.Exception.Message
        }
    }
}

function Get-RunCommandOutputMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $RunCommandResult
    )

    $values = @(Get-ObjectPropertyValue -InputObject $RunCommandResult -Name 'Value')
    $stdout = $values | Where-Object {
        [string] (Get-ObjectPropertyValue -InputObject $_ -Name 'Code') -match '(?i)StdOut'
    } | Select-Object -Last 1
    return [string] (Get-ObjectPropertyValue -InputObject $stdout -Name 'Message')
}

function Get-VMRunCommandEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VM,

        [Parameter(Mandatory)]
        [ValidateSet('Windows', 'Linux')]
        [string] $OSType,

        [Parameter(Mandatory)]
        [object] $AzContext
    )

    $resourceGroupName = Get-VMResourceGroupName -VM $VM
    $vmName = [string] (Get-ObjectPropertyValue -InputObject $VM -Name 'Name')

    try {
        if ($OSType -eq 'Windows') {
            $scriptString = @'
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$os | Select-Object Caption, Version, BuildNumber, OSArchitecture, ProductType | ConvertTo-Json -Compress
'@
            $runCommand = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -VMName $vmName `
                -CommandId 'RunPowerShellScript' -ScriptString $scriptString -DefaultProfile $AzContext
            $output = Get-RunCommandOutputMessage -RunCommandResult $runCommand
            $guest = $output | ConvertFrom-Json
            return [pscustomobject]@{
                Succeeded      = $true
                OSName         = [string] (Get-ObjectPropertyValue -InputObject $guest -Name 'Caption')
                OSVersion      = [string] (Get-ObjectPropertyValue -InputObject $guest -Name 'Version')
                Architecture   = [string] (Get-ObjectPropertyValue -InputObject $guest -Name 'OSArchitecture')
                ProductType    = [Nullable[int]] (Get-ObjectPropertyValue -InputObject $guest -Name 'ProductType')
                EvidenceSource = 'RunCommand'
                ErrorMessage   = $null
            }
        }

        $scriptString = @'
if [ -r /etc/os-release ]; then . /etc/os-release; fi
printf 'ID=%s\nNAME=%s\nPRETTY_NAME=%s\nVERSION_ID=%s\nVERSION_CODENAME=%s\nARCH=%s\n' \
  "$ID" "$NAME" "$PRETTY_NAME" "$VERSION_ID" "$VERSION_CODENAME" "$(uname -m)"
'@
        $runCommand = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -VMName $vmName `
            -CommandId 'RunShellScript' -ScriptString $scriptString -DefaultProfile $AzContext
        $output = Get-RunCommandOutputMessage -RunCommandResult $runCommand
        $values = @{}
        foreach ($line in ($output -split "`r?`n")) {
            if ($line -match '^([A-Z_]+)=(.*)$') {
                $values[$Matches[1]] = $Matches[2].Trim('"')
            }
        }
        if ([string]::IsNullOrWhiteSpace([string] $values.PRETTY_NAME) -or
            [string]::IsNullOrWhiteSpace([string] $values.VERSION_ID)) {
            throw 'Run Command did not return parseable /etc/os-release data.'
        }

        return [pscustomobject]@{
            Succeeded      = $true
            OSName         = [string] $values.PRETTY_NAME
            OSVersion      = [string] $values.VERSION_ID
            Architecture   = [string] $values.ARCH
            ProductType    = $null
            EvidenceSource = 'RunCommand'
            ErrorMessage   = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Succeeded      = $false
            OSName         = $null
            OSVersion      = $null
            Architecture   = $null
            ProductType    = $null
            EvidenceSource = 'RunCommand'
            ErrorMessage   = $_.Exception.Message
        }
    }
}

function Get-VMCompatibilityProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VM,

        [AllowNull()]
        [object[]] $ResourceSkus,

        [AllowNull()]
        [object] $InstanceView,

        [AllowNull()]
        [string] $DetectedArchitecture
    )

    $vmSize = [string] (Get-NestedPropertyValue -InputObject $VM -Path @('HardwareProfile', 'VmSize'))
    $resourceSku = $ResourceSkus | Where-Object {
        (Get-ObjectPropertyValue -InputObject $_ -Name 'ResourceType') -eq 'virtualMachines' -and
        (Get-ObjectPropertyValue -InputObject $_ -Name 'Name') -eq $vmSize
    } | Select-Object -First 1
    $capabilities = @(Get-ObjectPropertyValue -InputObject $resourceSku -Name 'Capabilities')
    $architectureCapability = $capabilities | Where-Object {
        (Get-ObjectPropertyValue -InputObject $_ -Name 'Name') -eq 'CpuArchitectureType'
    } | Select-Object -First 1
    $generationCapability = $capabilities | Where-Object {
        (Get-ObjectPropertyValue -InputObject $_ -Name 'Name') -eq 'HyperVGenerations'
    } | Select-Object -First 1

    $architecture = ConvertTo-NormalizedArchitecture -Architecture $DetectedArchitecture
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = ConvertTo-NormalizedArchitecture -Architecture ([string] (Get-ObjectPropertyValue -InputObject $architectureCapability -Name 'Value'))
    }

    $osType = [string] (Get-NestedPropertyValue -InputObject $VM -Path @('StorageProfile', 'OsDisk', 'OsType'))
    $securityType = [string] (Get-NestedPropertyValue -InputObject $VM -Path @('SecurityProfile', 'SecurityType'))
    if ([string]::IsNullOrWhiteSpace($securityType)) {
        $securityType = 'Standard'
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $warnings.Add('VM architecture could not be determined.')
    }
    if ($null -eq $resourceSku) {
        $warnings.Add("VM size '$vmSize' was not found in the regional resource SKU catalog.")
    }

    return [pscustomobject]@{
        OSType                     = $osType
        Architecture               = $architecture
        HyperVGeneration           = [string] (Get-ObjectPropertyValue -InputObject $InstanceView -Name 'HyperVGeneration')
        SupportedHyperVGenerations = [string] (Get-ObjectPropertyValue -InputObject $generationCapability -Name 'Value')
        SecurityType               = $securityType
        VMSize                     = $vmSize
        Warnings                   = @($warnings)
    }
}

function ConvertTo-ComparableText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return ($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '')
}

function Get-TextToken {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @($Value.ToLowerInvariant() -split '[^a-z0-9]+' | Where-Object { $_.Length -gt 1 } | Sort-Object -Unique)
}

function Get-ImageCandidateScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Candidate,

        [Parameter(Mandatory)]
        [object] $NormalizedOS,

        [AllowNull()]
        [object] $CurrentImageReference
    )

    $candidateText = "$($Candidate.offer) $($Candidate.sku)"
    $candidateComparable = ConvertTo-ComparableText -Value $candidateText
    $score = 0
    $mismatchCount = 0
    $reasons = [System.Collections.Generic.List[string]]::new()

    $release = [string] (Get-ObjectPropertyValue -InputObject $NormalizedOS -Name 'Release')
    $releaseComparable = ConvertTo-ComparableText -Value $release
    if (-not [string]::IsNullOrWhiteSpace($releaseComparable) -and $candidateComparable.Contains($releaseComparable)) {
        $score += 40
        $reasons.Add("Release '$release' matched the offer or SKU.")
    }
    else {
        $mismatchCount++
        $reasons.Add("Release '$release' was not explicit in the offer or SKU.")
    }

    $secondaryMatched = $false
    $codename = [string] (Get-ObjectPropertyValue -InputObject $NormalizedOS -Name 'Codename')
    $servicePack = [string] (Get-ObjectPropertyValue -InputObject $NormalizedOS -Name 'ServicePack')
    if (-not [string]::IsNullOrWhiteSpace($codename) -and
        $candidateComparable.Contains((ConvertTo-ComparableText -Value $codename))) {
        $secondaryMatched = $true
        $reasons.Add("Codename '$codename' matched.")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($servicePack) -and
        $candidateComparable.Contains((ConvertTo-ComparableText -Value $servicePack))) {
        $secondaryMatched = $true
        $reasons.Add("Service pack '$servicePack' matched.")
    }
    elseif ($release -match '\.' -or $release -match '(?i)H\d$') {
        $secondaryMatched = -not [string]::IsNullOrWhiteSpace($releaseComparable) -and
            $candidateComparable.Contains($releaseComparable)
    }
    if ($secondaryMatched) {
        $score += 20
    }

    $expectedPublisher = [string] (Get-ObjectPropertyValue -InputObject $NormalizedOS -Name 'Publisher')
    if ($Candidate.publisher -eq $expectedPublisher) {
        $score += 15
        $reasons.Add("Publisher '$expectedPublisher' matched the detected product family.")
    }
    else {
        $mismatchCount++
    }

    $editionTokens = @(Get-ObjectPropertyValue -InputObject $NormalizedOS -Name 'EditionTokens')
    if ($editionTokens.Count -gt 0) {
        $matchedEditionTokens = @($editionTokens | Where-Object {
                $candidateComparable.Contains((ConvertTo-ComparableText -Value ([string] $_)))
            })
        $editionPoints = [math]::Round(10 * ($matchedEditionTokens.Count / $editionTokens.Count))
        $score += $editionPoints
        if ($matchedEditionTokens.Count -gt 0) {
            $reasons.Add("Edition tokens matched: $($matchedEditionTokens -join ', ').")
        }
    }

    $specializationTokens = @('byos', 'payg', 'pro', 'sap', 'hpc', 'minimal', 'core', 'azureedition', 'ha', 'lvm', 'raw')
    $currentText = "$((Get-ObjectPropertyValue -InputObject $CurrentImageReference -Name 'Offer')) $((Get-ObjectPropertyValue -InputObject $CurrentImageReference -Name 'Sku'))"
    $currentComparable = ConvertTo-ComparableText -Value $currentText
    $currentSpecializations = @($specializationTokens | Where-Object { $currentComparable.Contains($_) })
    $candidateSpecializations = @($specializationTokens | Where-Object { $candidateComparable.Contains($_) })
    $missingSpecializations = @($currentSpecializations | Where-Object { $_ -notin $candidateSpecializations })
    $extraSpecializations = @($candidateSpecializations | Where-Object { $_ -notin $currentSpecializations })
    if ($missingSpecializations.Count -eq 0 -and $extraSpecializations.Count -eq 0) {
        $score += 10
        $reasons.Add('Image specialization matched the current reference.')
    }
    else {
        $mismatchCount += $missingSpecializations.Count + $extraSpecializations.Count
        $score -= [math]::Min(10, 5 * ($missingSpecializations.Count + $extraSpecializations.Count))
    }

    $currentTokens = @(Get-TextToken -Value $currentText)
    $candidateTokens = @(Get-TextToken -Value $candidateText)
    if ($currentTokens.Count -gt 0 -and $candidateTokens.Count -gt 0) {
        $intersection = @($currentTokens | Where-Object { $_ -in $candidateTokens }).Count
        $union = @($currentTokens + $candidateTokens | Sort-Object -Unique).Count
        if ($union -gt 0) {
            $score += [math]::Round(5 * ($intersection / $union))
        }
    }

    if ($candidateText -match '(?i)preview|beta') {
        $score -= 15
        $mismatchCount++
        $reasons.Add('Preview or beta image penalized.')
    }

    $score = [math]::Max(0, [math]::Min(100, $score))
    return [pscustomobject]@{
        Candidate     = $Candidate
        Score         = [int] $score
        MismatchCount = $mismatchCount
        Reasons       = @($reasons)
    }
}

function Get-RankedCatalogCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Catalog,

        [Parameter(Mandatory)]
        [object] $NormalizedOS,

        [AllowNull()]
        [object] $CurrentImageReference
    )

    if (-not (Get-ObjectPropertyValue -InputObject $NormalizedOS -Name 'IsSupported')) {
        return @()
    }

    $publisher = [string] (Get-ObjectPropertyValue -InputObject $NormalizedOS -Name 'Publisher')
    $candidates = @($Catalog.entries | Where-Object {
            $_.publisher -eq $publisher
        })
    $scored = foreach ($candidate in $candidates) {
        Get-ImageCandidateScore -Candidate $candidate -NormalizedOS $NormalizedOS -CurrentImageReference $CurrentImageReference
    }

    return @($scored | Where-Object { $_.Score -ge 40 } | Sort-Object `
            @{ Expression = 'Score'; Descending = $true },
            @{ Expression = 'MismatchCount'; Descending = $false },
            @{ Expression = { $_.Candidate.publisher }; Descending = $false },
            @{ Expression = { $_.Candidate.offer }; Descending = $false },
            @{ Expression = { $_.Candidate.sku }; Descending = $false })
}

function Get-RecommendationConfidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [int] $Score
    )

    if ($Score -ge 80) {
        return 'High'
    }
    if ($Score -ge 60) {
        return 'Medium'
    }
    return 'Low'
}

function Get-RegionalImageCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Location,

        [Parameter(Mandatory)]
        [string] $Publisher,

        [Parameter(Mandatory)]
        [object] $AzContext,

        [Parameter(Mandatory)]
        [hashtable] $Cache,

        [AllowNull()]
        [scriptblock] $CatalogLookup
    )

    $cacheKey = "$Location|$Publisher".ToLowerInvariant()
    if ($Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey]
    }

    try {
        $candidates = if ($null -ne $CatalogLookup) {
            @(& $CatalogLookup $Location $Publisher $AzContext)
        }
        else {
            $discovered = [System.Collections.Generic.List[object]]::new()
            $offers = @(Get-AzVMImageOffer -Location $Location -PublisherName $Publisher -DefaultProfile $AzContext)
            foreach ($offerObject in $offers) {
                $offer = Get-CatalogItemName -InputObject $offerObject -PreferredProperties @('Offer', 'Name')
                if ([string]::IsNullOrWhiteSpace($offer)) {
                    continue
                }

                $skus = @(Get-AzVMImageSku -Location $Location -PublisherName $Publisher -Offer $offer -DefaultProfile $AzContext)
                foreach ($skuObject in $skus) {
                    $sku = Get-CatalogItemName -InputObject $skuObject -PreferredProperties @('Skus', 'Sku', 'Name')
                    if (-not [string]::IsNullOrWhiteSpace($sku)) {
                        $discovered.Add([pscustomobject]@{
                                publisher = $Publisher
                                offer     = $offer
                                sku       = $sku
                            })
                    }
                }
            }
            @($discovered)
        }

        $record = [pscustomobject]@{
            Succeeded    = $true
            Candidates   = @($candidates | Sort-Object publisher, offer, sku -Unique)
            ErrorMessage = $null
        }
    }
    catch {
        $record = [pscustomobject]@{
            Succeeded    = $false
            Candidates   = @()
            ErrorMessage = $_.Exception.Message
        }
    }

    $Cache[$cacheKey] = $record
    return $record
}

function Get-VMImageRestDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Candidate,

        [Parameter(Mandatory)]
        [string] $Version,

        [Parameter(Mandatory)]
        [object] $AzContext
    )

    $subscriptionId = [string] (Get-NestedPropertyValue -InputObject $AzContext -Path @('Subscription', 'Id'))
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        return [pscustomobject]@{
            Succeeded    = $false
            Properties   = $null
            ErrorMessage = 'The active Azure context does not expose a subscription ID.'
        }
    }

    $segments = @(
        $Candidate.location
        $Candidate.publisher
        $Candidate.offer
        $Candidate.sku
        $Version
    ) | ForEach-Object { [uri]::EscapeDataString([string] $_) }
    $resourcePath = "/subscriptions/$subscriptionId/providers/Microsoft.Compute/locations/$($segments[0])/publishers/$($segments[1])/artifacttypes/vmimage/offers/$($segments[2])/skus/$($segments[3])/versions/$($segments[4])"
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($apiVersion in $script:MarketplaceImageApiVersions) {
        try {
            $response = Invoke-AzRestReadWithRetry -Path "$resourcePath`?api-version=$apiVersion" -AzContext $AzContext
            $statusCode = [int] (Get-ObjectPropertyValue -InputObject $response -Name 'StatusCode')
            if ($statusCode -lt 200 -or $statusCode -ge 300) {
                $errors.Add("API $apiVersion returned HTTP $statusCode.")
                continue
            }

            $body = ([string] (Get-ObjectPropertyValue -InputObject $response -Name 'Content')) | ConvertFrom-Json -Depth 20
            $properties = Get-ObjectPropertyValue -InputObject $body -Name 'Properties'
            if ($null -eq $properties) {
                $errors.Add("API $apiVersion returned no image properties.")
                continue
            }

            return [pscustomobject]@{
                Succeeded    = $true
                Properties   = $properties
                ErrorMessage = $null
            }
        }
        catch {
            $errors.Add("API $apiVersion failed: $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        Succeeded    = $false
        Properties   = $null
        ErrorMessage = $errors -join ' '
    }
}

function ConvertTo-VMImageDetailRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Image,

        [Parameter(Mandatory)]
        [string] $Version,

        [bool] $FeatureMetadataAvailable = $false,

        [AllowNull()]
        [string] $MetadataWarning
    )

    $features = @(Get-ObjectPropertyValue -InputObject $Image -Name 'Features') | ForEach-Object {
        [pscustomobject]@{
            Name  = [string] (Get-ObjectPropertyValue -InputObject $_ -Name 'Name')
            Value = [string] (Get-ObjectPropertyValue -InputObject $_ -Name 'Value')
        }
    }
    $deprecationState = [string] (Get-NestedPropertyValue -InputObject $Image -Path @('ImageDeprecationStatus', 'ImageState'))
    if ([string]::IsNullOrWhiteSpace($deprecationState)) {
        $deprecationState = 'Active'
    }
    $purchasePlan = Get-ObjectPropertyValue -InputObject $Image -Name 'Plan'
    if ($null -eq $purchasePlan) {
        $purchasePlan = Get-ObjectPropertyValue -InputObject $Image -Name 'PurchasePlan'
    }

    return [pscustomobject]@{
        Succeeded                = $true
        Version                  = $Version
        OSType                   = [string] (Get-NestedPropertyValue -InputObject $Image -Path @('OSDiskImage', 'OperatingSystem'))
        Architecture             = ConvertTo-NormalizedArchitecture -Architecture ([string] (Get-ObjectPropertyValue -InputObject $Image -Name 'Architecture'))
        HyperVGeneration         = [string] (Get-ObjectPropertyValue -InputObject $Image -Name 'HyperVGeneration')
        Features                 = @($features)
        FeatureMetadataAvailable = $FeatureMetadataAvailable
        DeprecationState         = $deprecationState
        PurchasePlan             = $purchasePlan
        MetadataWarning          = $MetadataWarning
        ErrorMessage             = $null
    }
}

function Get-LiveVMImageDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Candidate,

        [Parameter(Mandatory)]
        [object] $AzContext,

        [Parameter(Mandatory)]
        [hashtable] $Cache,

        [AllowNull()]
        [scriptblock] $ImageLookup
    )

    $cacheKey = "$($Candidate.location)|$($Candidate.publisher)|$($Candidate.offer)|$($Candidate.sku)".ToLowerInvariant()
    if ($Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey]
    }

    try {
        if ($null -ne $ImageLookup) {
            $image = @(& $ImageLookup $Candidate $AzContext) | Select-Object -First 1
            if ($null -eq $image) {
                throw 'No image version is available.'
            }
            $version = [string] (Get-CatalogItemName -InputObject $image -PreferredProperties @('Version', 'Name'))
            $hasFeatureProperty = $image.PSObject.Properties.Name -contains 'Features'
            $details = ConvertTo-VMImageDetailRecord -Image $image -Version $version `
                -FeatureMetadataAvailable:$hasFeatureProperty
        }
        else {
            $image = @(Get-AzVMImage -Location $Candidate.location -PublisherName $Candidate.publisher `
                    -Offer $Candidate.offer -Skus $Candidate.sku -Top 1 -OrderBy 'name desc' `
                    -DefaultProfile $AzContext) | Select-Object -First 1
            if ($null -eq $image) {
                throw 'No image version is available.'
            }
            $version = [string] (Get-CatalogItemName -InputObject $image -PreferredProperties @('Version', 'Name'))
            $restDetail = Get-VMImageRestDetail -Candidate $Candidate -Version $version -AzContext $AzContext
            if ($restDetail.Succeeded) {
                $details = ConvertTo-VMImageDetailRecord -Image $restDetail.Properties -Version $version `
                    -FeatureMetadataAvailable:$true
            }
            else {
                $exactImage = Get-AzVMImage -Location $Candidate.location -PublisherName $Candidate.publisher `
                    -Offer $Candidate.offer -Skus $Candidate.sku -Version $version -Expand 'properties' `
                    -DefaultProfile $AzContext
                $details = ConvertTo-VMImageDetailRecord -Image $exactImage -Version $version `
                    -MetadataWarning "Security feature metadata could not be retrieved from REST. $($restDetail.ErrorMessage)"
            }
        }
    }
    catch {
        $details = [pscustomobject]@{
            Succeeded          = $false
            Version            = $null
            OSType             = $null
            Architecture       = $null
            HyperVGeneration   = $null
            Features           = @()
            FeatureMetadataAvailable = $false
            DeprecationState   = $null
            PurchasePlan       = $null
            MetadataWarning    = $null
            ErrorMessage       = $_.Exception.Message
        }
    }

    $Cache[$cacheKey] = $details
    return $details
}

function Get-ValidatedVMImageCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $RankedCandidates,

        [Parameter(Mandatory)]
        [string] $Location,

        [Parameter(Mandatory)]
        [object] $CompatibilityProfile,

        [AllowNull()]
        [object] $CurrentImageReference,

        [Parameter(Mandatory)]
        [object] $AzContext,

        [Parameter(Mandatory)]
        [hashtable] $LiveImageCache,

        [Parameter(Mandatory)]
        [ValidateSet('StaticCatalog', 'RegionalDiscovery')]
        [string] $Source,

        [AllowNull()]
        [scriptblock] $ImageLookup,

        [ValidateRange(1, 50)]
        [int] $MaximumCandidates = 10
    )

    $validated = [System.Collections.Generic.List[object]]::new()
    $rejections = [System.Collections.Generic.List[object]]::new()
    foreach ($scoredCandidate in ($RankedCandidates | Select-Object -First $MaximumCandidates)) {
        $runtimeCandidate = [pscustomobject]@{
            location  = $Location.ToLowerInvariant()
            publisher = $scoredCandidate.Candidate.publisher
            offer     = $scoredCandidate.Candidate.offer
            sku       = $scoredCandidate.Candidate.sku
        }
        $details = Get-LiveVMImageDetail -Candidate $runtimeCandidate -AzContext $AzContext `
            -Cache $LiveImageCache -ImageLookup $ImageLookup
        $compatibility = Test-VMImageCompatibility -ImageDetails $details `
            -CompatibilityProfile $CompatibilityProfile -CurrentImageReference $CurrentImageReference
        if (-not $compatibility.IsCompatible) {
            $rejections.Add([pscustomobject]@{
                    ImageReference = "$($runtimeCandidate.publisher):$($runtimeCandidate.offer):$($runtimeCandidate.sku)"
                    Source         = $Source
                    Reasons        = @($compatibility.RejectionReasons)
                })
            continue
        }

        $validated.Add([pscustomobject]@{
                Candidate       = $runtimeCandidate
                Source          = $Source
                Score           = [math]::Max(0, $scoredCandidate.Score + $compatibility.ScoreAdjustment)
                MismatchCount   = $scoredCandidate.MismatchCount
                Reasons         = @($scoredCandidate.Reasons)
                Warnings        = @($compatibility.Warnings)
                ImageDetails    = $details
            })
    }

    return [pscustomobject]@{
        Compatible = @($validated)
        Rejections = @($rejections)
    }
}

function Test-VMImageCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $ImageDetails,

        [Parameter(Mandatory)]
        [object] $CompatibilityProfile,

        [AllowNull()]
        [object] $CurrentImageReference
    )

    $rejectionReasons = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $scoreAdjustment = 0

    if (-not $ImageDetails.Succeeded) {
        $rejectionReasons.Add("Live image lookup failed: $($ImageDetails.ErrorMessage)")
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($CompatibilityProfile.OSType) -and
            -not [string]::IsNullOrWhiteSpace($ImageDetails.OSType) -and
            $CompatibilityProfile.OSType -ne $ImageDetails.OSType) {
            $rejectionReasons.Add("OS type '$($ImageDetails.OSType)' does not match VM OS type '$($CompatibilityProfile.OSType)'.")
        }
        if (-not [string]::IsNullOrWhiteSpace($CompatibilityProfile.Architecture) -and
            -not [string]::IsNullOrWhiteSpace($ImageDetails.Architecture) -and
            $CompatibilityProfile.Architecture -ne $ImageDetails.Architecture) {
            $rejectionReasons.Add("Architecture '$($ImageDetails.Architecture)' does not match VM architecture '$($CompatibilityProfile.Architecture)'.")
        }
        if (-not [string]::IsNullOrWhiteSpace($CompatibilityProfile.HyperVGeneration) -and
            -not [string]::IsNullOrWhiteSpace($ImageDetails.HyperVGeneration) -and
            $CompatibilityProfile.HyperVGeneration -ne $ImageDetails.HyperVGeneration) {
            $rejectionReasons.Add("Hyper-V generation '$($ImageDetails.HyperVGeneration)' does not match VM generation '$($CompatibilityProfile.HyperVGeneration)'.")
        }

        $featureMetadataAvailable = Get-ObjectPropertyValue -InputObject $ImageDetails -Name 'FeatureMetadataAvailable'
        if ($null -eq $featureMetadataAvailable) {
            $featureMetadataAvailable = $ImageDetails.PSObject.Properties.Name -contains 'Features'
        }
        $featureText = ($ImageDetails.Features | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';'
        if ($CompatibilityProfile.SecurityType -in @('TrustedLaunch', 'ConfidentialVM')) {
            if (-not $featureMetadataAvailable) {
                $warnings.Add('Image security support could not be verified because feature metadata was unavailable.')
            }
            elseif ($CompatibilityProfile.SecurityType -eq 'TrustedLaunch' -and $featureText -notmatch '(?i)TrustedLaunch') {
                $rejectionReasons.Add('Image does not declare Trusted Launch support.')
            }
            elseif ($CompatibilityProfile.SecurityType -eq 'ConfidentialVM' -and $featureText -notmatch '(?i)Confidential') {
                $rejectionReasons.Add('Image does not declare Confidential VM support.')
            }
        }
        $metadataWarning = [string] (Get-ObjectPropertyValue -InputObject $ImageDetails -Name 'MetadataWarning')
        if (-not [string]::IsNullOrWhiteSpace($metadataWarning)) {
            $warnings.Add($metadataWarning)
        }

        if ($ImageDetails.DeprecationState -eq 'Deprecated') {
            $rejectionReasons.Add('Image is deprecated.')
        }
        elseif ($ImageDetails.DeprecationState -eq 'ScheduledForDeprecation') {
            $scoreAdjustment -= 10
            $warnings.Add('Image is scheduled for deprecation.')
        }

        $currentPlan = @(
            [string] (Get-ObjectPropertyValue -InputObject $CurrentImageReference -Name 'PlanPublisher')
            [string] (Get-ObjectPropertyValue -InputObject $CurrentImageReference -Name 'PlanProduct')
            [string] (Get-ObjectPropertyValue -InputObject $CurrentImageReference -Name 'PlanName')
        )
        $candidatePlan = @(
            [string] (Get-ObjectPropertyValue -InputObject $ImageDetails.PurchasePlan -Name 'Publisher')
            [string] (Get-ObjectPropertyValue -InputObject $ImageDetails.PurchasePlan -Name 'Product')
            [string] (Get-ObjectPropertyValue -InputObject $ImageDetails.PurchasePlan -Name 'Name')
        )
        $currentPlanUrn = $currentPlan -join ':'
        $candidatePlanUrn = $candidatePlan -join ':'
        $currentHasPlan = @($currentPlan | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
        $candidateHasPlan = @($candidatePlan | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
        if ($currentHasPlan -ne $candidateHasPlan -or
            ($currentHasPlan -and $candidatePlanUrn -ine $currentPlanUrn)) {
            $candidatePlanDescription = if ($candidateHasPlan) { $candidatePlanUrn } else { 'none' }
            $currentPlanDescription = if ($currentHasPlan) { $currentPlanUrn } else { 'none' }
            $rejectionReasons.Add("Image purchase plan '$candidatePlanDescription' does not match current VM plan '$currentPlanDescription'.")
        }
    }

    return [pscustomobject]@{
        IsCompatible     = $rejectionReasons.Count -eq 0
        RejectionReasons = @($rejectionReasons)
        Warnings         = @($warnings)
        ScoreAdjustment  = $scoreAdjustment
    }
}

function Find-VMImageRecommendation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Catalog,

        [Parameter(Mandatory)]
        [string] $Location,

        [Parameter(Mandatory)]
        [object] $NormalizedOS,

        [Parameter(Mandatory)]
        [object] $CompatibilityProfile,

        [AllowNull()]
        [object] $CurrentImageReference,

        [Parameter(Mandatory)]
        [object] $AzContext,

        [Parameter(Mandatory)]
        [hashtable] $LiveImageCache,

        [hashtable] $RegionalCatalogCache = @{},

        [AllowNull()]
        [scriptblock] $ImageLookup,

        [AllowNull()]
        [scriptblock] $RegionalCatalogLookup,

        [ValidateRange(1, 50)]
        [int] $MaximumCandidates = 10
    )

    $ranked = @(Get-RankedCatalogCandidate -Catalog $Catalog -NormalizedOS $NormalizedOS `
            -CurrentImageReference $CurrentImageReference)
    $validated = [System.Collections.Generic.List[object]]::new()
    $rejections = [System.Collections.Generic.List[object]]::new()
    $dynamicDiscoveryError = $null

    $staticValidation = Get-ValidatedVMImageCandidate -RankedCandidates $ranked -Location $Location `
        -CompatibilityProfile $CompatibilityProfile -CurrentImageReference $CurrentImageReference `
        -AzContext $AzContext -LiveImageCache $LiveImageCache `
        -Source 'StaticCatalog' -ImageLookup $ImageLookup -MaximumCandidates $MaximumCandidates
    foreach ($candidate in @($staticValidation.Compatible)) {
        $validated.Add($candidate)
    }
    foreach ($rejection in @($staticValidation.Rejections)) {
        $rejections.Add($rejection)
    }

    if ($validated.Count -eq 0 -and $NormalizedOS.IsSupported) {
        $regionalCatalog = Get-RegionalImageCandidate -Location $Location -Publisher $NormalizedOS.Publisher `
            -AzContext $AzContext -Cache $RegionalCatalogCache -CatalogLookup $RegionalCatalogLookup
        if ($regionalCatalog.Succeeded) {
            $dynamicCatalog = [pscustomobject]@{ entries = @($regionalCatalog.Candidates) }
            $dynamicRanked = @(Get-RankedCatalogCandidate -Catalog $dynamicCatalog -NormalizedOS $NormalizedOS `
                    -CurrentImageReference $CurrentImageReference)
            $staticKeys = @($ranked | ForEach-Object {
                    "$($_.Candidate.publisher)|$($_.Candidate.offer)|$($_.Candidate.sku)".ToLowerInvariant()
                })
            $dynamicRanked = @($dynamicRanked | Where-Object {
                    "$($_.Candidate.publisher)|$($_.Candidate.offer)|$($_.Candidate.sku)".ToLowerInvariant() -notin $staticKeys
                })
            $dynamicValidation = Get-ValidatedVMImageCandidate -RankedCandidates $dynamicRanked -Location $Location `
                -CompatibilityProfile $CompatibilityProfile -CurrentImageReference $CurrentImageReference `
                -AzContext $AzContext -LiveImageCache $LiveImageCache `
                -Source 'RegionalDiscovery' -ImageLookup $ImageLookup -MaximumCandidates $MaximumCandidates
            foreach ($candidate in @($dynamicValidation.Compatible)) {
                $validated.Add($candidate)
            }
            foreach ($rejection in @($dynamicValidation.Rejections)) {
                $rejections.Add($rejection)
            }
        }
        else {
            $dynamicDiscoveryError = $regionalCatalog.ErrorMessage
        }
    }

    $compatible = @($validated | Sort-Object `
            @{ Expression = 'Score'; Descending = $true },
            @{ Expression = 'MismatchCount'; Descending = $false },
            @{ Expression = { $_.Candidate.publisher }; Descending = $false },
            @{ Expression = { $_.Candidate.offer }; Descending = $false },
            @{ Expression = { $_.Candidate.sku }; Descending = $false })
    if ($compatible.Count -eq 0) {
        return [pscustomobject]@{
            Status       = 'NoCompatibleCandidate'
            Selected     = $null
            Alternatives = @()
            Rejections   = @($rejections)
            DynamicDiscoveryError = $dynamicDiscoveryError
        }
    }

    $winner = $compatible[0]
    $runnerUpScore = if ($compatible.Count -gt 1) { $compatible[1].Score } else { 0 }
    $lead = $winner.Score - $runnerUpScore
    $confidence = Get-RecommendationConfidence -Score $winner.Score

    $candidate = $winner.Candidate
    $selected = [pscustomobject]@{
        ImageReference  = "$($candidate.publisher):$($candidate.offer):$($candidate.sku)"
        Urn             = "$($candidate.publisher):$($candidate.offer):$($candidate.sku):latest"
        ConcreteVersion = $winner.ImageDetails.Version
        Score           = $winner.Score
        ScoreLead       = $lead
        Confidence      = $confidence
        Source          = $winner.Source
        Reasons         = @($winner.Reasons)
        Warnings        = @($winner.Warnings)
        OSType          = $winner.ImageDetails.OSType
        Architecture    = $winner.ImageDetails.Architecture
        HyperVGeneration = $winner.ImageDetails.HyperVGeneration
        DeprecationState = $winner.ImageDetails.DeprecationState
        PurchasePlan    = $winner.ImageDetails.PurchasePlan
    }

    $alternatives = @($compatible | Select-Object -Skip 1 -First 3 | ForEach-Object {
            [pscustomobject]@{
                ImageReference  = "$($_.Candidate.publisher):$($_.Candidate.offer):$($_.Candidate.sku)"
                Urn             = "$($_.Candidate.publisher):$($_.Candidate.offer):$($_.Candidate.sku):latest"
                ConcreteVersion = $_.ImageDetails.Version
                Score           = $_.Score
            }
        })

    return [pscustomobject]@{
        Status       = 'Selected'
        Selected     = $selected
        Alternatives = $alternatives
        Rejections   = @($rejections)
        DynamicDiscoveryError = $dynamicDiscoveryError
    }
}

function Get-CatalogWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Catalog
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($Catalog.AgeDays -gt 30) {
        $warnings.Add("Catalog is $($Catalog.AgeDays) days old. Refresh is recommended after 30 days.")
    }
    if ((Get-ObjectPropertyValue -InputObject $Catalog -Name 'IsPartial') -eq $true) {
        $warnings.Add('Catalog refresh was partial; inspect its errors before relying on missing entries.')
    }

    return @($warnings)
}

function Get-RegionalResourceSkus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Location,

        [Parameter(Mandatory)]
        [object] $AzContext,

        [Parameter(Mandatory)]
        [hashtable] $Cache
    )

    $key = $Location.ToLowerInvariant()
    if ($Cache.ContainsKey($key)) {
        return $Cache[$key]
    }

    try {
        $record = [pscustomobject]@{
            Succeeded    = $true
            ResourceSkus = @(Get-AzComputeResourceSku -Location $Location -DefaultProfile $AzContext)
            ErrorMessage = $null
        }
    }
    catch {
        $record = [pscustomobject]@{
            Succeeded    = $false
            ResourceSkus = @()
            ErrorMessage = $_.Exception.Message
        }
    }

    $Cache[$key] = $record
    return $record
}

function Get-EffectiveGuestEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VM,

        [Parameter(Mandatory)]
        [object] $InstanceView,

        [Parameter(Mandatory)]
        [object] $CurrentImageReference,

        [Parameter(Mandatory)]
        [object] $AzContext,

        [switch] $AllowRunCommand
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not $InstanceView.Succeeded) {
        $errors.Add("Instance View: $($InstanceView.ErrorMessage)")
    }

    $normalized = Get-NormalizedGuestOS -OSName $InstanceView.OSName -OSVersion $InstanceView.OSVersion `
        -Architecture $InstanceView.Architecture -ProductType $InstanceView.ProductType `
        -CurrentPublisher $CurrentImageReference.Publisher -CurrentOffer $CurrentImageReference.Offer `
        -CurrentSku $CurrentImageReference.Sku -EvidenceSource 'InstanceView'
    $evidence = $InstanceView
    $needsFallback = [string]::IsNullOrWhiteSpace($InstanceView.OSName) -or
        [string]::IsNullOrWhiteSpace($InstanceView.OSVersion) -or
        -not $normalized.IsSupported -or [string]::IsNullOrWhiteSpace($normalized.Release)

    if ($AllowRunCommand -and $needsFallback) {
        $osType = [string] (Get-NestedPropertyValue -InputObject $VM -Path @('StorageProfile', 'OsDisk', 'OsType'))
        if ($InstanceView.PowerState -ne 'PowerState/running') {
            $errors.Add('Run Command fallback skipped because the VM is not confirmed running.')
        }
        elseif (-not $InstanceView.VMAgentReady) {
            $errors.Add('Run Command fallback skipped because the VM Agent is not ready.')
        }
        elseif ($osType -notin @('Windows', 'Linux')) {
            $errors.Add("Run Command fallback skipped because OS type '$osType' is unsupported.")
        }
        else {
            $fallback = Get-VMRunCommandEvidence -VM $VM -OSType $osType -AzContext $AzContext
            if ($fallback.Succeeded) {
                $evidence = [pscustomobject]@{
                    Succeeded        = $true
                    OSName           = $fallback.OSName
                    OSVersion        = $fallback.OSVersion
                    Architecture     = $fallback.Architecture
                    ProductType      = $fallback.ProductType
                    HyperVGeneration = $InstanceView.HyperVGeneration
                    PowerState       = $InstanceView.PowerState
                    VMAgentReady     = $InstanceView.VMAgentReady
                    EvidenceSource   = 'RunCommand'
                    ErrorMessage     = $null
                }
                $normalized = Get-NormalizedGuestOS -OSName $fallback.OSName -OSVersion $fallback.OSVersion `
                    -Architecture $fallback.Architecture -ProductType $fallback.ProductType `
                    -CurrentPublisher $CurrentImageReference.Publisher -CurrentOffer $CurrentImageReference.Offer `
                    -CurrentSku $CurrentImageReference.Sku -EvidenceSource 'RunCommand'
            }
            else {
                $errors.Add("Run Command: $($fallback.ErrorMessage)")
            }
        }
    }

    return [pscustomobject]@{
        Evidence     = $evidence
        NormalizedOS = $normalized
        Errors       = @($errors)
    }
}

function ConvertTo-VMScanFailureRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $VM,

        [Parameter(Mandatory)]
        [string] $Message
    )

    return [pscustomobject]@{
        VM = [pscustomobject]@{
            Id                = [string] (Get-ObjectPropertyValue -InputObject $VM -Name 'Id')
            ResourceGroupName = Get-VMResourceGroupName -VM $VM
            Name              = [string] (Get-ObjectPropertyValue -InputObject $VM -Name 'Name')
            Location          = [string] (Get-ObjectPropertyValue -InputObject $VM -Name 'Location')
        }
        CurrentImageReference = $null
        InstanceView          = $null
        GuestOS               = $null
        Compatibility         = $null
        Recommendation        = [pscustomobject]@{ Status = 'ScanFailed'; Selected = $null; Alternatives = @(); Rejections = @() }
        Warnings              = @()
        Errors                = @($Message)
    }
}

function Get-CurrentImageUrn {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $ImageReference
    )

    if ($null -eq $ImageReference) {
        return ''
    }

    $version = [string] (Get-ObjectPropertyValue -InputObject $ImageReference -Name 'ExactVersion')
    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = [string] (Get-ObjectPropertyValue -InputObject $ImageReference -Name 'Version')
    }
    $segments = @(
        [string] (Get-ObjectPropertyValue -InputObject $ImageReference -Name 'Publisher')
        [string] (Get-ObjectPropertyValue -InputObject $ImageReference -Name 'Offer')
        [string] (Get-ObjectPropertyValue -InputObject $ImageReference -Name 'Sku')
        $version
    )
    if (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        return ''
    }

    return $segments -join ':'
}

function Get-CurrentPlanUrn {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $ImageReference
    )

    if ($null -eq $ImageReference) {
        return ''
    }

    $segments = @(
        [string] (Get-ObjectPropertyValue -InputObject $ImageReference -Name 'PlanPublisher')
        [string] (Get-ObjectPropertyValue -InputObject $ImageReference -Name 'PlanProduct')
        [string] (Get-ObjectPropertyValue -InputObject $ImageReference -Name 'PlanName')
    )
    if (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        return ''
    }

    return $segments -join ':'
}

function ConvertTo-VMReportJsonRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object] $Result
    )

    process {
        $current = Get-ObjectPropertyValue -InputObject $Result -Name 'CurrentImageReference'
        $recommendation = Get-ObjectPropertyValue -InputObject $Result -Name 'Recommendation'
        $selected = Get-ObjectPropertyValue -InputObject $recommendation -Name 'Selected'
        $selectedRecord = if ($null -eq $selected) {
            $null
        }
        else {
            [pscustomobject][ordered]@{
                Urn                = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'Urn')
                ConcreteVersion    = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'ConcreteVersion')
                Score              = Get-ObjectPropertyValue -InputObject $selected -Name 'Score'
                ScoreLead          = Get-ObjectPropertyValue -InputObject $selected -Name 'ScoreLead'
                Confidence         = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'Confidence')
                Source             = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'Source')
                Reasons            = @(Get-ObjectPropertyValue -InputObject $selected -Name 'Reasons')
                Warnings           = @(Get-ObjectPropertyValue -InputObject $selected -Name 'Warnings')
                OSType             = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'OSType')
                Architecture       = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'Architecture')
                HyperVGeneration   = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'HyperVGeneration')
                DeprecationState   = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'DeprecationState')
                PurchasePlan       = Get-ObjectPropertyValue -InputObject $selected -Name 'PurchasePlan'
            }
        }
        $alternatives = @(Get-ObjectPropertyValue -InputObject $recommendation -Name 'Alternatives') | ForEach-Object {
            [pscustomobject][ordered]@{
                Urn             = [string] (Get-ObjectPropertyValue -InputObject $_ -Name 'Urn')
                ConcreteVersion = [string] (Get-ObjectPropertyValue -InputObject $_ -Name 'ConcreteVersion')
                Score           = Get-ObjectPropertyValue -InputObject $_ -Name 'Score'
            }
        }

        [pscustomobject][ordered]@{
            VM = [pscustomobject][ordered]@{
                ResourceGroupName = [string] (Get-ObjectPropertyValue -InputObject $Result.VM -Name 'ResourceGroupName')
                Name              = [string] (Get-ObjectPropertyValue -InputObject $Result.VM -Name 'Name')
                Location          = [string] (Get-ObjectPropertyValue -InputObject $Result.VM -Name 'Location')
            }
            CurrentImageReference = if ($null -eq $current) {
                $null
            }
            else {
                [pscustomobject][ordered]@{
                    SourceType              = [string] (Get-ObjectPropertyValue -InputObject $current -Name 'SourceType')
                    Urn                     = Get-CurrentImageUrn -ImageReference $current
                    Id                      = [string] (Get-ObjectPropertyValue -InputObject $current -Name 'Id')
                    SharedGalleryImageId    = [string] (Get-ObjectPropertyValue -InputObject $current -Name 'SharedGalleryImageId')
                    CommunityGalleryImageId = [string] (Get-ObjectPropertyValue -InputObject $current -Name 'CommunityGalleryImageId')
                    PlanUrn                 = Get-CurrentPlanUrn -ImageReference $current
                }
            }
            InstanceView          = Get-ObjectPropertyValue -InputObject $Result -Name 'InstanceView'
            GuestOS               = Get-ObjectPropertyValue -InputObject $Result -Name 'GuestOS'
            Compatibility         = Get-ObjectPropertyValue -InputObject $Result -Name 'Compatibility'
            Recommendation        = [pscustomobject][ordered]@{
                Status                = [string] (Get-ObjectPropertyValue -InputObject $recommendation -Name 'Status')
                Selected              = $selectedRecord
                Alternatives          = @($alternatives)
                Rejections            = @(Get-ObjectPropertyValue -InputObject $recommendation -Name 'Rejections')
                DynamicDiscoveryError = Get-ObjectPropertyValue -InputObject $recommendation -Name 'DynamicDiscoveryError'
            }
            Warnings              = @(Get-ObjectPropertyValue -InputObject $Result -Name 'Warnings')
            Errors                = @(Get-ObjectPropertyValue -InputObject $Result -Name 'Errors')
        }
    }
}

function ConvertTo-VMReportCsvRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object] $Result,

        [Parameter(Mandatory)]
        [object] $Catalog
    )

    process {
        $selected = Get-ObjectPropertyValue -InputObject $Result.Recommendation -Name 'Selected'
        [pscustomobject][ordered]@{
            ResourceGroupName            = [string] (Get-ObjectPropertyValue -InputObject $Result.VM -Name 'ResourceGroupName')
            VMName                       = [string] (Get-ObjectPropertyValue -InputObject $Result.VM -Name 'Name')
            Location                     = [string] (Get-ObjectPropertyValue -InputObject $Result.VM -Name 'Location')
            VMSize                       = [string] (Get-ObjectPropertyValue -InputObject $Result.Compatibility -Name 'VMSize')
            CurrentSourceType            = [string] (Get-ObjectPropertyValue -InputObject $Result.CurrentImageReference -Name 'SourceType')
            CurrentUrn                   = Get-CurrentImageUrn -ImageReference $Result.CurrentImageReference
            CurrentImageId               = [string] (Get-ObjectPropertyValue -InputObject $Result.CurrentImageReference -Name 'Id')
            CurrentSharedGalleryImageId  = [string] (Get-ObjectPropertyValue -InputObject $Result.CurrentImageReference -Name 'SharedGalleryImageId')
            CurrentCommunityGalleryId    = [string] (Get-ObjectPropertyValue -InputObject $Result.CurrentImageReference -Name 'CommunityGalleryImageId')
            CurrentPlanUrn               = Get-CurrentPlanUrn -ImageReference $Result.CurrentImageReference
            RunningOSName                = [string] (Get-ObjectPropertyValue -InputObject $Result.InstanceView -Name 'OSName')
            RunningOSVersion             = [string] (Get-ObjectPropertyValue -InputObject $Result.InstanceView -Name 'OSVersion')
            OSEvidenceSource             = [string] (Get-ObjectPropertyValue -InputObject $Result.InstanceView -Name 'EvidenceSource')
            NormalizedPublisher          = [string] (Get-ObjectPropertyValue -InputObject $Result.GuestOS -Name 'Publisher')
            NormalizedFamily             = [string] (Get-ObjectPropertyValue -InputObject $Result.GuestOS -Name 'Family')
            NormalizedRelease            = [string] (Get-ObjectPropertyValue -InputObject $Result.GuestOS -Name 'Release')
            NormalizedBuild              = [string] (Get-ObjectPropertyValue -InputObject $Result.GuestOS -Name 'Build')
            Architecture                 = [string] (Get-ObjectPropertyValue -InputObject $Result.Compatibility -Name 'Architecture')
            HyperVGeneration             = [string] (Get-ObjectPropertyValue -InputObject $Result.Compatibility -Name 'HyperVGeneration')
            SecurityType                 = [string] (Get-ObjectPropertyValue -InputObject $Result.Compatibility -Name 'SecurityType')
            RecommendationStatus         = [string] (Get-ObjectPropertyValue -InputObject $Result.Recommendation -Name 'Status')
            RecommendedUrn               = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'Urn')
            ValidatedConcreteVersion     = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'ConcreteVersion')
            RecommendationScore          = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'Score')
            RecommendationConfidence     = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'Confidence')
            RecommendationSource         = [string] (Get-ObjectPropertyValue -InputObject $selected -Name 'Source')
            CatalogGeneratedAtUtc        = [string] $Catalog.generatedAtUtc
            CatalogAgeDays               = [string] $Catalog.AgeDays
            Warnings                     = @($Result.Warnings) -join '; '
            Errors                       = @($Result.Errors) -join '; '
        }
    }
}

function Export-VMImageReferenceReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Results,

        [Parameter(Mandatory)]
        [object] $Catalog,

        [Parameter(Mandatory)]
        [object] $AzContext,

        [Parameter(Mandatory)]
        [string] $TargetSubscriptionId,

        [Parameter(Mandatory)]
        [string] $Directory
    )

    [System.IO.Directory]::CreateDirectory($Directory) | Out-Null
    $timestamp = [datetimeoffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $csvPath = Join-Path $Directory "vm-image-reference-report-$timestamp.csv"
    $jsonPath = Join-Path $Directory "vm-image-reference-report-$timestamp.json"
    $csvTemporaryPath = "$csvPath.$([guid]::NewGuid().Guid).tmp"
    $jsonTemporaryPath = "$jsonPath.$([guid]::NewGuid().Guid).tmp"

    $flatResults = @($Results | ConvertTo-VMReportCsvRow -Catalog $Catalog)
    $jsonResults = @($Results | ConvertTo-VMReportJsonRecord)
    $selectedCount = @($Results | Where-Object { $_.Recommendation.Status -eq 'Selected' }).Count
    $report = [ordered]@{
        schemaVersion  = $script:ReportSchemaVersion
        generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        subscriptionId = $TargetSubscriptionId
        environment    = [string] (Get-NestedPropertyValue -InputObject $AzContext -Path @('Environment', 'Name'))
        catalog         = [ordered]@{
            schemaVersion  = $Catalog.schemaVersion
            scope          = $Catalog.scope
            generatedAtUtc = $Catalog.generatedAtUtc
            ageDays         = $Catalog.AgeDays
            baseRegion      = $Catalog.baseRegion
            isPartial       = [bool] (Get-ObjectPropertyValue -InputObject $Catalog -Name 'IsPartial')
        }
        summary         = [ordered]@{
            vmCount                 = $Results.Count
            recommendationCount     = $selectedCount
            unresolvedCount         = $Results.Count - $selectedCount
        }
        results         = $jsonResults
    }

    try {
        $csvLines = if ($flatResults.Count -eq 0) { @() } else { @($flatResults | ConvertTo-Csv -NoTypeInformation) }
        [System.IO.File]::WriteAllLines($csvTemporaryPath, $csvLines, [System.Text.UTF8Encoding]::new($false))
        $json = $report | ConvertTo-Json -Depth 30
        [System.IO.File]::WriteAllText($jsonTemporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        Get-Content -LiteralPath $jsonTemporaryPath -Raw | ConvertFrom-Json -Depth 30 | Out-Null

        [System.IO.File]::Move($csvTemporaryPath, $csvPath, $true)
        [System.IO.File]::Move($jsonTemporaryPath, $jsonPath, $true)
    }
    finally {
        foreach ($temporaryPath in @($csvTemporaryPath, $jsonTemporaryPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
    }

    return [pscustomobject]@{
        CsvPath             = (Resolve-Path -LiteralPath $csvPath).Path
        JsonPath            = (Resolve-Path -LiteralPath $jsonPath).Path
        VMCount             = $Results.Count
        RecommendationCount = $selectedCount
        UnresolvedCount     = $Results.Count - $selectedCount
    }
}

function Invoke-VMImageReferenceReport {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($VMName) -and
        [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        throw 'ResourceGroupName is required when VMName is specified.'
    }

    $context = Get-ValidatedAzContext -TargetSubscriptionId $SubscriptionId
    $catalog = Import-VMImageCatalog -Path $CatalogPath
    $runWarnings = @(Get-CatalogWarning -Catalog $catalog)
    foreach ($warning in $runWarnings) {
        Write-Warning $warning
    }

        $virtualMachines = @(Get-TargetVM -AzContext $context -TargetResourceGroupName $ResourceGroupName `
            -TargetVMName $VMName | Where-Object { Test-IsStandaloneVM -VM $_ })
    $results = [System.Collections.Generic.List[object]]::new()
    $resourceSkuCache = @{}
    $liveImageCache = @{}
    $regionalCatalogCache = @{}

    for ($index = 0; $index -lt $virtualMachines.Count; $index++) {
        $vm = $virtualMachines[$index]
        $vmName = [string] (Get-ObjectPropertyValue -InputObject $vm -Name 'Name')
        Write-Progress -Activity 'Scanning Azure virtual machines' -Status $vmName `
            -PercentComplete ((($index + 1) / [math]::Max(1, $virtualMachines.Count)) * 100)

        try {
            $location = ([string] (Get-ObjectPropertyValue -InputObject $vm -Name 'Location')).ToLowerInvariant()
            $currentImageReference = Get-VMImageReferenceRecord -VM $vm
            $instanceView = Get-VMInstanceViewRecord -VM $vm -AzContext $context -ApiVersion $ComputeApiVersion
            $guest = Get-EffectiveGuestEvidence -VM $vm -InstanceView $instanceView `
                -CurrentImageReference $currentImageReference -AzContext $context `
                -AllowRunCommand:$UseRunCommandFallback

            $resourceSkuRecord = Get-RegionalResourceSkus -Location $location -AzContext $context -Cache $resourceSkuCache
            $compatibility = Get-VMCompatibilityProfile -VM $vm -ResourceSkus $resourceSkuRecord.ResourceSkus `
                -InstanceView $instanceView -DetectedArchitecture $guest.Evidence.Architecture
            $warnings = [System.Collections.Generic.List[string]]::new()
            foreach ($warning in $runWarnings + @($compatibility.Warnings)) {
                $warnings.Add($warning)
            }
            $errors = [System.Collections.Generic.List[string]]::new()
            foreach ($message in @($guest.Errors)) {
                $errors.Add($message)
            }
            if (-not $resourceSkuRecord.Succeeded) {
                $errors.Add("Resource SKU lookup: $($resourceSkuRecord.ErrorMessage)")
            }

            $recommendation = Find-VMImageRecommendation -Catalog $catalog -Location $location `
                -NormalizedOS $guest.NormalizedOS -CompatibilityProfile $compatibility `
                -CurrentImageReference $currentImageReference -AzContext $context `
                -LiveImageCache $liveImageCache -RegionalCatalogCache $regionalCatalogCache `
                -MaximumCandidates $CandidateLimit
            if (-not [string]::IsNullOrWhiteSpace($recommendation.DynamicDiscoveryError)) {
                $errors.Add("Regional image discovery: $($recommendation.DynamicDiscoveryError)")
            }
            if ($null -ne $recommendation.Selected) {
                foreach ($warning in @($recommendation.Selected.Warnings)) {
                    $warnings.Add($warning)
                }
            }

            $results.Add([pscustomobject]@{
                    VM = [pscustomobject]@{
                        Id                = [string] (Get-ObjectPropertyValue -InputObject $vm -Name 'Id')
                        ResourceGroupName = Get-VMResourceGroupName -VM $vm
                        Name              = $vmName
                        Location          = $location
                    }
                    CurrentImageReference = $currentImageReference
                    InstanceView          = $guest.Evidence
                    GuestOS               = $guest.NormalizedOS
                    Compatibility         = $compatibility
                    Recommendation        = $recommendation
                    Warnings              = @($warnings)
                    Errors                = @($errors)
                })
        }
        catch {
            $results.Add((ConvertTo-VMScanFailureRecord -VM $vm -Message $_.Exception.Message))
        }
    }
    Write-Progress -Activity 'Scanning Azure virtual machines' -Completed

    return Export-VMImageReferenceReport -Results @($results) -Catalog $catalog -AzContext $context `
        -TargetSubscriptionId $SubscriptionId -Directory $OutputDirectory
}

function Invoke-VMImageCatalogRefresh {
    [CmdletBinding()]
    param()

    $context = Get-ValidatedAzContext -TargetSubscriptionId $SubscriptionId
    $catalog = Get-VMImageCatalogSnapshot -AzContext $context -BaseRegion $CatalogBaseRegion
    $savedPath = Export-VMImageCatalog -Catalog $catalog -Path $CatalogPath -AllowPartial:$AllowPartialCatalog

    [pscustomobject]@{
        CatalogPath      = $savedPath
        EntryCount       = @($catalog.entries).Count
        BaseRegion       = $catalog.baseRegion
        IsPartial        = $catalog.isPartial
        ErrorCount       = @($catalog.errors).Count
        GeneratedAtUtc   = $catalog.generatedAtUtc
        Scope            = $catalog.scope
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($PSCmdlet.ParameterSetName -eq 'RefreshCatalog') {
        Invoke-VMImageCatalogRefresh
    }
    else {
        Invoke-VMImageReferenceReport
    }
}