$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ("migtest-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
. "$root/Invoke-VmSkuMigration.ps1" -TenantId 't1' -SubscriptionId 's1' -ResourceGroupName 'rg1' -VmName 'vm1' -WorkRoot $work

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
$global:Az = @{ vms = @{}; disks = @{}; snaps = @{}; nics = @{}; locks = @(); calls = [System.Collections.Generic.List[string]]::new() }
function Rec($m) { $global:Az.calls.Add($m) }
$sub = '/subscriptions/s1/resourceGroups/rg1/providers'
$subnetId = "$sub/Microsoft.Network/virtualNetworks/vnet1/subnets/sn1"
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
    Name = 'vm1'; Id = "$sub/Microsoft.Compute/virtualMachines/vm1"; Location = 'westeurope'; Zones = @('1'); Tags = @{ app = 'x'; env = 'test' }
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

function Get-AzContext { O @{ Account = (O @{ Id = 'tester@x' }); Tenant = (O @{ Id = 't1' }); Subscription = (O @{ Id = 's1'; Name = 'sub' }) } }
function Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status)
    $v = $global:Az.vms[$Name]; if (-not $v) { throw "ResourceNotFound: VM $Name" }
    if ($Status) { return O @{ Statuses = @(O @{ Code = "PowerState/$($v.Power)" }) } }
    return $v }
function Stop-AzVM { param($ResourceGroupName, $Name, [switch]$Force) Rec "stop $Name"; $global:Az.vms[$Name].Power = 'deallocated' }
function Start-AzVM { param($ResourceGroupName, $Name) Rec "start $Name"; $global:Az.vms[$Name].Power = 'running' }
function Remove-AzVM { param($ResourceGroupName, $Name, [switch]$Force) Rec "remove-vm $Name"; $global:Az.vms.Remove($Name) }
function Update-AzVM { param($ResourceGroupName, $VM) Rec 'update-vm' }
function Get-AzDisk { param($ResourceGroupName, $DiskName) $d = $global:Az.disks[$DiskName]; if (-not $d) { throw "ResourceNotFound disk $DiskName" }; $d }
function New-AzDiskConfig { param($Location, $CreateOption, $SourceResourceId, $SkuName, $DiskSizeGB, $Zone, $Tag, $DiskEncryptionSetId, $EncryptionType, $OsType, $HyperVGeneration, $SecurityType) @{ sku = $SkuName; size = $DiskSizeGB; zone = $Zone; os = $OsType; gen = $HyperVGeneration; sec = $SecurityType; tag = $Tag } }
function New-AzDisk { param($ResourceGroupName, $DiskName, $Disk) Rec "new-disk $DiskName"
    $global:Az.disks[$DiskName] = O @{ Name = $DiskName; Id = "$sub/Microsoft.Compute/disks/$DiskName"; Sku = (O @{ Name = $Disk.sku }); DiskSizeGB = $Disk.size; Zones = @($Disk.zone); OsType = $Disk.os; HyperVGeneration = $Disk.gen; SecurityProfile = $null; Encryption = $null; Tags = $Disk.tag }
    $global:Az.disks[$DiskName] }
function Remove-AzDisk { param($ResourceGroupName, $DiskName, [switch]$Force) Rec "remove-disk $DiskName"; $global:Az.disks.Remove($DiskName) }
function New-AzSnapshotConfig { param($SourceUri, $Location, $CreateOption, $SkuName, $Tag, $HyperVGeneration) @{ src = $SourceUri } }
function New-AzSnapshot { param($ResourceGroupName, $SnapshotName, $Snapshot) Rec "new-snap $SnapshotName"; $global:Az.snaps[$SnapshotName] = O @{ Name = $SnapshotName; Id = "$sub/Microsoft.Compute/snapshots/$SnapshotName" }; $global:Az.snaps[$SnapshotName] }
function Get-AzSnapshot { param($ResourceGroupName, $SnapshotName) $s = $global:Az.snaps[$SnapshotName]; if (-not $s) { throw "ResourceNotFound snap" }; $s }
function Remove-AzSnapshot { param($ResourceGroupName, $SnapshotName, [switch]$Force) Rec "remove-snap $SnapshotName"; $global:Az.snaps.Remove($SnapshotName) }
function Get-AzNetworkInterface { param($ResourceGroupName, $Name) $n = $global:Az.nics[$Name]; if (-not $n) { throw "ResourceNotFound nic $Name" }; $n }
function Set-AzNetworkInterface { param([Parameter(ValueFromPipeline)]$NetworkInterface) process { Rec "set-nic $($NetworkInterface.Name) -> $($NetworkInterface.IpConfigurations[0].PrivateIpAddress)"; $NetworkInterface } }
function Remove-AzNetworkInterface { param($ResourceGroupName, $Name, [switch]$Force) Rec "remove-nic $Name"; $global:Az.nics.Remove($Name) }
function New-AzNetworkInterfaceIpConfig { param($Name, $SubnetId, $PrivateIpAddress, [switch]$Primary, $PublicIpAddressId, $ApplicationSecurityGroupId, $LoadBalancerBackendAddressPoolId, $LoadBalancerInboundNatRuleId, $ApplicationGatewayBackendAddressPoolId)
    O @{ Name = $Name; Primary = [bool]$Primary; PrivateIpAddress = $PrivateIpAddress; PrivateIpAllocationMethod = 'Static'; PrivateIpAddressVersion = 'IPv4'; Subnet = (O @{ Id = $SubnetId })
        PublicIpAddress = $(if ($PublicIpAddressId) { O @{ Id = $PublicIpAddressId } }); ApplicationSecurityGroups = @(); LoadBalancerBackendAddressPools = @($LoadBalancerBackendAddressPoolId | % { O @{ Id = $_ } }); LoadBalancerInboundNatRules = @(); ApplicationGatewayBackendAddressPools = @() } }
