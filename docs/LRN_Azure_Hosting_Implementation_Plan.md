# LRN Azure Hosting — Implementation Plan and Verification Checklist

Companion to **`docs/LRN Azure Hosting Guide.pdf`** (16 pp, 23 Sep 2026).

The guide sets the target architecture and the cost model; both still hold. This
document is the part the guide could not supply: what the LRN codebase actually
contains, which of the guide's assumptions survive contact with it, the phases
rewritten against real project names, and a checklist to audit progress against.

Everything in Section 1 and Section 2 was verified against the repository at
commit `8ec2858`. Where a guide statement did not survive, the correction says how
it was checked so the next person can re-run it rather than trust this page.

---

## 1. Corrections to the guide

Seven statements in the guide do not match the repository. Four change the plan.

| # | Guide says | Repository shows | Impact |
|---|---|---|---|
| 1 | "six Windows Services" (p.1) | **Eleven** projects call `AddWindowsService`/`UseWindowsService` | Phase 4 is roughly twice the size budgeted |
| 2 | "a Python processor started by Windows Task Scheduler… about 10 GB RAM" (p.1) | **No Python service exists here.** The only `.py` files are five utility scripts (doc generation, a SQL column sync). `PredictionAnalysisApp` is C#, `net8.0`, `Exe` | Phase 2 has no target in this repo — resolve before planning |
| 3 | "LRN apps are .NET Core and Python, so this is feasible [Linux]" (p.2, p.11) | `LRN.CpuMonitor` targets **`net8.0-windows`** and references `System.Management` (WMI). `CaptureDataApp` and `ClaimLineCSVDataCapture` are **`WinExe`** desktop apps | Three projects cannot move to Linux as-is |
| 4 | "LRN.ReportsApi/Dockerfile" cited as existing (p.2) | Now true — added with `LabMetricsDashboard/Dockerfile` and `lrn.webui/Dockerfile` | Phase 1 partly done; see §3 |
| 5 | RunId design assumes an `ExecutionName` column and `sp_getapplock` in the worker (p.10) | Neither exists. `ExecutionName` and `CONTAINER_APP_JOB_EXECUTION_NAME` appear **nowhere**; `sp_getapplock` appears only in `LRN.ReportsApi/Services/DenialCodeMasterServices.cs:855` | Section 7 is entirely new work, correctly flagged as "a proposal" on p.11 |
| 6 | "a .NET Core web app" (unnamed, p.1) | `LabMetricsDashboard`, **`net9.0`** — a different runtime from `LRN.ReportsApi` (`net8.0`) | Two base images, two upgrade tracks |
| 7 | Key Vault as one uniform concern | Config key differs per project: `KeyVault:Uri` (dashboard, ReportsApi) vs **`KeyVault:VaultUri`** (`LRN.MasterFileProcessorWorker/Program.cs:38`) | A single env-var convention will silently miss one |

### 1.1 Blockers the guide does not mention

Found while containerising the three web workloads. Each is a code or
infrastructure change, not a setting.

**A. DataProtection key ring — will break sign-in on any multi-replica app.**
`LabMetricsDashboard/Program.cs:405-441` resolves the key ring to a local
directory. Container filesystems are ephemeral and per-replica, so scaling past
one replica hands each replica a different ring and users are logged out at
random as requests land on different ones. A redeploy at one replica logs
*everyone* out. Fix: persist to Azure Blob Storage with
`PersistKeysToAzureBlobStorage()` and protect with Key Vault. **This gates
`minReplicas > 1` on both .NET web apps** and is the single most likely cause of
a "works in test, chaos in production" cut-over.

**B. CORS origins are hard-coded.** `LRN.ReportsApi/Program.cs:170-186` allows
only `https://www.lrnanalytics.com` and `https://lrnanalytics.com` in
Production; localhost origins are added only in Development. A Static Web App on
`*.azurestaticapps.net`, or any new hostname, is blocked and **no configuration
setting changes it**. Fix before Phase 1 goes live behind a new hostname.

**C. The SPA bakes its backend URLs at build time.** Vite substitutes `VITE_*` at
build, so one image or SWA build serves exactly one environment. `lrn.webui/src/config/apiConfig.js:30,55`
already falls through to `window.__LRN_METRICS_BASE` / `window.__LRN_DENIAL_API_BASE`,
so a runtime-config shim is cheap — but note `import.meta.env` is checked *first*,
so the build must leave `VITE_*` unset or the runtime values are ignored.

