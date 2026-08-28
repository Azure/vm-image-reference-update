BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '../scripts/Get-AzVmImageReferenceReport.ps1'
    . $scriptPath -SubscriptionId '00000000-0000-0000-0000-000000000000'
}

Describe 'Get-NormalizedGuestOS' {
    It 'normalizes Windows Server from build and product type' {
        $result = Get-NormalizedGuestOS -OSName 'Microsoft Windows NT' `
            -OSVersion 'Microsoft Windows NT 10.0.20348.2402' -ProductType 3

        $result.Publisher | Should -Be 'MicrosoftWindowsServer'
        $result.Release | Should -Be '2022'
        $result.Build | Should -Be 20348
    }

    It 'normalizes Windows desktop without confusing build 26100 with Server 2025' {
        $result = Get-NormalizedGuestOS -OSName 'Windows 11 Enterprise' `
            -OSVersion 'Microsoft Windows NT 10.0.26100.3915' -ProductType 1

        $result.Publisher | Should -Be 'MicrosoftWindowsDesktop'
        $result.Family | Should -Be 'Windows 11'
        $result.Release | Should -Be '24H2'
    }

    It 'infers a missing Windows Server release from its Marketplace source SKU' {
        $result = Get-NormalizedGuestOS -CurrentPublisher 'MicrosoftWindowsServer' `
            -CurrentOffer 'WindowsServer' -CurrentSku '2019-datacenter-gensecond'

        $result.Publisher | Should -Be 'MicrosoftWindowsServer'
        $result.Release | Should -Be '2019'
        $result.ResolutionNotes -join ' ' | Should -Match 'current Marketplace image reference'
    }

    It 'normalizes Canonical Ubuntu' {
        $result = Get-NormalizedGuestOS -OSName 'Ubuntu 22.04.5 LTS (Jammy Jellyfish)' -OSVersion '22.04'

        $result.Publisher | Should -Be 'Canonical'
        $result.Release | Should -Be '22.04'
        $result.Codename | Should -Be 'jammy'
    }

    It 'normalizes Red Hat Enterprise Linux' {
        $result = Get-NormalizedGuestOS -OSName 'Red Hat Enterprise Linux 9.4 (Plow)' -OSVersion '9.4'

        $result.Publisher | Should -Be 'RedHat'
        $result.Release | Should -Be '9.4'
    }

    It 'normalizes SUSE Linux Enterprise Server service packs' {
        $result = Get-NormalizedGuestOS -OSName 'SUSE Linux Enterprise Server 15 SP6' -OSVersion '15.6'

        $result.Publisher | Should -Be 'SUSE'
        $result.Release | Should -Be '15'
        $result.ServicePack | Should -Be 'SP6'
    }
}

Describe 'Import-VMImageCatalog' {
    It 'loads a valid catalog and calculates its age' {
        $path = Join-Path $TestDrive 'valid-catalog.json'
        @{
            schemaVersion  = 3
            scope          = 'MarketplaceImageNames'
            generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
            baseRegion     = 'westus3'
            publishers     = @('Canonical')
            entries        = @(
                @{ publisher = 'Canonical'; offer = 'ubuntu'; sku = '22_04-lts-gen2' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8NoBOM

        $catalog = Import-VMImageCatalog -Path $path

        @($catalog.entries).Count | Should -Be 1
        $catalog.AgeDays | Should -BeGreaterOrEqual 0
    }

    It 'rejects duplicate publisher offer and SKU entries' {
        $path = Join-Path $TestDrive 'duplicate-catalog.json'
        @{
            schemaVersion  = 3
            scope          = 'MarketplaceImageNames'
            generatedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
            baseRegion     = 'westus3'
            publishers     = @('Canonical')
            entries        = @(
                @{ publisher = 'Canonical'; offer = 'ubuntu'; sku = '22_04-lts-gen2' }
                @{ publisher = 'canonical'; offer = 'Ubuntu'; sku = '22_04-LTS-GEN2' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8NoBOM

        { Import-VMImageCatalog -Path $path } | Should -Throw '*duplicate entry*'
    }
}

Describe 'ConvertTo-CatalogSafeErrorMessage' {
    It 'redacts subscription and tenant-shaped GUIDs from catalog errors' {
        $message = 'Request failed for subscription 12345678-1234-4234-8234-123456789abc in tenant 11111111-2222-4333-8444-555555555555.'

        $safeMessage = ConvertTo-CatalogSafeErrorMessage -Message $message

        $safeMessage | Should -Not -Match '12345678'
        $safeMessage | Should -Not -Match '11111111'
        $safeMessage | Should -Be 'Request failed for subscription <redacted-guid> in tenant <redacted-guid>.'
    }
}

Describe 'Checked-in image catalog' {
    BeforeAll {
        $script:checkedInCatalogPath = Join-Path $PSScriptRoot '../data/vm-image-catalog.json'
        $script:checkedInCatalog = Import-VMImageCatalog -Path $script:checkedInCatalogPath
        $script:checkedInCatalogJson = Get-Content -LiteralPath $script:checkedInCatalogPath -Raw
    }

    It 'is a complete westus3 image-name index' {
        $script:checkedInCatalog.scope | Should -Be 'MarketplaceImageNames'
        $script:checkedInCatalog.baseRegion | Should -Be 'westus3'
        $script:checkedInCatalog.isPartial | Should -BeFalse
        @($script:checkedInCatalog.entries).Count | Should -BeGreaterThan 0
        @($script:checkedInCatalog.entries.publisher | Sort-Object -Unique) | Should -Be @(
            'Canonical'
            'MicrosoftWindowsDesktop'
            'MicrosoftWindowsServer'
            'RedHat'
            'SUSE'
        )
    }

    It 'contains no customer identity or regional availability data' {
        $script:checkedInCatalogJson | Should -Not -Match '(?i)subscription|tenant|environment|AzureCloud'
        $script:checkedInCatalogJson | Should -Not -Match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'
        @($script:checkedInCatalog.entries | Where-Object {
                $_.PSObject.Properties.Name -contains 'location'
            }).Count | Should -Be 0
    }
}

Describe 'Get-TargetVM' {
    BeforeEach {
        $script:capturedResourceGroup = 'not-called'
        $script:capturedVMName = 'not-called'
        $script:vmLookup = {
            param($lookupResourceGroup, $lookupVMName)
            $script:capturedResourceGroup = $lookupResourceGroup
            $script:capturedVMName = $lookupVMName
            [pscustomobject]@{ Name = 'vm1' }
        }
    }

    It 'enumerates the subscription when no target is supplied' {
        $result = @(Get-TargetVM -AzContext @{} -VMLookup $script:vmLookup)

        $result.Count | Should -Be 1
        $script:capturedResourceGroup | Should -BeNullOrEmpty
        $script:capturedVMName | Should -BeNullOrEmpty
    }

    It 'enumerates only the requested resource group' {
        Get-TargetVM -AzContext @{} -TargetResourceGroupName 'rg-app' `
            -VMLookup $script:vmLookup | Out-Null

        $script:capturedResourceGroup | Should -Be 'rg-app'
        $script:capturedVMName | Should -BeNullOrEmpty
    }

    It 'targets a VM using its resource group and name' {
        Get-TargetVM -AzContext @{} -TargetResourceGroupName 'rg-app' -TargetVMName 'vm1' `
            -VMLookup $script:vmLookup | Out-Null

        $script:capturedResourceGroup | Should -Be 'rg-app'
        $script:capturedVMName | Should -Be 'vm1'
    }

    It 'requires a resource group when a VM name is supplied' {
        { Get-TargetVM -AzContext @{} -TargetVMName 'vm1' -VMLookup $script:vmLookup } |
            Should -Throw '*ResourceGroupName is required*'
        $script:capturedResourceGroup | Should -Be 'not-called'
    }
}

Describe 'Test-VMImageCompatibility' {
    It 'rejects architecture mismatches' {
        $image = [pscustomobject]@{
            Succeeded = $true; OSType = 'Linux'; Architecture = 'Arm64'; HyperVGeneration = 'V2'
            Features = @(); DeprecationState = 'Active'; PurchasePlan = $null
        }
        $compatibilityProfile = [pscustomobject]@{
            OSType = 'Linux'; Architecture = 'x64'; HyperVGeneration = 'V2'; SecurityType = 'Standard'
        }

        $result = Test-VMImageCompatibility -ImageDetails $image -CompatibilityProfile $compatibilityProfile

        $result.IsCompatible | Should -BeFalse
        $result.RejectionReasons -join ' ' | Should -Match 'Architecture'
    }

    It 'requires Trusted Launch image support' {
        $image = [pscustomobject]@{
            Succeeded = $true; OSType = 'Windows'; Architecture = 'x64'; HyperVGeneration = 'V2'
            Features = @(); FeatureMetadataAvailable = $true
            DeprecationState = 'Active'; PurchasePlan = $null
        }
        $compatibilityProfile = [pscustomobject]@{
            OSType = 'Windows'; Architecture = 'x64'; HyperVGeneration = 'V2'; SecurityType = 'TrustedLaunch'
        }

        (Test-VMImageCompatibility -ImageDetails $image -CompatibilityProfile $compatibilityProfile).IsCompatible |
            Should -BeFalse
    }

    It 'accepts Azure combined Trusted Launch and Confidential VM support metadata' -ForEach @(
        @{ SecurityType = 'TrustedLaunch' }
        @{ SecurityType = 'ConfidentialVM' }
    ) {
        $image = [pscustomobject]@{
            Succeeded = $true; OSType = 'Windows'; Architecture = 'x64'; HyperVGeneration = 'V2'
            Features = @(
                [pscustomobject]@{
                    Name = 'SecurityType'; Value = 'TrustedLaunchAndConfidentialVmSupported'
                }
            )
            FeatureMetadataAvailable = $true
            DeprecationState = 'Active'; PurchasePlan = $null
        }
        $compatibilityProfile = [pscustomobject]@{
            OSType = 'Windows'; Architecture = 'x64'; HyperVGeneration = 'V2'
            SecurityType = $SecurityType
        }

        $result = Test-VMImageCompatibility -ImageDetails $image -CompatibilityProfile $compatibilityProfile

        $result.IsCompatible | Should -BeTrue
        $result.Warnings | Should -BeNullOrEmpty
    }

    It 'warns instead of rejecting when security feature metadata is unavailable' {
        $image = [pscustomobject]@{
            Succeeded = $true; OSType = 'Windows'; Architecture = 'x64'; HyperVGeneration = 'V2'
            Features = @(); FeatureMetadataAvailable = $false
            DeprecationState = 'Active'; PurchasePlan = $null
            MetadataWarning = 'REST metadata lookup failed.'
        }
        $compatibilityProfile = [pscustomobject]@{
            OSType = 'Windows'; Architecture = 'x64'; HyperVGeneration = 'V2'; SecurityType = 'TrustedLaunch'
        }

        $result = Test-VMImageCompatibility -ImageDetails $image -CompatibilityProfile $compatibilityProfile

        $result.IsCompatible | Should -BeTrue
        $result.Warnings -join ' ' | Should -Match 'could not be verified'
        $result.Warnings -join ' ' | Should -Match 'REST metadata lookup failed'
    }

    It 'rejects an image plan when the current VM has no purchase plan' {
        $image = [pscustomobject]@{
            Succeeded = $true; OSType = 'Linux'; Architecture = 'x64'; HyperVGeneration = 'V2'
            Features = @(); FeatureMetadataAvailable = $true; DeprecationState = 'Active'
            PurchasePlan = [pscustomobject]@{
                Publisher = 'canonical'; Product = 'ubuntu-paid'; Name = '18_04-lts'
            }
        }
        $compatibilityProfile = [pscustomobject]@{
            OSType = 'Linux'; Architecture = 'x64'; HyperVGeneration = 'V2'; SecurityType = 'Standard'
        }
        $currentReference = [pscustomobject]@{
            PlanPublisher = ''; PlanProduct = ''; PlanName = ''
        }

        $result = Test-VMImageCompatibility -ImageDetails $image `
            -CompatibilityProfile $compatibilityProfile -CurrentImageReference $currentReference

        $result.IsCompatible | Should -BeFalse
        $result.RejectionReasons -join ' ' | Should -Match "does not match current VM plan 'none'"
    }

    It 'accepts an image plan that exactly matches the current VM plan' {
        $plan = [pscustomobject]@{
            Publisher = 'canonical'; Product = 'ubuntu-paid'; Name = '18_04-lts'
        }
        $image = [pscustomobject]@{
            Succeeded = $true; OSType = 'Linux'; Architecture = 'x64'; HyperVGeneration = 'V2'
            Features = @(); FeatureMetadataAvailable = $true; DeprecationState = 'Active'
            PurchasePlan = $plan
        }
        $compatibilityProfile = [pscustomobject]@{
            OSType = 'Linux'; Architecture = 'x64'; HyperVGeneration = 'V2'; SecurityType = 'Standard'
        }
        $currentReference = [pscustomobject]@{
            PlanPublisher = 'Canonical'; PlanProduct = 'Ubuntu-Paid'; PlanName = '18_04-LTS'
        }

        $result = Test-VMImageCompatibility -ImageDetails $image `
            -CompatibilityProfile $compatibilityProfile -CurrentImageReference $currentReference

        $result.IsCompatible | Should -BeTrue
        $result.Warnings | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-VMImageDetailRecord' {
    It 'maps exact-version REST properties including features and plan' {
        $plan = [pscustomobject]@{ Publisher = 'contoso'; Product = 'server'; Name = 'byol' }
        $properties = [pscustomobject]@{
            OSDiskImage = [pscustomobject]@{ OperatingSystem = 'Linux' }
            Architecture = 'x64'
            HyperVGeneration = 'V2'
            Features = @(
                [pscustomobject]@{
                    Name = 'SecurityType'; Value = 'TrustedLaunchAndConfidentialVmSupported'
                }
            )
            ImageDeprecationStatus = [pscustomobject]@{ ImageState = 'Active' }
            Plan = $plan
        }

        $result = ConvertTo-VMImageDetailRecord -Image $properties -Version '1.2.3' `
            -FeatureMetadataAvailable:$true

        $result.Version | Should -Be '1.2.3'
        $result.FeatureMetadataAvailable | Should -BeTrue
        $result.Features[0].Value | Should -Be 'TrustedLaunchAndConfidentialVmSupported'
        $result.PurchasePlan | Should -Be $plan
    }
}

