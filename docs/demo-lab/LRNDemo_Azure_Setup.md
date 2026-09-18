# LRNDemo — demo lab on Azure, cloned from Cove

A demo lab cloned from **CoveLRN** (Azure SQL **Managed Instance**) into **LRNDemoLab**
(Azure **SQL Database**) and de-identified.

| | |
|---|---|
| **Lab key** | `LRNDemo` |
| **LabId** | `98` — reserved for demo/training labs (real labs are 2–24; `99` is LRNLabDemo) |
| **Source** | `CoveLRN` on Azure SQL Managed Instance — **LabId 4** |
| **Target** | `LRNDemoLab` — pick a copy method below to match where it lives |

## Pick your step 1

Everything from step 2 onward is identical. Only the copy differs, and it differs
by **where LRNDemoLab lives**:

| Target | Script | Needs |
|---|---|---|
| **Same Managed Instance** (recommended) | `Demo_LRNDemo_01a_CopyOnSameMI.ps1` | Az.Sql module. **No storage account.** |
| Same or another MI, via a backup file | `Demo_LRNDemo_01b_CopyViaBackupToUrl.sql` | Blob container + SAS. Pure T-SQL, runs in SSMS. |
| **Azure SQL Database** (PaaS) | `Demo_LRNDemo_01_CopyFromManagedInstance.ps1` | SqlPackage. BACPAC export/import. |

Prefer **01a** where you can. It restores from the instance's own automatic backups,
so nothing reads the live database, no storage account is involved, and — the real
point — **no portable file of patient data is ever created**. The copy never leaves
the instance.

Use **01b** when you need a copy on a *different* Managed Instance, or deliberately
want a backup file as a fixed demo baseline to re-restore.

Use **01** only if LRNDemoLab must be on Azure SQL Database: there is no
backup/restore path from MI to that engine, so it has to go through a BACPAC.

> **Not SQL Server Express.** Express does not enter into any of these. CoveLRN is
> on a Managed Instance, which backs up to blob URLs and does not expose a file
> system; a local Express instance cannot restore an MI backup.

This is the Azure sibling of [`DemoLab_Setup.md`](DemoLab_Setup.md), which covers the on-prem
`LRNLabDemo`. **Read the "Residual risk" section of that document — it applies here unchanged**
and is not repeated below.

---

## Why this is not just the old pipeline with new names

The on-prem pipeline copies the database in T-SQL: `BACKUP DATABASE ... TO DISK`, then
`RESTORE DATABASE`. None of that works here, and no amount of parameter-changing makes it work:

- **Azure SQL Database supports no `BACKUP` and no `RESTORE`.** Not a permissions problem — the
  statements do not exist on that engine.
- **A Managed Instance native backup cannot be restored into Azure SQL Database.** Different
  engines, different file formats.
- **`CREATE DATABASE ... AS COPY OF`** works only *within* Azure SQL Database, so it cannot reach
  back to the Managed Instance.
- **`USE <database>` is not supported on Azure SQL Database.** The on-prem scripts open with it as
  a safety measure; here the connection itself must target the right database.

The supported MI → SQL Database path is a **BACPAC** — a logical export of schema and data — which
is what step 1 drives.

---

## Before you start

| | |
|---|---|
| **SqlPackage** | `dotnet tool install -g microsoft.sqlpackage`, then reopen the shell |
| **Source access** | Read on `CoveLRN`. The MI public endpoint is port **3342**, not 1433 |
| **Target access** | `dbmanager` (or contributor) on the target logical server |
| **Firewall** | Your client IP allowed on **both** the MI and the SQL Database server |

> The machine these scripts were written on has `sqlcmd` and `bcp` but **not** `az` or
> `sqlpackage`. Nothing here was executed against Azure — the scripts are unrun.

---

## The PHI window

This is the part worth slowing down for.

Between step 1 finishing and step 2 completing, `LRNDemoLab` holds real patient data — whichever
copy method you used.

**Options 1b and 1c also create a file** (a `.bak` blob or a `.bacpac`), and that file is the more
dangerous artefact: a single portable thing, and whoever has it has every patient record in it.
Option 1a creates no file at all, which is the main reason to prefer it.

- Write it to an **encrypted local path**. Never a network share, never a synced folder
  (OneDrive / Dropbox), never a blob container with public or broad access.
- **Run step 2 immediately.** Do not break for the day with the window open.
- The script deletes the BACPAC on success by default (`-RemoveBacpac:$false` to keep it). If the
  import fails it deliberately keeps the file and tells you where it is — delete it yourself if
  you are abandoning the run.
