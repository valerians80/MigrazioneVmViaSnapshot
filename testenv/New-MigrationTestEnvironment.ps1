#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys (or removes) a small test environment for Invoke-VmSkuMigration.ps1 in ONE subscription.

.DESCRIPTION
    One subscription, two resource groups:
      rg-<prefix>-net : a VNet (10.250.0.0/16) with one subnet (10.250.1.0/24)
      rg-<prefix>-vm  : one VM of a retiring family (default Standard_B2ms) with its NIC (static private IP, on the
                        subnet of the network resource group), NSG, an optional public IP, data disk(s) and one
                        extension.

    Everything is created through prompts (tenant, subscription, VM credentials). Nothing is hard-coded.
    Both resource groups are tagged purpose=migration-test, and -Destroy only deletes resource groups carrying
    that tag. The deployment is recorded in testenv.json next to this script. The script can be re-run after a
    partial failure: tagged resource groups and an existing VNet / NSG are reused.

.PARAMETER Destroy
    Deletes the two resource groups recorded in testenv.json (after you type DELETE).
.PARAMETER VmSize
    Size of the test VM. Default Standard_B2ms (maps to Standard_B2s_v2, an "Exact" fit).
    Use Standard_F4s_v2 to test the Fsv2 -> Dlsv6 path.
.PARAMETER Generation
    2 (default) or 1. A Gen1 VM is a useful negative test: Bsv2/Dlsv6 do not support Gen1, phase 1 must block it.
.PARAMETER Zone
    Optional availability zone (1, 2 or 3).
.PARAMETER PrivateIp
    Static private IP in the subnet 10.250.1.0/24. Empty = dynamic.
.PARAMETER WithPublicIp
    Adds a Standard static public IP to the NIC.
.PARAMETER WithSystemIdentity
    Enables the system-assigned identity (the migration script must flag it as "not handled").
.PARAMETER WithHybridBenefit
    Sets licenseType Windows_Server. Only use it if your test subscription is entitled to Azure Hybrid Benefit.
.PARAMETER SkipExtension
    Do not install the test extension.
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$Location = 'westeurope',
    [string]$Prefix = 'migtest',
    [string]$VmName,
    [string]$VmSize = 'Standard_B2ms',
    [ValidateSet('Windows', 'Linux')][string]$OsType = 'Windows',
    [ValidateSet(1, 2)][int]$Generation = 2,
    [ValidateSet('', '1', '2', '3')][string]$Zone = '',
    [ValidateRange(0, 8)][int]$DataDiskCount = 1,
    [string]$PrivateIp = '10.250.1.10',
    [switch]$WithPublicIp,
    [switch]$WithSystemIdentity,
    [switch]$WithHybridBenefit,
    [switch]$SkipExtension,
    [switch]$Destroy,
    [string]$StatePath = (Join-Path $PSScriptRoot 'testenv.json')
)

$ErrorActionPreference = 'Stop'

$VnetAddressSpace = '10.250.0.0/16'
$SubnetPrefix = '10.250.1.0/24'
$TestTag = @{ purpose = 'migration-test' }

# ---------------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------------
function Write-Step { param([string]$Message, [string]$Color = 'Cyan') Write-Host ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color }

function Read-Required {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) { $v = Read-Host $Prompt; if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() } }
}

function Confirm-Typed {
    param([Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)][string]$Expected)
    return ((Read-Host "$Message (type '$Expected' to confirm, anything else cancels)").Trim() -ceq $Expected)
}

function Invoke-InSubscription {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][scriptblock]$Script)
    $ctx = Get-AzContext
    if ($ctx.Subscription.Id -ne $SubscriptionId) { Set-AzContext -SubscriptionId $SubscriptionId -Tenant $ctx.Tenant.Id | Out-Null }
    & $Script
}

function Select-Subscription {
    param([Parameter(Mandatory)]$Subscriptions, [Parameter(Mandatory)][string]$Role, [string]$Preset)
    if ($Preset) {
        $s = $Subscriptions | Where-Object { $_.Id -eq $Preset -or $_.Name -eq $Preset } | Select-Object -First 1
        if (-not $s) { throw "Subscription '$Preset' not found in this tenant." }
        return $s
    }
    Write-Host "Choose the $Role subscription:"
    for ($i = 0; $i -lt $Subscriptions.Count; $i++) { Write-Host ('  [{0}] {1}  ({2})' -f ($i + 1), $Subscriptions[$i].Name, $Subscriptions[$i].Id) }
    while ($true) {
        $pick = Read-Required 'Number'
        if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $Subscriptions.Count) { return $Subscriptions[[int]$pick - 1] }
    }
}

