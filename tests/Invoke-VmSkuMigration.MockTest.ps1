$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ("migtest-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
. "$root/Invoke-VmSkuMigration.ps1" -TenantId 't1' -SubscriptionId 's1' -VmName 'vm1' -WorkRoot $work
$script:ClearScreen = $false

# ---------- helper unit tests ----------
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAILED: $msg" } else { Write-Host "ok  - $msg" -ForegroundColor Green } }
Assert (Test-IpInCidr '10.0.1.5' '10.0.1.0/24') 'ip in cidr'
Assert (-not (Test-IpInCidr '10.0.2.5' '10.0.1.0/24')) 'ip outside cidr'
Assert (Test-IpInCidr '10.255.0.1' '10.0.0.0/8') '/8'
Assert (Test-IpInCidr '1.2.3.4' '0.0.0.0/0') '/0'
$p = Split-ResourceId '/subscriptions/s1/resourceGroups/rgA/providers/Microsoft.Network/virtualNetworks/vnet1/subnets/sn1'
Assert ($p.Name -eq 'vnet1' -and $p.Rest -eq 'subnets/sn1' -and $p.ResourceGroup -eq 'rgA') 'split subnet id'
Assert ((Get-TargetName 'abc') -eq 'abc-mig') 'target name'
try { Get-TargetName ('x' * 80); $bad = $true } catch { $bad = $false }
Assert (-not $bad) 'name too long rejected'

# ---------- in-memory Azure ----------
function Get-Module { param([switch]$ListAvailable, $Name) [pscustomobject]@{ Name = $Name } }
$global:Az = @{ vms = @{}; disks = @{}; snaps = @{}; nics = @{}; locks = @(); calls = [System.Collections.Generic.List[string]]::new() }
function Rec($m) { $global:Az.calls.Add($m) }
$sub = '/subscriptions/s1/resourceGroups/rg1/providers'
$subnetId = "/subscriptions/s2/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet1/subnets/sn1"   # subnet in ANOTHER subscription
$pipId = "$sub/Microsoft.Network/publicIPAddresses/pip1"
$nsgId = "$sub/Microsoft.Network/networkSecurityGroups/nsg1"
$poolId = "$sub/Microsoft.Network/loadBalancers/lb1/backendAddressPools/pool1"

function O($h) { [pscustomobject]$h }
$global:Az.nics['nic1'] = O @{
    Name = 'nic1'; Id = "$sub/Microsoft.Network/networkInterfaces/nic1"; Tags = @{ t = 'n' }
    NetworkSecurityGroup = (O @{ Id = $nsgId }); EnableAcceleratedNetworking = $true; EnableIPForwarding = $false
    DnsSettings = (O @{ DnsServers = @('10.0.0.4') })
    IpConfigurations = @(O @{
            Name = 'ipconfig1'; Primary = $true; PrivateIpAddress = '10.0.1.10'; PrivateIpAllocationMethod = 'Static'; PrivateIpAddressVersion = 'IPv4'
            Subnet = (O @{ Id = $subnetId }); PublicIpAddress = (O @{ Id = $pipId })
            ApplicationSecurityGroups = @(); LoadBalancerBackendAddressPools = @(O @{ Id = $poolId }); LoadBalancerInboundNatRules = @(); ApplicationGatewayBackendAddressPools = @()
        })
}
$global:Az.disks['os1'] = O @{ Name = 'os1'; Id = "$sub/Microsoft.Compute/disks/os1"; Sku = (O @{ Name = 'Premium_LRS' }); DiskSizeGB = 128; Zones = @('1'); OsType = 'Windows'; HyperVGeneration = 'V2'
    SecurityProfile = (O @{ SecurityType = 'TrustedLaunch' }); Encryption = (O @{ DiskEncryptionSetId = ''; Type = '' }); MaxShares = $null; EncryptionSettingsCollection = $null; Tags = @{ d = 'os' } }
$global:Az.disks['data1'] = O @{ Name = 'data1'; Id = "$sub/Microsoft.Compute/disks/data1"; Sku = (O @{ Name = 'Premium_LRS' }); DiskSizeGB = 256; Zones = @('1'); OsType = $null; HyperVGeneration = $null
    SecurityProfile = $null; Encryption = (O @{ DiskEncryptionSetId = ''; Type = '' }); MaxShares = $null; EncryptionSettingsCollection = $null; Tags = $null }

$global:Az.vms['vm1'] = [pscustomobject]@{
    Name = 'vm1'; ResourceGroupName = 'rg1'; Id = "$sub/Microsoft.Compute/virtualMachines/vm1"; Location = 'westeurope'; Zones = @('1'); Tags = @{ app = 'x'; env = 'test' }
    LicenseType = 'Windows_Server'; Plan = $null; Priority = $null; Power = 'running'
    AvailabilitySetReference = $null; ProximityPlacementGroup = $null; VirtualMachineScaleSet = $null; AdditionalCapabilities = $null; CapacityReservation = $null
    HardwareProfile = (O @{ VmSize = 'Standard_B2ms' })
    SecurityProfile = (O @{ SecurityType = 'TrustedLaunch'; EncryptionAtHost = $false; UefiSettings = (O @{ SecureBootEnabled = $true; VTpmEnabled = $true }) })
    DiagnosticsProfile = (O @{ BootDiagnostics = (O @{ Enabled = $true; StorageUri = '' }) })
    Identity = (O @{ Type = 'SystemAssigned'; PrincipalId = 'pid-old'; UserAssignedIdentities = $null })
    StorageProfile = (O @{
            OsDisk = (O @{ ManagedDisk = (O @{ Id = "$sub/Microsoft.Compute/disks/os1" }); Caching = 'ReadWrite'; DiffDiskSettings = $null; DeleteOption = 'Detach'; WriteAcceleratorEnabled = $false })
            DataDisks = @(O @{ Lun = 2; Name = 'data1'; ManagedDisk = (O @{ Id = "$sub/Microsoft.Compute/disks/data1" }); Caching = 'ReadOnly'; DeleteOption = 'Detach'; WriteAcceleratorEnabled = $false })
        })
    NetworkProfile = (O @{ NetworkInterfaces = @(O @{ Id = "$sub/Microsoft.Network/networkInterfaces/nic1"; Primary = $true; DeleteOption = 'Detach' }) })
}

$global:CurSub = 's1'
function Get-AzContext { O @{ Account = (O @{ Id = 'tester@x' }); Tenant = (O @{ Id = 't1' }); Subscription = (O @{ Id = $global:CurSub; Name = 'sub' }) } }
function Set-AzContext { param($SubscriptionId, $Tenant) Rec "ctx $SubscriptionId"; $global:CurSub = $SubscriptionId; O @{ Account = (O @{ Id = 'tester@x' }) } }
function Connect-AzAccount { param($Tenant, $ClaimsChallenge) if ($ClaimsChallenge) { Rec "connect claims $ClaimsChallenge" } else { Rec 'connect' } }
function Get-AzSubscription { param($TenantId) @(O @{ Id = 's1'; Name = 'test-sub'; State = 'Enabled'; TenantId = 't1' }) }
function Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status)
    if (-not $Name) { return @($global:Az.vms.Values) }
    $v = $global:Az.vms[$Name]; if (-not $v) { throw "ResourceNotFound: VM $Name" }
    if ($Status) { return O @{ Statuses = @(O @{ Code = "PowerState/$($v.Power)" }) } }
    return $v }