Describe 'Get-RecommendationConfidence' {
    It 'classifies score <Score> as <Expected>' -ForEach @(
        @{ Score = 100; Expected = 'High' }
        @{ Score = 80; Expected = 'High' }
        @{ Score = 79; Expected = 'Medium' }
        @{ Score = 60; Expected = 'Medium' }
        @{ Score = 59; Expected = 'Low' }
    ) {
        Get-RecommendationConfidence -Score $Score | Should -Be $Expected
    }
}

Describe 'Report output projections' {
    BeforeAll {
        $script:reportResult = [pscustomobject]@{
            VM = [pscustomobject]@{
                Id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                ResourceGroupName = 'rg'; Name = 'vm1'; Location = 'eastus'
            }
            CurrentImageReference = [pscustomobject]@{
                SourceType = 'Marketplace'; Publisher = 'Canonical'; Offer = 'ubuntu-24_04-lts'
                Sku = 'server'; Version = 'latest'; ExactVersion = '24.04.202608070'
                Id = ''; SharedGalleryImageId = ''; CommunityGalleryImageId = ''
                PlanPublisher = 'canonical'; PlanProduct = 'ubuntu'; PlanName = 'server'
            }
            InstanceView = [pscustomobject]@{ OSName = 'ubuntu'; OSVersion = '24.04'; EvidenceSource = 'InstanceView' }
            GuestOS = [pscustomobject]@{
                Publisher = 'Canonical'; Family = 'Ubuntu'; Release = '24.04'; Build = $null
            }
            Compatibility = [pscustomobject]@{
                VMSize = 'Standard_D2s_v3'; Architecture = 'x64'; HyperVGeneration = 'V2'; SecurityType = 'TrustedLaunch'
            }
            Recommendation = [pscustomobject]@{
                Status = 'Selected'
                Selected = [pscustomobject]@{
                    ImageReference = 'Canonical:ubuntu-24_04-lts:server'
                    Urn = 'Canonical:ubuntu-24_04-lts:server:latest'; ConcreteVersion = '24.04.202608070'
                    Score = 100; ScoreLead = 1; Confidence = 'High'; Source = 'StaticCatalog'
                    Reasons = @('Release matched.'); Warnings = @(); OSType = 'Linux'; Architecture = 'x64'
                    HyperVGeneration = 'V2'; DeprecationState = 'Active'; PurchasePlan = $null
                }
                Alternatives = @(
                    [pscustomobject]@{
                        ImageReference = 'Canonical:ubuntu-24_04-lts-daily:server'
                        Urn = 'Canonical:ubuntu-24_04-lts-daily:server:latest'
                        ConcreteVersion = '24.04.202608060'; Score = 99
                    }
                )
                Rejections = @(); DynamicDiscoveryError = $null
            }
            Warnings = @(); Errors = @()
        }
        $script:reportCatalog = [pscustomobject]@{
            generatedAtUtc = '2026-08-28T00:00:00Z'; AgeDays = 0
        }
    }

    It 'emits the compact CSV schema with current URNs' {
        $row = $script:reportResult | ConvertTo-VMReportCsvRow -Catalog $script:reportCatalog

        $row.CurrentUrn | Should -Be 'Canonical:ubuntu-24_04-lts:server:24.04.202608070'
        $row.CurrentPlanUrn | Should -Be 'canonical:ubuntu:server'
        $row.RecommendedUrn | Should -Be 'Canonical:ubuntu-24_04-lts:server:latest'
        $row.PSObject.Properties.Name | Should -Not -Contain 'VMId'
        $row.PSObject.Properties.Name | Should -Not -Contain 'CurrentVersion'
        $row.PSObject.Properties.Name | Should -Not -Contain 'CurrentPublisher'
        $row.PSObject.Properties.Name | Should -Not -Contain 'CurrentPlanPublisher'
        $row.PSObject.Properties.Name | Should -Not -Contain 'RecommendedImageReference'
        $row.PSObject.Properties.Name | Should -Contain 'NormalizedRelease'
    }

    It 'emits compact JSON records without duplicate image fields' {
        $record = $script:reportResult | ConvertTo-VMReportJsonRecord

        $record.VM.PSObject.Properties.Name | Should -Not -Contain 'Id'
        $record.CurrentImageReference.Urn | Should -Be 'Canonical:ubuntu-24_04-lts:server:24.04.202608070'
        $record.CurrentImageReference.PlanUrn | Should -Be 'canonical:ubuntu:server'
        $record.CurrentImageReference.PSObject.Properties.Name | Should -Not -Contain 'Publisher'
        $record.CurrentImageReference.PSObject.Properties.Name | Should -Not -Contain 'Version'
        $record.Recommendation.Selected.PSObject.Properties.Name | Should -Not -Contain 'ImageReference'
        $record.Recommendation.Selected.Urn | Should -Be 'Canonical:ubuntu-24_04-lts:server:latest'
        $record.Recommendation.Alternatives[0].PSObject.Properties.Name | Should -Not -Contain 'ImageReference'
        $record.GuestOS.Release | Should -Be '24.04'
    }
}