**D. Excel export needs fonts in the image.** ClosedXML's `AdjustToContents()` is
used across the export builders in both the dashboard and the API. It measures
text against real font files; a bare Linux image has none and the export throws
at runtime, not at startup. Both Dockerfiles install `fontconfig` and
`fonts-dejavu-core`.

**E. Hardcoded Windows paths in every shipped config.** Count of `"X:\…"` string
values per `appsettings.json`:

| Project | Hits | Project | Hits |
|---|---|---|---|
| LRN.DenialDatabaseWorker | 29 | LabMetricsDashboard | 4 |
| LRN.MasterFileProcessorWorker | 8 | LRN.ReportWorker | 4 |
| LRN.ReportsApi | 7 | LRN.AzBlobSync | 3 |
| ClaimLineCSVDataCapture | 4 | LRN.SharePointSynchronizer | 3 |
| CaptureDataApp | 4 | RcmWatcherService | 2 |
| CodingMasterGenerator | 3 | LRN.SharePointUploader | 2 |
| PredictionAnalysisApp | 2 | LRN.PayerPolicyMapper | 1 |

Every one is a Linux-readiness item. They are *configuration*, so they can be
overridden per environment without a code change — but they must be overridden
deliberately, and a missed one fails at runtime on first file access.

**F. `LabConfigFolder` must become a mounted share.** The dashboard reads per-lab
JSON at startup from `LabConfig:LabConfigFolder`; the lab picker is empty without
it and `Program.cs` logs a startup warning. These files carry plaintext database
passwords, so they must stay out of the image — Azure Files mount, not a `COPY`.

**G. The dashboard hosts a `FileSystemWatcher` of its own.**
`LabMetricsDashboard/Services/RcmFileWatcherService.cs` watches a directory from
inside the web app. In a container that watches an ephemeral, per-replica
filesystem: it will not see files written anywhere else, and at more than one
replica each replica reacts to a different view. This needs the same re-shape as
`RcmWatcherService` (§2.2) — an Azure Files mount at minimum, a queue or Event
Grid trigger properly. It is easy to miss because it lives in the web app rather
than among the services.

---

## 2. Real workload inventory

26 buildable projects. This is the migration surface, replacing the guide's
five-row table on p.7.

### 2.1 Web-facing (3)

| Project | TFM | Target | Container status |
|---|---|---|---|
| `LabMetricsDashboard` | net9.0 | Container Apps | **Dockerfile written**, not yet built |
| `LRN.ReportsApi` | net8.0 | Container Apps | **Dockerfile written**, not yet built |
| `lrn.webui` | Vite/React | Static Web Apps | **Dockerfile + nginx written** (Container Apps path) |

### 2.2 Windows Services (11) — Phase 4

All eleven reference `Microsoft.Extensions.Hosting.WindowsServices`. Classify each
as Job (finite) or Container App (continuous) before touching it.

| Project | TFM | Shape | Linux risk |
|---|---|---|---|
| `LRN.MasterFileProcessorWorker` | net8.0 | Scheduled batch | Low — guide's Phase 3 target |
| `LRN.DenialDatabaseWorker` | net8.0 | Scheduled batch | Low, but 29 hardcoded paths |
| `LRN.ReportWorker` | net9.0 | Queue consumer | Low — `WinExe`, retarget to `Exe` |
| `LRN.PayerPolicyMapper` | net8.0 | Batch | Low |
| `LRN.AveragesImport.Worker` | net8.0 | Batch | Low |
| `LRN.AzBlobSync` | net9.0 | Sync worker | Low |
| `LRN.SharePointSynchronizer` | net8.0 | Continuous | Medium — file-share paths |
| `LRN.SharePointUploader` | net8.0 | Continuous | Medium — file-share paths |
| `FolderRetentionCleanupWorker` | net8.0 | Scheduled cleanup | Medium — operates on local/SMB paths |
| `RcmWatcherService` | net9.0 | `FileSystemWatcher` | **High** — watching a path is not a container pattern; re-shape to a queue or poll |
| `LRN.CpuMonitor` | **net8.0-windows** | Continuous | **Blocked** — WMI via `System.Management` |

`LRN.CpuMonitor` deserves a decision rather than a port: it watches VM CPU and
SQL activity, and Container Apps supplies host metrics through Azure Monitor
natively. **No other project in the repository references it** — a search for
consumers returns only its own files and the `.sln` entry. Combined with the
`net8.0-windows` + WMI dependency, **retiring it with the VM is the recommended
call**; it is the only hard Linux blocker among the eleven services. Confirm no
*external* consumer (a dashboard, an alert rule) reads its output first.

### 2.3 Desktop / not migrating (2)

