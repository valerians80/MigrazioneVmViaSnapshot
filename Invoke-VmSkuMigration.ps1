#Requires -Version 7.0
<#
.SYNOPSIS
    Interactive, tenant/subscription-agnostic rebuild of ONE Azure VM on a new size through snapshots.

.DESCRIPTION
    Automates the Azure control-plane steps of the "SKU conversion and migration plan" playbook
    (Bv1 -> Bsv2, Fsv2 -> Dlsv6, or any other mapping you configure below).

    SCOPE: plain VM recreation only. The replacement VM is created next to the source with the suffix "-mig"
    (VM, NICs, disks) and takes over the original private IP address. Everything the script does NOT handle
    (managed identity, load balancer / application gateway pools, availability set, backup, locks, monitoring
    rule associations, ...) is detected in phase 1, listed, and must be acknowledged before the migration starts.
    Those items are handled by hand.

    NOTHING of the source is ever deleted. The source VM, its NIC and its disks stay in place, deallocated, and
    its NIC is parked on a placeholder IP. Rollback is therefore a reversal. Removing the old VM, disks and
    snapshots, and re-enabling backup on the new VM, is a manual step after sign-off.

    The script does NOT touch the guest operating system. Temp-disk remediation, DHCP check, DNS, drive
    letters, services and application tests are owned by the team and are listed as a manual checklist.

    Phases (chosen from a menu, each one gated by the state of the previous ones):
      1  Capture      Read-only. Writes config.json and lists what the script cannot handle.
      2  Network prep Read-only. Placeholder IPs, free target names, acknowledgements.
      3  Execute      Deallocate source, snapshots, new disks, IP swap, new NIC/VM, extensions.
      4  Validate     Read-only. Compares the new VM with config.json, prints the manual checklist.
      5  Rollback     Reverses phase 3 and starts the source VM again.

    Everything is kept per VM in <WorkRoot>\<vmName>\ : config.json, state.json, migration.log, reports.
    Phase 3 writes a checkpoint after every step and can be re-run to resume.

.PARAMETER TenantId
    Optional. Prompted when omitted.
.PARAMETER SubscriptionId
    Optional. Prompted (with a list) when omitted.
.PARAMETER ResourceGroupName
    Optional. Prompted when omitted.
.PARAMETER VmName
    Optional. Prompted when omitted.
.PARAMETER WorkRoot
    Folder holding one sub-folder per VM. Default: .\migration
.PARAMETER Suffix
    Suffix appended to the names of everything the script creates. Default: -mig

.NOTES
    Required modules : Az.Accounts, Az.Compute, Az.Network, Az.Resources
    Optional modules : Az.RecoveryServices (only used to detect whether the VM is backed up)
    Required rights  : Contributor on the VM / network / disk resource groups.
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$VmName,
    [string]$WorkRoot = (Join-Path -Path (Get-Location).Path -ChildPath 'migration'),
    [string]$Suffix = '-mig'
)

$ErrorActionPreference = 'Stop'

# ======================================================================================================
# CONFIGURATION (edit here, nothing below is tenant or customer specific)
# ======================================================================================================

# Source size -> target size. Sizes not listed here are asked interactively.
$script:SkuMap = @{
    'Standard_B1s'    = 'Standard_B2ls_v2'
    'Standard_B1ms'   = 'Standard_B2ls_v2'
    'Standard_B2s'    = 'Standard_B2ls_v2'
    'Standard_B2ms'   = 'Standard_B2s_v2'
    'Standard_B4ms'   = 'Standard_B4s_v2'
    'Standard_B8ms'   = 'Standard_B8s_v2'
    'Standard_B12ms'  = 'Standard_B16s_v2'
    'Standard_B16ms'  = 'Standard_B16s_v2'
    'Standard_F2s_v2' = 'Standard_D2ls_v6'
    'Standard_F4s_v2' = 'Standard_D4ls_v6'
    'Standard_F8s_v2' = 'Standard_D8ls_v6'
}

# Extension types that are re-created by the platform / backup service and must not be restored by hand.
$script:ExtensionsToSkip = @('VMSnapshot', 'VMSnapshotLinux', 'RestorePoint*')

# Extension types whose protected settings (keys, passwords) cannot be read back from Azure.
# They are reported and must be re-applied manually.
$script:ExtensionsManual = @('CustomScriptExtension', 'CustomScript', 'JsonADDomainExtension',
    'MicrosoftMonitoringAgent', 'OmsAgentForLinux', 'DSC', 'Microsoft.Powershell.DSC')

# ======================================================================================================
# SCRIPT STATE
# ======================================================================================================

$script:Paths    = $null
$script:State    = $null
$script:Config   = $null
$script:SkuCache = @{}
$script:Suffix   = $Suffix
$script:Checks   = $null

# ======================================================================================================
# LOGGING AND PROMPTS
# ======================================================================================================

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO'
    )
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } 'STEP' { 'Cyan' } default { 'Gray' } }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $color
    if ($script:Paths -and $script:Paths.Log) { Add-Content -Path $script:Paths.Log -Value $line }
}

function Read-Required {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default)
    while ($true) {
        $text = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $value = Read-Host $text
        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($Default) { return $Default }
            continue
        }
        return $value.Trim()
    }
}

function Confirm-Action {
    param([Parameter(Mandatory)][string]$Message, [switch]$DefaultYes)
    $hint = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Message $hint").Trim()
        if ($answer -eq '') { return [bool]$DefaultYes }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
    }
}

function Confirm-Typed {
    param([Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)][string]$Expected)
    $answer = Read-Host "$Message (type '$Expected' to confirm, anything else cancels)"
    return ($answer.Trim() -ceq $Expected)
}

# ======================================================================================================
# GENERIC HELPERS
# ======================================================================================================

function Split-ResourceId {
    param([Parameter(Mandatory)][string]$Id)
    $m = [regex]::Match($Id, '(?i)^/subscriptions/(?<sub>[^/]+)/resourceGroups/(?<rg>[^/]+)/providers/(?<ns>[^/]+)/(?<type>[^/]+)/(?<name>[^/]+)(/(?<rest>.*))?$')
    if (-not $m.Success) { throw "Cannot parse resource ID: $Id" }
    [pscustomobject]@{
        Subscription  = $m.Groups['sub'].Value
        ResourceGroup = $m.Groups['rg'].Value
        Provider      = $m.Groups['ns'].Value
        Type          = $m.Groups['type'].Value
        Name          = $m.Groups['name'].Value
        Rest          = $m.Groups['rest'].Value
    }
}

function Test-IpInCidr {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Cidr)
    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) { return $false }
    $ipBytes  = ([ipaddress]$Ip).GetAddressBytes()
    $netBytes = ([ipaddress]$parts[0]).GetAddressBytes()
    if ($ipBytes.Length -ne 4 -or $netBytes.Length -ne 4) { return $false }
    [uint64]$ipNum = 0
    [uint64]$netNum = 0
    foreach ($b in $ipBytes) { $ipNum = ($ipNum -shl 8) -bor $b }
    foreach ($b in $netBytes) { $netNum = ($netNum -shl 8) -bor $b }
    [uint64]$mask = ([uint64]4294967295 -shl (32 - [int]$parts[1])) -band [uint64]4294967295
    return (($ipNum -band $mask) -eq ($netNum -band $mask))
}

function Test-ResourceExists {
    param([Parameter(Mandatory)][scriptblock]$Getter)
    try { return [bool](& $Getter) }
    catch {
        if ($_.Exception.Message -match 'NotFound|not found|could not be found|does not exist') { return $false }
        throw
    }
}

function Invoke-InSubscription {
    # Network resources (VNet/subnet, NSG, public IP) can live in another subscription than the VM.
    # Az cmdlets only look in the current context, so switch for the call and switch back afterwards.
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][scriptblock]$Script)
    $ctx = Get-AzContext
    if ($ctx.Subscription.Id -eq $SubscriptionId) { return (& $Script) }
    Write-Log "Switching context to subscription $SubscriptionId for a lookup."
    Set-AzContext -SubscriptionId $SubscriptionId -Tenant $ctx.Tenant.Id | Out-Null
    try { return (& $Script) }
    finally { Set-AzContext -SubscriptionId $ctx.Subscription.Id -Tenant $ctx.Tenant.Id | Out-Null }
}

function ConvertTo-PlainHashtable {
    param($Dictionary)
    $h = @{}
    if ($Dictionary) { foreach ($k in $Dictionary.Keys) { $h[[string]$k] = [string]$Dictionary[$k] } }
    return $h
}

function Get-TargetName {
    param([Parameter(Mandatory)][string]$Name, [string]$Middle = '', [int]$MaxLength = 80)
    $new = "$Name$Middle$script:Suffix"
    if ($new.Length -gt $MaxLength) { throw "Name '$new' is longer than the $MaxLength characters Azure allows." }
    return $new
}

function Get-VmPowerState {
    param([Parameter(Mandatory)][string]$Rg, [Parameter(Mandatory)][string]$Name)
    try { $v = Get-AzVM -ResourceGroupName $Rg -Name $Name -Status -ErrorAction Stop }
    catch {
        if ($_.Exception.Message -match 'NotFound|not found|could not be found') { return 'notfound' }
        throw
    }
    $code = ($v.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).Code
    if ($code) { return $code.Substring(11) }
    return 'unknown'
}

function Wait-VmPowerState {
    param([string]$Rg, [string]$Name, [string]$State, [int]$TimeoutSec = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VmPowerState -Rg $Rg -Name $Name) -eq $State) { return }
        Start-Sleep -Seconds 10
    }
    throw "VM '$Name' did not reach power state '$State' within $TimeoutSec seconds."
}

