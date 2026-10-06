#Requires -Version 7.0
<#
.SYNOPSIS
    Guided, tenant/subscription-agnostic rebuild of ONE Azure VM on a new size through snapshots.

.DESCRIPTION
    Automates the Azure control-plane steps of the "SKU conversion and migration plan" playbook
    (Bv1 -> Bsv2, Fsv2 -> Dlsv6, or any other mapping you configure below).

    The script is a single guided flow:
      1. clears the screen and explains what it does
      2. Connect-AzAccount, subscription (from a list), VM name
      3. reminds the manual checks (guest OS) and asks for a Y/N confirmation
      4. reads the VM and shows two columns: CURRENT VM (green, left) and NEW VM (red, right), redrawn after
         every step, with the power state of both machines
      5. asks for the new size (the playbook list, checked against the subscription: region, zone, quota)
      6. takes the first free IP of the subnet as placeholder for the old NIC(s); the new NIC(s) get the original IP
      7. shows the full plan and what is NOT handled, asks to acknowledge it, then Y/N to deploy
      8. deploys: shut down the old VM, snapshots, new disks, IP hand-over, new NIC/VM
      9. runs automatic checks and reminds the tests to do, keeping the old VM switched off

    Running the script again on a VM that already has a migration offers: resume, run the checks again, or roll back.

    SCOPE: plain VM recreation only. The replacement VM is created next to the source with the suffix "-mig"
    (VM, NICs, disks). Everything the script does NOT handle (VM extensions, backup, managed identity, load balancer /
    application gateway pools, availability set, locks, monitoring rule associations, ...) is detected, listed and
    must be acknowledged before the start; those items are done by hand. Backup and extensions are stated on the
    very first screen.

    NOTHING of the source is ever deleted. The source VM, its NIC and its disks stay in place, deallocated, and its
    NIC is parked on a placeholder IP. Rollback is a reversal. Removing the old VM, disks and snapshots, and
    enabling backup on the new VM, are manual steps after sign-off.

    The script does NOT touch the guest operating system.

    Everything is kept per VM in <WorkRoot>\<vmName>\ : config.json, state.json, migration.log, reports.
    The deployment writes a checkpoint after every step and can be resumed.

.PARAMETER TenantId
    Optional. Signs in to this tenant. Prompted by Connect-AzAccount when omitted.
.PARAMETER SubscriptionId
    Optional. Skips the subscription list.
.PARAMETER ResourceGroupName
    Optional. Skips the VM lookup (use together with -VmName).
.PARAMETER VmName
    Optional. Prompted when omitted.
.PARAMETER WorkRoot
    Folder holding one sub-folder per VM. Default: .\migration
.PARAMETER Suffix
    Suffix appended to the names of everything the script creates. Default: -mig
.PARAMETER RequireMfa
    Signs in at the very start with a fixed claims challenge (authentication context "p1"), so the MFA is done before
    any change. That value was taken from the error message of ONE tenant: it is not guaranteed to be valid in every
    tenant. In another tenant use -ClaimsChallenge with the value Azure prints there. Without either switch the script
    signs in normally and, if Azure refuses a change because MFA is missing, it signs in again by itself, with the
    claims Azure printed in that very error (valid for any tenant), and retries the step.
.PARAMETER ClaimsChallenge
    Same as -RequireMfa but with the value that Azure printed in its own error message (base64 string, or the raw JSON).

.NOTES
    Required modules : Az.Accounts, Az.Compute, Az.Network, Az.Resources
    Required rights  : Contributor on the VM / network / disk resource groups.
    Window width     : two columns need about 110 characters; narrower windows stack the two blocks.
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$VmName,
    [string]$WorkRoot = (Join-Path -Path (Get-Location).Path -ChildPath 'migration'),
    [string]$Suffix = '-mig',
    [switch]$RequireMfa,
    [string]$ClaimsChallenge
)

$ErrorActionPreference = 'Stop'

# Claims challenge used by -RequireMfa: {"access_token":{"acrs":{"essential":true,"values":["p1"]}}}
# It comes from the error message of one tenant; other tenants may ask for a different value (use -ClaimsChallenge there).
$script:MfaClaims = 'eyJhY2Nlc3NfdG9rZW4iOnsiYWNycyI6eyJlc3NlbnRpYWwiOnRydWUsInZhbHVlcyI6WyJwMSJdfX19'

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

# ======================================================================================================
# SCRIPT STATE
# ======================================================================================================

$script:Paths    = $null
$script:State    = $null
$script:Config   = $null
$script:SkuCache = @{}
$script:Suffix   = $Suffix
$script:Checks   = $null

# screen / UI state
$script:UiActive      = $false   # when $true, Write-Log only writes to the log file (the wizard draws the screen)
$script:ClearScreen   = $true
$script:Notices       = [System.Collections.Generic.List[string]]::new()
$script:PowerCache    = $null
$script:CurrentStep   = $null
$script:OnStepChanged = $null
$script:LastBlockers  = @()

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
    if ($script:Paths -and $script:Paths.Log) { Add-Content -Path $script:Paths.Log -Value $line }
    if ($Level -in 'WARN', 'ERROR') {
        $script:Notices.Add($Message)
        while ($script:Notices.Count -gt 5) { $script:Notices.RemoveAt(0) }
    }
    if (-not $script:UiActive) { Write-Host $line -ForegroundColor $color }
}

function Write-Busy {
    # Always visible one-line progress message for long operations (also logged).
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  ... $Message" -ForegroundColor DarkGray
    if ($script:Paths -and $script:Paths.Log) { Add-Content -Path $script:Paths.Log -Value ('{0} [INFO] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) }
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

function ConvertTo-ClaimsValue {
    # Accepts the base64 string printed by Azure or the raw JSON, returns the base64 form.
    param([string]$Value)
    if ($Value -and $Value.TrimStart().StartsWith('{')) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)) }
    return $Value
}