Describe 'Find-VMImageRecommendation' {
    BeforeEach {
        $script:catalog = [pscustomobject]@{
            entries = @(
                [pscustomobject]@{
                    publisher = 'MicrosoftWindowsServer'; offer = 'WindowsServer'
                    sku = '2022-datacenter-azure-edition'
                }
                [pscustomobject]@{
                    publisher = 'MicrosoftWindowsServer'; offer = 'WindowsServer'
                    sku = '2022-datacenter'
                }
            )
        }
        $script:normalizedOS = Get-NormalizedGuestOS -OSName 'Windows Server 2022 Datacenter' `
            -OSVersion 'Microsoft Windows NT 10.0.20348.2402' -ProductType 3
        $script:currentReference = [pscustomobject]@{
            Offer = 'WindowsServer'; Sku = '2019-datacenter-azure-edition'
        }
        $script:recommendationCompatibility = [pscustomobject]@{
            OSType = 'Windows'; Architecture = 'x64'; HyperVGeneration = 'V2'; SecurityType = 'TrustedLaunch'
        }
    }

    It 'selects the next compatible candidate when the best static match is unavailable' {
        $imageLookup = {
            param($lookupCandidate)
            if ($lookupCandidate.sku -like '*azure-edition') {
                throw 'Image withdrawn'
            }
            [pscustomobject]@{
                Version = '20348.1.240101'
                OSDiskImage = [pscustomobject]@{ OperatingSystem = 'Windows' }
                Architecture = 'x64'
                HyperVGeneration = 'V2'
                Features = @([pscustomobject]@{ Name = 'SecurityType'; Value = 'TrustedLaunchSupported' })
                ImageDeprecationStatus = [pscustomobject]@{ ImageState = 'Active' }
                PurchasePlan = $null
            }
        }

        $result = Find-VMImageRecommendation -Catalog $script:catalog -Location 'eastus' `
            -NormalizedOS $script:normalizedOS -CompatibilityProfile $script:recommendationCompatibility `
            -CurrentImageReference $script:currentReference -AzContext @{} -LiveImageCache @{} `
            -ImageLookup $imageLookup

        $result.Status | Should -Be 'Selected'
        $result.Selected.ImageReference | Should -Be 'MicrosoftWindowsServer:WindowsServer:2022-datacenter'
        $result.Selected.Confidence | Should -Be 'Medium'
        @($result.Rejections).Count | Should -Be 1
    }

    It 'rates an 80-point exact match High despite a close runner-up' {
        $catalog = [pscustomobject]@{
            entries = @(
                [pscustomobject]@{
                    publisher = 'MicrosoftWindowsServer'; offer = 'WindowsServer'; sku = '2022-datacenter'
                }
                [pscustomobject]@{
                    publisher = 'MicrosoftWindowsServer'; offer = 'WindowsServer'; sku = '2022-datacenter-g2'
                }
            )
        }
        $currentReference = [pscustomobject]@{
            Offer = 'WindowsServer'; Sku = '2022-datacenter'
        }
        $imageLookup = {
            [pscustomobject]@{
                Version = '20348.1.240101'
                OSDiskImage = [pscustomobject]@{ OperatingSystem = 'Windows' }
                Architecture = 'x64'
                HyperVGeneration = 'V2'
                Features = @([pscustomobject]@{ Name = 'SecurityType'; Value = 'TrustedLaunchSupported' })
                ImageDeprecationStatus = [pscustomobject]@{ ImageState = 'Active' }
                PurchasePlan = $null
            }
        }

        $result = Find-VMImageRecommendation -Catalog $catalog -Location 'eastus' `
            -NormalizedOS $script:normalizedOS -CompatibilityProfile $script:recommendationCompatibility `
            -CurrentImageReference $currentReference -AzContext @{} -LiveImageCache @{} `
            -ImageLookup $imageLookup

        $result.Selected.Score | Should -Be 80
        $result.Selected.ScoreLead | Should -BeLessThan 5
        $result.Selected.Confidence | Should -Be 'High'
    }

    It 'prefers a plan-free Ubuntu image for a VM without a purchase plan' {
        $catalog = [pscustomobject]@{
            entries = @(
                [pscustomobject]@{
                    publisher = 'Canonical'; offer = '0001-com-ubuntu-server-bionic-wm'; sku = '18_04-lts'
                }
                [pscustomobject]@{
                    publisher = 'Canonical'; offer = 'ubuntu'; sku = '18_04-lts-gen2'
                }
            )
        }
        $normalizedOS = Get-NormalizedGuestOS -OSName 'ubuntu' -OSVersion '18.04'
        $compatibility = [pscustomobject]@{
            OSType = 'Linux'; Architecture = 'x64'; HyperVGeneration = 'V2'; SecurityType = 'Standard'
        }
        $currentReference = [pscustomobject]@{
            Offer = ''; Sku = ''; PlanPublisher = ''; PlanProduct = ''; PlanName = ''
        }
        $imageLookup = {
            param($candidate)
            [pscustomobject]@{
                Version = '18.04.202401161'
                OSDiskImage = [pscustomobject]@{ OperatingSystem = 'Linux' }
                Architecture = 'x64'; HyperVGeneration = 'V2'; Features = @()
                ImageDeprecationStatus = [pscustomobject]@{ ImageState = 'Active' }
                PurchasePlan = if ($candidate.offer -like '*bionic-wm') {
                    [pscustomobject]@{
                        Publisher = 'canonical'; Product = $candidate.offer; Name = $candidate.sku
                    }
                }
                else {
                    $null
                }
            }
        }

        $result = Find-VMImageRecommendation -Catalog $catalog -Location 'eastus' `
            -NormalizedOS $normalizedOS -CompatibilityProfile $compatibility `
            -CurrentImageReference $currentReference -AzContext @{} -LiveImageCache @{} `
            -ImageLookup $imageLookup

        $result.Selected.ImageReference | Should -Be 'Canonical:ubuntu:18_04-lts-gen2'
        $result.Rejections[0].Reasons -join ' ' | Should -Match 'purchase plan'
    }

    It 'reuses cached live image details' {
        $script:lookupCount = 0
        $imageLookup = {
            $script:lookupCount++
            [pscustomobject]@{
                Version = '20348.1.240101'
                OSDiskImage = [pscustomobject]@{ OperatingSystem = 'Windows' }
                Architecture = 'x64'
                HyperVGeneration = 'V2'
                Features = @([pscustomobject]@{ Name = 'SecurityType'; Value = 'TrustedLaunchSupported' })
                ImageDeprecationStatus = [pscustomobject]@{ ImageState = 'Active' }
                PurchasePlan = $null
            }
        }
        $candidate = [pscustomobject]@{
            location = 'eastus'; publisher = 'MicrosoftWindowsServer'
            offer = 'WindowsServer'; sku = '2022-datacenter'
        }
        $cache = @{}

        Get-LiveVMImageDetail -Candidate $candidate -AzContext @{} -Cache $cache -ImageLookup $imageLookup | Out-Null
        Get-LiveVMImageDetail -Candidate $candidate -AzContext @{} -Cache $cache -ImageLookup $imageLookup | Out-Null

        $script:lookupCount | Should -Be 1
    }

    It 'discovers candidates in the VM region when the static catalog lacks the OS release' {
        $ubuntuCatalog = [pscustomobject]@{
            entries = @(
                [pscustomobject]@{
                    publisher = 'Canonical'; offer = '0001-com-ubuntu-server-jammy'; sku = '22_04-lts-gen2'
                }
            )
        }
        $ubuntuOS = Get-NormalizedGuestOS -OSName 'Ubuntu 24.04.3 LTS (Noble Numbat)' -OSVersion '24.04'
        $ubuntuCompatibility = [pscustomobject]@{
            OSType = 'Linux'; Architecture = 'x64'; HyperVGeneration = 'V2'; SecurityType = 'Standard'
        }
        $regionalLookup = {
            param($lookupLocation, $lookupPublisher)
            $lookupLocation | Should -Be 'centralus'
            $lookupPublisher | Should -Be 'Canonical'
            [pscustomobject]@{
                publisher = 'Canonical'; offer = 'ubuntu-24_04-lts'; sku = 'server-gen2'
            }
        }
        $imageLookup = {
            [pscustomobject]@{
                Version = '24.04.202608010'
                OSDiskImage = [pscustomobject]@{ OperatingSystem = 'Linux' }
                Architecture = 'x64'
                HyperVGeneration = 'V2'
                Features = @()
                ImageDeprecationStatus = [pscustomobject]@{ ImageState = 'Active' }
                PurchasePlan = $null
            }
        }

        $result = Find-VMImageRecommendation -Catalog $ubuntuCatalog -Location 'centralus' `
            -NormalizedOS $ubuntuOS -CompatibilityProfile $ubuntuCompatibility `
            -CurrentImageReference $null -AzContext @{} -LiveImageCache @{} `
            -RegionalCatalogCache @{} -RegionalCatalogLookup $regionalLookup -ImageLookup $imageLookup

        $result.Status | Should -Be 'Selected'
        $result.Selected.ImageReference | Should -Be 'Canonical:ubuntu-24_04-lts:server-gen2'
        $result.Selected.Source | Should -Be 'RegionalDiscovery'
    }
}