function Assert-NotBothRunning {
    # Golden rule 1: the source and the rebuilt VM share hostname, SID and AD computer account.
    $rg = $script:Config.resourceGroup
    $src = Get-VmPowerState -Rg $rg -Name $script:Config.vmName
    $new = Get-VmPowerState -Rg $rg -Name (Get-TargetName $script:Config.vmName -MaxLength 64)
    $srcOff = $src -in @('deallocated', 'notfound')
    $newOff = $new -in @('deallocated', 'notfound')
    if (-not $srcOff -and -not $newOff) {
        throw "GOLDEN RULE: source ($src) and replacement ($new) are both not deallocated. Refusing to continue."
    }
}

# ======================================================================================================
# WORKSPACE, STATE, CHECKPOINTS
# ======================================================================================================

function Save-State {
    $script:State | ConvertTo-Json -Depth 20 | Set-Content -Path $script:Paths.State -Encoding utf8
}

function Import-Config {
    $script:Config = Get-Content -Raw -Path $script:Paths.Config | ConvertFrom-Json -AsHashtable
}

function Initialize-Workspace {
    $dir = Join-Path $WorkRoot $script:VmName
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script:Paths = @{
        Dir    = $dir
        Config = Join-Path $dir 'config.json'
        State  = Join-Path $dir 'state.json'
        Log    = Join-Path $dir 'migration.log'
        Report = Join-Path $dir 'validation-report.csv'
    }

    if (Test-Path $script:Paths.State) {
        $script:State = Get-Content -Raw -Path $script:Paths.State | ConvertFrom-Json -AsHashtable
        if ($script:State.subscriptionId -ne $script:SubscriptionId -or $script:State.resourceGroup -ne $script:ResourceGroupName) {
            throw "Folder '$dir' belongs to a different VM (subscription $($script:State.subscriptionId), resource group $($script:State.resourceGroup)). Use another -WorkRoot."
        }
        if ($script:State.suffix -and $script:State.suffix -ne $script:Suffix) {
            Write-Log "Using suffix '$($script:State.suffix)' recorded in state.json (ignoring '$script:Suffix')." 'WARN'
        }
        $script:Suffix = $script:State.suffix
        Write-Log "Resuming existing workspace $dir"
    }
    else {
        $script:State = [ordered]@{
            schema         = 1
            tenantId       = $script:TenantId
            subscriptionId = $script:SubscriptionId
            resourceGroup  = $script:ResourceGroupName
            vmName         = $script:VmName
            suffix         = $script:Suffix
            phases         = @{}
            steps          = @{}
            placeholders   = @{}
            attestations   = @()
            created        = @{ snapshots = @(); disks = @(); nics = @(); vm = $null }
            phase3Started  = $false
            warnings       = @()
            history        = @()
        }
        Save-State
        Write-Log "Created workspace $dir"
    }
    if (Test-Path $script:Paths.Config) { Import-Config }
}

function Set-PhaseResult {
    param([Parameter(Mandatory)][int]$Phase, [Parameter(Mandatory)][string]$Status)
    $script:State.phases[[string]$Phase] = @{ status = $Status; at = (Get-Date).ToString('o') }
    Save-State
}

function Get-PhaseStatus {
    param([Parameter(Mandatory)][int]$Phase)
    $p = $script:State.phases[[string]$Phase]
    if ($p) { return [string]$p.status }
    return ''
}

function Invoke-Step {
    # Runs one checkpointed step. A step that already completed is skipped, so a phase can be re-run to resume.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$NonFatal
    )
    if ($script:State.steps.ContainsKey($Name)) {
        Write-Log "Step '$Name' already completed, skipping."
        return
    }
    Write-Log "Step: $Name" 'STEP'
    try {
        & $Action
        $script:State.steps[$Name] = (Get-Date).ToString('o')
        Save-State
    }
    catch {
        $msg = "Step '$Name' failed: $($_.Exception.Message)"
        Add-Content -Path $script:Paths.Log -Value $_.ScriptStackTrace
        if ($NonFatal) {
            Write-Log $msg 'ERROR'
            $script:State.warnings += $msg
            Save-State
        }
        else {
            Write-Log $msg 'ERROR'
            throw
        }
    }
}

# ======================================================================================================
# AZURE HELPERS
# ======================================================================================================

function Test-Prerequisites {
    foreach ($m in 'Az.Accounts', 'Az.Compute', 'Az.Network', 'Az.Resources') {
        if (-not (Get-Module -ListAvailable -Name $m)) { throw "Required module '$m' is not installed (Install-Module Az)." }
    }
    if (-not (Get-Module -ListAvailable -Name 'Az.RecoveryServices')) {
        Write-Log "Optional module 'Az.RecoveryServices' is not installed: backup protection cannot be detected, check it manually." 'WARN'
    }
}

function Connect-Target {
    if (-not $script:TenantId) { $script:TenantId = Read-Required 'Tenant ID (GUID or domain name)' }

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $reuse = $false
    if ($ctx -and $ctx.Tenant -and ($ctx.Tenant.Id -eq $script:TenantId)) {
        $reuse = Confirm-Action "Already signed in as '$($ctx.Account.Id)' on this tenant. Reuse the session?" -DefaultYes
    }
    if (-not $reuse) { Connect-AzAccount -Tenant $script:TenantId | Out-Null }

    $subs = @(Get-AzSubscription -TenantId $script:TenantId | Where-Object { $_.State -eq 'Enabled' })
    if (-not $subs) { throw 'No enabled subscription visible in this tenant.' }

    if (-not $script:SubscriptionId) {
        for ($i = 0; $i -lt $subs.Count; $i++) { Write-Host ('  [{0}] {1}  ({2})' -f ($i + 1), $subs[$i].Name, $subs[$i].Id) }
        $pick = Read-Required 'Subscription number, name or ID'
        $sub = if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $subs.Count) { $subs[[int]$pick - 1] }
        else { $subs | Where-Object { $_.Id -eq $pick -or $_.Name -eq $pick } | Select-Object -First 1 }
        if (-not $sub) { throw "Subscription '$pick' not found." }
        $script:SubscriptionId = $sub.Id
    }

    $ctx = Set-AzContext -SubscriptionId $script:SubscriptionId -Tenant $script:TenantId
    Write-Log "Context: $($ctx.Account.Id) | tenant $($ctx.Tenant.Id) | subscription $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" 'OK'
    if (-not (Confirm-Action 'Work on THIS subscription?' -DefaultYes)) { throw 'Cancelled by operator.' }
}

function Get-VmSkuInfo {
    param([Parameter(Mandatory)][string]$Location, [Parameter(Mandatory)][string]$SkuName)
    if (-not $script:SkuCache.ContainsKey($Location)) {
        Write-Log "Loading the compute SKU catalogue for '$Location' (can take a minute)..."
        $script:SkuCache[$Location] = @(Get-AzComputeResourceSku -Location $Location | Where-Object { $_.ResourceType -eq 'virtualMachines' })
    }
    $s = $script:SkuCache[$Location] | Where-Object { $_.Name -eq $SkuName } | Select-Object -First 1
    if (-not $s) { return $null }

    $cap = @{}
    foreach ($c in $s.Capabilities) { $cap[$c.Name] = $c.Value }
    $zones = @()
    foreach ($li in $s.LocationInfo) { if ($li.Location -ieq $Location) { $zones += @($li.Zones) } }
    $restrictions = @(foreach ($r in $s.Restrictions) {
            [pscustomobject]@{
                Type      = [string]$r.Type
                Reason    = [string]$r.ReasonCode
                Zones     = @($r.RestrictionInfo.Zones)
            }
        })
    $mem = 0.0
    if ($cap['MemoryGB']) { $mem = [double]::Parse($cap['MemoryGB'], [Globalization.CultureInfo]::InvariantCulture) }
    $gens = @()
    if ($cap['HyperVGenerations']) { $gens = @($cap['HyperVGenerations'] -split ',' | ForEach-Object { $_.Trim() }) }

    [pscustomobject]@{
        Name         = $SkuName
        Family       = [string]$s.Family
        VCpus        = [int]$cap['vCPUs']
        MemoryGB     = $mem
        Generations  = $gens
        Zones        = $zones
        Restrictions = $restrictions
    }
}

function Test-TargetSku {
    # Returns a list of blocking problems (empty list = target is usable).
    param([string]$Location, [string]$Zone, [string]$Generation, $Source, $Target)
    $problems = @()
    if (-not $Target) { return @("Target size is not offered in '$Location'.") }

    foreach ($r in $Target.Restrictions) {
        if ($r.Type -eq 'Location') { $problems += "Target size is restricted in '$Location' ($($r.Reason))." }
        elseif ($r.Type -eq 'Zone' -and $Zone -and ($Zone -in $r.Zones)) { $problems += "Target size is restricted in zone $Zone ($($r.Reason))." }
    }
    if ($Zone -and ($Zone -notin $Target.Zones)) { $problems += "Target size is not offered in zone $Zone of '$Location'." }

    if ($Generation -and $Target.Generations.Count -gt 0) {
        $g = $Generation.ToUpper()
        if ($g -notin ($Target.Generations | ForEach-Object { $_.ToUpper() })) {
            $problems += "Target size does not support Hyper-V generation $g (supports: $($Target.Generations -join ', ')). A Gen1 to Gen2 conversion is required first."
        }
    }
    if ($Source) {
        if ($Target.VCpus -lt $Source.VCpus) { $problems += "Target would reduce vCPU ($($Source.VCpus) -> $($Target.VCpus))." }
        if ($Target.MemoryGB -lt $Source.MemoryGB) { $problems += "Target would reduce memory ($($Source.MemoryGB) -> $($Target.MemoryGB) GiB)." }
    }
    try {
        $usage = Get-AzVMUsage -Location $Location | Where-Object { $_.Name.Value -ieq $Target.Family } | Select-Object -First 1
        if ($usage -and (($usage.Limit - $usage.CurrentValue) -lt $Target.VCpus)) {
            $problems += "vCPU quota for family '$($Target.Family)' is insufficient ($($usage.CurrentValue)/$($usage.Limit) used, $($Target.VCpus) needed)."
        }
    }
    catch { Write-Log "Could not read vCPU quota: $($_.Exception.Message)" 'WARN' }
    return $problems
}

