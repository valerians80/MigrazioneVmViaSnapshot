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
# optional, skips the matching questions:
.\Invoke-VmSkuMigration.ps1 -TenantId <id> -SubscriptionId <id> -VmName <vm>
```

The size mapping and the extension skip lists are at the top of the script.

## The guided flow

1. The screen is cleared and the script explains what it does and what it does not.
2. `Connect-AzAccount`, the subscription where the VM lives (from a list), the VM name (the resource group is found for you).
3. The manual checks to be done inside the guest are listed; you confirm Y/N that they are all done.
4. The VM is read and a two-column screen is shown, redrawn after every step: **CURRENT VM** (green, left) and
   **NEW VM** (red, right), with resource group, name, size, security type, public IP, NICs with IPs, OS disk,
   data disks with LUN, extensions, and the power state of both machines.
5. You choose the new size from the playbook list. Each size is checked against the subscription (region, zone,
   quota, Hyper-V generation, no reduction of vCPU/memory).
6. For every IP configuration the first free address of its subnet is taken as placeholder for the old NIC;
   the new NIC takes over the original address. If no address is free, the script stops.
7. The plan is shown (old VM with the placeholder IPs, new VM with everything that will be applied) together
   with what the script does **not** handle. You type `ACKNOWLEDGE`, then confirm Y/N to deploy.
8. Deployment, with a progress list: shut down the old VM, snapshots, new disks, old NIC moved to the placeholder,
   new NIC with the original IP, new VM, extensions.
9. Automatic checks compare the new VM with the recorded configuration (`validation-report.csv`), then the
   tests to do are listed with a reminder to **keep the old VM switched off**.

If the VM already has a migration, running the script again offers: resume the deployment (checkpoint per step),
run the automatic checks again, or **roll back** (delete the new VM and NICs, give the original IP and public IP
back to the old NIC, start the old VM).

Naming: VM, NICs and disks get the suffix `-mig`; snapshots are `<disk>-snap-os-mig` (OS disk) and
`<disk>-snap-lun<N>-mig` (data disks), so the LUN is visible in the name for any manual intervention.
Per-VM files live in `.\migration\<vmName>\` (`config.json`, `state.json`, `migration.log`, `validation-report.csv`):
run the script from the same folder to find them again.

## What the script recreates

VM (target size, zone, security type, Hyper-V generation, license type / Hybrid Benefit, tags, marketplace plan),
OS and data disks (same SKU, size, zone, LUN, caching), NIC(s) with the original private IP as static, NSG,
application security groups, accelerated networking, custom DNS servers, the original public IP, and the VM
extensions that do not need protected settings.

## What it only reports (to be done by hand)

Managed identities (system and user-assigned, with their role assignments and Key Vault policies), load balancer /
application gateway pools and NAT rules, availability set and proximity placement group, Azure Backup, resource
locks, data collection rule associations, capacity reservation, extensions with protected settings.
They are listed before the start and you must type `ACKNOWLEDGE`.

The VM is not migrated at all (the script stops and says why) when: no target size is usable in the subscription,
the VM has Azure Disk Encryption, an ephemeral / shared / Ultra / PremiumV2 disk, is a scale-set member, has an
IPv6 configuration or no free placeholder IP exists.

## After a successful migration (manual)

After the owner's formal sign-off: remove the old VM, NIC, disks and snapshots (default retention 14 days), and
enable backup on the new VM once the old backup item is dealt with.

## Safety rules enforced by the script

- Source and replacement VM are never both allowed to run (checked before creating the replacement and before starting the source).
- The script only deletes resources it created itself, and only in rollback.
- The deployment does not start without the manual-checks confirmation, the acknowledgement and the final Y/N.

## Known limits

- Extensions with protected settings (custom script, domain join, MMA/OMS, DSC) cannot be read back: they are reported.
- The replacement VM uses managed boot diagnostics.
- The security type of the new OS disk is inherited from the snapshot (it cannot be set when copying); the script warns if it differs.
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
pwsh .\testenv\New-MigrationTestEnvironment.ps1 -Generation 1    # negative test: the migration must refuse sizes without Gen1 support
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

`tests/Invoke-VmSkuMigration.MockTest.ps1` runs the whole guided flow (a failure and resume, repeated checks, rollback, a second migration) against an
in-memory fake of the Az cmdlets. It checks the script's logic, ordering and checkpointing, **not** the real
Azure parameter surface: run the first migrations in a test subscription.

```powershell
pwsh -File .\tests\Invoke-VmSkuMigration.MockTest.ps1
```
