# Stato dei lavori: migrazione VM via snapshot (aggiornato al 05/10/2026)

## Obiettivo

Uno script PowerShell **agnostico da tenant e subscription** che automatizza i passaggi del playbook
*"Azure B-series / Fsv2 retirement: SKU conversion and migration plan"* (Bv1 → Bsv2, Fsv2 → Dlsv6),
ricreando la VM via snapshot. Una VM per esecuzione, richieste via prompt, codice e messaggi in inglese.

## Decisioni prese

| Tema | Decisione |
|---|---|
| Perimetro | Solo **ricreazione base** della VM, come da playbook |
| Livello di lavoro | Solo control plane Azure. Nessun accesso al guest: i controlli dentro la VM restano al team (checklist manuale) |
| Input | Prompt interattivi (tenant, subscription, resource group, VM). Un CSV di VM è un'evoluzione futura |
| Nomi | VM, NIC e dischi = nome originale + `-mig`; snapshot `<disco>-snap-mig` |
| Snapshot | Interi, non incrementali |
| Cancellazioni | **Lo script non cancella nulla della VM vecchia**: resta spenta (deallocata), con la NIC su un IP placeholder. Rimozione di VM/NIC/dischi/snapshot e riattivazione del backup sono manuali dopo il sign-off |
| Gestito dallo script | VM (size, zona, security type, generazione, AHB, tag, plan marketplace), dischi (SKU, size, zona, LUN, caching), NIC con IP originale statico, NSG, ASG, accelerated networking, DNS, IP pubblico, **estensioni** |
| Solo segnalato (a mano) | Managed identity (+ ruoli, Key Vault), pool Load Balancer / App Gateway / NAT, availability set / PPG, **backup**, lock, associazioni DCR, capacity reservation, estensioni con settings protetti. Phase 1 li elenca, Phase 2 richiede di digitare `ACKNOWLEDGE` |
| Bloccato in Phase 1 | Size non disponibile in region/zona, target senza supporto Gen1, quota vCPU, ADE, dischi effimeri/condivisi/Ultra/PremiumV2, scale set, IPv6 |

## Cosa è stato consegnato (branch `claude/dreamy-ramanujan-al2iqw`, nessuna PR aperta)

- `Invoke-VmSkuMigration.ps1`: menu con 5 fasi
  1. **Capture**: scrive `config.json`, elenca blocchi e "non gestito"
  2. **Network prep**: placeholder IP verificato nella subnet, nomi `-mig` liberi, conferme
  3. **Execute**: spegne la sorgente, snapshot, nuovi dischi, parcheggia la NIC sorgente, nuova NIC con IP originale, nuova VM, estensioni. Checkpoint per step (si riprende rilanciando)
  4. **Validate**: confronto con `config.json`, `validation-report.csv`, screenshot boot diagnostics, checklist manuale
  5. **Rollback**: cancella solo la VM nuova e le sue NIC, ripristina IP/IP pubblico sulla sorgente e la riavvia; azzera Fasi 3 e 4
- `testenv/New-MigrationTestEnvironment.ps1`: deploy (e `-Destroy`) dell'ambiente di test in una subscription, due resource group
- `tests/Invoke-VmSkuMigration.MockTest.ps1`: test con Azure simulato in memoria (fasi 1-5 + rollback + seconda migrazione)
- `README.md`: uso, perimetro, fasi, regole di sicurezza, limiti noti
- Schema grafico del flusso (artifact): https://claude.ai/artifact/CiMMxDiY3W3z79RrLGsYAR (privato; la Fase 6 mostrata lì è stata poi eliminata)

## Ambiente di test