function Get-VmBackupInfo {
    # Detection only: the script never enrols or removes backup protection.
    param([Parameter(Mandatory)][string]$Rg, [Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command Get-AzRecoveryServicesBackupStatus -ErrorAction SilentlyContinue)) {
        return @{ moduleAvailable = $false; protected = $false }
    }
    try {
        $st = Get-AzRecoveryServicesBackupStatus -Name $Name -ResourceGroupName $Rg -Type AzureVM
        if (-not $st.BackedUp) { return @{ moduleAvailable = $true; protected = $false } }
        return @{ moduleAvailable = $true; protected = $true; vaultName = (Split-ResourceId $st.VaultId).Name }
    }
    catch {
        Write-Log "Backup status lookup failed: $($_.Exception.Message)" 'WARN'
        return @{ moduleAvailable = $true; protected = $false; lookupError = $_.Exception.Message }
    }
}

function Get-DcrAssociations {
    param([Parameter(Mandatory)][string]$VmId)
    $path = "$VmId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2022-06-01"
    $resp = Invoke-AzRestMethod -Method GET -Path $path
    if ($resp.StatusCode -ne 200) { throw "DCR association lookup returned HTTP $($resp.StatusCode)." }
    $items = ($resp.Content | ConvertFrom-Json).value
    return @(foreach ($a in $items) {
            @{
                name = [string]$a.name
                dcrId = [string]$a.properties.dataCollectionRuleId
                dceId = [string]$a.properties.dataCollectionEndpointId
            }
        })
}

# ======================================================================================================
# PHASE 1 - CAPTURE
# ======================================================================================================

function Get-DiskRecord {
    param([string]$ManagedDiskId, [string]$Caching, $Lun, [string]$DeleteOption, [bool]$WriteAccelerator)
    $p = Split-ResourceId $ManagedDiskId
    $d = Get-AzDisk -ResourceGroupName $p.ResourceGroup -DiskName $p.Name
    return [ordered]@{
        name                = $d.Name
        id                  = $d.Id
        resourceGroup       = $p.ResourceGroup
        lun                 = $Lun
        caching             = $Caching
        deleteOption        = $DeleteOption
        writeAccelerator    = $WriteAccelerator
        sku                 = [string]$d.Sku.Name
        sizeGB              = [int]$d.DiskSizeGB
        zones               = @($d.Zones | Where-Object { $_ })
        osType              = [string]$d.OsType
        hyperVGeneration    = [string]$d.HyperVGeneration
        securityType        = [string]$d.SecurityProfile.SecurityType
        diskEncryptionSetId = [string]$d.Encryption.DiskEncryptionSetId
        encryptionType      = [string]$d.Encryption.Type
        maxShares           = $d.MaxShares
        adeEnabled          = [bool]$d.EncryptionSettingsCollection.Enabled
        tags                = (ConvertTo-PlainHashtable $d.Tags)
    }
}