`CaptureDataApp` (net8.0, WinExe) and `ClaimLineCSVDataCapture` (net9.0, WinExe)
are Windows desktop apps. They are not server workloads and do not belong in this
migration — but if they run *on the VM* today, retiring the VM (Phase 6) strands
them. Decide where they live before that phase, not during it.

---

## 3. Revised phases

The guide's Phase 0–5 structure is sound. Below it is re-scoped against the
inventory above, with a new Phase 1a for the blockers that must clear before any
web workload can serve real traffic.

### Phase 0 — Foundation
*Guide p.15, unchanged in intent.*

Resource group; VNet subnet routed to SQL MI; VNet-integrated Container Apps
environment; ACR (Standard); Log Analytics. Grant managed identities `AcrPull`,
Key Vault Secrets User, and SQL access.

**Done when:** a throwaway container in the environment can `SELECT 1` against
SQL MI over the VNet.

**LRN-specific:** decide the Key Vault config convention now and normalise
`KeyVault:VaultUri` → `KeyVault:Uri` in `LRN.MasterFileProcessorWorker`, or the
env-var convention will miss it (correction #7).

### Phase 1 — LRN.ReportsApi
*Partly done.*

1. `docker build -f LRN.ReportsApi/Dockerfile -t lrn-reports-api:<ver> .` — **from the repo root**, the project references `LRN.PayerPolicyMapper.Core`.
2. `docker run` locally against a test database; exercise an Excel export endpoint specifically (blocker D).
3. Push to ACR; deploy to Container Apps with system-assigned identity, `minReplicas: 1`.
4. Move secrets to Key Vault; blank `KeyVault__Uri` only for local runs.
5. Compare responses against the IIS instance.

**Done when:** same results from Azure as from IIS, including a downloaded workbook.

### Phase 1a — Pre-traffic blockers *(new)*

Neither .NET web app should take production traffic until these close.

1. **DataProtection to Blob Storage** (blocker A) — both web apps. Until then, pin `minReplicas: 1` *and* accept that every revision logs users out.
2. **CORS origins to configuration** (blocker B) — `LRN.ReportsApi`. Required before the SPA moves to any new hostname.
3. **SPA runtime config** (blocker C) — decide: per-environment builds, or the `window.__LRN_*` shim.
4. **Path overrides** (blocker E) — env-var overrides for every `C:\` config value in the two web apps (11 values).
5. **`LabConfigFolder` on Azure Files** (blocker F) — dashboard only.

### Phase 2 — Python processor
**Blocked pending clarification (correction #2).** No Python service exists in
this repository. Before this phase can be planned, answer: is it in another repo,
is it `PredictionAnalysisApp` (which is C#), or has it already been retired? The
guide's 10 GB memory figure drives the Dedicated-profile decision and the
top end of the cost range, so this is not a detail.

### Phase 3 — LRN.MasterFileProcessorWorker
*Guide §6 and §7 — the most design-heavy phase, and all of §7 is new build.*

1. Run-once host: drop `UseWindowsService` (`Program.cs:19`), process all enabled labs, exit 0/non-zero. Remove any internal timer loop.
2. Linux paths: replace the 8 hardcoded config paths; verify filename case sensitivity against SharePoint downloads.
3. **RunId ↔ Azure execution:** add an `ExecutionName` column; read `CONTAINER_APP_JOB_EXECUTION_NAME` **and confirm the variable name in the first test run** — the guide flags it as unconfirmed.
4. **Overlap protection:** `sp_getapplock` immediately after RunId creation; if held, log Skipped and exit 0. Parallelism 1.
5. **Startup reconciliation:** close any `Running` RunId with the same `ExecutionName` as `Failed (TimedOut)` before creating a new one.
6. Scheduled Job, cron in **UTC** (`0 22 * * *` = 06:00 SGT).

**Done when:** RunId logs complete for all enabled labs and the VM service is stopped.

### Phase 4 — Remaining services + dashboard
*Eleven services, not six.*

Classify each per §2.2, then migrate in this order — cheapest and most
independent first, so the pipeline is proven before the awkward ones:

1. Batch, low risk: `LRN.PayerPolicyMapper`, `LRN.AveragesImport.Worker`, `LRN.DenialDatabaseWorker`
2. Queue/sync: `LRN.ReportWorker` (retarget `WinExe`→`Exe`), `LRN.AzBlobSync`
3. `LabMetricsDashboard` — only after Phase 1a
4. File-share dependent: `LRN.SharePointSynchronizer`, `LRN.SharePointUploader`, `FolderRetentionCleanupWorker` — need Azure Files or a re-shape
5. Re-shape required: `RcmWatcherService`
6. Decide: `LRN.CpuMonitor` — retire rather than port

### Phase 5 — React UI
Static Web Apps, after blockers B and C. Cheap and low-risk once CORS accepts the
new hostname — which is exactly why it must not go first.

### Phase 6 — Retire the VM
Monitor 2–4 weeks, downsize, decommission. **First confirm** the two desktop apps
(§2.3) and anything consuming `LRN.CpuMonitor` have somewhere to live.

---

## 4. Verification checklist

Audit format: tick only what has been *observed working*, not what has been
written. "Written" and "verified" are separate columns because the first three
Dockerfiles are currently in the first state and not the second.

### 4.1 Corrections acknowledged

- [ ] Service count reconciled — 11, not 6, and Phase 4 estimate revised
- [ ] Python processor located, or confirmed non-existent / retired
- [ ] `LRN.CpuMonitor` decision recorded (port vs retire)
- [ ] Desktop apps (`CaptureDataApp`, `ClaimLineCSVDataCapture`) have a home post-VM
- [ ] Key Vault config key normalised across all projects
- [ ] Two runtimes (net8.0 + net9.0) accepted, or projects aligned

### 4.2 Pre-traffic blockers

| Blocker | Written | Verified in Azure |
|---|---|---|
| A — DataProtection to Blob Storage | ☐ | ☐ |
| B — CORS origins configurable | ☐ | ☐ |
| C — SPA runtime config decided | ☐ | ☐ |
| D — Fonts in image (Excel export) | ☑ *(in Dockerfiles)* | ☐ |
| E — Windows path overrides | ☐ | ☐ |
| F — LabConfigFolder on Azure Files | ☐ | ☐ |
| G — Dashboard `FileSystemWatcher` re-shaped | ☐ | ☐ |

### 4.3 Phase 0 — Foundation

- [ ] Resource group, VNet subnet routed to SQL MI
- [ ] VNet-integrated Container Apps environment
- [ ] ACR (Standard) + Log Analytics
- [ ] Managed identities granted `AcrPull`, Key Vault Secrets User, SQL access
- [ ] **Test container queries SQL MI over the VNet** ← the real gate

### 4.4 Phase 1 — ReportsApi

- [x] Dockerfile written (`LRN.ReportsApi/Dockerfile`, net8.0)
- [ ] Image builds
- [ ] Runs locally against a test database
- [ ] **Excel export endpoint exercised** (blocker D shows up only here)
- [ ] Pushed to ACR with a version tag
- [ ] Deployed, managed identity, secrets from Key Vault
- [ ] Output matches IIS

### 4.5 Phase 3 — Master File Processor

- [ ] `UseWindowsService` removed; exits 0/non-zero
- [ ] 8 hardcoded paths overridden; filename case verified
- [ ] `ExecutionName` column added
- [ ] `CONTAINER_APP_JOB_EXECUTION_NAME` **confirmed by observation**
- [ ] `sp_getapplock` overlap guard; parallelism 1
- [ ] Startup marks orphaned `Running` RunIds as `Failed (TimedOut)`
- [ ] Cron converted to UTC
- [ ] Manual re-run overrides (`LAB_FILTER`, `WEEK_FOLDER`) implemented — *proposed, not existing*
- [ ] Full run across all enabled labs; VM service stopped

### 4.6 Cut-over safety

- [ ] VM Task Scheduler entry / service **disabled** at go-live (guide p.12: double processing)
- [ ] Azure run tested against a **test** database first
- [ ] Alerts on failed executions
- [ ] Outbound IP: NAT Gateway decided if any firewall allow-lists LRN
- [ ] Rollback path written down and tested

---

## 5. Open questions

Blocking, in priority order:

1. **Where is the Python processor?** Not in this repo. Drives Phase 2 entirely and the top of the cost range.
2. **Does anything *outside* the repo consume `LRN.CpuMonitor`?** Nothing inside does. A "no" retires it and removes the only hard Linux blocker among the services.
3. **What writes the folders `RcmWatcherService` and the dashboard's `RcmFileWatcherService` watch?** Both need the same answer, and it determines re-shape vs retirement for each.
4. **Target `minReplicas` for the web apps?** If >1, blocker A is mandatory before go-live, not optional.
5. **Which hostname will the SPA serve from?** Determines urgency of blocker B.

The guide's p.16 questionnaire (run time, peak memory, file volumes, log volume,
current VM size) still needs answering per workload to convert the USD 72–244
range into a firm SGD figure.
