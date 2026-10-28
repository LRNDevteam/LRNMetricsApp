# LRN Platform — HIPAA Implementation (PHI storage, access and audit)

**Version 2.0 · 27 Oct 2026 · Prepared by Jameel** — supersedes *AR Workbench — HIPAA-Compliant Azure Blob Document Storage* v1.0 (26 Oct 2026), which is now **Wave 1** of this document.
**Applies to:** every project in the `LRNMetricsApp` repository (branch `main` at `99eff65`).
**Status:** Wave 1 (AR Workbench) implemented on branch `feature/arwb-hipaa-blob-documents`; Wave 0 implemented on `security/hipaa-phase0` (not merged); Waves 2–6 specified, not started.

This document has two parts:

- **Part A — HIPAA summary (for management and compliance).** Which projects touch PHI, where it rests today, which HIPAA rules apply, the gaps, the plan and the decisions needed.
- **Part B — Implementation specification (for developers and Claude Code).** The shared standard every project follows, then one section per wave with files, tasks, tests and rollout. Give Part B, one wave at a time, to Claude Code as the task brief.

---

# Part A — HIPAA summary

## A1. Why this changes

LRN processes laboratory claims for client labs. Claim and line data (patient name, patient ID, date of birth, date of service, CPT/ICD codes, payer, accession number), claim attachments (EOBs, insurance cards, medical records, appeal letters) and the reports built from them are **Protected Health Information (PHI)**. The HIPAA Security Rule (45 CFR Part 164, Subpart C) therefore applies to every system that stores, moves or displays them.

Version 1.0 of this document fixed this for one module, AR Workbench attachments. A review of the whole repository found the same pattern in other projects: **PHI files on the API and ReportEngine server disks, without malware scanning, integrity checks or a tamper-proof access log**, plus a few platform-level issues (committed credentials, a SAS token, an AI API key). Version 2.0 applies one standard across all projects and orders the work in waves, AR Workbench first.

## A2. Where PHI lives today — project inventory

"PHI at rest" is where the data sits outside the lab SQL databases. Every lab database (`dbo.ClaimLevelData`, `dbo.LineLevelData`, `dbo.ARWB_*`, `dbo.Denial*`) holds PHI as well; that is covered in Wave 6.