function Get-ClaimsChallengeFromMessage {
    # Azure's MFA refusal contains: Connect-AzAccount -Tenant ... -ClaimsChallenge "<base64>"
    param([string]$Message)
    $m = [regex]::Match($Message, 'ClaimsChallenge\s+"?([A-Za-z0-9+/=_-]{20,})"?')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Request-StepUpSignIn {
    param([Parameter(Mandatory)][string]$Claims)
    Write-Host ''
    Write-Host 'Azure asks for a stronger sign-in (MFA) before it accepts changes. A browser window opens: complete the sign-in.' -ForegroundColor Yellow
    Write-Log 'Azure requested a claims challenge (MFA): signing in again' 'WARN'
    $ctx = Get-AzContext
    Connect-AzAccount -Tenant $ctx.Tenant.Id -ClaimsChallenge $Claims | Out-Null
    Set-AzContext -SubscriptionId $script:SubscriptionId -Tenant $script:TenantId | Out-Null
}

function Invoke-Step {
    # Runs one checkpointed step. A step that already completed is skipped, so a phase can be re-run to resume.
    # If Azure refuses a change because the MFA is missing, the script signs in again with the requested claims and retries once.
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
    $script:CurrentStep = $Name
    if ($script:OnStepChanged) { & $script:OnStepChanged $Name $false }
    try {
        try { & $Action }
        catch {
            $claims = Get-ClaimsChallengeFromMessage $_.Exception.Message
            if (-not $claims) { throw }
            Request-StepUpSignIn -Claims $claims
            & $Action
        }
        $script:State.steps[$Name] = (Get-Date).ToString('o')
        Save-State
        $script:CurrentStep = $null
        if ($script:OnStepChanged) { & $script:OnStepChanged $Name $true }
    }
    catch {
        $script:CurrentStep = $null
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
}

function Connect-Target {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $reuse = $false
    $claims = $null
    if ($script:ClaimsChallenge) { $claims = ConvertTo-ClaimsValue $script:ClaimsChallenge }
    elseif ($script:RequireMfa) { $claims = $script:MfaClaims }
    if (-not $claims -and $ctx -and $ctx.Account -and (-not $script:TenantId -or $ctx.Tenant.Id -eq $script:TenantId)) {
        $reuse = Confirm-Action "Already signed in as '$($ctx.Account.Id)'. Use this session?" -DefaultYes
    }
    if (-not $reuse) {
        Write-Host 'Signing in with Connect-AzAccount ...' -ForegroundColor Cyan
        $signIn = @{}
        if ($script:TenantId) { $signIn.Tenant = $script:TenantId }
        elseif ($claims -and $ctx.Tenant.Id) { $signIn.Tenant = $ctx.Tenant.Id }
        if ($claims) { $signIn.ClaimsChallenge = $claims; Write-Host 'MFA requested at sign-in: complete it in the browser.' -ForegroundColor Yellow }
        Connect-AzAccount @signIn | Out-Null
    }

    Write-Busy 'Reading the subscriptions you can access...'
    $subs = @(Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' } | Sort-Object Name)
    if (-not $subs) { throw 'No enabled subscription visible with this account.' }

    $sub = $null
    if ($script:SubscriptionId) { $sub = $subs | Where-Object { $_.Id -eq $script:SubscriptionId } | Select-Object -First 1 }
    if (-not $sub) {
        Write-Host ''
        Write-Host 'Subscription where the VM lives:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $subs.Count; $i++) { Write-Host ('  [{0}] {1}  ({2})' -f ($i + 1), $subs[$i].Name, $subs[$i].Id) }
        while (-not $sub) {
            $pick = Read-Required 'Subscription number'
            if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $subs.Count) { $sub = $subs[[int]$pick - 1] }
        }
    }
    $ctx = Set-AzContext -SubscriptionId $sub.Id -Tenant $sub.TenantId
    $script:SubscriptionId = $sub.Id
    $script:TenantId = $sub.TenantId
    Write-Log "Context: $($ctx.Account.Id) | tenant $($sub.TenantId) | subscription $($sub.Name) ($($sub.Id))" 'OK'
}

function Select-Vm {
    if ($script:ResourceGroupName -and $script:VmName) { $null = Get-AzVM -ResourceGroupName $script:ResourceGroupName -Name $script:VmName; return }
    while ($true) {
        if (-not $script:VmName) { $script:VmName = Read-Required 'Name of the VM to migrate' }
        Write-Busy 'Looking for the VM in the subscription...'
        $found = @(Get-AzVM | Where-Object { $_.Name -ieq $script:VmName -and (-not $script:ResourceGroupName -or $_.ResourceGroupName -ieq $script:ResourceGroupName) })
        if ($found.Count -eq 1) { $script:ResourceGroupName = $found[0].ResourceGroupName; $script:VmName = $found[0].Name; return }
        if ($found.Count -eq 0) { Write-Host "VM '$($script:VmName)' not found in this subscription." -ForegroundColor Yellow; $script:VmName = $null; continue }
        Write-Host "More than one VM is called '$($script:VmName)':" -ForegroundColor Yellow
        for ($i = 0; $i -lt $found.Count; $i++) { Write-Host ('  [{0}] resource group {1} ({2})' -f ($i + 1), $found[$i].ResourceGroupName, $found[$i].Location) }
        while ($true) {
            $pick = Read-Required 'Number'
            if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $found.Count) { $script:ResourceGroupName = $found[[int]$pick - 1].ResourceGroupName; return }
        }
    }
}

function Get-VmSkuInfo {
    param([Parameter(Mandatory)][string]$Location, [Parameter(Mandatory)][string]$SkuName)
    if (-not $script:SkuCache.ContainsKey($Location)) {
        Write-Busy "Loading the compute SKU catalogue for '$Location' (can take a minute)..."
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

function Invoke-Capture {
    # Read-only. Writes config.json. Returns $true when the VM can be migrated, $false when there are blockers.
    Write-Log 'Capture the source configuration (read-only)' 'STEP'
    if ($script:State.phase3Started) { throw 'The migration already started: the configuration record is frozen.' }

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

    # ---- source size (the target is chosen later) ----
    $sourceInfo = Get-VmSkuInfo -Location $location -SkuName $sourceSku
    if (-not $sourceInfo) { $blockers += "Source size $sourceSku not found in the SKU catalogue of $location." }
    $targetSku = ''
    $fit = ''

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
    # Extensions are never installed by the script: they are only recorded, so the operator knows what to reinstall by hand.
    foreach ($e in @(Get-AzVMExtension -ResourceGroupName $rg -VMName $vm.Name)) {
        if ($e.ExtensionType -like 'AzureDiskEncryption*') { $blockers += "Azure Disk Encryption extension '$($e.Name)' present: handle this VM separately." }
        $extRecords += [ordered]@{
            name      = $e.Name
            publisher = $e.Publisher
            type      = $e.ExtensionType
            version   = $e.TypeHandlerVersion
            state     = [string]$e.ProvisioningState
        }
    }
    if ($extRecords.Count) {
        $list = ($extRecords | ForEach-Object { "$($_.name) [$($_.type) $($_.version), $($_.state)]" }) -join '; '
        $complications += "VM extensions: NONE is installed on the new VM. Install them by hand (settings and keys included). On the old VM: $list"
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

    # Backup is never detected nor handled: it is always on the list, so it is shown from the very start.
    $complications += 'Azure Backup: the new VM is NOT enrolled in backup. Enable it by hand after validation, once the old VM and its backup item are dealt with.'

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
        complications             = $complications
        warnings                  = $warnings
    }
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $script:Paths.Config -Encoding utf8
    Import-Config

    $script:LastBlockers = @($blockers)
    foreach ($w in $warnings) { Write-Log $w 'WARN' }
    if ($blockers.Count) {
        foreach ($b in $blockers) { Write-Log "BLOCKER: $b" 'ERROR' }
        Set-PhaseResult 1 'blocked'
        return $false
    }
    Set-PhaseResult 1 'done'
    Write-Log "Capture complete. Record saved to $($script:Paths.Config)" 'OK'
    return $true
}

# ======================================================================================================
# PHASE 2 - NETWORK PREPARATION
# ======================================================================================================

function Get-SnapshotName {
    # The LUN is part of the name so that a manual intervention knows which snapshot belongs to which disk.
    param([Parameter(Mandatory)]$Disk, [Parameter(Mandatory)][bool]$IsOs)
    if ($IsOs) { return (Get-TargetName $Disk.name -Middle '-snap-os') }
    return (Get-TargetName $Disk.name -Middle "-snap-lun$($Disk.lun)")
}

function Get-SnapshotNameCandidates {
    # Current name plus the name used by earlier versions of the script (so rollback and the free-name check see both).
    param([Parameter(Mandatory)]$Disk, [Parameter(Mandatory)][bool]$IsOs)
    return @((Get-SnapshotName -Disk $Disk -IsOs $IsOs), (Get-TargetName $Disk.name -Middle '-snap')) | Select-Object -Unique
}

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
        $isOs = ($d.name -eq $c.osDisk.name)
        $dn = Get-TargetName $d.name
        if (Test-ResourceExists { Get-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $dn -ErrorAction Stop }) { $taken += "disk $dn" }
        foreach ($sn in (Get-SnapshotNameCandidates -Disk $d -IsOs $isOs)) {
            if (Test-ResourceExists { Get-AzSnapshot -ResourceGroupName $d.resourceGroup -SnapshotName $sn -ErrorAction Stop }) { $taken += "snapshot $sn" }
        }
    }
    return $taken
}

function Select-TargetSku {
    # Lists the target sizes of the playbook, checks them against the subscription and lets the operator choose.
    $c = $script:Config
    Write-Busy 'Checking the target sizes against the subscription (region, zone, quota)...'
    $sourceInfo = Get-VmSkuInfo -Location $c.location -SkuName $c.sourceSku
    $zone = if ($c.zones.Count) { [string]$c.zones[0] } else { '' }
    $suggested = $script:SkuMap[$c.sourceSku]
    $rows = @()
    $ordered = @($script:SkuMap.Values | Select-Object -Unique | Sort-Object { $_ -replace '^Standard_([A-Za-z]+)\d+.*$', '$1' }, { [int]($_ -replace '^Standard_[A-Za-z]+(\d+).*$', '$1') }, { $_ })
    foreach ($name in $ordered) {
        $info = Get-VmSkuInfo -Location $c.location -SkuName $name
        $problems = @(Test-TargetSku -Location $c.location -Zone $zone -Generation $c.hyperVGeneration -Source $sourceInfo -Target $info)
        $fit = if ($info -and $sourceInfo) { if ($info.VCpus -eq $sourceInfo.VCpus -and $info.MemoryGB -eq $sourceInfo.MemoryGB) { 'Exact' } elseif ($info.VCpus -ge $sourceInfo.VCpus -and $info.MemoryGB -ge $sourceInfo.MemoryGB) { 'Upsize' } else { 'Smaller' } } else { '-' }
        $rows += [pscustomobject]@{ Name = $name; Info = $info; Fit = $fit; Problems = $problems; Ok = ($problems.Count -eq 0) }
    }

    Show-Screen -Title 'CHOOSE THE NEW SIZE'
    Write-Host ''
    Write-Host "Current size: $($c.sourceSku)   ($($sourceInfo.VCpus) vCPU / $($sourceInfo.MemoryGB) GiB, Hyper-V $($c.hyperVGeneration), zone '$zone')" -ForegroundColor Cyan
    Write-Host 'Target sizes from the playbook:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $spec = if ($r.Info) { '{0,2} vCPU {1,5} GiB' -f $r.Info.VCpus, $r.Info.MemoryGB } else { '' }
        $mark = if ($r.Name -eq $suggested) { ' (proposed by the mapping)' } else { '' }
        if ($r.Ok) { Write-Host ('  [{0}] {1,-20} {2}  {3,-7} available{4}' -f ($i + 1), $r.Name, $spec, $r.Fit, $mark) -ForegroundColor Green }
        else { Write-Host ('  [{0}] {1,-20} {2}  {3,-7} NOT USABLE: {4}' -f ($i + 1), $r.Name, $spec, $r.Fit, $r.Problems[0]) -ForegroundColor DarkGray }
    }
    $usable = @($rows | Where-Object { $_.Ok })
    if (-not $usable) { throw 'None of the target sizes can be used for this VM in this subscription (see the list above).' }

    $default = $rows | Where-Object { $_.Name -eq $suggested -and $_.Ok } | Select-Object -First 1
    $chosen = $null
    while (-not $chosen) {
        $prompt = if ($default) { 'New size number (Enter = proposed)' } else { 'New size number' }
        $pick = (Read-Host $prompt).Trim()
        if ($pick -eq '' -and $default) { $chosen = $default }
        elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $rows.Count -and $rows[[int]$pick - 1].Ok) { $chosen = $rows[[int]$pick - 1] }
        else { Write-Host 'Choose one of the available sizes.' -ForegroundColor Yellow }
    }
    $c.targetSku = $chosen.Name
    $c.skuFit = $chosen.Fit
    $c | ConvertTo-Json -Depth 20 | Set-Content -Path $script:Paths.Config -Encoding utf8
    Write-Log "Target size chosen: $($chosen.Name) ($($chosen.Fit))" 'OK'
}