function Stop-AzVM { param($ResourceGroupName, $Name, [switch]$Force) Rec "stop $Name"; $global:Az.vms[$Name].Power = 'deallocated' }
function Start-AzVM { param($ResourceGroupName, $Name) Rec "start $Name"; $global:Az.vms[$Name].Power = 'running' }
function Remove-AzVM { param($ResourceGroupName, $Name, [switch]$Force) Rec "remove-vm $Name"; $global:Az.vms.Remove($Name) }
function Update-AzVM { param($ResourceGroupName, $VM) Rec 'update-vm' }
function Get-AzDisk { param($ResourceGroupName, $DiskName) $d = $global:Az.disks[$DiskName]; if (-not $d) { throw "ResourceNotFound disk $DiskName" }; $d }
function New-AzDiskConfig { param($Location, $CreateOption, $SourceResourceId, $SkuName, $DiskSizeGB, $Zone, $Tag, $DiskEncryptionSetId, $EncryptionType, $OsType, $HyperVGeneration) @{ sku = $SkuName; size = $DiskSizeGB; zone = $Zone; os = $OsType; gen = $HyperVGeneration; sec = $null; tag = $Tag } }
function New-AzDisk { param($ResourceGroupName, $DiskName, $Disk) Rec "new-disk $DiskName"
    $global:Az.disks[$DiskName] = O @{ Name = $DiskName; Id = "$sub/Microsoft.Compute/disks/$DiskName"; Sku = (O @{ Name = $Disk.sku }); DiskSizeGB = $Disk.size; Zones = @($Disk.zone); OsType = $Disk.os; HyperVGeneration = $Disk.gen; SecurityProfile = $(if ($Disk.os) { O @{ SecurityType = 'TrustedLaunch' } }); Encryption = $null; Tags = $Disk.tag }
    $global:Az.disks[$DiskName] }