function Invoke-Phase1 {
    Write-Log 'PHASE 1 - Capture the source configuration (read-only)' 'STEP'
    if ($script:State.phase3Started) { Write-Log 'Phase 3 already started: the configuration record is frozen.' 'ERROR'; return }
    if ((Test-Path $script:Paths.Config) -and -not (Confirm-Action 'config.json already exists. Capture again and overwrite it?')) { return }

    $rg = $script:ResourceGroupName
    $vm = Get-AzVM -ResourceGroupName $rg -Name $script:VmName
    $location = $vm.Location
    $blockers = @()        # the VM cannot be migrated by this script
    $complications = @()   # the script does not handle these: listed and acknowledged, then done by hand
    $warnings = @()        # informational

    # ---- compute ----
    $zones = @($vm.Zones | Where-Object { $_ })
    $zone = if ($zones.Count) { $zones[0] } else { '' }
    $sourceSku = $vm.HardwareProfile.VmSize
    $osd = $vm.StorageProfile.OsDisk
    if (-not $osd.ManagedDisk) { $blockers += 'Unmanaged (VHD) OS disk: not supported.' }
    if ($osd.DiffDiskSettings) { $blockers += 'Ephemeral OS disk: not supported (no snapshot possible).' }
    if ($vm.VirtualMachineScaleSet) { $blockers += 'VM belongs to a scale set: not supported.' }
    if ($vm.AdditionalCapabilities.UltraSSDEnabled) { $blockers += 'Ultra SSD enabled: not supported.' }
    if ($vm.CapacityReservation.CapacityReservationGroup.Id) { $complications += 'Capacity reservation group: the new VM will NOT join it.' }
    $secType = [string]$vm.SecurityProfile.SecurityType
    if ($secType -match 'Confidential') { $blockers += "Security type '$secType' is not supported." }

    $osRecord = Get-DiskRecord -ManagedDiskId $osd.ManagedDisk.Id -Caching ([string]$osd.Caching) -Lun $null `
        -DeleteOption ([string]$osd.DeleteOption) -WriteAccelerator ([bool]$osd.WriteAcceleratorEnabled)
    $dataRecords = @(foreach ($dd in $vm.StorageProfile.DataDisks) {
            if (-not $dd.ManagedDisk) { $blockers += "Unmanaged data disk '$($dd.Name)': not supported."; continue }
            Get-DiskRecord -ManagedDiskId $dd.ManagedDisk.Id -Caching ([string]$dd.Caching) -Lun $dd.Lun `
                -DeleteOption ([string]$dd.DeleteOption) -WriteAccelerator ([bool]$dd.WriteAcceleratorEnabled)
        })
    foreach ($d in @($osRecord) + $dataRecords) {
        if ($d.adeEnabled) { $blockers += "Disk '$($d.name)' uses Azure Disk Encryption: handle this VM separately." }
        if ($d.maxShares -and [int]$d.maxShares -gt 1) { $blockers += "Disk '$($d.name)' is a shared disk: not supported." }
        if ($d.sku -in @('UltraSSD_LRS', 'PremiumV2_LRS')) { $blockers += "Disk '$($d.name)' is $($d.sku): not supported." }
    }
    $generation = if ($osRecord.hyperVGeneration) { $osRecord.hyperVGeneration } else { 'V1' }

    # ---- target size ----
    $sourceInfo = Get-VmSkuInfo -Location $location -SkuName $sourceSku
    $suggested = $script:SkuMap[$sourceSku]
    if ($suggested) { Write-Log "Mapping table proposes $sourceSku -> $suggested" }
    else { Write-Log "No mapping for ${sourceSku}: enter the target size manually." 'WARN' }
    $targetSku = Read-Required 'Target size' $suggested
    $targetInfo = Get-VmSkuInfo -Location $location -SkuName $targetSku
    $skuProblems = @(Test-TargetSku -Location $location -Zone $zone -Generation $generation -Source $sourceInfo -Target $targetInfo)
    $blockers += $skuProblems
    $fit = 'Unknown'
    if ($sourceInfo -and $targetInfo) {
        $fit = if ($targetInfo.VCpus -eq $sourceInfo.VCpus -and $targetInfo.MemoryGB -eq $sourceInfo.MemoryGB) { 'Exact' } else { 'Upsize' }
        Write-Log ("Fit: {0} ({1} vCPU / {2} GiB -> {3} vCPU / {4} GiB)" -f $fit, $sourceInfo.VCpus, $sourceInfo.MemoryGB, $targetInfo.VCpus, $targetInfo.MemoryGB)
    }

    # ---- network ----
    $nicRecords = @()
    foreach ($ref in $vm.NetworkProfile.NetworkInterfaces) {
        $np = Split-ResourceId $ref.Id
        $nic = Get-AzNetworkInterface -ResourceGroupName $np.ResourceGroup -Name $np.Name
        $ipcs = @()
        foreach ($ic in $nic.IpConfigurations) {
            if ([string]$ic.PrivateIpAddressVersion -eq 'IPv6') { $blockers += "NIC '$($nic.Name)' has an IPv6 configuration: not supported."; continue }
            $pipRecord = $null
            if ($ic.PublicIpAddress) {
                $pp = Split-ResourceId $ic.PublicIpAddress.Id
                $pip = Invoke-InSubscription $pp.Subscription { Get-AzPublicIpAddress -ResourceGroupName $pp.ResourceGroup -Name $pp.Name }
                $pipRecord = [ordered]@{
                    id = $pip.Id; name = $pip.Name; sku = [string]$pip.Sku.Name
                    allocation = [string]$pip.PublicIpAllocationMethod; address = $pip.IpAddress
                }
                if ($pipRecord.allocation -eq 'Dynamic') { $warnings += "Public IP '$($pip.Name)' is dynamic: its address can change when detached." }
            }
            $ipcs += [ordered]@{
                name         = $ic.Name
                primary      = [bool]$ic.Primary
                privateIp    = $ic.PrivateIpAddress
                allocation   = [string]$ic.PrivateIpAllocationMethod
                subnetId     = $ic.Subnet.Id
                publicIpId   = [string]$ic.PublicIpAddress.Id
                publicIp     = $pipRecord
                asgIds       = @($ic.ApplicationSecurityGroups | ForEach-Object { $_.Id })
                lbPoolIds    = @($ic.LoadBalancerBackendAddressPools | ForEach-Object { $_.Id })
                lbNatRuleIds = @($ic.LoadBalancerInboundNatRules | ForEach-Object { $_.Id })
                appGwPoolIds = @($ic.ApplicationGatewayBackendAddressPools | ForEach-Object { $_.Id })
            }
        }
        $nicRecords += [ordered]@{
            name                 = $nic.Name
            id                   = $nic.Id
            resourceGroup        = $np.ResourceGroup
            primary              = [bool]$ref.Primary
            deleteOption         = [string]$ref.DeleteOption
            nsgId                = [string]$nic.NetworkSecurityGroup.Id
            acceleratedNetworking = [bool]$nic.EnableAcceleratedNetworking
            ipForwarding         = [bool]$nic.EnableIPForwarding
            dnsServers           = @($nic.DnsSettings.DnsServers)
            tags                 = (ConvertTo-PlainHashtable $nic.Tags)
            ipConfigs            = $ipcs
        }
    }

    # ---- extensions ----
    $extRecords = @()
    foreach ($e in @(Get-AzVMExtension -ResourceGroupName $rg -VMName $vm.Name)) {
        if ($e.ExtensionType -like 'AzureDiskEncryption*') { $blockers += "Azure Disk Encryption extension '$($e.Name)' present: handle this VM separately." }
        $skip = [bool]($script:ExtensionsToSkip | Where-Object { $e.ExtensionType -like $_ })
        $manual = [bool]($script:ExtensionsManual | Where-Object { $e.ExtensionType -like $_ })
        if ($manual) { $complications += "Extension '$($e.Name)' ($($e.ExtensionType)) has protected settings that cannot be read: re-apply it manually." }
        $extRecords += [ordered]@{
            name                   = $e.Name
            publisher              = $e.Publisher
            type                   = $e.ExtensionType
            version                = $e.TypeHandlerVersion
            settings               = [string]$e.PublicSettings
            autoUpgradeMinor       = [bool]$e.AutoUpgradeMinorVersion
            enableAutomaticUpgrade = [bool]$e.EnableAutomaticUpgrade
            skip                   = $skip
            manual                 = $manual
        }
    }

    # ---- things the script does not handle (detected for the operator) ----
    $identityType = [string]$vm.Identity.Type
    $hasSystem = $identityType -match 'SystemAssigned'
    $hasUser = $identityType -match 'UserAssigned'
    $userIds = @(if ($vm.Identity.UserAssignedIdentities) { $vm.Identity.UserAssignedIdentities.Keys })
    if ($hasSystem) { $complications += 'System-assigned managed identity: the new VM gets a NEW principal ID. Re-enable the identity and re-grant every role assignment and Key Vault access policy.' }
    if ($hasUser) { $complications += "User-assigned managed identity ($($userIds.Count)): not attached to the new VM. Attach: $($userIds -join ', ')" }

    $poolRefs = @($nicRecords | ForEach-Object { $_.ipConfigs } | ForEach-Object { @($_.lbPoolIds) + @($_.lbNatRuleIds) + @($_.appGwPoolIds) })
    if ($poolRefs.Count) { $complications += "Load balancer / application gateway membership ($($poolRefs.Count) reference(s)): the new VM is NOT added. Add it to the same pools and rules." }
    if ($vm.AvailabilitySetReference.Id) { $complications += "Availability set '$(Split-Path $vm.AvailabilitySetReference.Id -Leaf)': the new VM is created WITHOUT it (availability set membership cannot be changed afterwards)." }
    if ($vm.ProximityPlacementGroup.Id) { $complications += "Proximity placement group '$(Split-Path $vm.ProximityPlacementGroup.Id -Leaf)': the new VM is created WITHOUT it." }

    $dcr = @()
    try { $dcr = @(Get-DcrAssociations -VmId $vm.Id) } catch { $warnings += "Could not read data collection rule associations: $($_.Exception.Message)" }
    if ($dcr.Count) { $complications += "Data collection rule association(s) ($(($dcr | ForEach-Object { $_.name }) -join ', ')): re-create them on the new VM." }

    $vmLocks = @()
    try {
        foreach ($l in @(Get-AzResourceLock -ResourceGroupName $rg)) {
            $lockScope = ($l.ResourceId -replace '/providers/Microsoft\.Authorization/locks/.*$', '')
            if ($lockScope -ieq $vm.Id) {
                $vmLocks += [ordered]@{ name = $l.Name; level = [string]$l.Properties.level; notes = [string]$l.Properties.notes }
                $complications += "Resource lock '$($l.Name)' ($($l.Properties.level)) on the VM: not copied to the new VM."
            }
            elseif ($lockScope -ieq "/subscriptions/$($script:SubscriptionId)/resourceGroups/$rg") {
                $warnings += "Resource-group lock '$($l.Name)' ($($l.Properties.level)) exists and may block changes."
            }
            elseif ($lockScope -match '/(networkInterfaces|disks|snapshots)/') {
                $warnings += "Lock '$($l.Name)' on $lockScope may block the migration."
            }
        }
    }
    catch { $warnings += "Could not read resource locks: $($_.Exception.Message)" }

    $backup = Get-VmBackupInfo -Rg $rg -Name $vm.Name
    if ($backup.protected) { $complications += "Azure Backup (vault '$($backup.vaultName)'): the new VM is NOT protected. Enable backup by hand after validation, once the old VM and its backup item are dealt with." }
    elseif (-not $backup.moduleAvailable) { $complications += 'Backup protection could not be checked (Az.RecoveryServices not installed): verify manually.' }

    # ---- write the record ----
    $bootDiag = $vm.DiagnosticsProfile.BootDiagnostics
    $cfg = [ordered]@{
        schema                    = 1
        capturedAt                = (Get-Date).ToString('o')
        capturedBy                = (Get-AzContext).Account.Id
        tenantId                  = $script:TenantId
        subscriptionId            = $script:SubscriptionId
        resourceGroup             = $rg
        vmName                    = $vm.Name
        vmId                      = $vm.Id
        location                  = $location
        zones                     = $zones
        sourceSku                 = $sourceSku
        targetSku                 = $targetSku
        skuFit                    = $fit
        osType                    = $osRecord.osType
        hyperVGeneration          = $generation
        securityType              = $secType
        secureBoot                = [bool]$vm.SecurityProfile.UefiSettings.SecureBootEnabled
        vTpm                      = [bool]$vm.SecurityProfile.UefiSettings.VTpmEnabled
        encryptionAtHost          = [bool]$vm.SecurityProfile.EncryptionAtHost
        licenseType               = [string]$vm.LicenseType
        tags                      = (ConvertTo-PlainHashtable $vm.Tags)
        plan                      = if ($vm.Plan) { [ordered]@{ name = $vm.Plan.Name; publisher = $vm.Plan.Publisher; product = $vm.Plan.Product } } else { $null }
        bootDiagnostics           = [ordered]@{ enabled = [bool]$bootDiag.Enabled; storageUri = [string]$bootDiag.StorageUri }
        identity                  = [ordered]@{ type = $identityType; hasSystem = $hasSystem; hasUser = $hasUser; userAssignedIds = $userIds }
        osDisk                    = $osRecord
        dataDisks                 = $dataRecords
        nics                      = $nicRecords
        extensions                = $extRecords
        dcrAssociations           = $dcr
        locks                     = $vmLocks
        backup                    = $backup
        complications             = $complications
        warnings                  = $warnings
    }
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $script:Paths.Config -Encoding utf8
    Import-Config

    Write-Host ''
    Write-Log "VM $($vm.Name) | $location | zone '$zone' | $sourceSku -> $targetSku | Gen $generation | $($script:Config.osType)"
    Write-Log "Disks: 1 OS + $($dataRecords.Count) data | NICs: $($nicRecords.Count) | Extensions: $($extRecords.Count) | AHB: '$($script:Config.licenseType)'"
    foreach ($n in $nicRecords) { foreach ($i in $n.ipConfigs) { Write-Log "  NIC $($n.name) / $($i.name): $($i.privateIp) ($($i.allocation))$(if ($i.publicIp) { ' + public ' + $i.publicIp.address })" } }
    foreach ($w in $warnings) { Write-Log $w 'WARN' }
    if ($complications.Count) {
        Write-Host ''
        Write-Log "NOT HANDLED BY THIS SCRIPT ($($complications.Count)) - to be done by hand, you will be asked to acknowledge them in phase 2:" 'WARN'
        foreach ($x in $complications) { Write-Log "  - $x" 'WARN' }
    }

    if ($blockers.Count) {
        foreach ($b in $blockers) { Write-Log "BLOCKER: $b" 'ERROR' }
        Set-PhaseResult 1 'blocked'
        Write-Log "config.json written but the VM cannot be migrated as is. Fix the blockers and capture again." 'ERROR'
        return
    }
    Set-PhaseResult 1 'done'
    Write-Log "Phase 1 complete. Record saved to $($script:Paths.Config)" 'OK'
}

# ======================================================================================================
# PHASE 2 - NETWORK PREPARATION
# ======================================================================================================

function Test-TargetNamesFree {
    $c = $script:Config
    $rg = $c.resourceGroup
    $taken = @()
    $vmN = Get-TargetName $c.vmName -MaxLength 64
    if (Test-ResourceExists { Get-AzVM -ResourceGroupName $rg -Name $vmN -ErrorAction Stop }) { $taken += "VM $vmN" }
    foreach ($n in $c.nics) {
        $nn = Get-TargetName $n.name
        if (Test-ResourceExists { Get-AzNetworkInterface -ResourceGroupName $n.resourceGroup -Name $nn -ErrorAction Stop }) { $taken += "NIC $nn" }
    }
    foreach ($d in @($c.osDisk) + @($c.dataDisks)) {
        $dn = Get-TargetName $d.name
        $sn = Get-TargetName $d.name -Middle '-snap'
        if (Test-ResourceExists { Get-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $dn -ErrorAction Stop }) { $taken += "disk $dn" }
        if (Test-ResourceExists { Get-AzSnapshot -ResourceGroupName $d.resourceGroup -SnapshotName $sn -ErrorAction Stop }) { $taken += "snapshot $sn" }
    }
    return $taken
}