- **Do not issue the LRNDemo credentials until step 2 has been verified.**

---

## 1a. Copy on the same Managed Instance — recommended

```powershell
Install-Module -Name Az.Sql -Scope CurrentUser -Repository PSGallery -Force
Connect-AzAccount

# Dry run - reads Azure, restores nothing:
.\LabMetricsDashboard\SqlScripts\Demo_LRNDemo_01a_CopyOnSameMI.ps1 `
    -ResourceGroupName 'rg-lrn' -InstanceName 'covemi' -WhatIf

# For real (prompts before restoring):
.\LabMetricsDashboard\SqlScripts\Demo_LRNDemo_01a_CopyOnSameMI.ps1 `
    -ResourceGroupName 'rg-lrn' -InstanceName 'covemi'
```

Defaults to `CoveLRN` → `LRNDemoLab` at "15 minutes ago" — a point-in-time restore
cannot use the last few minutes, so the script steps back rather than failing on it.
It checks the instance's earliest restore point, refuses a target that already exists
(with the drop command you need to refresh), then polls until the new database reports
`Online` rather than returning as soon as Azure accepts the request.

Roughly as long as the database is large. Cove stays online throughout — this reads
the instance's backups, not the live database.

**To refresh the demo:** drop `LRNDemoLab`, re-run this, then re-run steps 2 and 3.

## 1b. Copy via backup to blob — T-SQL, runs in SSMS

Create a **private** container and a SAS with `rwdl` (read/write/delete/list — a
read-only SAS fails the backup), then paste the token into `@Sas` **without its
leading `?`**; `CREATE CREDENTIAL` rejects that with an error that doesn't mention it.
The PowerShell to produce both is in the script header.

Run `Demo_LRNDemo_01b_CopyViaBackupToUrl.sql` with `@Apply = 0` first — it validates
and prints the exact `BACKUP`/`RESTORE` statements without running them.

The backup is `COPY_ONLY` and that is not optional: Managed Instance runs its own
automatic backup chain, and a normal full backup would take ownership of it and break
point-in-time restore for CoveLRN itself.

T-SQL cannot delete a blob, so **delete the `.bak` yourself** once the restore
succeeds — the script prints the command.

## 1c. Copy to Azure SQL Database — BACPAC

```powershell
# Dry run first - validates arguments and reports, contacts nothing:
.\LabMetricsDashboard\SqlScripts\Demo_LRNDemo_01_CopyFromManagedInstance.ps1 `
    -SourceServer 'covemi.public.<dns-zone>.database.windows.net,3342' `
    -TargetServer 'lrndemo.database.windows.net' `
    -WhatIf

# Then for real (it prompts before doing anything destructive):
.\LabMetricsDashboard\SqlScripts\Demo_LRNDemo_01_CopyFromManagedInstance.ps1 `
    -SourceServer 'covemi.public.<dns-zone>.database.windows.net,3342' `
    -TargetServer 'lrndemo.database.windows.net'
```

Defaults: `-SourceDatabase CoveLRN`, `-TargetDatabase LRNDemoLab`, Entra ID interactive auth
(no passwords on the command line, where they would land in shell history), and `Standard/S2`
for the target.

Two guards refuse to proceed, before any tool check so a typo surfaces instantly: a target name
without "Demo" in it, and a source equal to the target.

**If the target already exists the import fails by design** — SqlPackage will not overwrite. Drop
`LRNDemoLab` first when refreshing the demo. That is also the refresh path: drop, re-run step 1,
re-run steps 2 and 3.

A logical export is considerably slower than a `.bak` on a large lab. `SourceTimeout:0` is set so a
long export is not killed part-way by a transient disconnect.

---

## 2. De-identify — **connect directly to `LRNDemoLab`**

There is **no `USE` statement** in these scripts, because Azure SQL Database has no cross-database
context. Set the database on the connection itself:

- **SSMS** — Connect → Options → *Connect to database*: `LRNDemoLab`
- **sqlcmd** — `-d LRNDemoLab` (and `-I`, for the reason in the script header)

That removes the safety net the on-prem version had, where the `USE` line pinned the target
regardless of the connection. The `DB_NAME()` guard, which refuses any database without "Demo" in
its name, is now the *only* protection. Check what you are connected to.

Run **`Demo_LRNDemo_02_Deidentify.sql`** with `@Apply = 0` first (the default). It reports every
column it matched and changes nothing — **read that list**. A column you expected but do not see
needs its name adding to `#PhiColumn` at the top. Then `@Apply = 1`.

What it does, unchanged from the on-prem version:

