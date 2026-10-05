# Azure VM size migration via snapshot

`Invoke-VmSkuMigration.ps1` automates the Azure control-plane steps of the *SKU conversion and migration plan*
playbook (Bv1 -> Bsv2, Fsv2 -> Dlsv6, or any mapping you set). One VM per run, everything asked at prompts,
no tenant/subscription/customer values in the code.

The script **never touches the guest OS**. Temp-disk remediation and every in-guest check stay with the team
(phase 2 asks for an explicit confirmation, phase 4 prints the manual checklist).

## Requirements

- PowerShell 7+
- `Az.Accounts`, `Az.Compute`, `Az.Network`, `Az.Resources`
- Optional: `Az.RecoveryServices` (backup), `Az.KeyVault` (access policies of the system identity)
- Contributor on the VM / network / disk resource groups, and User Access Administrator (or Owner) on the scopes
  where the VM's system identity holds role assignments

## Usage

```powershell
.\Invoke-VmSkuMigration.ps1
# optional, skips the matching prompts:
.\Invoke-VmSkuMigration.ps1 -TenantId <id> -SubscriptionId <id> -ResourceGroupName <rg> -VmName <vm>
```

The size mapping, retention default and extension skip lists are at the top of the script.

## Phases

| # | Phase | Changes Azure? | What it does |
|---|-------|----------------|--------------|
| 1 | Capture | no | Writes `config.json`: compute, disks/LUNs, NICs/IPs, LB/AppGW pools, extensions, identity + role assignments + Key Vault policies, DCR associations, locks, backup, AHB, tags. Blocks unsupported cases (Gen1 -> Gen2-only target, size not available in region/zone, quota, ADE, ephemeral/shared/Ultra disks, scale-set member, IPv6). |
| 2 | Network prep | no | Checks the `-mig` names are free, chooses and verifies one placeholder IP per IP configuration, records the guest pre-check confirmation. |
| 3 | Execute | yes | Optional on-demand backup, deallocate, full snapshots, new disks (same SKU/size/zone), park the source NIC on the placeholder, new NIC with the original IP, new VM, then restore extensions, DCR associations, role assignments, Key Vault policies, locks and backup. |
| 4 | Validate | no | Compares the new VM with `config.json`, writes `validation-report.csv`, saves the boot-diagnostics screenshot, prints the manual checklist. |
| 5 | Rollback | yes | Deletes the new VM and NICs, restores the original IP/public IP/pools on the source NIC, starts the source. Resets phases 3 and 4 so the migration can be retried. |
| 6 | Decommission | yes | Pass 1 (after sign-off): lock source disks and snapshots, delete source VM and NIC. Pass 2 (after retention): delete source disks, then snapshots. |

Naming: VM, NICs and disks get the suffix `-mig`; snapshots are `<disk>-snap-mig`.
Per-VM files live in `.\migration\<vmName>\` (`config.json`, `state.json`, `migration.log`, `validation-report.csv`).
Phases 3 and 6 checkpoint every step: re-run the phase to resume after a failure.

## Safety rules enforced by the script

- Source and replacement VM are never both allowed to run (checked before creating the replacement and before starting the source).
- Nothing is deleted before phase 6, which requires phase 4 = PASS and the VM name typed as sign-off.
- Source disks/NICs are switched to *detach on VM delete* before the source VM is removed.
- Phase 3 does not start without `config.json` and the phase 2 confirmation.

## Known limits

- Extensions with protected settings (custom script, domain join, MMA/OMS, DSC) cannot be read back: they are reported for manual re-application.
- The replacement VM uses managed boot diagnostics.
- Capacity reservation membership and Azure Disk Encryption are not handled (ADE VMs are blocked).
- Rollback deletes the new VM/NICs; it does not offer a "park the new NIC on a placeholder" variant.

## Tests

`tests/Invoke-VmSkuMigration.MockTest.ps1` runs phases 1-6 (including rollback and a second migration) against an
in-memory fake of the Az cmdlets. It checks the script's logic, ordering and checkpointing, **not** the real
Azure parameter surface: run the first migrations in a test subscription.

```powershell
pwsh -File .\tests\Invoke-VmSkuMigration.MockTest.ps1
```