- Subscription **Hyper-v-drsource** (tenant DemoVV-Cloud; gli ID non sono salvati nel repo, vedi la cronologia della chat o `Get-AzSubscription`)
- `rg-migtest-net`: VNet `vnet-migtest` (10.250.0.0/16), subnet `snet-workload` (10.250.1.0/24)
- `rg-migtest-vm`: VM `vmmigtest01` (Standard_B2ms, Windows Server 2022 Gen2), NIC con IP statico 10.250.1.10, NSG, 1 data disk, estensione VMAccessAgent
- Placeholder IP scelto per il test: 10.250.1.50
- **Residuo del primo tentativo** (da pulire): nella subscription *Azure Virtual Desktop* esiste `rg-migtest-net` con una VNet `vnet-migtest` (tag `purpose=migration-test`)
- I file di stato del test sono in `<cartella da cui lanci lo script>\migration\vmmigtest01\` (`config.json`, `state.json`, `migration.log`). Lancia sempre lo script dalla stessa cartella (`AzMigSnap`)

## Problemi emersi dai test reali (tutti corretti)

1. **NIC su subnet di un'altra subscription: non supportato** (`InvalidResourceReference`). Ambiente riportato a una sola subscription. Per sicurezza lo script di migrazione cambia comunque contesto di subscription quando VNet/NSG/IP pubblico stanno altrove
2. **`New-AzDiskConfig` non ha `-SecurityType`** (nome di parametro sbagliato). Dopo l'errore ho verificato **tutti** i parametri dei due script contro la documentazione ufficiale dei cmdlet (raw su GitHub azure-powershell): nessun altro nome errato
3. **Con `CreateOption Copy` il security type (es. TrustedLaunch) non si può impostare**: il disco lo eredita dallo snapshot. Tolta l'impostazione, aggiunto un avviso se il disco nuovo non risulta con lo stesso security type della sorgente

## Stato attuale del test

- Fasi 1, 2, 3: **completate**
- Sorgente `vmmigtest01`: deallocata. Replacement `vmmigtest01-mig`: in esecuzione
- **Prossimo passo: Fase 4 (Validate)**. Rispondere `n` alla domanda sui controlli manuali (nel test non sono stati fatti davvero)

## Da fare (ordine suggerito)

1. Eseguire la Fase 4 e analizzare i FAIL/WARN (in particolare: avviso sul security type del disco OS, IP, NSG, estensioni, boot diagnostics)
2. Provare la **Fase 5 (Rollback)** e verificare che la sorgente torni con IP originale, riparta, e che la VM nuova sparisca
3. Rifare una migrazione completa dopo il rollback (Fasi 3 e 4 azzerate)
4. **Nomi snapshot con il LUN** (richiesta dell'utente, da applicare dopo questo giro per non rompere lo stato): disco OS `<disco>-snap-os-mig`, data disk `<disco>-snap-lun<N>-mig`
5. Varianti di test con l'ambiente: `-WithPublicIp`, `-WithSystemIdentity` (deve essere segnalata e riconosciuta), `-Zone 1`, `-OsType Linux`, `-Generation 1` (deve essere bloccata in Fase 1), `-VmSize Standard_F4s_v2`
6. Pulizia: `.\testenv\New-MigrationTestEnvironment.ps1 -Destroy` e rimozione del residuo `rg-migtest-net` nella subscription Azure Virtual Desktop
7. Decidere se aprire una **pull request** verso `main` (al momento si lavora sul branch)
8. Valutare evoluzioni: input da CSV, rollback che parcheggia la NIC nuova invece di cancellarla, boot diagnostics con storage account originale, copia dei lock sulla nuova VM

## Punti di attenzione noti

- Il test con Azure simulato verifica logica, ordine e checkpoint, **non** il comportamento reale di Azure: gli errori emersi finora (punti 1-3) sono venuti solo dai test reali
- Estensioni con settings protetti (custom script, domain join, MMA/OMS, DSC) non sono rileggibili: vengono segnalate, non ripristinate
- Boot diagnostics della VM nuova: sempre managed
- La macchina di lavoro mostra "Constrained Language AUDIT Mode": oggi non blocca nulla, ma se passasse in modalità forzata alcune parti dello script potrebbero non funzionare
- La cartella del repo è dentro OneDrive: se compaiono errori strani con `git`, spostarla fuori da OneDrive

## Come riprendere domani

```powershell
cd "C:\Users\villav\OneDrive - 4ward srl\Documenti\GitHub\AzMigSnap"
git pull origin claude/dreamy-ramanujan-al2iqw
.\Invoke-VmSkuMigration.ps1 -TenantId <TENANT-ID> -SubscriptionId <SUBSCRIPTION-ID-Hyper-v-drsource> -ResourceGroupName rg-migtest-vm -VmName vmmigtest01
```

Rispondere `y` alla subscription, poi `4` per la validazione. Per ripulire tutto a fine test:

```powershell
.\testenv\New-MigrationTestEnvironment.ps1 -Destroy -TenantId <TENANT-ID>
```


---

## Aggiornamento del 06/10/2026: percorso guidato

Lo script è stato riscritto come **percorso guidato unico** (niente più menu a fasi), come richiesto:

- schermo pulito e spiegazione; `Connect-AzAccount`; subscription da elenco; nome VM (il resource group lo trova da solo)
- promemoria dei check manuali con conferma Y/N
- schermata a due colonne: **VM attuale (verde, sinistra)** e **VM nuova (rossa, destra)**, ridisegnata dopo ogni passo, con stato acceso/deallocata
- scelta della nuova taglia da un elenco del playbook, controllata sulla subscription (region, zona, quota, generazione, nessuna riduzione di capacità)
- IP placeholder preso automaticamente (primo libero della subnet) per ogni NIC della VM vecchia; la nuova NIC prende l'IP originale; se non c'è un IP libero, si ferma
- riepilogo del piano, elenco del "non gestito" con `ACKNOWLEDGE`, poi Y/N per il deploy
- deploy con lista di avanzamento, controlli automatici, e a fine corsa i test da fare con il promemoria di **tenere spenta la VM sorgente**
- rilanciando lo script su una VM già migrata: riprendi / ricontrolla / **rollback**
- snapshot con il LUN nel nome: `<disco>-snap-os-mig` e `<disco>-snap-lun<N>-mig` (il rollback toglie anche i vecchi `<disco>-snap-mig`)

Il test con Azure simulato è stato riscritto sul nuovo percorso (errore e ripresa, controlli ripetuti, rollback, seconda migrazione).
Non ancora provato su Azure reale dopo la riscrittura: **il prossimo test reale è la prova del nuovo percorso**.

Nota per il test già in corso: la migrazione di `vmmigtest01` fatta con la versione precedente ha snapshot con il nome vecchio;
il nuovo script li riconosce (entrambi i nomi) quando si esegue il rollback.
