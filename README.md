# Azure VM size migration via snapshot

`Invoke-VmSkuMigration.ps1` automates the Azure control-plane steps of the *SKU conversion and migration plan*
playbook (Bv1 -> Bsv2, Fsv2 -> Dlsv6, or any mapping you set). One VM per run, everything asked at prompts,
no tenant/subscription/customer values in the code.

**Scope: plain VM recreation.** Anything beyond that is detected, listed and acknowledged before the migration
starts, then done by hand. **Nothing of the old VM is ever deleted**: it stays in place, deallocated.

The script never touches the guest OS. Temp-disk remediation and every in-guest check stay with the team
(phase 2 asks for an explicit confirmation, phase 4 prints the manual checklist).

## Requirements

- PowerShell 7+
- `Az.Accounts`, `Az.Compute`, `Az.Network`, `Az.Resources`
- Optional: `Az.RecoveryServices` (only to detect whether the VM is backed up)
- Contributor on the VM / network / disk resource groups

## Usage

```powershell
.\Invoke-VmSkuMigration.ps1
# optional, skips the matching prompts:
.\Invoke-VmSkuMigration.ps1 -TenantId <id> -SubscriptionId <id> -ResourceGroupName <rg> -VmName <vm>
```

The size mapping and the extension skip lists are at the top of the script.

## What the script recreates

VM (target size, zone, security type, Hyper-V generation, license type / Hybrid Benefit, tags, marketplace plan),
OS and data disks (same SKU, size, zone, LUN, caching), NIC(s) with the original private IP as static, NSG,
application security groups, accelerated networking, custom DNS servers, the original public IP, and the VM
extensions that do not need protected settings.

## What it only reports (to be done by hand)

Managed identities (system and user-assigned, with their role assignments and Key Vault policies), load balancer /
application gateway pools and NAT rules, availability set and proximity placement group, Azure Backup, resource
locks, data collection rule associations, capacity reservation, extensions with protected settings.
Phase 1 lists them, phase 2 requires typing `ACKNOWLEDGE`, phase 3 and 4 repeat the list.

## Phases

| # | Phase | Changes Azure? | What it does |
|---|-------|----------------|--------------|
| 1 | Capture | no | Writes `config.json` and lists the items above. Blocks unsupported cases: size not available in region/zone, target without Gen1 support, vCPU quota, ADE, ephemeral/shared/Ultra/PremiumV2 disks, scale-set member, IPv6. |
| 2 | Network prep | no | Checks the `-mig` names are free, chooses and verifies one placeholder IP per IP configuration, collects the acknowledgements. |
| 3 | Execute | yes | Deallocates the source, takes full snapshots, creates new disks, parks the source NIC on the placeholder IP, creates the new NIC and VM, restores extensions. |
| 4 | Validate | no | Compares the new VM with `config.json`, writes `validation-report.csv`, saves the boot-diagnostics screenshot, prints the manual checklist. |
| 5 | Rollback | yes | Deletes the **new** VM and NICs, restores the original IP and public IP on the source NIC, starts the source. Resets phases 3 and 4 so the migration can be retried. |

Naming: VM, NICs and disks get the suffix `-mig`; snapshots are `<disk>-snap-mig`.
Per-VM files live in `.\migration\<vmName>\` (`config.json`, `state.json`, `migration.log`, `validation-report.csv`).
Phase 3 checkpoints every step: re-run it to resume after a failure.

## After a successful validation (manual)

After the owner's formal sign-off: remove the old VM, NIC, disks and snapshots (default retention 14 days), and
enable backup on the new VM once the old backup item is dealt with.

## Safety rules enforced by the script

- Source and replacement VM are never both allowed to run (checked before creating the replacement and before starting the source).
- The script only deletes resources it created itself, and only in rollback.
- Phase 3 does not start without `config.json`, the placeholder IPs and the acknowledgements from phase 2.

## Known limits

- Extensions with protected settings (custom script, domain join, MMA/OMS, DSC) cannot be read back: they are reported.
- The replacement VM uses managed boot diagnostics.
- Rollback deletes the new VM/NICs; it does not offer a "park the new NIC on a placeholder" variant.

## Test environment (one subscription)

`testenv/New-MigrationTestEnvironment.ps1` deploys a disposable environment through prompts (tenant, subscription,
VM admin credentials), in one subscription and two resource groups:

- `rg-migtest-net`: a VNet (`10.250.0.0/16`) with one subnet (`10.250.1.0/24`)
- `rg-migtest-vm`: a Bv1 VM (default `Standard_B2ms`) whose NIC uses the subnet of the network resource group
  (static private IP, NSG), one data disk and one extension

```powershell
pwsh .\testenv\New-MigrationTestEnvironment.ps1                  # Windows Server 2022 Gen2, B2ms
pwsh .\testenv\New-MigrationTestEnvironment.ps1 -WithPublicIp -WithSystemIdentity -Zone 1
pwsh .\testenv\New-MigrationTestEnvironment.ps1 -OsType Linux
pwsh .\testenv\New-MigrationTestEnvironment.ps1 -Generation 1    # negative test: phase 1 must block it
pwsh .\testenv\New-MigrationTestEnvironment.ps1 -VmSize Standard_F4s_v2   # Fsv2 -> Dlsv6 path
pwsh .\testenv\New-MigrationTestEnvironment.ps1 -Destroy         # removes both resource groups
```

The script prints the exact command to run the migration against it and saves the deployment in `testenv.json`.
It can be re-run after a partial failure: tagged resource groups and an existing VNet / NSG are reused.
Both resource groups are tagged `purpose=migration-test`; `-Destroy` only deletes groups carrying that tag.
Run `-Destroy` when finished: a running B2ms VM costs a few cents per hour.

Note: a NIC cannot use a subnet that lives in another subscription (Azure answers `InvalidResourceReference`), so
the whole environment is in one subscription. The migration script still switches subscription context by itself
when a NSG, public IP or VNet it needs lives elsewhere.

## Tests

`tests/Invoke-VmSkuMigration.MockTest.ps1` runs phases 1-5 (including a rollback and a second migration) against an
in-memory fake of the Az cmdlets. It checks the script's logic, ordering and checkpointing, **not** the real
Azure parameter surface: run the first migrations in a test subscription.

```powershell
pwsh -File .\tests\Invoke-VmSkuMigration.MockTest.ps1
```