function Invoke-Phase2 {
    Write-Log 'PHASE 2 - Network preparation (read-only)' 'STEP'
    if ((Get-PhaseStatus 1) -ne 'done') { Write-Log 'Phase 1 must be completed first.' 'ERROR'; return }
    if ($script:State.phase3Started) { Write-Log 'Phase 3 already started: placeholders are frozen.' 'ERROR'; return }
    $c = $script:Config

    $taken = @(Test-TargetNamesFree)
    if ($taken.Count) {
        foreach ($t in $taken) { Write-Log "Name already in use: $t" 'ERROR' }
        Write-Log 'Remove or rename these resources, then run phase 2 again.' 'ERROR'
        return
    }
    Write-Log "Target names are free (suffix '$script:Suffix')." 'OK'

    $placeholders = @{}
    $used = @()
    foreach ($n in $c.nics) {
        foreach ($i in $n.ipConfigs) {
            $key = "$($n.name)|$($i.name)"
            $existing = $script:State.placeholders[$key]
            if ($existing -and (Confirm-Action "Keep placeholder $existing for $key?" -DefaultYes)) { $placeholders[$key] = $existing; $used += $existing; continue }

            $sn = Split-ResourceId $i.subnetId
            $subnetName = ($sn.Rest -split '/')[1]
            $prefixes = @(Invoke-InSubscription $sn.Subscription {
                    $vnet = Get-AzVirtualNetwork -ResourceGroupName $sn.ResourceGroup -Name $sn.Name
                    (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $subnetName).AddressPrefix
                })
            $probe = Invoke-InSubscription $sn.Subscription { Test-AzPrivateIPAddressAvailability -ResourceGroupName $sn.ResourceGroup -VirtualNetworkName $sn.Name -IPAddress $i.privateIp }
            if ($probe.AvailableIPAddresses) { Write-Log "Free addresses suggested by Azure: $($probe.AvailableIPAddresses -join ', ')" }

            while ($true) {
                $ip = Read-Required "Placeholder IP for $key (subnet $subnetName, $($prefixes -join ', '); current $($i.privateIp))"
                $parsed = $null
                if (-not [ipaddress]::TryParse($ip, [ref]$parsed)) { Write-Log 'Not a valid IP address.' 'WARN'; continue }
                if ($ip -eq $i.privateIp -or $ip -in $used) { Write-Log 'Must differ from the original IP and from the other placeholders.' 'WARN'; continue }
                if (-not ($prefixes | Where-Object { Test-IpInCidr -Ip $ip -Cidr $_ })) { Write-Log 'Address is outside the subnet.' 'WARN'; continue }
                $res = Invoke-InSubscription $sn.Subscription { Test-AzPrivateIPAddressAvailability -ResourceGroupName $sn.ResourceGroup -VirtualNetworkName $sn.Name -IPAddress $ip }
                if (-not $res.Available) { Write-Log "Address is not available. Suggested: $($res.AvailableIPAddresses -join ', ')" 'WARN'; continue }
                break
            }
            $placeholders[$key] = $ip
            $used += $ip
        }
    }

    if ($c.complications.Count) {
        Write-Host ''
        Write-Host 'The following are NOT handled by this script. The replacement VM will be created without them:' -ForegroundColor Yellow
        foreach ($x in $c.complications) { Write-Host "  - $x" -ForegroundColor Yellow }
        if (-not (Confirm-Typed 'Acknowledge that these will be handled by hand' 'ACKNOWLEDGE')) { Write-Log 'Complications not acknowledged: phase 2 not completed.' 'WARN'; return }
        $script:State.attestations += @{ type = 'complications-acknowledged'; count = $c.complications.Count; by = $env:USERNAME; at = (Get-Date).ToString('o') }
    }

    Write-Host ''
    Write-Host 'Guest pre-checks are owned by the team and are NOT verified by this script:'
    Write-Host '  - temp-disk remediation done (page file / swap, tempdb, fstab, app paths) and VM rebooted cleanly'
    Write-Host '  - guest network interface is on DHCP (no static IPv4 inside the OS)'
    Write-Host '  - owners informed, change window agreed, DNS/firewall dependencies listed for rollback'
    if (-not (Confirm-Typed 'Confirm the guest pre-checks are complete' 'YES')) { Write-Log 'Pre-checks not confirmed: phase 2 not completed.' 'WARN'; return }

    $script:State.placeholders = $placeholders
    $script:State.attestations += @{ type = 'guest-prechecks'; by = $env:USERNAME; at = (Get-Date).ToString('o') }
    Set-PhaseResult 2 'done'
    Write-Log 'Phase 2 complete.' 'OK'
}

# ======================================================================================================
# PHASE 3 - EXECUTE
# ======================================================================================================

function Set-SourceNicState {
    # Rewrites the source NIC. Mode 'park' moves it to the placeholder IP and detaches the public IP.
    # Mode 'restore' puts the original IP and public IP back. Pools, rules and NSG/ASG are never touched.
    param([Parameter(Mandatory)][ValidateSet('park', 'restore')][string]$Mode, [Parameter(Mandatory)]$NicRecord)
    $nic = Get-AzNetworkInterface -ResourceGroupName $NicRecord.resourceGroup -Name $NicRecord.name
    foreach ($ic in $nic.IpConfigurations) {
        $rec = $NicRecord.ipConfigs | Where-Object { $_.name -eq $ic.Name } | Select-Object -First 1
        if (-not $rec) { continue }
        if ($Mode -eq 'park') {
            $ic.PrivateIpAddress = $script:State.placeholders["$($NicRecord.name)|$($ic.Name)"]
            $ic.PrivateIpAllocationMethod = 'Static'
            $ic.PublicIpAddress = $null
        }
        else {
            $ic.PrivateIpAddress = $rec.privateIp
            $ic.PrivateIpAllocationMethod = $rec.allocation
            if ($rec.publicIpId) {
                $pp = Split-ResourceId $rec.publicIpId
                $ic.PublicIpAddress = Invoke-InSubscription $pp.Subscription { Get-AzPublicIpAddress -ResourceGroupName $pp.ResourceGroup -Name $pp.Name }
            }
        }
    }
    $nic | Set-AzNetworkInterface | Out-Null

    # verify
    $check = Get-AzNetworkInterface -ResourceGroupName $NicRecord.resourceGroup -Name $NicRecord.name
    foreach ($ic in $check.IpConfigurations) {
        $rec = $NicRecord.ipConfigs | Where-Object { $_.name -eq $ic.Name } | Select-Object -First 1
        if (-not $rec) { continue }
        $expected = if ($Mode -eq 'park') { $script:State.placeholders["$($NicRecord.name)|$($ic.Name)"] } else { $rec.privateIp }
        if ($ic.PrivateIpAddress -ne $expected) { throw "NIC $($NicRecord.name)/$($ic.Name) holds $($ic.PrivateIpAddress) instead of $expected." }
    }
}

function New-ReplacementNic {
    param([Parameter(Mandatory)]$NicRecord)
    $c = $script:Config
    $ipcfgs = @(foreach ($i in $NicRecord.ipConfigs) {
            $p = @{ Name = $i.name; SubnetId = $i.subnetId; PrivateIpAddress = $i.privateIp }
            if ($i.primary) { $p.Primary = $true }
            if ($i.publicIpId) { $p.PublicIpAddressId = $i.publicIpId }
            if ($i.asgIds.Count) { $p.ApplicationSecurityGroupId = @($i.asgIds) }
            New-AzNetworkInterfaceIpConfig @p
        })
    $np = @{
        Name = (Get-TargetName $NicRecord.name); ResourceGroupName = $NicRecord.resourceGroup
        Location = $c.location; IpConfiguration = $ipcfgs; Force = $true
    }
    if ($NicRecord.nsgId) {
        $ns = Split-ResourceId $NicRecord.nsgId
        $np.NetworkSecurityGroup = Invoke-InSubscription $ns.Subscription { Get-AzNetworkSecurityGroup -ResourceGroupName $ns.ResourceGroup -Name $ns.Name }
    }
    if ($NicRecord.acceleratedNetworking) { $np.EnableAcceleratedNetworking = $true }
    if ($NicRecord.ipForwarding) { $np.EnableIPForwarding = $true }
    if ($NicRecord.dnsServers.Count) { $np.DnsServer = @($NicRecord.dnsServers) }
    if ($NicRecord.tags.Count) { $np.Tag = $NicRecord.tags }

    $attempt = 0
    while ($true) {
        try { return (New-AzNetworkInterface @np) }
        catch {
            $attempt++
            if ($attempt -ge 5 -or $_.Exception.Message -notmatch 'already in use|PrivateIPAddressInUse|IPConfigurationInUse') { throw }
            Write-Log "Original IP not yet released, retrying in 20 s ($attempt/5)..." 'WARN'
            Start-Sleep -Seconds 20
        }
    }
}