function Register-Provider {
    param([string]$SubscriptionId, [string[]]$Namespaces)
    Invoke-InSubscription $SubscriptionId {
        foreach ($ns in $Namespaces) {
            $state = (Get-AzResourceProvider -ProviderNamespace $ns | Select-Object -First 1).RegistrationState
            if ($state -ne 'Registered') {
                Write-Step "Registering $ns in $SubscriptionId ..." 'Yellow'
                Register-AzResourceProvider -ProviderNamespace $ns | Out-Null
                $deadline = (Get-Date).AddMinutes(5)
                do {
                    Start-Sleep -Seconds 10
                    $state = (Get-AzResourceProvider -ProviderNamespace $ns | Select-Object -First 1).RegistrationState
                } while ($state -ne 'Registered' -and (Get-Date) -lt $deadline)
                if ($state -ne 'Registered') { throw "Provider $ns is still '$state' in $SubscriptionId." }
            }
        }
    }
}

function Ensure-TestResourceGroup {
    param([string]$SubscriptionId, [string]$Name)
    Invoke-InSubscription $SubscriptionId {
        $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
        if ($rg) {
            if ($rg.Tags -and $rg.Tags['purpose'] -eq 'migration-test') { Write-Step "Resource group $Name already exists (tagged as test): reusing it." 'Yellow'; return }
            throw "Resource group '$Name' already exists and is NOT tagged purpose=migration-test. Choose another -Prefix."
        }
        New-AzResourceGroup -Name $Name -Location $Location -Tag $TestTag | Out-Null
        Write-Step "Created resource group $Name"
    }
}

# ---------------------------------------------------------------------------------------------------------
# sign in and pick the two subscriptions
# ---------------------------------------------------------------------------------------------------------
foreach ($m in 'Az.Accounts', 'Az.Compute', 'Az.Network', 'Az.Resources') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Required module '$m' is not installed (Install-Module Az -Scope CurrentUser)." }
}

if (-not $TenantId) { $TenantId = Read-Required 'Tenant ID (GUID or domain name)' }
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not ($ctx -and $ctx.Tenant -and $ctx.Tenant.Id -eq $TenantId)) { Connect-AzAccount -Tenant $TenantId | Out-Null }
$subs = @(Get-AzSubscription -TenantId $TenantId | Where-Object { $_.State -eq 'Enabled' })
if ($subs.Count -lt 1) { throw 'No enabled subscription visible in this tenant.' }

# ---------------------------------------------------------------------------------------------------------
# destroy
# ---------------------------------------------------------------------------------------------------------
if ($Destroy) {
    if (-not (Test-Path $StatePath)) { throw "State file not found: $StatePath" }
    $state = Get-Content -Raw $StatePath | ConvertFrom-Json
    Write-Host ''
    Write-Host "This DELETES, with everything inside (including any -mig resources created by the migration test):"
    Write-Host "  subscription $($state.subscriptionId) : resource group $($state.vmResourceGroup)"
    Write-Host "  subscription $($state.subscriptionId) : resource group $($state.networkResourceGroup)"
    if (-not (Confirm-Typed 'Delete both resource groups?' 'DELETE')) { Write-Host 'Cancelled.'; return }
    foreach ($rgName in @($state.vmResourceGroup, $state.networkResourceGroup)) {
        Invoke-InSubscription $state.subscriptionId {
            $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
            if (-not $rg) { Write-Step "$rgName not found, nothing to do." 'Yellow'; return }
            if (-not ($rg.Tags -and $rg.Tags['purpose'] -eq 'migration-test')) { Write-Step "$rgName is not tagged purpose=migration-test: NOT deleted." 'Red'; return }
            Write-Step "Deleting $rgName ..."
            Remove-AzResourceGroup -Name $rgName -Force | Out-Null
            Write-Step "Deleted $rgName" 'Green'
        }
    }
    Remove-Item $StatePath -Force
    return
}

# ---------------------------------------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------------------------------------
$sub = Select-Subscription -Subscriptions $subs -Role 'test' -Preset $SubscriptionId
if ($PrivateIp -and -not $PrivateIp.StartsWith('10.250.1.')) { throw "PrivateIp must be inside $SubnetPrefix (or empty for dynamic)." }
if (-not $VmName) { $VmName = "vm${Prefix}01" }
if ($OsType -eq 'Windows' -and $VmName.Length -gt 15) { throw 'On Windows the VM name can be at most 15 characters.' }
if ($WithHybridBenefit -and $OsType -ne 'Windows') { throw '-WithHybridBenefit only applies to Windows.' }