function New-AzNetworkInterface { param($Name, $ResourceGroupName, $Location, $IpConfiguration, $NetworkSecurityGroup, [switch]$EnableAcceleratedNetworking, [switch]$EnableIPForwarding, $DnsServer, $Tag, [switch]$Force)
    foreach ($n in $global:Az.nics.Values) { foreach ($i in $n.IpConfigurations) { if ($i.PrivateIpAddress -eq $IpConfiguration[0].PrivateIpAddress) { throw "PrivateIPAddressInUse: already in use" } } }
    Rec "new-nic $Name ip=$($IpConfiguration[0].PrivateIpAddress)"
    $global:Az.nics[$Name] = O @{ Name = $Name; Id = "$sub/Microsoft.Network/networkInterfaces/$Name"; Tags = $Tag; NetworkSecurityGroup = $(if ($NetworkSecurityGroup) { O @{ Id = $NetworkSecurityGroup.Id } }); EnableAcceleratedNetworking = [bool]$EnableAcceleratedNetworking; EnableIPForwarding = $false
        DnsSettings = (O @{ DnsServers = @($DnsServer) }); IpConfigurations = @($IpConfiguration) }
    $global:Az.nics[$Name] }
function Get-AzNetworkSecurityGroup { param($ResourceGroupName, $Name) O @{ Id = "$sub/Microsoft.Network/networkSecurityGroups/$Name" } }
function Get-AzPublicIpAddress { param($ResourceGroupName, $Name) O @{ Id = "$sub/Microsoft.Network/publicIPAddresses/$Name"; Name = $Name; Sku = (O @{ Name = 'Standard' }); PublicIpAllocationMethod = 'Static'; IpAddress = '20.1.1.1' } }
function Get-AzLoadBalancer { param($ResourceGroupName, $Name) O @{ BackendAddressPools = @(O @{ Id = $poolId }); InboundNatRules = @() } }
function Get-AzVirtualNetwork { param($ResourceGroupName, $Name) O @{ Name = $Name } }
function Get-AzVirtualNetworkSubnetConfig { param($VirtualNetwork, $Name) O @{ AddressPrefix = @('10.0.1.0/24') } }
function Test-AzPrivateIPAddressAvailability { param($ResourceGroupName, $VirtualNetworkName, $IPAddress)
    $taken = @($global:Az.nics.Values | % { $_.IpConfigurations } | % { $_.PrivateIpAddress })
    O @{ Available = ($IPAddress -notin $taken); AvailableIPAddresses = @('10.0.1.50') } }
function Get-AzVMExtension { param($ResourceGroupName, $VMName)
    @(O @{ Name = 'AzureMonitorWindowsAgent'; Publisher = 'Microsoft.Azure.Monitor'; ExtensionType = 'AzureMonitorWindowsAgent'; TypeHandlerVersion = '1.0'; PublicSettings = '{}'; AutoUpgradeMinorVersion = $true; EnableAutomaticUpgrade = $true; ProvisioningState = 'Succeeded' }
      O @{ Name = 'CustomScriptExtension'; Publisher = 'Microsoft.Compute'; ExtensionType = 'CustomScriptExtension'; TypeHandlerVersion = '1.10'; PublicSettings = '{}'; AutoUpgradeMinorVersion = $true; EnableAutomaticUpgrade = $false; ProvisioningState = 'Succeeded' }) }
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
    & $mk 'Standard_B2ms' 'standardBSFamily' 2 8 'V1,V2'; & $mk 'Standard_B2s_v2' 'standardBsv2Family' 2 8 'V2'; & $mk 'Standard_B2ls_v2' 'standardBsv2Family' 2 4 'V2' }