| Project | What it does with PHI | PHI at rest outside SQL today | Wave |
| --- | --- | --- | --- |
| `LRN.ReportsApi` — AR Workbench | Claim attachments and client CIP responses | `C:\LRN-Files\ApplicationFolder\DenialWorkFlow\Uploads\ARWorkbench\{lab}\{yyyy}\{MM}\{guid}` | **1 — done in code** |
| `LRN.ARWorkbench` (React) | AR Workbench UI; Document Vault search by patient name | Browser only (patient names were sent in the URL) | **1 — done in code** |
| `LRN.ReportsApi` — Denial Workflow | Claim documents uploaded by AR, Client and Account Managers | `…\DenialWorkFlow\Uploads\{lab}\{claimId}\{guid}` — **claim ID in the folder name**, absolute path stored in `dbo.DenialClaimDocuments.FilePath` | 2 |
| `LRN.WebUI` (React) | Denial Workflow UI: uploads and downloads claim documents | Browser only | 2 |
| `LRN.ReportsApi` — exports | Denial Workflow / AR Workbench background Excel exports | `…\DenialWorkFlow\Downloads` and job-history folders | 3 |
| `LRN.ReportWorker` | On-demand report workbooks (Production, Collection, Denial, LIS, Coding, Clinic…) | `E:\LRN-Data\GeneratedReports` (RetentionDays 7, PurgeAfterDays 90) | 3 |
| `LabMetricsDashboard` (MVC) | Dashboards, Excel exports, serves `UserReports` files, denial and master uploads, Reimbursement chat | Serves files from the ReportWorker folder; `DashboardController` writes a temp workbook to disk; logs under `C:\LRN-Files\ApplicationFolder\LRNMetrics\Logs` | 3 |
| `LRN.ProductionReports` | Post-processes Production Report workbooks | Report folders on ReportEngine | 3 |
| `LRN.MasterFileProcessorWorker` | Pulls lab master files (claim + line level) from SharePoint and loads SQL | `C:\LRN-Files\Automation\LRN-Input`, `\Error`, `\LRN-RAWFILE\…\Archive` | 4 |
| `LRN.DenialDatabaseWorker` | Denial database build and payer-policy validation reports | `C:\LRN-Files\Automation\LRN-Output\DenialDatabase`, `\PayerPolicy_Validation_Report\{lab}` | 4 |
| `CaptureDataApp` | Coding master capture into SQL | `C:\LRN-Files\ApplicationFolder\CodingAutomation\Labs\` | 4 |
| `ClaimLineCSVDataCapture` | Claim/line CSV capture; writes Production / Collection reports and Beech Tree three-pillar JSON | Lab working folders and report output folders | 4 |
| `CodingMasterGenerator`, `PredictionAnalysisApp`, `RcmWatcherService` | Coding master, prediction reports, RCM JSON summaries | Lab working folders on ReportEngine | 4 |
| `Services\LRN.SharePoint*` | Moves files between ReportEngine folders and SharePoint | Both sides (SharePoint is Microsoft 365) | 4 |
| `Services\FolderRetentionCleanupWorker` | Deletes old files from the folders above | — (disposal, see 164.310(d)(2)(i)) | 4 |
| `LRN.AzBlobSync` | Uploads Beech Tree LIS / PMS / Cash JSON to Blob; sends it to Azure OpenAI for insights | Storage account `lrnbackupstorage01`, container `threepillar`, reached with a **SAS token**; Azure OpenAI with an **API key** | 5 |
| `LRN.AgentInterface`, `bridge` | Reimbursement Insights agent proxy (Foundry) and its Data API Builder bridge over LRNMaster | None found (aggregates); prompts may contain PHI typed by users | 5 |
| `LRN.Notification`, Teams webhooks | Email and Teams notifications from workers and the API | Message bodies (must not carry PHI) | 5 |
| `LRN.PayerPolicyMapper(.Core)`, `LRN.AveragesImport`, `LRN.ReportQueue.Shared`, `Services\LRN.CpuMonitor`, `tools` | Payer reference data, averages, queue library, monitoring | No PHI files found; `LRN.AveragesImport` has committed credentials (Wave 0) | 0 / none |
| `HelloMauiApp`, `BillingAgent` | Sample app / empty folder | — | Out of scope |

## A3. The platform standard — HIPAA requirements and how every project meets them

One pattern, already built for AR Workbench in Wave 1, is reused by every wave. "Existing" = already on `main`. "New" = added by this programme.

| HIPAA rule (45 CFR) | What the rule requires | How the platform meets it | Status |
| --- | --- | --- | --- |
| **164.308(a)(1)(ii)(A)** Risk analysis | Know where ePHI is and what threatens it | The inventory in A2, reviewed each release; this document is the record | New |
| **164.312(a)(1)** Access control | Only authorized people and software reach PHI | Lab access enforced server-side on every endpoint (Wave 0); role and claim scope in SQL. PHI files only in **private** storage (public network access disabled, private endpoint), reachable only by the owning app's **managed identity**. Browsers never connect to storage. | Existing + New |
| **164.312(a)(2)(i)** Unique user identification | Every action traceable to one person | Uploader and access-log identity always from the signed-in user, never from a request field (Denial Workflow currently accepts `uploadedBy` from the form — fixed in Wave 2) | Existing + New |
| **164.312(a)(2)(iv)** Encryption at rest | PHI encrypted when stored | Azure Storage with a **customer-managed key** in `kv-lrnmetrics-prod` plus **infrastructure (double) encryption**, key rotated every 2 years. Server disks that still hold PHI during migration: BitLocker (Wave 6). Lab databases: TDE verified (Wave 6). | New |
| **164.312(b)** Audit controls; **164.308(a)(1)(ii)(D)** activity review | Record and review activity on systems holding PHI | Per-module access logs (`ARWB_DocumentAccessLog`; Denial Workflow gets one in Wave 2; generated reports in Wave 3) recording Upload, Download, **Blocked**, **Migrate**, with user, role, IP and time — **append-only**. Storage diagnostic logs to Log Analytics `reimbursement-agent-logs`. Alerts in B12. | Existing + New |
| **164.312(c)(1)** Integrity; **(c)(2)** mechanism to authenticate ePHI | Protect PHI from improper change or destruction | SHA-256 recorded at upload and **re-checked on every download**; mismatch blocks the file and raises a critical alert. Blobs are **write-once**, with versioning, 30-day soft delete and point-in-time restore. | Existing + New |
| **164.312(d)** Person or entity authentication | Verify who or what is accessing PHI | Users sign in as today. Apps authenticate to Azure with **Entra ID managed identity**; storage **account keys disabled**; no SAS tokens, connection-string passwords or API keys in code or config (Waves 0 and 5). | Existing + New |
| **164.312(e)(1)** Transmission security | Protect PHI in transit | HTTPS only, **TLS 1.2 minimum**; app-to-storage traffic stays on the private endpoint. No PHI in URLs (Document Vault search moved to a POST body; same rule for every search screen). | New |
| **164.308(a)(5)(ii)(B)** Protection from malicious software | Guard against malware | **Defender for Storage** scans every upload; a document cannot be downloaded until the scan is clean; malicious files are blocked for everyone. Required because client users outside LRN upload files. | New |
| **164.308(a)(7)(ii)(A)** Data backup; **(a)(7)** contingency | Backup and disaster recovery | **RA-GZRS** (zones + paired region), versioning, soft delete, point-in-time restore, delete lock on the account. | New |
| **164.310(d)(2)(i)** Disposal; **(d)(2)(ii)** media re-use | PHI removed securely when no longer needed | After each migration, the old server folder is securely wiped (`cipher /w`) with signed-off evidence. `FolderRetentionCleanupWorker` deletions are logged; once files live in Blob, lifecycle policies replace it. | New |
| **164.316(b)(2)(i)** Documentation retention | Keep required HIPAA documentation (policies, risk analyses, audit records) **6 years** | Access logs are never deleted (append-only, ≥ 6 years). *Correction to v1.0:* this rule does not set how long the **documents themselves** are kept — that comes from state medical-record law and client contracts (decision D1); the lifecycle policy enforces whatever is chosen, never less than 6 years. | New |
| **164.502(b) / 164.514(d)** Minimum necessary (Privacy Rule) | Do not expose more PHI than needed | No PHI in blob names, metadata, tags, log messages, notification bodies or AI prompts beyond what the feature needs. Downloads `Cache-Control: no-store`. | New |
| **164.308(a)(6)** Security incident procedures | Detect and respond to incidents | Alerts (B12) route malware, integrity failures, unexpected storage callers and bulk downloads to Security and the AR manager. | New |
| **164.308(b)(1)** Business associate agreements | A BAA with every vendor handling PHI | Microsoft's HIPAA BAA (Microsoft Product Terms) covers Azure Storage, Key Vault, Defender for Storage, Log Analytics, Azure OpenAI / Foundry and Microsoft 365 (SharePoint, Teams, Exchange). **To be confirmed** for our tenant and subscription (decision D2). | Confirm |

## A4. Gaps found on `main`

| # | Project | Gap | Risk | Fix | Wave |
| --- | --- | --- | --- | --- | --- |
| G1 | ReportsApi (AR Workbench) | PHI attachments on the API server disk | Any server admin can read them; no recovery; blocks the Container Apps move | Private, encrypted Blob | 1 ✔ |
| G2 | ReportsApi (AR Workbench) | No malware scan (client users upload) | Malware reaches AR staff | Defender scan; download blocked until clean | 1 ✔ |
| G3 | ReportsApi (AR Workbench) | SHA-256 stored, never checked | Altered files go unnoticed | Hash verified on download | 1 ✔ |
| G4 | ARWorkbench (React) | Document Vault sent patient names in the URL | PHI in IIS / proxy logs and browser history | Search moved to a POST body | 1 ✔ |
| G5 | ReportsApi (AR Workbench) | Downloads had no cache directives | PHI copies in browser / proxy caches | `Cache-Control: no-store` | 1 ✔ |
| G6 | Lab DB (AR Workbench) | Access log rows could be edited or deleted | Audit trail could be altered | Append-only trigger | 1 ✔ |
| G7 | ReportsApi (AR Workbench) | Refused downloads not recorded | Incomplete audit | `Blocked` access type with a reason | 1 ✔ |
| G8 | ReportsApi (AR Workbench) | UI offered tif/tiff/gif, server rejected them | Scanned TIFFs refused | File signatures added | 1 ✔ |
| G9 | ARWorkbench (React) | CIP attachment download ignored errors | Refusals failed silently | Error shown | 1 ✔ |
| G10 | **Several** | **Real SQL passwords committed** in `CaptureDataApp`, `ClaimLineCSVDataCapture` and `LRN.AveragesImport` `appsettings.json`; **live Teams webhook URLs** in `LRN.ReportsApi` and `PredictionAnalysisApp` `appsettings.json` | Anyone with repository access can reach lab databases holding PHI | **Rotate every exposed credential now**, move to Key Vault, purge from git history (decision D6) | 0 |
| G11 | ReportsApi / MVC | Lab access not enforced server-side on every endpoint | A user could request another lab's PHI | Done on `security/hipaa-phase0` (P0-C, P0-D) — merge it | 0 |
| G12 | ReportsApi (Denial Workflow) | Claim documents on disk under a **claim-ID folder**; absolute path in SQL | PHI identifier in paths and backups; same G1 risks | Move to Blob (shared store) | 2 |
| G13 | ReportsApi (Denial Workflow) | No document access log; download not scope-checked beyond lab | No record of who opened which document | Access log + scope check on download | 2 |
| G14 | ReportsApi (Denial Workflow) | `uploadedBy` accepted from the form | Uploader identity can be forged (164.312(a)(2)(i)) | Always the signed-in user | 2 |
| G15 | ReportsApi (Denial Workflow) | No SHA-256, no malware scan, no `no-store` | As G2, G3, G5 | Shared store does all three | 2 |
| G16 | ReportWorker / MVC / ReportsApi | Generated report workbooks and exports (full claim lists) sit on server disks | Same as G1, for the largest PHI files we produce | Generated reports to Blob; download through the app with access log | 3 |
| G17 | Workers | Lab master files, raw-file archives and error files on ReportEngine disks | Same as G1 | Encrypted disks now (BitLocker); ingest folders to Blob later | 4 / 6 |
| G18 | LRN.AzBlobSync | Blob reached with a **SAS token**; Azure OpenAI with an **API key**; account `lrnbackupstorage01` not hardened | Long-lived secrets can leak; public endpoint | Managed identity for both; harden the account or move to the platform PHI account | 5 |
| G19 | Logging | Several services log file paths and claim IDs to local text logs | PHI identifiers in logs kept 30 days on disk | Log document IDs only; review each logger (B9 rule 1) | 6 |
| G20 | SQL | TDE and SQL auditing status of lab databases not documented | Unknown encryption / audit of the main PHI store | Verify TDE; enable auditing to Log Analytics | 6 |

## A5. Waves

| Wave | Scope | Status |
| --- | --- | --- |
| **0 — Prerequisites** | Remove and rotate committed credentials; lab access enforced server-side (branch `security/hipaa-phase0`); confirm BAA | Code on `security/hipaa-phase0`, **not merged**; G10 credentials still to rotate |
| **1 — AR Workbench documents** | Blob store, malware scan, hash check, audit, POST search, Bicep | **Implemented** on `feature/arwb-hipaa-blob-documents`; deploy pending |
| **2 — Denial Workflow documents** | Same store and rules for `dbo.DenialClaimDocuments` | Specified (B5) |
| **3 — Generated reports and exports** | ReportWorker output, `UserReports`, API exports, snapshots | Specified (B6) |
| **4 — Ingestion and file workers** | Master files, worker outputs, SharePoint sync, retention cleanup | Specified (B7) |
| **5 — AI, agents and notifications** | AzBlobSync, Foundry agent, email / Teams | Specified (B8) |
| **6 — Platform hardening** | SQL TDE and audit, server disk encryption, PHI-free logging, alerts, secure wipe | Specified (B9) |

## A6. Decisions needed from management / compliance

- [ ] **D1 Retention period** for documents and generated reports (v1.0 default 10 years for documents; minimum 6). Generated reports can be much shorter (they can be regenerated) — propose 90 days.
- [ ] **D2 Confirm the Microsoft BAA** covers our Azure subscription and Microsoft 365 tenant (Storage, Key Vault, Defender, Log Analytics, Azure OpenAI / Foundry, SharePoint, Teams, Exchange).
- [ ] **D3 Identity:** one user-assigned managed identity per application (API, MVC, workers) shared by the VM and the future Container Apps (recommended), or the VM's system identity now.
- [ ] **D4 Storage account layout:** one platform PHI account with one container per workload (recommended — one set of controls, one Defender plan, one private endpoint) or one account per module. Nothing is deployed yet, so the Wave 1 parameter `storageAccountName` (`stlrnarwbphi`) can still change to a platform name such as `stlrnphi01`.
- [ ] **D5 Sign-off for secure wipe** of each server folder after its migration.
- [ ] **D6 Git history:** rewrite history to purge the committed credentials (needs every clone re-cloned) or accept that they stay in history after rotation.

---

# Part B — Implementation specification

> **Instructions for Claude Code (VS Code):** Implement **one wave per branch**, created from `main`: `feature/hipaa-wave{N}-{short-name}`. Within a wave implement the tasks in order and build the affected projects after each task. Do not change behaviour beyond what a task states. Follow the existing style of each file (file-scoped namespaces, `SqlParameter` with explicit `SqlDbType`, the repository's `Truncate(...)` helper, short XML doc comments, comment density of the surrounding code). Reuse the Wave 1 types rather than copying them. Never put PHI in names, logs, tags, URLs or test fixtures.

## B1. Shared standard (all waves)

Every project that stores a PHI file follows this pattern. Wave 1 is the reference implementation.

| Concern | Rule | Reference implementation (Wave 1) |
| --- | --- | --- |
| Store abstraction | Metadata in SQL; bytes behind an async store interface: `SaveAsync`, `OpenReadAsync`, `DeleteAsync`, `GetScanResultAsync` | `IArWorkbenchDocumentStore` in `LRN.ReportsApi/Services/ArWorkbench/ArWorkbenchDocumentStore.cs` |
| Routing | `container == "local"` → legacy disk store (read-only until migrated); otherwise Blob | `RoutingArWorkbenchDocumentStore` |
| Blob names | One folder per lab, named as in `LabConfig:LabsID` (letters, digits, `-`, `_`; `lab-{labId}` when the lab has no name there): `{LabName}/{yyyy}/{MM}/{dd}/{Guid:N}{ext}` (UTC upload date; no claim folder — the claim ID is an identifier, and `dbo.ARWB_Document` maps claim → blob). A module that shares a container prefixes the folder (`dwf/{LabName}/…`). Extension sanitised; metadata `labid`, `sha256` only; `If-None-Match: *` | `AzureBlobArWorkbenchDocumentStore.SaveAsync` |
| Authentication | `DefaultAzureCredential` with `ManagedIdentityClientId`; https URI required; exponential retry ×3 | `AddArWorkbenchDocumentStorage` |
| Upload | Validate scope, count, type, size, magic bytes → store → SQL row + `Upload` log in one transaction → delete the blob if the row is refused | `UploadClaimDocuments`, `CipRespond` |
| Download | Scope check + `Download` log → scan tag (409 pending / 423 blocked) → read → SHA-256 check (409) → file with `Cache-Control: no-store, no-cache, must-revalidate, private` and `Pragma: no-cache`; every refusal writes `Blocked` | `DownloadDocument`, `BlockDocumentAsync` |
| Audit table | `{Module}AccessLog` with `AccessType`, `Detail nvarchar(200)` (never PHI), append-only trigger raising 51000 | `10_ARWB_Document_Blob_HIPAA.sql` |
| Migration | Site-admin `POST …/admin/migrate-to-blob?labId&batchSize=200&dryRun=true`: re-hash, upload, repoint, log `Migrate`; never deletes the local file | `MigrateDocumentsToBlob` |
| Search | Any search that accepts patient data is a POST with a JSON body | `POST documents/search` |
| Config | Section `{Module}Documents` with `Provider` (`Local` / `AzureBlob`), `BlobServiceUri`, `ContainerName`, `ManagedIdentityClientId`, `RequireCleanMalwareScan`, `VerifyHashOnDownload`, `MaxVerifiedDownloadBytes`; production values in Key Vault (`--` for `:`) | `ArWorkbenchDocumentStorageOptions` |
| Infrastructure | Private storage account, CMK, RA-GZRS, versioning, soft delete, PITR, lifecycle, Defender, diagnostics, container-scoped roles | `infra/arwb-document-storage/` |

**Promote to shared code in Wave 2.** Move the generic parts of the Wave 1 store (`DocumentScanResult`, `StoredDocument`, the Blob store, the routing store, the options binding) to `LRN.ReportsApi/Services/Documents/` with the container and section name as constructor/option inputs, and keep thin AR Workbench registrations so the Wave 1 code and tests keep working unchanged. Workers outside the API (Waves 3–4) reference the same code through a small `Services/LRN.PhiStorage` class library rather than copying it.

**Shared infrastructure.** Per decision D4, extend `infra/arwb-document-storage/arwb-document-storage.bicep` into `infra/phi-storage/phi-storage.bicep` with a `containers` array parameter — `{ name, retentionDays, coolAfterDays, writerPrincipalIds[] }` — producing one container, one lifecycle rule and container-scoped role assignments per entry. Each wave adds its container to the parameters file; nothing else in the template changes.

## B2. Wave 0 — Prerequisites

1. **Rotate now (does not wait for code):** every SQL login whose password is in a tracked `appsettings.json` (`CaptureDataApp`, `ClaimLineCSVDataCapture`, `LRN.AveragesImport.Worker`) and both Teams webhooks (`LRN.ReportsApi`, `PredictionAnalysisApp`). Treat as a security incident under 164.308(a)(6): record what was exposed, since when, and who had repository access.
2. **Merge `security/hipaa-phase0`** after review: P0-A removes credentials from tracked config and fails fast on a missing signing key; P0-B admin role + antiforgery; P0-C / P0-D lab access enforced server-side in the MVC dashboard and every Reports API workflow endpoint. Re-run its tests on current `main`.
3. Confirm the secret scanner from P0 runs in CI (`.github/`) and fails the build on a new credential.
4. Decision D6 on git history.

**Done when:** rotated credentials verified dead; P0 merged; CI secret scan green.

## B3. Wave 1 — AR Workbench documents (implemented)

Branch `feature/arwb-hipaa-blob-documents`. Tasks T1–T10 of v1.0 are implemented as specified, with the notes below.

| Task | Files | Status / notes |
| --- | --- | --- |
| T1 NuGet | `LRN.ReportsApi.csproj` — `Azure.Storage.Blobs` 12.24.0 | Done; restore succeeds |
| T2 Async store | `Services/ArWorkbench/ArWorkbenchDocumentStore.cs` | Done; `SafeExtension` made `internal` so Blob and disk name files the same way |
| T3 Blob + routing + DI | `Services/ArWorkbench/AzureBlobArWorkbenchDocumentStore.cs`, `Program.cs` | Done. **Change from v1.0:** blobs go to one folder per lab named after the lab (`PCRLabsofAmerica/2026/10/27/{guid}.pdf`), not `lab-{labId}/…`. The name comes from `LabConfig:LabsID`, the list that already picks each lab's database. |
| T4 Repository | `SqlArWorkbenchRepository.cs`, `SqlArWorkbenchRepository.Documents.cs` | Done; `MoveDocumentToBlobAsync` updates the row and writes `Migrate` in one transaction (`XACT_ABORT`) |
| T5 Controller | `Controllers/ArWorkbenchController.cs` | Done: uploads, `POST documents/search`, download, `POST documents/admin/migrate-to-blob` |
| T6 File guard | `Security/FileUploadGuard.cs` | Done; `ValidateDocumentAsync` (Denial Workflow) unchanged |
| T7 Config | `appsettings.json` `ArWorkbenchDocuments` | Done; `Provider = Local` by default |
| T8 SQL | `LabDatabase/10_ARWB_Document_Blob_HIPAA.sql`, `Build-MergedScripts.ps1`, README, merged script regenerated | Done |
| T9 React | `arWorkbenchService.js`, `CipShared.jsx` | Done; `npm run build` succeeds |
| T10 Bicep | `infra/arwb-document-storage/*.bicep`, `*.parameters.json` | Written; **not compiled locally** (no Bicep CLI on the dev machine) — run `az bicep build` and `what-if` before deployment |
| Tests | `tests/LRN.ReportsApi.Tests/ArWorkbenchDocumentStorageTests.cs` | 9 test methods (11 cases): tif/gif signatures, renamed file, Denial Workflow rules unchanged, DI for Local / AzureBlob / non-https, local routing, script 10 parses. Full suite: 586 of 587 pass; the one failure (`DenialSummaryRequestValidationTests` "Lab User") fails on `main` too. |

**Behaviour to know about**

- A refused download writes `Download` (from the unchanged scope check) **then** `Blocked`. Reports and the bulk-download alert must count a download as successful only when no `Blocked` row follows it for the same document and user.
- Migration batches always start from the lowest `local` `DocumentId`. Documents that fail (missing on disk, hash mismatch) stay `local` and come back first in the next batch, so resolve `problemDocumentIds` before running further batches — 200 unresolved problems would stall the migration.
- `GET documents` (search in the query string) still exists for compatibility. **Follow-up:** remove it once the new React build is deployed everywhere, so a patient name can no longer reach a URL.
- `RequireCleanMalwareScan = true` means every new upload is unavailable for about a minute while Defender scans it (test F-08).

**Rollout, tests and operations:** v1.0 sections B5–B7 apply unchanged and are summarised in B10–B12 below.

## B4. Shared code promotion (start of Wave 2)

1. Create `LRN.ReportsApi/Services/Documents/` with `IPhiDocumentStore` (the Wave 1 interface), `DocumentScanResult`, `StoredDocument`, `AzureBlobPhiDocumentStore`, `LocalPhiDocumentStore`, `RoutingPhiDocumentStore` and `PhiDocumentStorageOptions`. Each store takes its container name, blob prefix (`lab`, `dwf`, …) and local root from options.
2. `AddPhiDocumentStorage<TMarker>(this IServiceCollection, IConfiguration, string section)` registers a keyed routing store per module, sharing one `BlobServiceClient` per service URI.
3. Make the AR Workbench types thin wrappers (or keyed registrations) over the shared ones. **Wave 1 tests must pass unchanged.**
4. Extract `BlockDocumentAsync` and the download pipeline (scan → read → hash → headers) into `PhiDownloadPipeline` so each controller calls one method.

## B5. Wave 2 — Denial Workflow claim documents

Projects: `LRN.ReportsApi` (Denial Workflow), `LRN.WebUI`. Table `dbo.DenialClaimDocuments` (created in `SqlDenialWorkflowRepository.cs`): `DocumentId, LabId, ClaimId, OriginalFileName, StoredFileName, ContentType, FileSizeBytes, FilePath, Comment, UploadedBy, UploadedOn, IsDeleted`.

| # | Task | Detail |
| --- | --- | --- |
| W2-1 | SQL script | New idempotent `Database/LRN.ReportsApi/DenialWorkflow_Documents_HIPAA.sql`: add `BlobContainer nvarchar(100) NOT NULL DEFAULT 'local'`, `BlobPath nvarchar(1024) NULL`, `ContentSha256 varchar(64) NULL`; create `dbo.DenialClaimDocumentAccessLog` (`DocumentAccessLogId, DocumentId, AccessType CHECK IN ('Download','Upload','Delete','Blocked','Migrate'), UserName, RoleCode, ClientIp, Detail nvarchar(200), AccessedOn`) with the append-only trigger. Existing rows keep `FilePath` (absolute) until migrated. Add the same DDL to the repository's create-if-missing block. |
| W2-2 | Store | Register a Denial Workflow store (section `DenialWorkflowDocuments`, container `dwf-documents`, one folder per lab name as in Wave 1). The legacy disk store reads by the **absolute** `FilePath`, guarded to stay inside `DenialWorkflowFileStorage:UploadRootPath`. |
| W2-3 | Upload | `DenialWorkflowController.UploadClaimDocuments`: use the store (no claim ID in any path); record `BlobContainer`, `BlobPath`, `ContentSha256`; write `Upload` rows in the same transaction; on failure delete the blob. **Ignore the `uploadedBy` form field** — always the signed-in user (G14). Keep `ValidateDocumentAsync`, the 10-file / 25 MB limits and the Client/Account Manager escalation rule. |
| W2-4 | Download | `DownloadClaimDocument`: lab access (Wave 0) **plus** the same rule the upload uses for Client/Account Managers (`HasExternalManagerDocumentAccessAsync`); `Download` log; then the shared download pipeline (scan, hash, `no-store`, `Blocked`). |
| W2-5 | Migration | `POST /api/denialworkflow/claim-documents/admin/migrate-to-blob?labId&batchSize=200&dryRun=true`, site admins only; same counters and rules as Wave 1. Existing rows have no SHA-256: record the hash computed at migration, and report those rows as `unverified` in the response. |
| W2-6 | React (`LRN.WebUI`) | Downloads in `denialWorkflowService.js` and the pages using `documentPermissions.js` show the API message for 409 / 423 instead of failing silently; any search that accepts patient names moves to a POST body. |
| W2-7 | Bicep | Add container `dwf-documents` (retention D1) to the shared template; API identity gets the same two container roles. |
| W2-8 | Tests | Unit: path never contains the claim ID; `uploadedBy` ignored; legacy path guard rejects a path outside the root; script parses. Functional/security: the Wave 1 F and S cases repeated for Denial Workflow, plus "Client Manager downloads a document on a claim not escalated to them → 404 and no file". |

**Done when:** `dotnet build`, ReportsApi tests and `npm run build` in `LRN.WebUI` succeed; UAT F/S cases pass; migration complete; `…\DenialWorkFlow\Uploads\{lab}` folders wiped with evidence.

## B6. Wave 3 — Generated reports and exports

Projects: `LRN.ReportWorker`, `LabMetricsDashboard`, `LRN.ReportsApi` (export job services), `LRN.ProductionReports`.

| # | Task | Detail |
| --- | --- | --- |
| W3-1 | Report store | `LRN.ReportWorker` writes finished workbooks through the shared store (`Services/LRN.PhiStorage`) to container `generated-reports` (prefix `rpt-{labId}`) instead of `E:\LRN-Data\GeneratedReports`. Temp files: write to a per-job folder under the worker's temp root and delete in `finally`. The queue row (`UserReqReports`) records container, path, SHA-256 and size. |
| W3-2 | Serving | `LabMetricsDashboard` `UserReportsController` streams through the store with the shared download pipeline (no Defender wait needed for files the worker generated — `RequireCleanMalwareScan = false` for this container, malicious still blocked), `no-store`, and writes a `ReportAccessLog` row (Download / Blocked) — new append-only table in LRNMaster. |
| W3-3 | Retention | Replace `RetentionDays` / `PurgeAfterDays` file deletion with the container lifecycle rule (D1, propose 90 days). The SQL queue rows and access log stay. |
| W3-4 | API exports | `ArWorkbenchExportJobService` and `DenialWorkflowExportJobService` write export files to `generated-reports` (prefix `exp-{labId}`); download endpoints use the pipeline and log access. `DenialWorkflowFileStorage:DownloadRootPath` is retired after migration. |
| W3-5 | In-memory exports | Excel exports that stream from memory (`workbook.SaveAs(stream)` in MVC controllers) stay as they are but **must** set `Cache-Control: no-store` — add one result filter in `LabMetricsDashboard` for every `FileResult`, and one in `LRN.ReportsApi`. `DashboardController` line ~3830 (`SaveAs(tempPath)`) moves to a `MemoryStream` or a per-request temp file deleted in `finally`. |
| W3-6 | Snapshots | Denial Summary / Denial Dashboard snapshot workbooks ("archived, never deleted") move to `generated-reports` under `snap-{labId}` with their own lifecycle rule (D1). |
| W3-7 | Tests | No report file left under the old roots after a run; download writes an access row; `no-store` on every file response (integration test over the MVC result filter). |

## B7. Wave 4 — Ingestion and file workers

Projects: `LRN.MasterFileProcessorWorker`, `LRN.DenialDatabaseWorker`, `CaptureDataApp`, `ClaimLineCSVDataCapture`, `CodingMasterGenerator`, `PredictionAnalysisApp`, `RcmWatcherService`, `Services\LRN.SharePoint*`, `Services\FolderRetentionCleanupWorker`.

These workers move large lab files through local folders on ReportEngine, and SharePoint (Microsoft 365, under the BAA) is their system of record. Moving every working folder to Blob is a larger redesign tied to the Azure Container Apps move, so this wave first contains the risk, then moves the archives.

| # | Task | Detail |
| --- | --- | --- |
| W4-1 | Encrypt and restrict | BitLocker on every ReportEngine volume holding `C:\LRN-Files` / `E:\LRN-Data` (Wave 6 evidence). NTFS ACLs on those roots: the service accounts and a named admin group only; remove `Users` / `Everyone`. Record the ACLs. |
| W4-2 | Inventory | Each worker's README states every folder it reads or writes, whether it holds PHI, and how long files stay. Add the table to `docs/operations/LRN_Services_Audit.docx`. |
| W4-3 | Archives to Blob | `MasterFileProcessorWorker` `LRN-RAWFILE\Archive` and `\Error`, and `DenialDatabaseWorker` outputs, are written to container `ingest-archive` (prefix `{worker}-{labId}`) through `LRN.PhiStorage` after processing, then removed locally. Working folders stay local until the Container Apps move. |
| W4-4 | Retention cleanup | `FolderRetentionCleanupWorker` logs every deletion (path relative to the root, size, time — no file contents) to a CSV kept ≥ 6 years, and uses secure deletion for PHI folders (overwrite, or rely on BitLocker + `cipher /w` monthly). |
| W4-5 | SharePoint | Confirm the SharePoint sites used by `LRN.SharePoint*` and the master-file processor are restricted to LRN staff and covered by retention labels; app registrations use certificates or federated credentials, not client secrets (secrets move to Key Vault in Wave 0 at minimum). |
| W4-6 | Logs | Workers log file names that often contain lab, patient or claim identifiers. Log a hash or the relative path only (B9 rule 1). |

## B8. Wave 5 — AI, agents and notifications

| # | Project | Task |
| --- | --- | --- |
| W5-1 | `LRN.AzBlobSync` | Replace the SAS secret (`lrn-threepillar-blob-sas`) and connection-string fallback with `DefaultAzureCredential` + `ManagedIdentityClientId` and a `BlobServiceUri`; remove `CreateClientFromSas` and the hard-coded account URL. Either harden `lrnbackupstorage01` to the B1 settings (private endpoint, shared key disabled, CMK, Defender, diagnostics) or move container `threepillar` into the platform PHI account (D4). |
| W5-2 | `LRN.AzBlobSync` | Azure OpenAI with Entra ID (`Cognitive Services OpenAI User` role) instead of `lrn-foundry-api-key`; disable key auth on the resource; private endpoint. Confirm the deployment is under the BAA and abuse-monitoring data handling is approved (D2). Send only the fields the insight needs (164.502(b)) — drop patient names and IDs before the prompt. |
| W5-3 | `LRN.AgentInterface`, `bridge`, MVC Reimbursement chat | Already managed identity for Foundry. Add: the chat screen warns users not to type patient identifiers; prompts and responses are not written to local logs; confirm the DAB bridge exposes only aggregate entities (no patient-level columns). |
| W5-4 | `LRN.Notification`, Teams webhooks, `DenialWorkflowIssueNotifier` | Messages carry IDs and counts only — never patient names, claim contents or exception messages that include SQL parameter values. Webhook URLs and SMTP credentials from Key Vault only (Wave 0). |

## B9. Wave 6 — Platform hardening

| # | Task |
| --- | --- |
| W6-1 | **SQL:** verify Transparent Data Encryption on every lab database and LRNMaster (`SELECT name, is_encrypted FROM sys.databases`); enable SQL auditing (or Azure SQL auditing) to Log Analytics; TLS-encrypted connections (`Encrypt=True`) in every connection string. |
| W6-2 | **Servers:** BitLocker evidence for API and ReportEngine hosts; Windows Defender on; RDP restricted. |
| W6-3 | **Logging:** review `FileLoggerProvider` users (API, MVC, workers) for PHI in messages; the React client-log endpoint must not record request bodies. Logs retained 30 days locally, forwarded to Log Analytics with ≥ 6-year retention for audit categories. |
| W6-4 | **Session:** confirm automatic logoff (164.312(a)(2)(iii)) — JWT lifetime and idle timeout in MVC and both React apps. |
| W6-5 | **Secure wipe** of each migrated folder (`cipher /w:<folder>` after deletion) with evidence, per D5. |
| W6-6 | **Alerts** in B12 for every module that gained an access log. |

## B10. Rules every project must keep (HIPAA guardrails)

1. No PHI in blob names, metadata, index tags, URLs, log messages, notification bodies or an access log `Detail` column — use document IDs, lab IDs and blob paths only.
2. No storage account keys, SAS tokens, connection-string passwords or API keys in code or tracked config. Managed identity first; Key Vault for anything that must remain a secret.
3. The browser never receives a storage URL; every PHI download goes through an app endpoint that checks access and logs it.
4. Every refused download after the access check writes a `Blocked` row.
5. No app permanently deletes a recorded PHI document; `DeleteAsync` is only for files whose SQL row was never written. Expiry is the storage lifecycle policy's job.
6. Every response that carries PHI as a file carries `Cache-Control: no-store`.
7. Existing access rules (lab access, `AppendScope`, client CIP-only, Client/Account Manager escalation rules) are never weakened.
8. Access logs are append-only and kept at least 6 years.

## B11. Rollout

| Step | Owner | Action | Gate |
| --- | --- | --- | --- |
| 1 | Compliance / Infra | D1–D6 decided; BAA confirmed; credentials from G10 rotated | Decisions recorded |
| 2 | Dev | Merge Wave 0 (`security/hipaa-phase0`) | CI green, secret scan green |
| 3 | Infra | Purge protection on `kv-lrnmetrics-prod`; register `Microsoft.Security`, `Microsoft.EventGrid`; API identity; PE subnet and private DNS zone; `az bicep build`, `what-if`, `create` | `publicNetworkAccess = Disabled`, `allowSharedKeyAccess = false`, `TLS1_2`; `Resolve-DnsName` from the API host returns a private IP |
| 4 | DBA | Wave 1: script 10 in every lab DB (or the regenerated merged script) | Constraint shows `Blocked`; trigger exists |
| 5 | Dev / QA | Wave 1 to DEV with `Provider = AzureBlob`, then UAT with the B13 tests | Upload → "still being scanned" → downloads within a minute; log shows `Upload`, `Blocked`, `Download`; compliance sign-off |
| 6 | Dev / Infra | Wave 1 production go-live | Audit rows for real uploads |
| 7 | Site admin | Wave 1 migration per lab: dry run, then batches of 200 until `examined = 0` | Counts match; problem IDs resolved |
| 8 | Infra | Secure-wipe `…\Uploads\ARWorkbench` with evidence (D5) | Evidence filed |
| 9 | All | Waves 2–6, each repeating steps 3–8 for its scope | Each wave's definition of done |

Useful commands:

```bash
az keyvault update -n kv-lrnmetrics-prod -g lrn-reporting-apps --enable-purge-protection true
az vm identity assign -g Development -n ReportEngine
az vm show -g Development -n ReportEngine --query identity.principalId -o tsv
az bicep build -f infra/arwb-document-storage/arwb-document-storage.bicep
az deployment group what-if -g lrn-reporting-apps -f infra/arwb-document-storage/arwb-document-storage.bicep -p @infra/arwb-document-storage/arwb-document-storage.parameters.json
az storage account show -n stlrnarwbphi -g lrn-reporting-apps --query "{public:publicNetworkAccess, sharedKey:allowSharedKeyAccess, tls:minimumTlsVersion, infraEnc:encryption.requireInfrastructureEncryption}"
```

## B12. Operations

Who accessed a claim's AR Workbench documents (lab DB):

```sql
SELECT l.AccessedOn, l.UserName, l.RoleCode, l.AccessType, l.Detail, l.ClientIp,
       d.DocumentId, d.DocumentSource, d.DocumentTypeName
FROM dbo.ARWB_DocumentAccessLog l
JOIN dbo.ARWB_Document d ON d.DocumentId = l.DocumentId
JOIN dbo.ARWB_Claim w ON w.ClaimKey = d.ClaimKey
WHERE w.ClaimID = @ClaimID
ORDER BY l.AccessedOn DESC;
```

Migration progress: `SELECT BlobContainer, COUNT(*) FROM dbo.ARWB_Document GROUP BY BlobContainer;` (Wave 2: same query on `dbo.DenialClaimDocuments`).

Storage access by anyone other than the app identities (Log Analytics):

```kusto
StorageBlobLogs
| where AccountName == "stlrnarwbphi" and TimeGenerated > ago(7d)
| where tostring(RequesterObjectId) !in ("<API principal ID>", "<Defender scanner ID>")
| summarize count() by tostring(RequesterObjectId), OperationName, StatusCode
```

| Alert | Condition |
| --- | --- |
| Malware found | Any Defender for Storage alert → Security + module owner |
| Unexpected storage caller | KQL above returns rows in 15 minutes |
| Bulk download | One user > 200 `Download` rows without a following `Blocked` in 1 hour (any module) |
| Integrity failure | Any Critical API log containing "integrity check failed" |
| Scan backlog | > 20 `Blocked` "Malware scan pending" rows in 1 hour |
| Audit tampering attempt | Any SQL error 51000 in the API logs or SQL audit |

Rollback:

| Situation | Action |
| --- | --- |
| Blob unreachable | Set `{Module}Documents:Provider = Local`, recycle the app; new files go to disk; Blob rows return 404 until storage is back |
| All downloads stuck "being scanned" | Fix the tag-reader role; with Security approval set `RequireCleanMalwareScan = false` (malicious files still blocked) and record a risk exception |
| Full code rollback | Avoid once documents exist in Blob (old code reads only local paths); roll forward |

## B13. Test plan

### Wave 1 functional (AR Workbench; repeat per module in Waves 2–3)

| ID | Case | Expected |
| --- | --- | --- |
| F-01 | Agent attaches a PDF with a document type on an own claim | Saved; `BlobContainer = arwb-documents`; blob exists |
| F-02 | Attach 5 files with different types and notes | All saved with their own type; claim activity rows |
| F-03 | Attach 6 files | 400 "Attach at most 5 files at a time." |
| F-04 | Attach a scanned `.tif` | Saved |
| F-05 | Rename `.exe` to `.pdf` | 400 "content does not match" |
| F-06 | Client user responds to a CIP case with 3 files | Saved as `CipResponse` |
| F-07 | Download a clean document | File saves; `Cache-Control: no-store` |
| F-08 | Download immediately after upload | 409 "still being scanned"; access log `Blocked`; works a minute later |
| F-09 | Document Vault search by patient name | Results as before; request is `POST documents/search`; no name in URL |
| F-10 | Download a document still on local disk | Works |
| F-11 | Migration dry run then real run | Counts match; migrated documents download |

### Security and HIPAA (all waves)

| ID | Case | Expected |
| --- | --- | --- |
| S-01 | User opens a document ID outside their scope (another agent's claim, another lab) | 404 |
| S-02 | Client user opens a non-CIP document ID | 404 |
| S-03 | Client user calls `POST claims/{claimKey}/documents` | 403 |
| S-04 | Upload EICAR test file as `.txt` | 423 for every role; Defender alert; `Blocked` row |
| S-05 | Overwrite a blob's bytes in DEV | 409 integrity failure; `Blocked` row; critical log |
| S-06 | `az storage blob list --auth-mode login` from outside the VNet | Refused |
| S-07 | `--auth-mode key` | Refused (shared key disabled) |
| S-08 | `UPDATE` / `DELETE` on any access log table | Error 51000 |
| S-09 | Search API, IIS and worker logs for a test patient name / file name | No matches |
| S-10 | Delete a blob in DEV and restore from soft delete | Restored |
| S-11 | KQL `StorageBlobLogs` for test blobs | Only the app identities and the Defender scanner appear |
| S-12 | `git grep` for `Password=`, `AccountKey=`, `sig=`, `webhook.office.com` in tracked files | No real values (Wave 0) |
| S-13 | Denial Workflow upload with a forged `uploadedBy` form field | Row shows the signed-in user (Wave 2) |
| S-14 | Generated report download | Access row written; `no-store`; file not on any server disk after the run (Wave 3) |

## B14. Definition of done

- [ ] Wave 0: credentials rotated; `security/hipaa-phase0` merged; CI secret scan in place.
- [ ] Wave 1: `dotnet build LRN.ReportsApi` and `npm run build` in `LRN.ARWorkbench` succeed *(done on the branch)*; Bicep built and deployed; script 10 in every lab DB; F and S tests pass in UAT with evidence; documents migrated; folder wiped; `GET documents` removed.
- [ ] Wave 2: Denial Workflow documents on Blob with access log; tests pass; folders wiped.
- [ ] Wave 3: generated reports and exports on Blob or in memory; every file response `no-store`; report access logged.
- [ ] Wave 4: ReportEngine volumes encrypted and restricted; archives on Blob; deletions logged.
- [ ] Wave 5: no SAS or API key left; AI prompts minimised; notifications PHI-free.
- [ ] Wave 6: TDE and SQL auditing verified; logs reviewed; alerts live.
- [ ] Decisions D1–D6 answered and recorded.