$netRg = "rg-$Prefix-net"
$vmRg = "rg-$Prefix-vm"
$vnetName = "vnet-$Prefix"
$subnetName = 'snet-workload'
$nsgName = "nsg-$Prefix"
$nicName = "nic-$VmName"
$pipName = "pip-$VmName"
$tags = @{ purpose = 'migration-test'; createdBy = (Get-AzContext).Account.Id; createdOn = (Get-Date -Format 'yyyy-MM-dd') }

$image = if ($OsType -eq 'Windows') {
    @{ Publisher = 'MicrosoftWindowsServer'; Offer = 'WindowsServer'; Sku = $(if ($Generation -eq 2) { '2022-datacenter-g2' } else { '2022-datacenter' }) }
}
else {
    @{ Publisher = 'Canonical'; Offer = 'ubuntu-24_04-lts'; Sku = $(if ($Generation -eq 2) { 'server' } else { 'server-gen1' }) }
}

Write-Host ''
Write-Host 'Plan:' -ForegroundColor Cyan
Write-Host "  Tenant        : $TenantId"
Write-Host "  Subscription  : $($sub.Name) ($($sub.Id))"
Write-Host "  Network RG    : $netRg  -> $vnetName ($VnetAddressSpace) / $subnetName ($SubnetPrefix)"
Write-Host "  VM RG         : $vmRg"
Write-Host "  VM            : $VmName  $VmSize  $OsType Gen$Generation  zone '$Zone'  in $Location"
Write-Host "  NIC           : $nicName  IP $(if ($PrivateIp) { $PrivateIp + ' (static)' } else { 'dynamic' })  NSG $nsgName  public IP: $([bool]$WithPublicIp)"
Write-Host "  Extras        : $DataDiskCount data disk(s), identity: $([bool]$WithSystemIdentity), AHB: $([bool]$WithHybridBenefit), extension: $(-not $SkipExtension)"
Write-Host '  Cost          : a B2ms VM costs a few cents per hour. Run with -Destroy when finished.'
if ((Read-Host 'Deploy? [y/N]').Trim() -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; return }

$cred = Get-Credential -Message 'Local administrator credentials for the test VM (not stored anywhere)'

Register-Provider -SubscriptionId $sub.Id -Namespaces @('Microsoft.Network', 'Microsoft.Compute')

Invoke-InSubscription $sub.Id {
    # pre-checks
    $skuInfo = Get-AzComputeResourceSku -Location $Location | Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSize } | Select-Object -First 1
    if (-not $skuInfo) { throw "Size $VmSize is not offered in $Location." }
    foreach ($r in $skuInfo.Restrictions) {
        if ($r.Type -eq 'Location' -or ($r.Type -eq 'Zone' -and $Zone -and $Zone -in $r.RestrictionInfo.Zones)) {
            throw "Size $VmSize is restricted for this subscription ($($r.ReasonCode)). Try another size or region."
        }
    }
    $img = Get-AzVMImage -Location $Location -PublisherName $image.Publisher -Offer $image.Offer -Skus $image.Sku | Select-Object -Last 1
    if (-not $img) { throw "Image $($image.Publisher):$($image.Offer):$($image.Sku) not found in $Location." }
    Write-Step "Pre-checks ok (size available, image $($image.Sku) $($img.Version))" 'Green'
}

# --- network resource group ---
Ensure-TestResourceGroup -SubscriptionId $sub.Id -Name $netRg
$subnetId = Invoke-InSubscription $sub.Id {
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $netRg -Name $vnetName -ErrorAction SilentlyContinue
    if (-not $vnet) {
        $sn = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix $SubnetPrefix
        $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $netRg -Location $Location -AddressPrefix $VnetAddressSpace -Subnet $sn -Tag $tags
        Write-Step "Created VNet $vnetName with subnet $subnetName"
    }
    ($vnet.Subnets | Where-Object { $_.Name -eq $subnetName }).Id
}