function Set-PlaceholderIps {
    # For every IP configuration of the old VM, takes the first free address of its subnet. The old NIC is parked
    # on it, so the new NIC can take over the original address. Stops when no address is free.
    $c = $script:Config
    Write-Busy 'Looking for free placeholder addresses in the subnet(s)...'
    $placeholders = @{}
    $used = @()
    foreach ($n in $c.nics) {
        foreach ($i in $n.ipConfigs) {
            $key = "$($n.name)|$($i.name)"
            $sn = Split-ResourceId $i.subnetId
            $subnetName = ($sn.Rest -split '/')[1]
            $prefixes = @(Invoke-InSubscription $sn.Subscription {
                    $vnet = Get-AzVirtualNetwork -ResourceGroupName $sn.ResourceGroup -Name $sn.Name
                    (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $subnetName).AddressPrefix
                })
            $probe = Invoke-InSubscription $sn.Subscription { Test-AzPrivateIPAddressAvailability -ResourceGroupName $sn.ResourceGroup -VirtualNetworkName $sn.Name -IPAddress $i.privateIp }
            $pick = $null
            foreach ($candidate in @($probe.AvailableIPAddresses)) {
                if ($candidate -in $used -or $candidate -eq $i.privateIp) { continue }
                if (-not ($prefixes | Where-Object { Test-IpInCidr -Ip $candidate -Cidr $_ })) { continue }
                $check = Invoke-InSubscription $sn.Subscription { Test-AzPrivateIPAddressAvailability -ResourceGroupName $sn.ResourceGroup -VirtualNetworkName $sn.Name -IPAddress $candidate }
                if ($check.Available) { $pick = $candidate; break }
            }
            if (-not $pick) { throw "No free IP address available in subnet '$subnetName' ($($prefixes -join ', ')) for $key. Free an address and run the script again." }
            $placeholders[$key] = $pick
            $used += $pick
        }
    }
    $script:State.placeholders = $placeholders
    Set-PhaseResult 2 'done'
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

function Invoke-Execute {
    # Modifies Azure resources. Checkpointed: running it again resumes from the last completed step.
    foreach ($n in 1, 2) { if ((Get-PhaseStatus $n) -ne 'done') { throw "Step $n (capture / placeholders) must be completed first." } }
    if (-not $script:Config.targetSku) { throw 'No target size chosen.' }
    $c = $script:Config
    $st = $script:State
    $rg = $c.resourceGroup
    $newVmName = Get-TargetName $c.vmName -MaxLength 64
    if (-not $st.created.ContainsKey('diskIds')) { $st.created.diskIds = @{} }
    if (-not $st.created.ContainsKey('nicIds')) { $st.created.nicIds = @{} }
    if (-not $st.created.ContainsKey('snapshotIds')) { $st.created.snapshotIds = @{} }
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
            $snapName = Get-SnapshotName -Disk $d -IsOs $isOs
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
            }
            # The security type (e.g. TrustedLaunch) cannot be set with CreateOption Copy: the disk inherits it from the snapshot.
            $new = New-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $diskName -Disk (New-AzDiskConfig @dp)
            if ($isOs -and ([string]$new.SecurityProfile.SecurityType) -ne $d.securityType) {
                Write-Log "New OS disk security type is '$($new.SecurityProfile.SecurityType)', source was '$($d.securityType)'. Check it before using the replacement VM." 'WARN'
            }
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

    # Extensions, backup, identity, load balancer pools... are NOT handled: they are listed for the operator.
    Set-PhaseResult 3 'done'
    Write-Log "Deployment complete. Replacement VM $newVmName is running; source VM $($c.vmName) stays deallocated." 'OK'
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

function Invoke-Validate {
    # Read-only. Compares the new VM with config.json. Returns the list of checks.
    Write-Log 'Validate (read-only)' 'STEP'
    if ((Get-PhaseStatus 3) -notin 'done', 'done-with-warnings') { throw 'The deployment must be completed first.' }
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

    # ---- not handled by the script: listed, never checked ----
    foreach ($x in $c.complications) { Add-Check 'Manual follow-up' $x 'done by hand' 'not checked by script' 'INFO' }

    # boot diagnostics screenshot, for a human to look at
    try {
        $bd = @{ ResourceGroupName = $rg; Name = $newName; LocalPath = $script:Paths.Dir }
        if ($c.osType -eq 'Windows') { $bd.Windows = $true } else { $bd.Linux = $true }
        Get-AzVMBootDiagnosticsData @bd | Out-Null
        Add-Check 'VM' 'Boot diagnostics screenshot saved for review' $script:Paths.Dir 'saved' 'INFO'
    }
    catch {
        $why = ($_.Exception.Message -replace '\s+', ' ').Trim()
        Add-Check 'VM' 'Boot diagnostics screenshot' 'look at it in the portal (VM > Boot diagnostics)' "not downloadable: $why" 'INFO'
    }

    # ---- report ----
    $script:Checks | Export-Csv -Path $script:Paths.Report -NoTypeInformation -Encoding utf8
    $fail = @($script:Checks | Where-Object { $_.Result -eq 'FAIL' }).Count
    Write-Log "Platform checks: $($script:Checks.Count) total, $fail FAIL. Report: $($script:Paths.Report)" $(if ($fail) { 'ERROR' } else { 'OK' })
    Set-PhaseResult 4 $(if ($fail) { 'FAIL' } else { 'PASS' })
    return $script:Checks
}

# ======================================================================================================
# PHASE 5 - ROLLBACK
# ======================================================================================================

function Invoke-Rollback {
    # Modifies Azure resources: deletes the NEW VM and NICs, restores the old NIC and starts the old VM.
    $script:UiActive = $false
    $script:OnStepChanged = $null
    Write-Log 'Rollback (modifies Azure resources)' 'STEP'
    $st = $script:State
    if (-not $st.phase3Started) { Write-Log 'Nothing to roll back: the deployment never started.' 'WARN'; return }
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

    if (Confirm-Action 'Also delete the new disks and snapshots created by the deployment (needed to retry the migration with the same names)?') {
        Invoke-Step 'rb.delete-new-storage' -NonFatal {
            foreach ($d in @($c.osDisk) + @($c.dataDisks)) {
                $dn = Get-TargetName $d.name
                $isOs = ($d.name -eq $c.osDisk.name)
                if (Test-ResourceExists { Get-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $dn -ErrorAction Stop }) { Remove-AzDisk -ResourceGroupName $d.resourceGroup -DiskName $dn -Force | Out-Null }
                foreach ($sn in (Get-SnapshotNameCandidates -Disk $d -IsOs $isOs)) {
                    if (Test-ResourceExists { Get-AzSnapshot -ResourceGroupName $d.resourceGroup -SnapshotName $sn -ErrorAction Stop }) { Remove-AzSnapshot -ResourceGroupName $d.resourceGroup -SnapshotName $sn -Force | Out-Null }
                }
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
    Write-Log 'Rollback complete. The deployment state was reset; the failure reason is in state.json (history). Run the script again to start a new migration.' 'OK'
}

# ======================================================================================================
# SCREEN: current VM (green, left) and new VM (red, right)
# ======================================================================================================

function Clear-Screen { if ($script:ClearScreen) { Clear-Host } }

function Get-ScreenWidth {
    $w = 0
    try { $w = [int]$Host.UI.RawUI.WindowSize.Width } catch { $w = 0 }
    if ($w -lt 40) { $w = 120 }
    return $w
}

function Format-Cell {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) { return ($Text.Substring(0, [Math]::Max(0, $Width - 3)) + '...') }
    return $Text.PadRight($Width)
}

function Write-Columns {
    param([string[]]$Left, [string[]]$Right, [string]$LeftTitle, [string]$RightTitle)
    $width = Get-ScreenWidth
    if ($width -lt 110) {
        # narrow window: stack the two blocks
        Write-Host $LeftTitle -ForegroundColor Green
        foreach ($l in $Left) { Write-Host "  $l" -ForegroundColor Green }
        Write-Host ''
        Write-Host $RightTitle -ForegroundColor Red
        foreach ($r in $Right) { Write-Host "  $r" -ForegroundColor Red }
        return
    }
    $col = [int][Math]::Floor(($width - 4) / 2)
    Write-Host (Format-Cell $LeftTitle $col) -NoNewline -ForegroundColor Green
    Write-Host ' | ' -NoNewline -ForegroundColor DarkGray
    Write-Host (Format-Cell $RightTitle $col) -ForegroundColor Red
    Write-Host (('-' * $col) + '-+-' + ('-' * $col)) -ForegroundColor DarkGray
    $rows = [Math]::Max($Left.Count, $Right.Count)
    for ($i = 0; $i -lt $rows; $i++) {
        $l = if ($i -lt $Left.Count) { $Left[$i] } else { '' }
        $r = if ($i -lt $Right.Count) { $Right[$i] } else { '' }
        Write-Host (Format-Cell $l $col) -NoNewline -ForegroundColor Green
        Write-Host ' | ' -NoNewline -ForegroundColor DarkGray
        Write-Host (Format-Cell $r $col) -ForegroundColor Red
    }
}

function Update-PowerCache {
    $c = $script:Config
    $src = 'unknown'; $new = 'unknown'
    try { $src = Get-VmPowerState -Rg $c.resourceGroup -Name $c.vmName } catch { }
    try { $new = Get-VmPowerState -Rg $c.resourceGroup -Name (Get-TargetName $c.vmName -MaxLength 64) } catch { }
    $script:PowerCache = @{ src = $src; new = $new }
}

function Get-PowerLabel {
    param([string]$State, [bool]$IsNew)
    switch ($State) {
        'running' { return 'RUNNING' }
        'deallocated' { return 'DEALLOCATED (off)' }
        'notfound' { if ($IsNew) { return 'NOT CREATED YET' } else { return 'NOT FOUND' } }
        default { return $State.ToUpper() }
    }
}

function Get-CurrentVmLines {
    param([Parameter(Mandatory)]$C)
    $moved = [bool]($script:State.steps.Keys | Where-Object { $_ -like 'p3.park-source-nic.*' })
    $lines = @()
    $lines += "Resource group : $($C.resourceGroup)"
    $lines += "VM name        : $($C.vmName)"
    $lines += "Size           : $($C.sourceSku)"
    $lines += "Security type  : $(if ($C.securityType) { $C.securityType } else { 'Standard (none)' })"
    $pips = @($C.nics | ForEach-Object { $_.ipConfigs } | Where-Object { $_.publicIp } | ForEach-Object { "$($_.publicIp.address) ($($_.publicIp.name))" })
    $lines += "Public IP      : $(if ($pips) { ($pips -join ', ') + $(if ($moved) { ' - moved to new VM' } else { '' }) } else { 'none' })"
    $lines += "NICs           : $($C.nics.Count)"
    foreach ($n in $C.nics) {
        foreach ($i in $n.ipConfigs) {
            $ph = $script:State.placeholders["$($n.name)|$($i.name)"]
            $lines += "  $($n.name): $($i.privateIp) ($($i.allocation))"
            if ($ph) { $lines += "      -> placeholder $ph" }
        }
    }
    $lines += "OS disk        : $($C.osDisk.name)"
    if ($C.dataDisks.Count) {
        $lines += 'Data disks     :'
        foreach ($d in ($C.dataDisks | Sort-Object { [int]$_.lun })) { $lines += "  LUN $($d.lun)  $($d.name) ($($d.sizeGB) GB)" }
    }
    else { $lines += 'Data disks     : none' }
    if ($C.extensions.Count) {
        $lines += 'Extensions     :'
        foreach ($e in $C.extensions) { $lines += "  $($e.name) ($($e.state))" }
    }
    else { $lines += 'Extensions     : none' }
    return $lines
}

function Get-NewVmLines {
    param([Parameter(Mandatory)]$C)
    if (-not $C.targetSku) { return @('(new size not chosen yet)') }
    $lines = @()
    $lines += "Resource group : $($C.resourceGroup)"
    $lines += "VM name        : $(Get-TargetName $C.vmName -MaxLength 64)"
    $lines += "Size           : $($C.targetSku) ($($C.skuFit))"
    $lines += "Security type  : $(if ($C.securityType) { $C.securityType } else { 'Standard (none)' }) (same)"
    $pips = @($C.nics | ForEach-Object { $_.ipConfigs } | Where-Object { $_.publicIp } | ForEach-Object { "$($_.publicIp.address) ($($_.publicIp.name))" })
    $lines += "Public IP      : $(if ($pips) { $pips -join ', ' } else { 'none' })"
    $lines += "NICs           : $($C.nics.Count)"
    foreach ($n in $C.nics) {
        foreach ($i in $n.ipConfigs) { $lines += "  $(Get-TargetName $n.name): $($i.privateIp) (static, original IP)" }
    }
    $lines += "OS disk        : $(Get-TargetName $C.osDisk.name)"
    if ($C.dataDisks.Count) {
        $lines += 'Data disks     :'
        foreach ($d in ($C.dataDisks | Sort-Object { [int]$_.lun })) { $lines += "  LUN $($d.lun)  $(Get-TargetName $d.name) ($($d.sizeGB) GB)" }
    }
    else { $lines += 'Data disks     : none' }
    $lines += "Extensions     : $(if ($C.extensions.Count) { 'none - install by hand' } else { 'none' })"
    return $lines
}

function Get-ProgressItems {
    $c = $script:Config
    $items = @()
    $items += @{ key = 'p3.preflight'; label = 'Pre-flight checks' }
    $items += @{ key = 'p3.stop-source'; label = "Shut down and deallocate $($c.vmName)" }
    foreach ($d in @($c.osDisk) + @($c.dataDisks)) {
        $isOs = ($d.name -eq $c.osDisk.name)
        $tag = if ($isOs) { 'OS' } else { "LUN $($d.lun)" }
        $items += @{ key = "p3.snapshot.$($d.name)"; label = "Snapshot $(Get-SnapshotName -Disk $d -IsOs $isOs)" }
        $items += @{ key = "p3.disk.$($d.name)"; label = "Create disk $(Get-TargetName $d.name) ($tag)" }
    }
    foreach ($n in $c.nics) { $items += @{ key = "p3.park-source-nic.$($n.name)"; label = "Move old NIC $($n.name) to its placeholder IP, detach the public IP" } }
    foreach ($n in $c.nics) {
        $ips = @($n.ipConfigs | ForEach-Object { $_.privateIp }) -join ', '
        $pubs = @($n.ipConfigs | Where-Object { $_.publicIp } | ForEach-Object { $_.publicIp.address }) -join ', '
        $label = "Create NIC $(Get-TargetName $n.name) with the original IP $ips"
        if ($pubs) { $label += " and attach the public IP $pubs" }
        $items += @{ key = "p3.new-nic.$($n.name)"; label = $label }
    }
    $items += @{ key = 'p3.new-vm'; label = "Create VM $(Get-TargetName $c.vmName -MaxLength 64)" }
    return $items
}

function Show-Progress {
    Write-Host ''
    Write-Host 'Progress' -ForegroundColor Cyan
    foreach ($it in (Get-ProgressItems)) {
        if ($script:State.steps.ContainsKey($it.key)) { Write-Host "  [x] $($it.label)" -ForegroundColor Green }
        elseif ($script:CurrentStep -eq $it.key) { Write-Host "  [>] $($it.label)" -ForegroundColor Yellow }
        else { Write-Host "  [ ] $($it.label)" -ForegroundColor DarkGray }
    }
}

function Show-Screen {
    param([string]$Title = 'AZURE VM SIZE MIGRATION', [switch]$RefreshPower, [switch]$Progress)
    Clear-Screen
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * ([Math]::Min((Get-ScreenWidth), 100) - 1)) -ForegroundColor DarkGray
    if ($script:Config) {
        if ($RefreshPower -or -not $script:PowerCache) { Update-PowerCache }
        Write-Columns -Left (Get-CurrentVmLines -C $script:Config) -Right (Get-NewVmLines -C $script:Config) `
            -LeftTitle "CURRENT VM - $(Get-PowerLabel $script:PowerCache.src $false)" -RightTitle "NEW VM - $(Get-PowerLabel $script:PowerCache.new $true)"
    }
    if ($Progress) { Show-Progress }
    if ($script:Notices.Count) {
        Write-Host ''
        $max = (Get-ScreenWidth) - 6
        foreach ($n in $script:Notices) {
            $one = ($n -replace '\s+', ' ').Trim()
            if ($one.Length -gt $max) { $one = $one.Substring(0, $max - 3) + '...' }
            Write-Host "  ! $one" -ForegroundColor Yellow
        }
    }
}

# ======================================================================================================
# GUIDED FLOW
# ======================================================================================================

function Show-Intro {
    Clear-Screen
    Write-Host 'AZURE VM SIZE MIGRATION VIA SNAPSHOT' -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'What this script does, for ONE VM:'
    Write-Host '  1. reads the configuration of the VM and lets you choose the new size'
    Write-Host '  2. shuts the VM down and takes a snapshot of every disk'
    Write-Host '  3. rebuilds it as <name>-mig on the new size, with the same IP address'
    Write-Host '  4. checks the result and leaves the ORIGINAL VM switched off and untouched'
    Write-Host ''
    Write-Host 'What it does not do:'
    Write-Host '  - it never looks inside the guest operating system (those checks are yours)'
    Write-Host '  - it never deletes the old VM, its NIC, disks or snapshots'
    Write-Host '  - it does not move identity, load balancer membership, availability set or locks:'
    Write-Host '    it lists them before the start and you do them by hand'
    Write-Host ''
    Write-Host 'BACKUP: the script never touches Azure Backup. The new VM is NOT enrolled: enable backup by hand after validation.' -ForegroundColor Yellow
    Write-Host 'EXTENSIONS: the script never installs VM extensions. The new VM has none: install them by hand (the old VM''s list is shown).' -ForegroundColor Yellow
    Write-Host ''
}

function Confirm-ManualChecks {
    Clear-Screen
    Write-Host 'MANUAL CHECKS - to be completed by the team BEFORE you go on' -ForegroundColor Yellow
    Write-Host ('=' * 60) -ForegroundColor DarkGray
    Write-Host ''
    @(
        'Temp-disk remediation done (page file / swap, SQL tempdb, services and tasks on the temporary drive,'
        '   /etc/fstab entries for /mnt) and the VM rebooted cleanly on its CURRENT size'
        'The guest network interface is on DHCP: no static IPv4 address configured inside the operating system'
        'Application owners informed, change window agreed'
        'DNS, firewall and allow-list dependencies listed, so they can be reverted in case of rollback'
        'Drive letters / mount points recorded (the script records disks and LUNs, not drive letters)'
        'Backup: the script does not touch it and the NEW VM will NOT be protected: enable it by hand after validation'
        'Extensions: the script does not install them: note the extensions of the VM (settings and keys included) to reinstall them on the new VM'
    ) | ForEach-Object { Write-Host "  [ ] $_" }
    Write-Host ''
    return (Confirm-Action 'Have ALL the checks above been completed?')
}

function Show-ManualTests {
    Write-Host ''
    Write-Host 'TESTS TO DO NOW (guest and application, owned by the team):' -ForegroundColor Cyan
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
}

function Show-Result {
    param($Checks)
    Show-Screen -Title 'MIGRATION COMPLETED' -RefreshPower
    $fail = @($Checks | Where-Object { $_.Result -eq 'FAIL' })
    $warn = @($Checks | Where-Object { $_.Result -eq 'WARN' })
    Write-Host ''
    Write-Host ("Automatic checks: {0} total, {1} passed, {2} FAILED, {3} warnings" -f $Checks.Count, @($Checks | Where-Object { $_.Result -eq 'PASS' }).Count, $fail.Count, $warn.Count) -ForegroundColor $(if ($fail.Count) { 'Red' } else { 'Green' })
    foreach ($f in @($fail) + @($warn)) { Write-Host ("  {0,-5} {1} / {2}: expected '{3}', found '{4}'" -f $f.Result, $f.Area, $f.Check, $f.Expected, $f.Actual) -ForegroundColor $(if ($f.Result -eq 'FAIL') { 'Red' } else { 'Yellow' }) }
    Write-Host "Full report: $($script:Paths.Report)" -ForegroundColor DarkGray
    $c = $script:Config
    if ($c.complications.Count) {
        Write-Host ''
        Write-Host 'STILL TO DO BY HAND on the new VM:' -ForegroundColor Yellow
        foreach ($x in $c.complications) { Write-Host "  - $x" -ForegroundColor Yellow }
    }
    Show-ManualTests
    Write-Host ''
    Write-Host "KEEP THE SOURCE VM '$($c.vmName)' SWITCHED OFF while you test '$(Get-TargetName $c.vmName -MaxLength 64)'." -ForegroundColor Yellow
    Write-Host 'Both machines share hostname, SID and AD computer account: starting both can break the AD trust.' -ForegroundColor Yellow
    Write-Host 'After the owner has signed off, the old VM, NIC, disks and snapshots are removed by hand.' -ForegroundColor Yellow
    Write-Host ''
}

function Show-ResumeMenu {
    # Returns 'resume', 'validate', 'rollback' or 'quit'.
    $done = (Get-PhaseStatus 3) -in 'done', 'done-with-warnings'
    Show-Screen -Title 'A MIGRATION OF THIS VM ALREADY EXISTS' -RefreshPower -Progress
    Write-Host ''
    if ($done) { Write-Host '  [V] Run the automatic checks again' } else { Write-Host '  [R] Resume the deployment from the last completed step' }
    Write-Host '  [B] Roll back (delete the new VM, give the original IP back to the old VM and start it)'
    Write-Host '  [Q] Quit'
    while ($true) {
        $a = (Read-Host 'Choose').Trim().ToUpper()
        if ($a -eq 'Q') { return 'quit' }
        if ($a -eq 'B') { return 'rollback' }
        if ($done -and $a -eq 'V') { return 'validate' }
        if (-not $done -and $a -eq 'R') { return 'resume' }
    }
}

function Invoke-Deployment {
    $script:OnStepChanged = {
        param($StepName, $After)
        Show-Screen -Title 'DEPLOYING - do not close this window' -Progress -RefreshPower:($After -and ($StepName -match 'stop-source|new-vm'))
    }
    try { Invoke-Execute }
    finally { $script:OnStepChanged = $null }
}

function Start-Migration {
    $script:UiActive = $true
    try {
        Show-Intro
        Test-Prerequisites
        Connect-Target
        Select-Vm
        Initialize-Workspace
        $action = 'new'
        if ($script:State.phase3Started) { $action = Show-ResumeMenu }

        switch ($action) {
            'quit' { return }
            'rollback' {
                Invoke-Rollback
                $script:UiActive = $true
                Write-Host ''
                Read-Host 'Press Enter to exit' | Out-Null
                return
            }
            'validate' {
                Write-Busy 'Running the automatic checks...'
                $checks = Invoke-Validate
                Show-Result -Checks $checks
                Read-Host 'Press Enter to exit' | Out-Null
                return
            }
            'new' {
                if (-not (Confirm-ManualChecks)) { Write-Host 'Stopped: complete the manual checks first.' -ForegroundColor Yellow; return }
                $script:State.attestations += @{ type = 'manual-checks-confirmed'; by = $env:USERNAME; at = (Get-Date).ToString('o') }
                Save-State

                Write-Busy 'Reading the VM configuration (disks, network, extensions)...'
                if (-not (Invoke-Capture)) {
                    Show-Screen -Title 'THIS VM CANNOT BE MIGRATED BY THE SCRIPT'
                    Write-Host ''
                    foreach ($b in $script:LastBlockers) { Write-Host "  BLOCKER: $b" -ForegroundColor Red }
                    Write-Host ''
                    return
                }
                Select-TargetSku
                Set-PlaceholderIps
                $taken = @(Test-TargetNamesFree)
                if ($taken.Count) {
                    Show-Screen -Title 'NAMES ALREADY IN USE'
                    foreach ($t in $taken) { Write-Host "  already exists: $t" -ForegroundColor Red }
                    Write-Host 'Remove or rename these resources (or roll back an earlier attempt), then run the script again.' -ForegroundColor Red
                    return
                }

                Show-Screen -Title 'DEPLOYMENT PLAN' -RefreshPower
                if ($script:Config.warnings.Count -or $script:Config.complications.Count) {
                    Write-Host ''
                    foreach ($w in $script:Config.warnings) { Write-Host "  note: $w" -ForegroundColor DarkYellow }
                }
                if ($script:Config.complications.Count) {
                    Write-Host ''
                    Write-Host 'NOT HANDLED BY THIS SCRIPT - the new VM is created without these, you do them by hand:' -ForegroundColor Yellow
                    foreach ($x in $script:Config.complications) { Write-Host "  - $x" -ForegroundColor Yellow }
                    Write-Host ''
                    if (-not (Confirm-Typed 'Acknowledge that these are handled by hand' 'ACKNOWLEDGE')) { Write-Host 'Not acknowledged: nothing was changed.' -ForegroundColor Yellow; return }
                    $script:State.attestations += @{ type = 'complications-acknowledged'; count = $script:Config.complications.Count; by = $env:USERNAME; at = (Get-Date).ToString('o') }
                    Save-State
                }
                Write-Host ''
                Write-Host "The old VM '$($script:Config.vmName)' will be shut down. Nothing of it is deleted." -ForegroundColor Cyan
                if (-not (Confirm-Action 'Proceed with the deployment?')) { Write-Host 'Cancelled: nothing was changed.' -ForegroundColor Yellow; return }
            }
        }

        Invoke-Deployment
        Write-Busy 'Running the automatic checks...'
        $checks = Invoke-Validate
        Show-Result -Checks $checks
        Read-Host 'Press Enter to exit' | Out-Null
    }
    catch {
        $script:UiActive = $false
        Write-Host ''
        Write-Host "STOPPED: $($_.Exception.Message)" -ForegroundColor Red
        if ($script:Paths) {
            Add-Content -Path $script:Paths.Log -Value $_.ScriptStackTrace
            if ($script:State -and $script:State.phase3Started) {
                Write-Host "The deployment had started. The state is saved in $($script:Paths.Dir). Fix the cause and run the script again on the same VM: you can resume or roll back." -ForegroundColor Yellow
            }
            else {
                Write-Host "Nothing was changed in Azure. Fix the cause and run the script again." -ForegroundColor Yellow
            }
        }
    }
    finally { $script:UiActive = $false; $script:OnStepChanged = $null }
}

# Dot-sourcing (". .\Invoke-VmSkuMigration.ps1") loads the functions without starting the guided flow.
if ($MyInvocation.InvocationName -ne '.') { Start-Migration }