function New-ReplacementVm {
    $c = $script:Config
    $rg = $c.resourceGroup
    $newName = Get-TargetName $c.vmName -MaxLength 64

    $p = @{ VMName = $newName; VMSize = $c.targetSku }
    if ($c.zones.Count) { $p.Zone = @($c.zones) }
    if ($c.licenseType) { $p.LicenseType = $c.licenseType }
    if ($c.tags.Count) { $p.Tags = $c.tags }
    if ($c.encryptionAtHost) { $p.EncryptionAtHost = $true }
    $vmCfg = New-AzVMConfig @p

    if ($c.securityType -eq 'TrustedLaunch') {
        $vmCfg = Set-AzVMSecurityProfile -VM $vmCfg -SecurityType 'TrustedLaunch'
        $vmCfg = Set-AzVMUefi -VM $vmCfg -EnableVtpm $c.vTpm -EnableSecureBoot $c.secureBoot
    }
    if ($c.plan) { $vmCfg = Set-AzVMPlan -VM $vmCfg -Name $c.plan.name -Publisher $c.plan.publisher -Product $c.plan.product }

    $osParams = @{ VM = $vmCfg; Name = (Get-TargetName $c.osDisk.name); ManagedDiskId = $script:State.created.diskIds[$c.osDisk.name]; CreateOption = 'Attach' }
    if ($c.osDisk.caching) { $osParams.Caching = $c.osDisk.caching }
    if ($c.osType -eq 'Windows') { $osParams.Windows = $true } else { $osParams.Linux = $true }
    $vmCfg = Set-AzVMOSDisk @osParams

    foreach ($d in ($c.dataDisks | Sort-Object { [int]$_.lun })) {
        $dp = @{ VM = $vmCfg; Name = (Get-TargetName $d.name); ManagedDiskId = $script:State.created.diskIds[$d.name]; Lun = [int]$d.lun; CreateOption = 'Attach' }
        if ($d.caching) { $dp.Caching = $d.caching }
        $vmCfg = Add-AzVMDataDisk @dp
    }

    foreach ($n in $c.nics) {
        $np = @{ VM = $vmCfg; Id = $script:State.created.nicIds[$n.name] }
        if ($c.nics.Count -gt 1 -and $n.primary) { $np.Primary = $true }
        $vmCfg = Add-AzVMNetworkInterface @np
    }

    if ($c.bootDiagnostics.enabled) { $vmCfg = Set-AzVMBootDiagnostic -VM $vmCfg -Enable } else { $vmCfg = Set-AzVMBootDiagnostic -VM $vmCfg -Disable }

    $res = New-AzVM -ResourceGroupName $rg -Location $c.location -VM $vmCfg -DisableBginfoExtension
    if ($res -and ($res.PSObject.Properties.Name -contains 'IsSuccessStatusCode') -and -not $res.IsSuccessStatusCode) {
        throw "New-AzVM failed: $($res.ReasonPhrase)"
    }
}

function Invoke-Phase3 {
    Write-Log 'PHASE 3 - Execute (modifies Azure resources)' 'STEP'
    foreach ($n in 1, 2) { if ((Get-PhaseStatus $n) -ne 'done') { Write-Log "Phase $n must be completed first." 'ERROR'; return } }
    $c = $script:Config
    $st = $script:State
    $rg = $c.resourceGroup
    $newVmName = Get-TargetName $c.vmName -MaxLength 64
    if (-not $st.created.ContainsKey('diskIds')) { $st.created.diskIds = @{} }
    if (-not $st.created.ContainsKey('nicIds')) { $st.created.nicIds = @{} }
    if (-not $st.created.ContainsKey('snapshotIds')) { $st.created.snapshotIds = @{} }

    Write-Host ''
    Write-Host "  Source VM      : $($c.vmName)  ($($c.sourceSku))  -> will be SHUT DOWN and deallocated"
    Write-Host "  Replacement VM : $newVmName  ($($c.targetSku))"
    Write-Host "  Disks          : 1 OS + $($c.dataDisks.Count) data (full snapshots, new managed disks)"
    Write-Host "  IP hand-over   : $(($c.nics | ForEach-Object { $_.ipConfigs } | ForEach-Object { $_.privateIp }) -join ', ')"
    Write-Host '  Nothing on the source is deleted: it stays deallocated, with its NIC parked on a placeholder IP.'
    Write-Host '  Backup is not touched: the snapshots taken here are the rollback point.'
    if (-not (Confirm-Action 'Start (or resume) phase 3 now?')) { return }
    $st.phase3Started = $true
    Save-State

    # --- pre-flight -------------------------------------------------------------------------------------
    Invoke-Step 'p3.preflight' {
        $state = Get-VmPowerState -Rg $rg -Name $c.vmName
        if ($state -eq 'notfound') { throw "Source VM $($c.vmName) not found." }
        $taken = @(Test-TargetNamesFree)
        if ($taken.Count) { throw "Target names already in use: $($taken -join ', ')" }
    }

    # --- shutdown ---------------------------------------------------------------------------------------
    Invoke-Step 'p3.stop-source' {
        $state = Get-VmPowerState -Rg $rg -Name $c.vmName
        if ($state -ne 'deallocated') {
            Write-Log 'Stopping and deallocating the source VM (the platform asks the guest OS for a graceful shutdown)...'
            Stop-AzVM -ResourceGroupName $rg -Name $c.vmName -Force | Out-Null
        }
        Wait-VmPowerState -Rg $rg -Name $c.vmName -State 'deallocated'
        Write-Log 'Source VM is deallocated.' 'OK'
    }

    # --- snapshots and disks ----------------------------------------------------------------------------
    foreach ($d in @($c.osDisk) + @($c.dataDisks)) {
        $isOs = ($d.name -eq $c.osDisk.name)
        Invoke-Step "p3.snapshot.$($d.name)" {
            $snapName = Get-TargetName $d.name -Middle '-snap'
            $src = Get-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $d.name
            $sp = @{ SourceUri = $src.Id; Location = $c.location; CreateOption = 'Copy'; SkuName = 'Standard_LRS' }
            if ($d.tags.Count) { $sp.Tag = $d.tags }
            if ($isOs -and $d.hyperVGeneration) { $sp.HyperVGeneration = $d.hyperVGeneration }
            $snap = New-AzSnapshot -ResourceGroupName $d.resourceGroup -SnapshotName $snapName -Snapshot (New-AzSnapshotConfig @sp)
            $st.created.snapshots += $snap.Id
            $st.created.snapshotIds[$d.name] = $snap.Id
        }
        Invoke-Step "p3.disk.$($d.name)" {
            $diskName = Get-TargetName $d.name
            $snapId = $st.created.snapshotIds[$d.name]
            $dp = @{ Location = $c.location; CreateOption = 'Copy'; SourceResourceId = $snapId; SkuName = $d.sku; DiskSizeGB = $d.sizeGB }
            if ($d.zones.Count) { $dp.Zone = @($d.zones) }
            if ($d.tags.Count) { $dp.Tag = $d.tags }
            if ($d.diskEncryptionSetId) { $dp.DiskEncryptionSetId = $d.diskEncryptionSetId; $dp.EncryptionType = $d.encryptionType }
            if ($isOs) {
                $dp.OsType = $d.osType
                if ($d.hyperVGeneration) { $dp.HyperVGeneration = $d.hyperVGeneration }
                if ($d.securityType) { $dp.SecurityType = $d.securityType }
            }
            $new = New-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $diskName -Disk (New-AzDiskConfig @dp)
            $st.created.disks += $new.Id
            $st.created.diskIds[$d.name] = $new.Id
            Write-Log "Mapping: snapshot $(Split-Path $snapId -Leaf) -> disk $diskName -> LUN $(if ($isOs) { 'OS' } else { $d.lun })"
        }
    }

    # --- IP hand-over -----------------------------------------------------------------------------------
    foreach ($n in $c.nics) {
        Invoke-Step "p3.park-source-nic.$($n.name)" {
            Assert-NotBothRunning
            if ((Get-VmPowerState -Rg $rg -Name $c.vmName) -ne 'deallocated') { throw 'Source VM is not deallocated.' }
            Set-SourceNicState -Mode park -NicRecord $n
        }
    }
    foreach ($n in $c.nics) {
        Invoke-Step "p3.new-nic.$($n.name)" {
            $nic = New-ReplacementNic -NicRecord $n
            $st.created.nics += $nic.Id
            $st.created.nicIds[$n.name] = $nic.Id
        }
    }

    # --- replacement VM ---------------------------------------------------------------------------------
    Invoke-Step 'p3.new-vm' {
        Assert-NotBothRunning
        if ((Get-VmPowerState -Rg $rg -Name $c.vmName) -ne 'deallocated') { throw 'Source VM is not deallocated: refusing to create the replacement.' }
        New-ReplacementVm
        $nv = Get-AzVM -ResourceGroupName $rg -Name $newVmName
        $st.created.vm = $nv.Id
        Write-Log "Replacement VM created: $($nv.Id)" 'OK'
    }

    # --- extensions ---------------------------------------------------------------------------------------
    foreach ($e in $c.extensions) {
        if ($e.skip) { continue }
        if ($e.manual) { Write-Log "Extension '$($e.name)' needs manual re-application (protected settings)." 'WARN'; continue }
        Invoke-Step "p3.extension.$($e.name)" -NonFatal {
            $ep = @{
                ResourceGroupName = $rg; VMName = $newVmName; Location = $c.location; Name = $e.name
                Publisher = $e.publisher; ExtensionType = $e.type; TypeHandlerVersion = $e.version
            }
            if ($e.settings) { $ep.SettingString = $e.settings }
            if (-not $e.autoUpgradeMinor) { $ep.DisableAutoUpgradeMinorVersion = $true }
            if ($e.enableAutomaticUpgrade) { $ep.EnableAutomaticUpgrade = $true }
            $r = Set-AzVMExtension @ep
            if ($r -and ($r.PSObject.Properties.Name -contains 'IsSuccessStatusCode') -and -not $r.IsSuccessStatusCode) { throw "Set-AzVMExtension: $($r.ReasonPhrase)" }
        }
    }

    $failed = @($st.warnings)
    Set-PhaseResult 3 $(if ($failed.Count) { 'done-with-warnings' } else { 'done' })
    Write-Host ''
    Write-Log "Phase 3 complete. Replacement VM $newVmName is running; source VM $($c.vmName) stays deallocated." 'OK'
    foreach ($w in $failed) { Write-Log "Needs attention: $w (re-run phase 3 to retry failed extension steps)" 'WARN' }
    if ($c.complications.Count) {
        Write-Log 'Still to do by hand on the new VM:' 'WARN'
        foreach ($x in $c.complications) { Write-Log "  - $x" 'WARN' }
    }
    Write-Log 'Next: run phase 4 (validate) or phase 5 (rollback).'
}