# --- VM resource group ---
Ensure-TestResourceGroup -SubscriptionId $sub.Id -Name $vmRg
Invoke-InSubscription $sub.Id {
    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $vmRg -Name $nsgName -ErrorAction SilentlyContinue
    if (-not $nsg) { $nsg = New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $vmRg -Location $Location -Tag $tags; Write-Step "Created NSG $nsgName (default rules, no inbound from the internet)" }

    $ipParams = @{ Name = 'ipconfig1'; SubnetId = $subnetId; Primary = $true }
    if ($PrivateIp) { $ipParams.PrivateIpAddress = $PrivateIp }
    if ($WithPublicIp) {
        $pip = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $vmRg -Location $Location -Sku Standard -AllocationMethod Static -Tag $tags
        $ipParams.PublicIpAddressId = $pip.Id
        Write-Step "Created public IP $pipName ($($pip.IpAddress))"
    }
    $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $vmRg -Location $Location -IpConfiguration (New-AzNetworkInterfaceIpConfig @ipParams) -NetworkSecurityGroup $nsg -Tag $tags -Force
    Write-Step "Created NIC $nicName ($($nic.IpConfigurations[0].PrivateIpAddress)) on the subnet of $netRg"

    $cfg = @{ VMName = $VmName; VMSize = $VmSize; Tags = $tags }
    if ($Zone) { $cfg.Zone = @($Zone) }
    if ($WithSystemIdentity) { $cfg.IdentityType = 'SystemAssigned' }
    if ($WithHybridBenefit) { $cfg.LicenseType = 'Windows_Server' }
    $vm = New-AzVMConfig @cfg
    $os = @{ VM = $vm; ComputerName = $VmName.Substring(0, [Math]::Min(15, $VmName.Length)); Credential = $cred }
    if ($OsType -eq 'Windows') { $os.Windows = $true; $os.ProvisionVMAgent = $true; $os.EnableAutoUpdate = $true } else { $os.Linux = $true }
    $vm = Set-AzVMOperatingSystem @os
    $vm = Set-AzVMSourceImage -VM $vm -PublisherName $image.Publisher -Offer $image.Offer -Skus $image.Sku -Version 'latest'
    $vm = Set-AzVMOSDisk -VM $vm -Name "$VmName-osdisk" -CreateOption FromImage -StorageAccountType StandardSSD_LRS -Caching ReadWrite
    for ($i = 0; $i -lt $DataDiskCount; $i++) {
        $vm = Add-AzVMDataDisk -VM $vm -Name "$VmName-data$i" -Lun $i -CreateOption Empty -DiskSizeInGB 32 -StorageAccountType StandardSSD_LRS -Caching ReadOnly
    }
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id
    $vm = Set-AzVMBootDiagnostic -VM $vm -Enable

    Write-Step "Creating VM $VmName (this takes a few minutes) ..."
    New-AzVM -ResourceGroupName $vmRg -Location $Location -VM $vm -DisableBginfoExtension | Out-Null
    Write-Step "VM $VmName created" 'Green'

    if (-not $SkipExtension) {
        try {
            if ($OsType -eq 'Windows') { $ext = @{ Name = 'VMAccessAgent'; Publisher = 'Microsoft.Compute'; ExtensionType = 'VMAccessAgent'; TypeHandlerVersion = '2.4' } }
            else { $ext = @{ Name = 'VMAccessForLinux'; Publisher = 'Microsoft.OSTCExtensions'; ExtensionType = 'VMAccessForLinux'; TypeHandlerVersion = '1.5' } }
            Set-AzVMExtension -ResourceGroupName $vmRg -VMName $VmName -Location $Location -SettingString '{}' @ext | Out-Null
            Write-Step "Installed extension $($ext.Name)" 'Green'
        }
        catch { Write-Step "Extension not installed (not essential): $($_.Exception.Message)" 'Yellow' }
    }
}

# --- record and hand over ---
[ordered]@{
    tenantId             = $TenantId
    subscriptionId       = $sub.Id
    networkResourceGroup = $netRg
    vmResourceGroup      = $vmRg
    vnet                 = $vnetName
    subnetId             = $subnetId
    vmName               = $VmName
    vmSize               = $VmSize
    location             = $Location
    privateIp            = $PrivateIp
    createdAt            = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -Path $StatePath -Encoding utf8

Write-Host ''
Write-Step 'Test environment ready.' 'Green'
Write-Host "State saved to $StatePath"
Write-Host ''
Write-Host 'Run the migration against it:' -ForegroundColor Cyan
Write-Host "  pwsh .\Invoke-VmSkuMigration.ps1 -TenantId $TenantId -SubscriptionId $($sub.Id) -ResourceGroupName $vmRg -VmName $VmName"
Write-Host 'Pick a placeholder IP in 10.250.1.0/24, e.g. 10.250.1.50.'
Write-Host ''
Write-Host 'Remove everything afterwards:' -ForegroundColor Cyan
Write-Host "  pwsh .\testenv\New-MigrationTestEnvironment.ps1 -Destroy -TenantId $TenantId"