function Get-AzVMUsage { param($Location) @(O @{ Name = (O @{ Value = 'standardBsv2Family' }); CurrentValue = 0; Limit = 100 }) }
function New-AzVMConfig { param($VMName, $VMSize, $AvailabilitySetId, $Zone, $ProximityPlacementGroupId, $LicenseType, $Tags, [switch]$EncryptionAtHost, $IdentityType, $IdentityId) Rec "vmconfig size=$VMSize zone=$Zone lic=$LicenseType idt=$IdentityType"; @{ name = $VMName; size = $VMSize; nics = @(); disks = @(); zone = $Zone; tags = $Tags; lic = $LicenseType; ident = $IdentityType } }
function Set-AzVMSecurityProfile { param($VM, $SecurityType) $VM.sec = $SecurityType; $VM }
function Set-AzVMUefi { param($VM, $EnableVtpm, $EnableSecureBoot) $VM }
function Set-AzVMOSDisk { param($VM, $Name, $ManagedDiskId, $CreateOption, $Caching, [switch]$Windows, [switch]$Linux) $VM.os = $ManagedDiskId; $VM.oscache = $Caching; $VM }
function Add-AzVMDataDisk { param($VM, $Name, $ManagedDiskId, $Lun, $CreateOption, $Caching) $VM.disks += @{ lun = $Lun; id = $ManagedDiskId; cache = $Caching }; $VM }
function Add-AzVMNetworkInterface { param($VM, $Id, [switch]$Primary) $VM.nics += $Id; $VM }
function Set-AzVMBootDiagnostic { param($VM, [switch]$Enable, [switch]$Disable) $VM }
function New-AzVM { param($ResourceGroupName, $Location, $VM, [switch]$DisableBginfoExtension)
    Rec "new-vm $($VM.name)"
    $d = foreach ($x in $VM.disks) { @{ Lun = $x.lun; Name = (Split-Path $x.id -Leaf); ManagedDisk = @{ Id = $x.id }; Caching = $x.cache; DiskSizeGB = $global:Az.disks[(Split-Path $x.id -Leaf)].DiskSizeGB } }
    $global:Az.vms[$VM.name] = [pscustomobject]@{
        Name = $VM.name; Id = "$sub/Microsoft.Compute/virtualMachines/$($VM.name)"; Location = 'westeurope'; Zones = @($VM.zone); Tags = $VM.tags; LicenseType = $VM.lic; Power = 'running'; ProvisioningState = 'Succeeded'
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

Initialize-Workspace

Write-Host "`n===== PHASE 1 =====" -ForegroundColor Cyan
Say 'Standard_B2s_v2'                    # target size (suggested is B2s_v2)
Invoke-Phase1
Assert ((Get-PhaseStatus 1) -eq 'done') 'phase 1 done'
Assert ($script:Config.targetSku -eq 'Standard_B2s_v2' -and $script:Config.skuFit -eq 'Exact') 'target + fit recorded'
Assert ($script:Config.identity.roleAssignments.Count -eq 1) 'role assignments captured'
Assert ($script:Config.dcrAssociations.Count -eq 1) 'DCR association captured'
Assert ($script:Config.nics[0].ipConfigs[0].lbPoolIds.Count -eq 1) 'LB pool captured'

Write-Host "`n===== PHASE 2 =====" -ForegroundColor Cyan
Say '10.0.1.10', '10.0.2.5', '10.0.1.50', 'YES'   # original (rejected), outside subnet (rejected), valid placeholder, attestation
Invoke-Phase2
Assert ((Get-PhaseStatus 2) -eq 'done') 'phase 2 done'
Assert ($script:State.placeholders['nic1|ipconfig1'] -eq '10.0.1.50') 'placeholder stored'

Write-Host "`n===== PHASE 3 =====" -ForegroundColor Cyan
Say 'y'
Invoke-Phase3
$s = $script:State
Assert ($global:Az.vms['vm1'].Power -eq 'deallocated') 'source deallocated'
Assert ($global:Az.nics['nic1'].IpConfigurations[0].PrivateIpAddress -eq '10.0.1.50') 'source NIC parked'
Assert ($global:Az.nics['nic1'].IpConfigurations[0].PublicIpAddress -eq $null) 'public IP detached from source'
Assert ($global:Az.nics['nic1-mig'].IpConfigurations[0].PrivateIpAddress -eq '10.0.1.10') 'new NIC has original IP'
Assert ($global:Az.vms['vm1-mig'].Power -eq 'running') 'new VM running'
Assert ($global:Az.vms['vm1-mig'].HardwareProfile.VmSize -eq 'Standard_B2s_v2') 'new VM size'
Assert ($global:Az.disks.ContainsKey('os1-mig') -and $global:Az.disks.ContainsKey('data1-mig')) 'new disks'
Assert ($global:Az.snaps.ContainsKey('os1-snap-mig') -and $global:Az.snaps.ContainsKey('data1-snap-mig')) 'snapshots'
Assert ($global:ExtAdded -contains 'AzureMonitorWindowsAgent' -and $global:ExtAdded -notcontains 'CustomScriptExtension') 'extensions: restored vs manual'
Assert ($global:RoleAdded.Count -eq 1 -and $global:RoleAdded[0].ObjectId -eq 'pid-new') 'role re-granted to new principal'
Assert ((Get-PhaseStatus 3) -eq 'done') 'phase 3 status'
Assert ($global:Az.calls.IndexOf('stop vm1') -lt $global:Az.calls.IndexOf('new-vm vm1-mig')) 'order: stop before create'
Assert (@($global:Az.calls | ? { $_ -like 'start vm1' }).Count -eq 0) 'source never started in phase 3'

Write-Host "`n===== PHASE 3 re-run (must be a no-op) =====" -ForegroundColor Cyan
$before = $global:Az.calls.Count
Say 'y'
Invoke-Phase3
Assert ($global:Az.calls.Count -eq $before) 're-run executes no Azure calls'

Write-Host "`n===== PHASE 4 =====" -ForegroundColor Cyan
Say 'y', 'Alice'
Invoke-Phase4
$fails = @($script:Checks | ? Result -eq 'FAIL')
$fails | Format-Table -AutoSize | Out-String | Write-Host
Assert ($fails.Count -eq 0) 'no failing platform check'
Assert ((Get-PhaseStatus 4) -eq 'PASS') 'phase 4 PASS'

Write-Host "`n===== PHASE 5 (rollback) =====" -ForegroundColor Cyan
Say 'y', 'test rollback', 'y'
Invoke-Phase5
Assert (-not $global:Az.vms.ContainsKey('vm1-mig')) 'new VM removed'
Assert (-not $global:Az.nics.ContainsKey('nic1-mig')) 'new NIC removed'
Assert ($global:Az.nics['nic1'].IpConfigurations[0].PrivateIpAddress -eq '10.0.1.10') 'source NIC original IP restored'
Assert ($global:Az.nics['nic1'].IpConfigurations[0].PublicIpAddress.Id -eq $pipId) 'public IP restored on source'
Assert ($global:Az.vms['vm1'].Power -eq 'running') 'source running again'
Assert (-not $global:Az.disks.ContainsKey('os1-mig') -and -not $global:Az.snaps.ContainsKey('os1-snap-mig')) 'new storage deleted'
Assert ((Get-PhaseStatus 3) -eq '' -and -not $script:State.phase3Started) 'phase 3 reset'

Write-Host "`n===== PHASE 3+4 again, then PHASE 6 =====" -ForegroundColor Cyan
Say 'y'; Invoke-Phase3
Say 'y', 'Alice'; Invoke-Phase4
Assert ((Get-PhaseStatus 4) -eq 'PASS') 'second migration validated'
Say 'vm1', 'Bob', 'CHG0001', '14'
Invoke-Phase6
Assert (-not $global:Az.vms.ContainsKey('vm1')) 'source VM deleted'
Assert (-not $global:Az.nics.ContainsKey('nic1')) 'source NIC deleted'
Assert ($global:Az.disks.ContainsKey('os1') -and $global:Az.disks.ContainsKey('data1')) 'source disks kept'
Assert ($global:Az.snaps.ContainsKey('os1-snap-mig')) 'snapshots kept'
Invoke-Phase6   # retention not expired -> nothing
Assert ($global:Az.disks.ContainsKey('os1')) 'retention respected'
$script:State.decommission.retentionUntil = (Get-Date).AddDays(-1).ToString('o'); Save-State
Say 'vm1'
Invoke-Phase6
Assert (-not $global:Az.disks.ContainsKey('os1') -and -not $global:Az.snaps.ContainsKey('os1-snap-mig')) 'pass 2 deleted source disks and snapshots'
Assert ($global:Az.disks.ContainsKey('os1-mig') -and $global:Az.vms.ContainsKey('vm1-mig')) 'replacement untouched'
Assert ($script:State.decommission.completed) 'decommission complete'

Write-Host "`nALL MOCK TESTS PASSED" -ForegroundColor Green
Remove-Item $work -Recurse -Force