- **Patient ids, MRNs, member/subscriber ids, policy numbers** → a deterministic pseudonym derived
  from the original, so the same patient gets the same fake id in every table and claims, line
  items, tasks and notes still join up.
- **Names** → `Demo Patient <n>`, consistent the same way.
- **Dates of birth** → shifted by a fixed offset and flattened to the 1st of the month. A DOB held
  as *text* is reported as `DOBTEXT` and set to a placeholder instead.

Watch for `!! FAILED` lines. The script keeps going deliberately so one awkward column does not
leave everything else identifiable — but those columns are still real data and need handling by hand.

---

## 3. Re-stamp the copied data as LRNDemo

Run **`Demo_LRNDemo_03_RestampLabIdentity.sql`** against `LRNDemoLab` (`@Apply = 0` first).

The copy carries **Cove's** identity in its own rows — `LabId = 4` — while the app registers the
demo as **98**, and every claim-scoped query filters `[LabId] = @LabId`. Skip this and you get the
classic half-working demo: task counts, SLA counts and balances populate (those queries have no
LabId filter) while **open claims, assigned, unassigned, escalated and the whole Claim Assignment
page read zero**.

---

## 4. Register the lab — **connect directly to `LRNMaster`**

Run **`Demo_LRNDemo_04_RegisterLab.sql`**. Again no `USE`: connect to `LRNMaster` itself.

It writes **both** lab registries. `dbo.Labs` is the general one; `dbo.LRNMetricsLab` is what the
Denial Dashboard and Denial Workflow actually resolve against, and without a row there the
workflow API cannot open a connection for LabId 98 at all.

It inserts LabId 98 explicitly and stops if 98 is already taken — pick another reserved id and
change **both** appsettings files to match.

---

## 5. App configuration

### 5a. appsettings — all three apps

Add `LRNDemo` to `LabConfig.Labs` and `LabConfig.LabsID` (id **98**) in:

- `LabMetricsDashboard/appsettings.json`
- `LRN.ReportsApi/appsettings.json`
- `LRN.ReportWorker/appsettings.json` (`ReportWorker.Labs`)

Also add `LRNDemo` to `ReportBoard.NoMissingReportWarning` in the dashboard, so a frozen demo lab
shows a gear rather than a stalled-pipeline warning on the Report Control Board.

> Add `LRNDemo` to **`LRN.ReportsApi`'s** `LabConfig:DemoLabs` — that key drives the Denial
> Dashboard's placeholder source file name. Without it the real file name names Cove, which is the
> lab this demo was cloned from.
>
> Leave the **dashboard's** `DemoLabs` empty unless you want the lab hidden from admins who have
> not been assigned it. See `DemoLab_Setup.md` for why that was switched off.

### 5b. Lab config file

```
E:\LRN-Data\PayerPolicy_v2\2026\ReportsDashboard\Application\Configs\LRNDemo.json
```

Copy the real `Cove.json` from that folder and change only: the root property name → `LRNDemo`,
`DbLabName`, `DbConnectionString` → `LRNDemoLab`, and **every file path** → a demo folder.

> The paths matter as much as the connection string. Left pointing at Cove's folders, the demo
> reads Cove's live CSVs and Excel exports and you are showing production data again — the database
> scrub does not help you there.

### 5c. Demo users — the "LRNDemo account"

In the dashboard UI, so passwords hash correctly:

1. **Admin → Manage Users** — create the demo account(s).
2. **Admin → Assign User Role** — `Lab User` for look-but-don't-touch, `AR Manager` to demo
   assignment and workflow actions.
3. **Admin → Assign User Labs** — assign `LRNDemo`.

Consider also creating a **contained SQL user** on `LRNDemoLab` with read-only rights, so anything
holding demo database credentials cannot reach Cove or any other production database.

### 5d. Restart

`LabConfig:Labs` / `LabsID` / `DemoLabs` are read at startup. Deploy the appsettings changes, then
recycle LabMetricsDashboard, LRN.ReportsApi and the LRN.ReportWorker service.

---

## Verify

1. Sign in as the demo user → header shows `LRNDemo`.
2. Open a claim on the Denial Dashboard → names read `Demo Patient …`, ids read `DP……`.
3. Claim counts and dollar totals look like a real lab. An empty report usually means `DbLabName`
   in the lab config does not match the `LabName` values inside the copied data.
4. **Claim Assignment page is populated.** Empty here means step 3 did not run — the data is still
   stamped LabId 4.
5. Spot-check free-text columns (`DenialClaimNotes`, `DenialClaimEscalations`, reviewer comments)
   before showing anyone outside the company. The scrub does not touch them.