function Remove-AzDisk { param($ResourceGroupName, $DiskName, [switch]$Force) Rec "remove-disk $DiskName"; $global:Az.disks.Remove($DiskName) }
function New-AzSnapshotConfig { param($SourceUri, $Location, $CreateOption, $SkuName, $Tag, $HyperVGeneration) @{ src = $SourceUri } }
function New-AzSnapshot { param($ResourceGroupName, $SnapshotName, $Snapshot)
    if ($global:ClaimsFailOnce) { $global:ClaimsFailOnce = $false; throw "Resource '$SnapshotName' was disallowed by Azure: You are receiving this error because you tried to create, update or delete Azure resources without authenticating through MFA.`n`nConnect-AzAccount -Tenant (Get-AzContext).Tenant.Id -ClaimsChallenge `"eyJhY2Nlc3NfdG9rZW4iOnsiYWNycyI6eyJlc3NlbnRpYWwiOnRydWUsInZhbHVlcyI6WyJwMSJdfX19`"" }
    Rec "new-snap $SnapshotName";$global:Az.snaps[$SnapshotName] = O @{ Name = $SnapshotName; Id = "$sub/Microsoft.Compute/snapshots/$SnapshotName" }; $global:Az.snaps[$SnapshotName] }
function Get-AzSnapshot { param($ResourceGroupName, $SnapshotName) $s = $global:Az.snaps[$SnapshotName]; if (-not $s) { throw "ResourceNotFound snap" }; $s }
function Remove-AzSnapshot { param($ResourceGroupName, $SnapshotName, [switch]$Force) Rec "remove-snap $SnapshotName"; $global:Az.snaps.Remove($SnapshotName) }
function Get-AzNetworkInterface { param($ResourceGroupName, $Name) $n = $global:Az.nics[$Name]; if (-not $n) { throw "ResourceNotFound nic $Name" }; $n }
function Set-AzNetworkInterface { param([Parameter(ValueFromPipeline)]$NetworkInterface) process { Rec "set-nic $($NetworkInterface.Name) -> $($NetworkInterface.IpConfigurations[0].PrivateIpAddress)"; $NetworkInterface } }
function Remove-AzNetworkInterface { param($ResourceGroupName, $Name, [switch]$Force) Rec "remove-nic $Name"; $global:Az.nics.Remove($Name) }
function New-AzNetworkInterfaceIpConfig { param($Name, $SubnetId, $PrivateIpAddress, [switch]$Primary, $PublicIpAddressId, $ApplicationSecurityGroupId, $LoadBalancerBackendAddressPoolId, $LoadBalancerInboundNatRuleId, $ApplicationGatewayBackendAddressPoolId)
    O @{ Name = $Name; Primary = [bool]$Primary; PrivateIpAddress = $PrivateIpAddress; PrivateIpAllocationMethod = 'Static'; PrivateIpAddressVersion = 'IPv4'; Subnet = (O @{ Id = $SubnetId })
        PublicIpAddress = $(if ($PublicIpAddressId) { O @{ Id = $PublicIpAddressId } }); ApplicationSecurityGroups = @(); LoadBalancerBackendAddressPools = @(if ($LoadBalancerBackendAddressPoolId) { $LoadBalancerBackendAddressPoolId | % { O @{ Id = $_ } } }); LoadBalancerInboundNatRules = @(); ApplicationGatewayBackendAddressPools = @() } }
function New-AzNetworkInterface { param($Name, $ResourceGroupName, $Location, $IpConfiguration, $NetworkSecurityGroup, [switch]$EnableAcceleratedNetworking, [switch]$EnableIPForwarding, $DnsServer, $Tag, [switch]$Force)
    foreach ($n in $global:Az.nics.Values) { foreach ($i in $n.IpConfigurations) { if ($i.PrivateIpAddress -eq $IpConfiguration[0].PrivateIpAddress) { throw "PrivateIPAddressInUse: already in use" } } }
    Rec "new-nic $Name ip=$($IpConfiguration[0].PrivateIpAddress)"
    $global:Az.nics[$Name] = O @{ Name = $Name; Id = "$sub/Microsoft.Network/networkInterfaces/$Name"; Tags = $Tag; NetworkSecurityGroup = $(if ($NetworkSecurityGroup) { O @{ Id = $NetworkSecurityGroup.Id } }); EnableAcceleratedNetworking = [bool]$EnableAcceleratedNetworking; EnableIPForwarding = $false
        DnsSettings = (O @{ DnsServers = @($DnsServer) }); IpConfigurations = @($IpConfiguration) }
    $global:Az.nics[$Name] }
function Get-AzNetworkSecurityGroup { param($ResourceGroupName, $Name) O @{ Id = "$sub/Microsoft.Network/networkSecurityGroups/$Name" } }
function Get-AzPublicIpAddress { param($ResourceGroupName, $Name) O @{ Id = "$sub/Microsoft.Network/publicIPAddresses/$Name"; Name = $Name; Sku = (O @{ Name = 'Standard' }); PublicIpAllocationMethod = 'Static'; IpAddress = '20.1.1.1' } }
function Get-AzLoadBalancer { param($ResourceGroupName, $Name) O @{ BackendAddressPools = @(O @{ Id = $poolId }); InboundNatRules = @() } }
function Get-AzVirtualNetwork { param($ResourceGroupName, $Name) if ($global:CurSub -ne 's2') { throw 'ResourceNotFound: vnet is in another subscription' }; O @{ Name = $Name } }
function Get-AzVirtualNetworkSubnetConfig { param($VirtualNetwork, $Name) O @{ AddressPrefix = @('10.0.1.0/24') } }
function Test-AzPrivateIPAddressAvailability { param($ResourceGroupName, $VirtualNetworkName, $IPAddress)
    if ($global:CurSub -ne 's2') { throw 'ResourceNotFound: vnet is in another subscription' }
    $taken = @($global:Az.nics.Values | % { $_.IpConfigurations } | % { $_.PrivateIpAddress })
    O @{ Available = ($IPAddress -notin $taken); AvailableIPAddresses = @('10.0.1.50') } }
function Get-AzVMExtension { param($ResourceGroupName, $VMName)
    @(O @{ Name = 'AzureMonitorWindowsAgent'; Publisher = 'Microsoft.Azure.Monitor'; ExtensionType = 'AzureMonitorWindowsAgent'; TypeHandlerVersion = '1.0'; PublicSettings = '{}'; AutoUpgradeMinorVersion = $true; EnableAutomaticUpgrade = $true; ProvisioningState = 'Succeeded' }
      O @{ Name = 'CustomScriptExtension'; Publisher = 'Microsoft.Compute'; ExtensionType = 'CustomScriptExtension'; TypeHandlerVersion = '1.10'; PublicSettings = '{}'; AutoUpgradeMinorVersion = $true; EnableAutomaticUpgrade = $false; ProvisioningState = 'Succeeded' }
      O @{ Name = 'BrokenAccess'; Publisher = 'Microsoft.OSTCExtensions'; ExtensionType = 'VMAccessForLinux'; TypeHandlerVersion = '1.5'; PublicSettings = '{}'; AutoUpgradeMinorVersion = $true; EnableAutomaticUpgrade = $false; ProvisioningState = 'Failed' }) }
$global:ExtAdded = @()
function Set-AzVMExtension { param($ResourceGroupName, $VMName, $Location, $Name, $Publisher, $ExtensionType, $TypeHandlerVersion, $SettingString, [switch]$DisableAutoUpgradeMinorVersion, [switch]$EnableAutomaticUpgrade) Rec "ext $Name"; $global:ExtAdded += $Name; O @{ IsSuccessStatusCode = $true } }
function Get-AzRoleAssignment { param($ObjectId)
    if ($ObjectId -eq 'pid-old') { @(O @{ Scope = "$sub/Microsoft.KeyVault/vaults/kv1"; RoleDefinitionId = 'rd1'; RoleDefinitionName = 'Key Vault Secrets User'; Condition = $null; ConditionVersion = $null }) }
    else { @($global:RoleAdded | ? { $_.ObjectId -eq $ObjectId } | % { O @{ Scope = $_.Scope; RoleDefinitionId = $_.RoleDefinitionId; RoleDefinitionName = 'x' } }) } }
$global:RoleAdded = @()
function New-AzRoleAssignment { param($ObjectId, $ObjectType, $RoleDefinitionId, $Scope, $Condition, $ConditionVersion) Rec "role $RoleDefinitionId"; $global:RoleAdded += @{ ObjectId = $ObjectId; RoleDefinitionId = $RoleDefinitionId; Scope = $Scope } }
function Remove-AzRoleAssignment { param($ObjectId, $RoleDefinitionId, $Scope) Rec "remove-role"; }
function Get-AzResourceLock { param($ResourceGroupName, $Scope)
    $all = $global:Az.locks
    if ($Scope) { return @($all | ? { $_.ResourceId -like "$Scope/providers/Microsoft.Authorization/locks/*" }) }
    $all }
function New-AzResourceLock { param($LockName, $LockLevel, $LockNotes, $Scope, $ResourceName, $ResourceType, $ResourceGroupName, [switch]$Force) Rec "lock $LockName on $(if ($Scope) { $Scope } else { $ResourceName })"
    if ($Scope) { $global:Az.locks += O @{ Name = $LockName; ResourceId = "$Scope/providers/Microsoft.Authorization/locks/$LockName"; LockId = "$Scope/providers/Microsoft.Authorization/locks/$LockName"; Properties = (O @{ level = $LockLevel; notes = $LockNotes }) } } }
function Remove-AzResourceLock { param($LockId, $LockName, $ResourceName, $ResourceType, $ResourceGroupName, [switch]$Force) Rec "unlock $LockId$LockName"; $global:Az.locks = @($global:Az.locks | ? { $_.LockId -ne $LockId }) }
function Invoke-AzRestMethod { param($Method, $Path, $Payload) Rec "rest $Method"; if ($Method -eq 'GET') { O @{ StatusCode = 200; Content = '{"value":[{"name":"assoc1","properties":{"dataCollectionRuleId":"/dcr/1"}}]}' } } else { O @{ StatusCode = 200; Content = '{}' } } }
function Get-AzComputeResourceSku { param($Location)
    $mk = { param($n, $f, $c, $m, $g) O @{ ResourceType = 'virtualMachines'; Name = $n; Family = $f; Restrictions = @(); LocationInfo = @(O @{ Location = 'westeurope'; Zones = @('1', '2', '3') })
            Capabilities = @(O @{ Name = 'vCPUs'; Value = "$c" }; O @{ Name = 'MemoryGB'; Value = "$m" }; O @{ Name = 'HyperVGenerations'; Value = $g }) } }
    & $mk 'Standard_B2ms' 'standardBSFamily' 2 8 'V1,V2'; & $mk 'Standard_B2s_v2' 'standardBsv2Family' 2 8 'V2'; & $mk 'Standard_B2ls_v2' 'standardBsv2Family' 2 4 'V2'; & $mk 'Standard_B4s_v2' 'standardBsv2Family' 4 16 'V2' }
function Get-AzVMUsage { param($Location) @(O @{ Name = (O @{ Value = 'standardBsv2Family' }); CurrentValue = 0; Limit = 100 }) }
function New-AzVMConfig { param($VMName, $VMSize, $AvailabilitySetId, $Zone, $ProximityPlacementGroupId, $LicenseType, $Tags, [switch]$EncryptionAtHost, $IdentityType, $IdentityId) Rec "vmconfig size=$VMSize zone=$Zone lic=$LicenseType idt=$IdentityType"; @{ name = $VMName; size = $VMSize; nics = @(); disks = @(); zone = $Zone; tags = $Tags; lic = $LicenseType; ident = $IdentityType } }
function Set-AzVMSecurityProfile { param($VM, $SecurityType) $VM.sec = $SecurityType; $VM }
function Set-AzVMUefi { param($VM, $EnableVtpm, $EnableSecureBoot) $VM }
function Set-AzVMOSDisk { param($VM, $Name, $ManagedDiskId, $CreateOption, $Caching, [switch]$Windows, [switch]$Linux) $VM.os = $ManagedDiskId; $VM.oscache = $Caching; $VM }
function Add-AzVMDataDisk { param($VM, $Name, $ManagedDiskId, $Lun, $CreateOption, $Caching) $VM.disks += @{ lun = $Lun; id = $ManagedDiskId; cache = $Caching }; $VM }
function Add-AzVMNetworkInterface { param($VM, $Id, [switch]$Primary) $VM.nics += $Id; $VM }
function Set-AzVMBootDiagnostic { param($VM, [switch]$Enable, [switch]$Disable) $VM }
function New-AzVM { param($ResourceGroupName, $Location, $VM, [switch]$DisableBginfoExtension)
    if ($global:FailVmOnce) { $global:FailVmOnce = $false; throw 'simulated New-AzVM failure' }
    Rec "new-vm $($VM.name)"
    $d = foreach ($x in $VM.disks) { @{ Lun = $x.lun; Name = (Split-Path $x.id -Leaf); ManagedDisk = @{ Id = $x.id }; Caching = $x.cache; DiskSizeGB = $global:Az.disks[(Split-Path $x.id -Leaf)].DiskSizeGB } }
    $global:Az.vms[$VM.name] = [pscustomobject]@{
        Name = $VM.name; ResourceGroupName = 'rg1'; Id = "$sub/Microsoft.Compute/virtualMachines/$($VM.name)"; Location = 'westeurope'; Zones = @($VM.zone); Tags = $VM.tags; LicenseType = $VM.lic; Power = 'running'; ProvisioningState = 'Succeeded'
        AvailabilitySetReference = $null; HardwareProfile = (O @{ VmSize = $VM.size }); SecurityProfile = (O @{ SecurityType = $VM.sec }); DiagnosticsProfile = (O @{ BootDiagnostics = (O @{ Enabled = $true }) })
        Identity = (O @{ Type = 'SystemAssigned'; PrincipalId = 'pid-new'; UserAssignedIdentities = $null })
        StorageProfile = (O @{ OsDisk = (O @{ Caching = $VM.oscache }); DataDisks = @($d | % { O $_ }) })
        NetworkProfile = (O @{ NetworkInterfaces = @($VM.nics | % { O @{ Id = $_ } }) }) }
    O @{ IsSuccessStatusCode = $true } }
function Get-AzVMBootDiagnosticsData { param($ResourceGroupName, $Name, $LocalPath, [switch]$Windows, [switch]$Linux) }
function Update-AzVM2 {}

# ---------- scripted operator answers ----------
$global:Answers = [System.Collections.Generic.Queue[string]]::new()
function Read-Host { param($Prompt) if ($global:Answers.Count -eq 0) { throw "Prompt without scripted answer: $Prompt" }; $a = $global:Answers.Dequeue(); Write-Host "   <$Prompt> => $a" -ForegroundColor DarkGray; $a }
function Say { param([string[]]$a) foreach ($x in $a) { $global:Answers.Enqueue($x) } }
function Assert-NoLeftoverAnswers { if ($global:Answers.Count) { throw "Unused scripted answers: $($global:Answers -join ', ')" } }

# ================= RUN 1: new migration, deployment fails at VM creation =================
Write-Host "`n===== RUN 1: new migration (VM creation fails once) =====" -ForegroundColor Cyan
$global:FailVmOnce = $true
$global:ClaimsFailOnce = $true          # Azure refuses the first snapshot asking for MFA: the script must sign in again and retry
Say 'y', 'y', '', 'ACKNOWLEDGE', 'y'   # reuse session, manual checks done, accept proposed size, acknowledge, proceed
Start-Migration
Assert-NoLeftoverAnswers
Assert ($global:Az.calls -contains 'connect claims eyJhY2Nlc3NfdG9rZW4iOnsiYWNycyI6eyJlc3NlbnRpYWwiOnRydWUsInZhbHVlcyI6WyJwMSJdfX19') 'MFA refusal: signed in again with the claims Azure asked for'
Assert ($global:Az.snaps.ContainsKey('os1-snap-os-mig')) 'MFA refusal: the step was retried and succeeded'
Assert ((ConvertTo-ClaimsValue '{"a":1}') -eq 'eyJhIjoxfQ==') 'raw JSON claims are converted to base64'
Assert ($script:Config.targetSku -eq 'Standard_B2s_v2' -and $script:Config.skuFit -eq 'Exact') 'size chosen and recorded'
Assert ($script:State.placeholders['nic1|ipconfig1'] -eq '10.0.1.50') 'placeholder IP taken automatically'
Assert ($script:State.steps.ContainsKey('p3.snapshot.os1') -and $script:State.steps.ContainsKey('p3.disk.os1')) 'steps before the failure are checkpointed'
Assert (-not $script:State.steps.ContainsKey('p3.new-vm')) 'failed step is not marked done'
Assert (-not $global:Az.vms.ContainsKey('vm1-mig')) 'no replacement VM yet'
Assert ($global:Az.snaps.ContainsKey('os1-snap-os-mig') -and $global:Az.snaps.ContainsKey('data1-snap-lun2-mig')) 'snapshot names carry OS / LUN'
Assert ($global:Az.nics['nic1'].IpConfigurations[0].PrivateIpAddress -eq '10.0.1.50') 'old NIC parked'

$cur = (Get-CurrentVmLines -C $script:Config) -join "`n"
$new = (Get-NewVmLines -C $script:Config) -join "`n"
Assert ($cur -match 'vm1' -and $cur -match 'Standard_B2ms' -and $cur -match 'LUN 2' -and $cur -match 'placeholder 10.0.1.50') 'left column: current VM with placeholder'
Assert ($new -match 'vm1-mig' -and $new -match 'Standard_B2s_v2' -and $new -match '10.0.1.10' -and $new -match 'data1-mig') 'right column: new VM'
Assert ($new -match 'Extensions     : none - install by hand') 'right column: extensions are by hand'
Assert ($cur -match 'AzureMonitorWindowsAgent \(Succeeded\)' -and $cur -match 'BrokenAccess \(Failed\)') 'left column: extensions of the old VM, one per line, with their state'
$extNote = ($script:Config.complications | Where-Object { $_ -like 'VM extensions:*' }) -join ''
Assert ($extNote -match 'NONE is installed on the new VM' -and $extNote -match 'AzureMonitorWindowsAgent \[AzureMonitorWindowsAgent 1.0, Succeeded\]' -and $extNote -match 'BrokenAccess \[VMAccessForLinux 1.5, Failed\]') 'extensions listed as not handled, with type, version and state'
Assert (($script:Config.complications -join ' | ') -match 'Azure Backup: the new VM is NOT enrolled') 'backup is always listed as not handled'
Assert (-not ($global:Az.calls -match 'backup')) 'no backup lookup at all'
$nicLabel = (Get-ProgressItems | Where-Object { $_.key -eq 'p3.new-nic.nic1' }).label
Assert ($nicLabel -match '10.0.1.10' -and $nicLabel -match 'attach the public IP 20.1.1.1') 'progress says the public IP is attached to the new NIC'
Assert ($cur -match '-> placeholder 10.0.1.50') 'placeholder shown on its own line'
Assert (($script:Notices -join ' ') -notmatch "`n") 'notices are single-line'

# ================= RUN 2: resume =================
Write-Host "`n===== RUN 2: resume =====" -ForegroundColor Cyan
Say 'y', 'r', ''
Start-Migration
Assert-NoLeftoverAnswers
Assert ($global:Az.vms['vm1-mig'].Power -eq 'running') 'replacement VM created after resume'
Assert ((Get-PhaseStatus 3) -eq 'done') 'deployment done'
Assert ((Get-PhaseStatus 4) -eq 'PASS') 'automatic checks PASS'
Assert ($global:ExtAdded.Count -eq 0) 'no extension is ever installed by the script'
Assert (-not ((Get-ProgressItems | ForEach-Object { $_.key }) -match 'extension')) 'no extension step in the progress list'
Assert ($global:RoleAdded.Count -eq 0) 'no role assignments touched'
Assert (@($global:Az.calls | ? { $_ -like 'rest PUT' -or $_ -like 'rest DELETE' -or $_ -like 'lock*' -or $_ -like 'role*' }).Count -eq 0) 'no DCR write, lock or role calls'
Assert ($global:Az.nics['nic1-mig'].IpConfigurations[0].LoadBalancerBackendAddressPools.Count -eq 0) 'new NIC not added to LB pool (flagged only)'
Assert ($global:Az.nics['nic1'].IpConfigurations[0].LoadBalancerBackendAddressPools.Count -eq 1) 'old NIC pool membership untouched'
Assert (-not (@($global:Az.calls | ? { $_ -like 'remove-*' }).Count)) 'nothing deleted by the migration'
Assert ($global:Az.vms['vm1'].Power -eq 'deallocated') 'old VM left deallocated'
Assert (@($global:Az.calls | ? { $_ -eq 'start vm1' }).Count -eq 0) 'old VM never started'
$idxStop = $global:Az.calls.IndexOf('stop vm1'); $idxNew = $global:Az.calls.IndexOf('new-vm vm1-mig')
Assert ($idxStop -ge 0 -and $idxStop -lt $idxNew) 'order: old VM stopped before the new one is created'

# ================= RUN 3: existing finished migration -> checks again =================
Write-Host "`n===== RUN 3: run the checks again =====" -ForegroundColor Cyan
Say 'y', 'v', ''
Start-Migration
Assert-NoLeftoverAnswers
Assert ((Get-PhaseStatus 4) -eq 'PASS') 'checks repeated: PASS'

# ================= RUN 4: rollback =================
Write-Host "`n===== RUN 4: rollback =====" -ForegroundColor Cyan
Say 'y', 'b', 'y', 'test rollback', 'y', ''
Start-Migration
Assert-NoLeftoverAnswers
Assert (-not $global:Az.vms.ContainsKey('vm1-mig') -and -not $global:Az.nics.ContainsKey('nic1-mig')) 'new VM and NIC removed'
Assert ($global:Az.nics['nic1'].IpConfigurations[0].PrivateIpAddress -eq '10.0.1.10') 'old NIC original IP restored'
Assert ($global:Az.nics['nic1'].IpConfigurations[0].PublicIpAddress.Id -eq $pipId) 'public IP restored on the old NIC'
Assert ($global:Az.vms['vm1'].Power -eq 'running') 'old VM running again'
Assert (-not $global:Az.disks.ContainsKey('os1-mig') -and -not $global:Az.snaps.ContainsKey('os1-snap-os-mig')) 'new storage deleted'
Assert (-not $script:State.phase3Started) 'state reset after rollback'

# ================= RUN 5: second migration, subscription picked from the list =================
Write-Host "`n===== RUN 5: second migration (subscription picked from the list) =====" -ForegroundColor Cyan
$script:SubscriptionId = $null
Say 'y', '1', 'y', '', 'ACKNOWLEDGE', 'y', ''
Start-Migration
Assert-NoLeftoverAnswers
Assert ((Get-PhaseStatus 4) -eq 'PASS' -and $global:Az.vms['vm1-mig'].Power -eq 'running') 'second migration completed'
Assert ($global:Az.nics.ContainsKey('nic1') -and $global:Az.disks.ContainsKey('os1') -and $global:Az.vms.ContainsKey('vm1')) 'old resources all still there'

Write-Host "`nALL MOCK TESTS PASSED" -ForegroundColor Green
Remove-Item $work -Recurse -Force