# ======================================================================================================
# PHASE 4 - VALIDATE
# ======================================================================================================

function Add-Check {
    param([string]$Area, [string]$Check, $Expected, $Actual, [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Result)
    $script:Checks.Add([pscustomobject]@{ Area = $Area; Check = $Check; Expected = [string]$Expected; Actual = [string]$Actual; Result = $Result })
}

function Add-EqCheck {
    param([string]$Area, [string]$Check, $Expected, $Actual)
    $result = if ([string]$Expected -ieq [string]$Actual) { 'PASS' } else { 'FAIL' }
    Add-Check $Area $Check $Expected $Actual $result
}

function Invoke-Phase4 {
    Write-Log 'PHASE 4 - Validate (read-only)' 'STEP'
    if ((Get-PhaseStatus 3) -notin 'done', 'done-with-warnings') { Write-Log 'Phase 3 must be completed first.' 'ERROR'; return }
    $c = $script:Config
    $rg = $c.resourceGroup
    $newName = Get-TargetName $c.vmName -MaxLength 64
    $script:Checks = [System.Collections.Generic.List[object]]::new()

    $nv = Get-AzVM -ResourceGroupName $rg -Name $newName
    $power = Get-VmPowerState -Rg $rg -Name $newName
    $srcPower = Get-VmPowerState -Rg $rg -Name $c.vmName

    # ---- platform: VM ----
    Add-EqCheck 'VM' 'Power state' 'running' $power
    Add-EqCheck 'VM' 'Provisioning state' 'Succeeded' $nv.ProvisioningState
    Add-EqCheck 'VM' 'Size' $c.targetSku $nv.HardwareProfile.VmSize
    Add-Check 'VM' 'Source VM not running (golden rule)' 'deallocated' $srcPower $(if ($srcPower -eq 'running') { 'FAIL' } else { 'PASS' })
    Add-EqCheck 'VM' 'Zone' ($c.zones -join ',') (@($nv.Zones) -join ',')
    Add-EqCheck 'VM' 'Security type' $c.securityType $nv.SecurityProfile.SecurityType
    Add-EqCheck 'VM' 'Hybrid Benefit (license type)' $c.licenseType $nv.LicenseType
    Add-EqCheck 'VM' 'Boot diagnostics enabled' $c.bootDiagnostics.enabled ([bool]$nv.DiagnosticsProfile.BootDiagnostics.Enabled)
    $nvOs = Get-AzDisk -ResourceGroupName $c.osDisk.resourceGroup -DiskName (Get-TargetName $c.osDisk.name)
    Add-EqCheck 'VM' 'Hyper-V generation' $c.hyperVGeneration $nvOs.HyperVGeneration
    $srcTags = $c.tags; $newTags = ConvertTo-PlainHashtable $nv.Tags
    $tagDiff = @($srcTags.Keys | Where-Object { $newTags[$_] -ne $srcTags[$_] })
    Add-Check 'VM' 'Tags' "$($srcTags.Count) tags" "$($newTags.Count) tags$(if ($tagDiff) { ', differing: ' + ($tagDiff -join ',') })" $(if ($tagDiff) { 'FAIL' } else { 'PASS' })

    # ---- platform: disks ----
    $nvDisks = @{}
    foreach ($dd in $nv.StorageProfile.DataDisks) { $nvDisks[[int]$dd.Lun] = $dd }
    Add-EqCheck 'Disk' 'OS disk caching' $c.osDisk.caching $nv.StorageProfile.OsDisk.Caching
    Add-EqCheck 'Disk' 'OS disk SKU' $c.osDisk.sku $nvOs.Sku.Name
    Add-EqCheck 'Disk' 'Data disk count' $c.dataDisks.Count $nvDisks.Count
    foreach ($d in $c.dataDisks) {
        $actual = $nvDisks[[int]$d.lun]
        if (-not $actual) { Add-Check 'Disk' "LUN $($d.lun)" $d.name 'missing' 'FAIL'; continue }
        Add-EqCheck 'Disk' "LUN $($d.lun) disk" (Get-TargetName $d.name) $actual.Name
        Add-EqCheck 'Disk' "LUN $($d.lun) caching" $d.caching $actual.Caching
        Add-EqCheck 'Disk' "LUN $($d.lun) size GB" $d.sizeGB $actual.DiskSizeGB
        $ad = Get-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $actual.Name
        Add-EqCheck 'Disk' "LUN $($d.lun) SKU" $d.sku $ad.Sku.Name
        Add-EqCheck 'Disk' "LUN $($d.lun) zone" ($d.zones -join ',') (@($ad.Zones) -join ',')
    }

    # ---- platform: network ----
    foreach ($n in $c.nics) {
        $nn = Get-TargetName $n.name
        $nic = Get-AzNetworkInterface -ResourceGroupName $n.resourceGroup -Name $nn
        Add-Check 'NIC' "$nn attached to VM" 'yes' $(if ($nv.NetworkProfile.NetworkInterfaces.Id -contains $nic.Id) { 'yes' } else { 'no' }) $(if ($nv.NetworkProfile.NetworkInterfaces.Id -contains $nic.Id) { 'PASS' } else { 'FAIL' })
        Add-EqCheck 'NIC' "$nn NSG" $n.nsgId $nic.NetworkSecurityGroup.Id
        Add-EqCheck 'NIC' "$nn accelerated networking" $n.acceleratedNetworking ([bool]$nic.EnableAcceleratedNetworking)
        Add-EqCheck 'NIC' "$nn DNS servers" ($n.dnsServers -join ',') (@($nic.DnsSettings.DnsServers) -join ',')
        foreach ($i in $n.ipConfigs) {
            $ni = $nic.IpConfigurations | Where-Object { $_.Name -eq $i.name } | Select-Object -First 1
            Add-EqCheck 'NIC' "$nn/$($i.name) private IP" $i.privateIp $ni.PrivateIpAddress
            Add-EqCheck 'NIC' "$nn/$($i.name) allocation" 'Static' $ni.PrivateIpAllocationMethod
            Add-EqCheck 'NIC' "$nn/$($i.name) public IP" $i.publicIpId $ni.PublicIpAddress.Id
            Add-EqCheck 'NIC' "$nn/$($i.name) ASGs" (($i.asgIds | Sort-Object) -join ',') ((@($ni.ApplicationSecurityGroups | ForEach-Object { $_.Id }) | Sort-Object) -join ',')
        }
        $srcNic = Get-AzNetworkInterface -ResourceGroupName $n.resourceGroup -Name $n.name
        foreach ($i in $n.ipConfigs) {
            $si = $srcNic.IpConfigurations | Where-Object { $_.Name -eq $i.name } | Select-Object -First 1
            $ph = $script:State.placeholders["$($n.name)|$($i.name)"]
            Add-EqCheck 'NIC' "Source $($n.name)/$($i.name) parked on placeholder" $ph $si.PrivateIpAddress
        }
    }

    # ---- platform: extensions, identity, locks, monitoring, backup ----
    $nvExt = @(Get-AzVMExtension -ResourceGroupName $rg -VMName $newName)
    foreach ($e in $c.extensions) {
        if ($e.skip) { continue }
        $found = $nvExt | Where-Object { $_.Name -eq $e.name } | Select-Object -First 1
        if ($e.manual) { Add-Check 'Extension' $e.name 'manual re-apply' $(if ($found) { $found.ProvisioningState } else { 'absent' }) $(if ($found -and $found.ProvisioningState -eq 'Succeeded') { 'PASS' } else { 'WARN' }); continue }
        if (-not $found) { Add-Check 'Extension' $e.name 'Succeeded' 'absent' 'FAIL' }
        else { Add-EqCheck 'Extension' $e.name 'Succeeded' $found.ProvisioningState }
    }
    foreach ($x in $c.complications) { Add-Check 'Manual follow-up' $x 'done by hand' 'not checked by script' 'INFO' }

    # boot diagnostics screenshot, for a human to look at
    try {
        $bd = @{ ResourceGroupName = $rg; Name = $newName; LocalPath = $script:Paths.Dir }
        if ($c.osType -eq 'Windows') { $bd.Windows = $true } else { $bd.Linux = $true }
        Get-AzVMBootDiagnosticsData @bd | Out-Null
        Add-Check 'VM' 'Boot diagnostics screenshot saved for review' $script:Paths.Dir 'saved' 'INFO'
    }
    catch { Add-Check 'VM' 'Boot diagnostics screenshot' 'saved' $_.Exception.Message 'WARN' }

    foreach ($w in @($script:State.warnings)) { Add-Check 'Phase 3' 'Restore step' 'completed' $w 'FAIL' }

    # ---- report ----
    $script:Checks | Export-Csv -Path $script:Paths.Report -NoTypeInformation -Encoding utf8
    $script:Checks | Format-Table Area, Check, Expected, Actual, Result -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    $fail = @($script:Checks | Where-Object { $_.Result -eq 'FAIL' }).Count
    $warn = @($script:Checks | Where-Object { $_.Result -eq 'WARN' }).Count
    Write-Log "Platform checks: $($script:Checks.Count) total, $fail FAIL, $warn WARN. Report: $($script:Paths.Report)" $(if ($fail) { 'ERROR' } else { 'OK' })

    Write-Host ''
    Write-Host 'MANUAL CHECKLIST (guest and application, owned by the team):' -ForegroundColor Cyan
    @(
        'Guest interface is on DHCP and received the expected address (check inside the OS, not only the portal)'
        'DNS servers correct; forward and reverse resolution working; no stale cached entries on clients'
        'Drive letters / mount points match the pre-migration record (D: may have been reassigned)'
        'Page file or swap on its new location, not on a temporary disk'
        'No automatic-start service stopped, no failed systemd unit, no new errors in the system event log'
        'Domain-joined Windows: AD trust relationship intact'
        'SQL Server: service running and tempdb up from its relocated path'
        'Application owner confirms a representative transaction, database connectivity and scheduled jobs'
        'Inbound/outbound connectivity and reachability from dependent systems on the expected ports'
    ) | ForEach-Object { Write-Host "  [ ] $_" }
    Write-Host ''

    if ($fail) { Set-PhaseResult 4 'FAIL'; Write-Log 'Validation FAILED on platform checks. Fix them (re-run phase 3 for restore steps) or roll back (phase 5).' 'ERROR'; return }
    if (-not (Confirm-Action 'Have the manual guest/application checks been completed by the team and passed?')) {
        Set-PhaseResult 4 'FAIL'
        Write-Log 'Manual checks not passed. Phase 4 recorded as FAIL.' 'WARN'
        return
    }
    $approver = Read-Required 'Name of the person who confirmed the manual checks'
    $script:State.attestations += @{ type = 'manual-validation'; by = $approver; recordedBy = $env:USERNAME; at = (Get-Date).ToString('o') }
    Set-PhaseResult 4 'PASS'
    Write-Log 'Phase 4 PASS.' 'OK'
    Write-Log "Nothing was deleted. After the owner's formal sign-off, by hand: remove the old VM, NIC, disks and snapshots (keep them for the agreed retention, 14 days by default), and enable backup on the new VM once the old backup item is dealt with." 'WARN'
}

# ======================================================================================================
# PHASE 5 - ROLLBACK
# ======================================================================================================

function Invoke-Phase5 {
    Write-Log 'PHASE 5 - Rollback (modifies Azure resources)' 'STEP'
    $st = $script:State
    if (-not $st.phase3Started) { Write-Log 'Nothing to roll back: phase 3 never started.' 'WARN'; return }
    $c = $script:Config
    $rg = $c.resourceGroup
    $newName = Get-TargetName $c.vmName -MaxLength 64

    Write-Host ''
    Write-Host "  The replacement VM $newName and its NICs will be DELETED."
    Write-Host "  Source $($c.vmName) gets its original IP(s) back and is started."
    Write-Host '  New disks and snapshots are kept unless you choose otherwise below.'
    if (-not (Confirm-Action 'Roll back now?')) { return }
    $reason = Read-Required 'Failure reason (recorded in the log; understand it before retrying)'
    Write-Log "Rollback requested. Reason: $reason" 'WARN'

    Invoke-Step 'rb.stop-new' {
        if ((Get-VmPowerState -Rg $rg -Name $newName) -notin 'deallocated', 'notfound') {
            Stop-AzVM -ResourceGroupName $rg -Name $newName -Force | Out-Null
        }
        if ((Get-VmPowerState -Rg $rg -Name $newName) -ne 'notfound') { Wait-VmPowerState -Rg $rg -Name $newName -State 'deallocated' }
    }

    Invoke-Step 'rb.delete-new-vm' {
        if ((Get-VmPowerState -Rg $rg -Name $newName) -ne 'notfound') { Remove-AzVM -ResourceGroupName $rg -Name $newName -Force | Out-Null }
    }

    foreach ($n in $c.nics) {
        Invoke-Step "rb.delete-new-nic.$($n.name)" {
            $nn = Get-TargetName $n.name
            if (Test-ResourceExists { Get-AzNetworkInterface -ResourceGroupName $n.resourceGroup -Name $nn -ErrorAction Stop }) {
                Remove-AzNetworkInterface -ResourceGroupName $n.resourceGroup -Name $nn -Force | Out-Null
            }
        }
    }

    foreach ($n in $c.nics) {
        Invoke-Step "rb.restore-source-nic.$($n.name)" { Set-SourceNicState -Mode restore -NicRecord $n }
    }
    Write-Log 'Source NIC(s) hold the original address(es).' 'OK'

    Invoke-Step 'rb.start-source' {
        if ((Get-VmPowerState -Rg $rg -Name $newName) -notin 'deallocated', 'notfound') { throw 'GOLDEN RULE: the replacement VM is still not deallocated.' }
        Start-AzVM -ResourceGroupName $rg -Name $c.vmName | Out-Null
        Wait-VmPowerState -Rg $rg -Name $c.vmName -State 'running'
    }

    if (Confirm-Action 'Also delete the new disks and snapshots created by phase 3 (needed to retry the migration with the same names)?') {
        Invoke-Step 'rb.delete-new-storage' -NonFatal {
            foreach ($d in @($c.osDisk) + @($c.dataDisks)) {
                $dn = Get-TargetName $d.name; $sn = Get-TargetName $d.name -Middle '-snap'
                if (Test-ResourceExists { Get-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $dn -ErrorAction Stop }) { Remove-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $dn -Force | Out-Null }
                if (Test-ResourceExists { Get-AzSnapshot -ResourceGroupName $d.resourceGroup -SnapshotName $sn -ErrorAction Stop }) { Remove-AzSnapshot -ResourceGroupName $d.resourceGroup -SnapshotName $sn -Force | Out-Null }
            }
        }
    }

    Write-Host ''
    Write-Host 'MANUAL ROLLBACK CHECKLIST:' -ForegroundColor Cyan
    @(
        'Confirm from inside the guest that the interface received the original address and DNS servers are correct'
        'Revert DNS records changed at cutover'
        'Revert firewall rules, allow-lists, application configuration, monitoring and backup targets changed at cutover'
        'Undo anything already done by hand on the new VM (identity grants, load balancer pools, backup) if the new VM was touched'
        'Confirm with the application owner that service is restored'
    ) | ForEach-Object { Write-Host "  [ ] $_" }

    # reset phase 3 so the migration can be retried from a clean state
    $st.history += @{ event = 'rollback'; at = (Get-Date).ToString('o'); by = $env:USERNAME; reason = $reason }
    foreach ($k in @($st.steps.Keys | Where-Object { $_ -like 'p3.*' -or $_ -like 'rb.*' })) { $st.steps.Remove($k) }
    $st.created = @{ snapshots = @(); disks = @(); nics = @(); vm = $null }
    $st.phase3Started = $false
    $st.warnings = @()
    foreach ($k in '3', '4') { $st.phases.Remove($k) }
    Save-State
    Write-Log 'Rollback complete. Phases 3 and 4 were reset; the failure reason is in state.json history.' 'OK'
}

# ======================================================================================================
# MENU
# ======================================================================================================

function Show-Status {
    $st = $script:State
    $rg = $script:ResourceGroupName
    Write-Host ''
    Write-Host "VM $($script:VmName) | RG $rg | subscription $($script:SubscriptionId)" -ForegroundColor Cyan
    foreach ($row in @(
            @{ n = 1; t = 'Capture' }, @{ n = 2; t = 'Network prep' }, @{ n = 3; t = 'Execute' },
            @{ n = 4; t = 'Validate' })) {
        $s = Get-PhaseStatus $row.n
        Write-Host ('  Phase {0} {1,-13}: {2}' -f $row.n, $row.t, $(if ($s) { $s } else { '-' }))
    }
    if ($st.history.Count) { Write-Host "  Rollbacks so far  : $($st.history.Count)" }
    try {
        $src = Get-VmPowerState -Rg $rg -Name $script:VmName
        $new = Get-VmPowerState -Rg $rg -Name (Get-TargetName $script:VmName -MaxLength 64)
        Write-Host "  Source VM         : $src"
        Write-Host "  Replacement VM    : $new"
    }
    catch { Write-Host "  (power state unavailable: $($_.Exception.Message))" }
    Write-Host ''
}

function Start-Migration {
    Write-Host ''
    Write-Host 'Azure VM size migration via snapshot - control-plane only, one VM at a time' -ForegroundColor Cyan
    Test-Prerequisites
    Connect-Target
    if (-not $script:ResourceGroupName) { $script:ResourceGroupName = Read-Required 'Resource group of the VM' }
    if (-not $script:VmName) { $script:VmName = Read-Required 'VM name' }
    $null = Get-AzVM -ResourceGroupName $script:ResourceGroupName -Name $script:VmName
    Initialize-Workspace

    $actions = [ordered]@{
        '1' = @{ Label = 'Capture source configuration'; Run = { Invoke-Phase1 } }
        '2' = @{ Label = 'Network preparation';          Run = { Invoke-Phase2 } }
        '3' = @{ Label = 'Execute migration';            Run = { Invoke-Phase3 } }
        '4' = @{ Label = 'Validate';                     Run = { Invoke-Phase4 } }
        '5' = @{ Label = 'Rollback';                     Run = { Invoke-Phase5 } }
    }
    while ($true) {
        Show-Status
        foreach ($k in $actions.Keys) { Write-Host "  [$k] $($actions[$k].Label)" }
        Write-Host '  [Q] Quit'
        $choice = (Read-Host 'Choose').Trim().ToUpper()
        if ($choice -eq 'Q') { break }
        if (-not $actions.Contains($choice)) { continue }
        try { & $actions[$choice].Run }
        catch {
            Write-Log "Phase $choice stopped: $($_.Exception.Message)" 'ERROR'
            Add-Content -Path $script:Paths.Log -Value $_.ScriptStackTrace
            Write-Log 'State is saved. Fix the cause and re-run the phase to resume, or roll back (phase 5).' 'WARN'
        }
    }
    Write-Log 'Bye.'
}

# Dot-sourcing (". .\Invoke-VmSkuMigration.ps1") loads the functions without starting the menu.
if ($MyInvocation.InvocationName -ne '.') { Start-Migration }
