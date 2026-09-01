# Denial Database Processor — Requirements Specification

**Component:** `LRN.DenialDatabaseWorker` (assembly `DenialDatabaseProcessorWorker`)
**Type:** .NET 8 Worker Service, installable as a Windows Service (`LRN - Denial Database Processor`)
**Status:** Reverse-engineered from the implementation as of 2026-09-01. Where the code and the
existing [README.md](../../LRN.DenialDatabaseWorker/README.md) disagree, this document follows the **code** and flags the drift in
§11.

---

## 1. Purpose and scope

### 1.1 Purpose

For each configured laboratory, the worker converts denied claim lines produced by the upstream
Payer Policy Validation process into three normalized denial tables inside that lab's own database,
and records the outcome centrally so the Report Control Board can display it.

It is an **enrichment and reconciliation** step, not a data-entry system: it reads denial rows,
resolves each denial code against a claim-action mapper workbook, derives an actionable task board,
and reconciles that board against the work humans have already done on the previous run.

### 1.2 In scope

- Selecting the run to process, per lab, from the central run log.
- Reading `PayStatus = 'Denied'` rows from each lab's `PayerValidationReport`.
- Denial-code normalization and mapper-driven enrichment.
- Building and reconciling `DenialInsight`, `DenialLineItem`, `DenialTaskBoard`.
- Central run logging and workflow-tracker outcomes in `LRNMaster`.
- Optional Excel/CSV/ZIP export package and optional SharePoint upload of it.

### 1.3 Out of scope

- Producing `PayerValidationReport` itself (upstream).
- Any user-facing workflow: assignment, closure and verification are performed elsewhere
  (LRN.ReportsApi / Denial Workflow React app). This worker only *preserves* those decisions.
- Task-board synchronization through the Denial Workflow API. Deliberately disabled — see §11.4.

### 1.4 Definitions

| Term | Meaning |
| --- | --- |
| **RunId** | Identifier of one upstream processing run, owned by `LRNMaster.dbo.LRN_Run_Log`. This worker never invents one. |
| **ClaimUID** | `{VisitNumber}_{AccessionNo}_{DateOfService:yyyyMMdd}` — the claim-level key used across denial tables. |
| **UniqueTrackId** | `{ClaimUID}\|{CPTCode}\|{DenialCode}` — the task-level identity that survives across runs. |
| **Lab database** | The per-lab SQL database (`CoveLRN`, `NWL_LRN`, …). Distinct from `LRNMaster`. |
| **Mapper** | `*Denial_Action_Classifier_v<major>.<minor>.xlsx`, sheet `Denial Classifier`. |
| **Generic code** | A denial code carrying no actionable meaning; stripped during normalization (§4.1). |

---

## 2. Context and interfaces

### 2.1 External dependencies

| Dependency | Direction | Purpose | Failure behaviour |
| --- | --- | --- | --- |
| `LRNMaster` (`ConnectionStrings:DenialDatabase`) | read/write | RunId lookup, run log, info log, workflow tracker | Startup throws if the connection string is absent; logging failures are swallowed (§7.4) |
| Lab database (per `LabDbConnectionKey`) | read/write | Source rows and all three output tables | Startup throws if the secret cannot be resolved |
| Azure Key Vault `kv-lrnmetrics-prod` | read | Every secret | Startup throws on an unreadable vault when `KeyVault:VaultUri` is set |
| Mapper workbook (file share) | read | Denial-code enrichment | Lab fails with `FileNotFoundException`; other labs continue |
| Microsoft Graph | write | SharePoint upload of the export package | Only reached when both file switches are on |
| Teams incoming webhook | write | Notifications | Currently inert — see §11.2 |

### 2.2 Trigger

The worker is not externally triggered. `ExecuteAsync` runs on host start and iterates the
configured labs in declaration order, sequentially.

---

## 3. Functional requirements — per-lab processing

Each lab is processed independently and in full isolation: **FR-1** an unhandled failure in one lab
must not prevent the remaining labs from being processed. The `try/catch` wraps exactly one lab.

The following steps execute in order for every lab.

### FR-2 — Resolve the run (Step 1)

Call `DenialDatabaseProcessor:RecentSuccessRunProcedure`
(`dbo.sp_GetRecentSuccessRunByLab`) in `LRNMaster` with `@LabName`.

- Discard rows with a blank `RunID` (log a warning).
- Keep only rows where `OverallStatus` equals `SUCCESS`, case-insensitively.
- The procedure matches `@LabName` with `LIKE '%name%'`, so more than one lab can return.
  **Prefer an exact case-insensitive `LabName` match**; fall back to all rows with a warning.
- Select the newest by `EndTimeIST`, tie-broken by descending `RunId`.
- **No successful run ⇒ return silently.** Not an error: both logging procedures reject a blank
  RunId, so there is nothing to log under.

### FR-3 — Idempotency guard (Step 2)

Query `dbo.ReportsWorkflowTracker` for `RunId + ReportName + Status = 'Success'`. A hit ⇒ skip the
lab entirely.

- The `Status = 'Success'` filter is **required**: without it a prior `Failed`, `Skipped` or
  `InProgress` row would block the retry that is precisely what is needed.
- A tracker read failure must return `false` (proceed), not abort. The `DenialAnalysisRunLog` check
  in FR-6 is the backstop against a genuine repeat.

### FR-4 — Open the audit trail (Step 3)

Before any work: write a `Start` row to `dbo.ReportRunIdInfoLog` and upsert the tracker to
`InProgress` with `StartedOn`.

### FR-5 — Confirm the run exists in this lab

Aggregate `PayerValidationReport` for the RunId, returning week folder, source path, last inserted
timestamp, total row count and denied row count.

- **FR-5.1** The fast path uses a bare `RunId = @RunId` predicate to stay sargable.
- **FR-5.2** On a miss, retry with `LTRIM(RTRIM(RunId)) = @RunId`, because `=` ignores *trailing*
  but not *leading* blanks. If that resolves, all subsequent data queries must use the **stored**
  spelling while the tracker and info log continue to use `LRNMaster`'s spelling. A divergence must
  be logged as a warning naming both values.
- **FR-5.3** Zero rows ⇒ complete as `Skipped` (§6.2), and the remark must list the most recent
  RunIds the table *does* hold, with row counts. A bare "no rows" is indistinguishable from a RunId
  mismatch, which is the usual cause.

### FR-6 — Duplicate-run guard

If the RunId already exists in `dbo.DenialAnalysisRunLog` ⇒ complete as `Skipped`.

### FR-7 — Resolve the mapper workbook

From the lab's `ClaimActionMapper` folder, select `*Denial_Action_Classifier_v*.xlsx` with the
highest `_v<major>.<minor>` suffix. A missing folder or no match is a **lab failure**, not a skip.

### FR-8 — Derive the output folder structure

Year / Month / Week are taken from `SourceFullPath` when it still carries the
`…\Year\Month\Week\File.xlsx` shape. Otherwise, parse the week-start date out of the `WeekFolder`
value (`02.06.2026 - 02.12.2026`), falling back to `InsertedDateTime`, and format as `yyyy` and
`MM.MMMM`. Week segments must be sanitized of invalid path characters.

### FR-9 — Load carry-forward state

Read existing tasks from **the lab's own** `dbo.DenialTaskBoard` where `LabId = @LabId`.

- **FR-9.1** The query must select only the ten columns the builder consumes. Selecting the full
  row drags two `NVARCHAR(MAX)` columns across the wire for every task the lab has ever
  accumulated — the cause of the production timeout described in §9.2.
- **FR-9.2** Key each row by `UniqueTrackId`, rebuilt from `ClaimUID|CPTCode|DenialCode`, falling
  back to the stored `UniqueTrackId` column. Rows that yield no key are dropped.

### FR-10 — Read the denied rows

`SELECT *` from the configured table where `LTRIM(RTRIM(PayStatus)) = @DeniedPayStatus`, restricted
to the run when `ProcessLatestRunOnly` is true.

- **FR-10.1** The RunId filter must be **composed into the SQL**, not expressed as
  `(@RunId IS NULL OR RunId = @RunId)`. The `OR` form forces one plan for both cases and abandons
  the index seek.
- **FR-10.2** Columns are re-keyed from SQL names to the legacy Excel header names so every
  downstream builder is unchanged (~100 mappings; `LabName → "Lab Name"`, `AccessionNo →
  "Accession No"`, …). Unmapped columns keep their SQL name.
- **FR-10.3** Run metadata and surrogate keys are excluded: `ReportId`, `FileLogId`, `WeekFolder`,
  `SourceFullPath`, `InsertedDateTime`, `LabName2`.
- **FR-10.4** `"Pat name"` must additionally be exposed as `"Patient Name"` (alias), because the
  line-item builder maps the two to different SQL columns.
- **FR-10.5** Values must be stringified exactly as the retired Excel reader did: dates as
  `MM/dd/yyyy` invariant, decimals without trailing zeros, booleans as `True`/`False`, nulls as
  empty string.
- **FR-10.6** Zero denied rows ⇒ complete as `Skipped`, with a remark distinguishing "the run has
  N rows but none denied" from "the run is absent".

### FR-11 — Normalize and enrich (§4)

### FR-12 — Derive ClaimUID

Set `ClaimUID` on every row per §1.4. A trailing `.00` must be stripped from the visit and
accession parts (they arrive as floats). All three parts blank ⇒ empty ClaimUID.

### FR-13 — Lab-specific insurance balance rule

For `LabId ∈ {18, 19, 20}` — or a `LabName` containing `Certus`, `Augustus`, `NorthWest`,
`Northwest` or `North West` — **`Insurance Balance` must be overwritten with `Billed Amount`**,
under both the display key (`Insurance Balance`) and the SQL key (`InsuranceBalance`).

This applies before insight aggregation, task-board construction, export and database load, so all
four agree.

### FR-14 — Build the insight table (§5)

### FR-15 — Build the task board (§4.4)

### FR-16 — Export package (optional)

Governed by `GenerateOutputFiles` (default `false`). When off, the worker is a pure SQL copy and
writes no files; the step must still be logged as `Skipped` with the reason. When on, write
`{RunId}_{LabName}_DenialAnalysisReport_{Week}.xlsx` plus line-item CSV and ZIP under
`{OutputRoot}\{Lab}\{Year}\{Month}\{Week}\`.

Only rows with a non-blank `DenialCode_Original` are exported as line items.

### FR-17 — Reconcile and load (§6)

### FR-18 — Record the run

Insert `RunId`, `LabId`, `SYSUTCDATETIME()` and the export package path into
`LRNMaster.dbo.DenialAnalysisRunLog`.

### FR-19 — SharePoint upload (optional)

Requires `GenerateOutputFiles` **and** `UploadOutputsToSharePoint` **and** a non-empty package path.
The destination is `{folder parsed from SharePointUploadPath}/{LabName}/{MMMM-yyyy}/{MMddyyyy}/`.

`SharePointUploadPath` is stored as an `AllItems.aspx?id=…` browser link; the server-relative folder
must be extracted from the URL-decoded `id` query parameter. A value already starting `/sites/` is
accepted as-is. An unparseable value is a lab failure.

### FR-20 — Close out

Upsert the tracker to `Success` with `RowCount` = the **DenialLineItem** row count, and write an
`End` info row.

---

## 4. Functional requirements — transformation rules

### 4.1 Denial-code normalization

Applied to the source `DenialCode` field:

1. Split on `,` or `;`, tolerating surrounding whitespace.
2. Remove all internal whitespace and hyphens (`CO 55`, `CO-55` → `CO55`).
3. Uppercase.
4. Drop these generic codes wherever they appear, including alone:
   `PR1 CO1 PI1 PR2 CO2 PI2 PR3 CO3 PI3 PR45 CO45 PI45 PR253 CO253 PI253`
5. De-duplicate, preserving first-seen order.

Three columns result:

| Column | Value |
| --- | --- |
| `DenialCode_Original` | the raw input, untouched |
| `DenialCode_Normalized` | the surviving codes joined with **`;`** |
| `DenialCode` (in place) | overwritten with the same `;`-joined value |

> The `;` separator is load-bearing: `TaskBoardBuilder` splits `DenialCode_Normalized` on `;`.

### 4.2 Mapper match precedence

For each surviving code, candidate mapper rows are those indexed under that code. Among them, the
first match wins, in this order:

1. Mapper `Coverage Status` **and** `ICD Compliance Status` are both N/A (`N/A`, `NA`, `BLANK` or
   blank).
2. Both normalized values equal the row's normalized `Coverage Status` / `ICD Compliance Status`.
3. Mapper coverage is N/A **and** the ICD values match.
4. The row's coverage is blank, mapper coverage is N/A, and the ICD values match.

No match ⇒ that code contributes nothing. Normalization for comparison strips every non-alphanumeric
character and lowercases.

`Denial Description`, `Denial Classification` and `Denial Type` are taken from the **first**
candidate row regardless of match — they describe the code, not the situation. Note that
`Denial Type` is populated from `DenialClassification`, not from a separate mapper column.

### 4.3 Multi-code value formatting

Enriched columns are aggregated across codes by **grouping equal values** and emitting
`CODE[, CODE…]: Value`, joined with `, `. Blank values are omitted.

> Example: two codes sharing a description and one differing produces
> `CO55, CO56: Missing documentation, CO97: Bundled service`.

Columns formatted this way: `Denial Description`, `Denial Classification`, `Denial Type`,
`Denial Validity`, `Action Code`, `Status Action Code`, `Recommended Action`, `Action Category`,
`Task Guidance`, `Short Category`, `Priority`, `SLA (Days)`, `Notes / Comments`.

`Recommended Action`, `Task Guidance` and `Notes / Comments` are additionally reduced to their
**last sentence** before grouping.

### 4.4 Task-board construction

One task row is produced **per (line row × denial code)**. Rows with a blank
`DenialCode_Normalized` are skipped.

| Rule | Requirement |
| --- | --- |
| Identity | `UniqueTrackId = ClaimUID\|CPTCode\|DenialCode`. Any part blank ⇒ the task is **dropped**. |
| Task ID | Carried forward from the existing task when one matches; otherwise `TSK-{counter:D5}` — see §11.5. |
| Date opened | Carried forward when the task existed; otherwise today. |
| Due date | `DateOpened + SLA(Days)` when SLA > 0, else null. |
| Value alignment | Where a column holds `CODE: Value` pairs, the value for *this* code is selected; a single common value applies to all codes; otherwise positional alignment, then first value. |
| Task text | Prefix stripped (`CO50:` / `RB:`), discarded if it equals the denial code, and falls back to `Recommended Action` when empty. |

**Status carry-forward** (this is what protects human work):

| Existing state | Resulting status |
| --- | --- |
| No existing task | `New` |
| Existing, `AssignedTo` set, old status `Closed` | `Closed` |
| Existing, `AssignedTo` set, any other status | `Review` |
| Existing, unassigned, old status `Closed` or `Review` | that status |
| Existing, unassigned, anything else | `New` |

`DateCompleted` is carried forward only for `Closed` tasks. `WorkFlowStatus` is carried forward, or
defaults to the computed status. Status comparison must tolerate non-breaking spaces, zero-width
spaces and stray newlines in the stored value.

**SLA status** — first matching rule:

| Condition | Value |
| --- | --- |
| Completed on or before the due date | `Met` |
| Open/New, not completed, past due | `Overdue` |
| Open/New, not completed, ≤ 3 days remaining | `Due Soon` |
| Open/New, not completed, > 3 days remaining | `On Track` |

Every task row is stamped `ClaimFrom = "Current Run"`, `IsCurrentDenial = true`, and the current
`LabId` / `LabName` / `RunId`.

---

## 5. Functional requirements — insight aggregation

Only rows with a non-blank `DenialCode_Normalized` participate. Rows group by the tuple
(`DenialCode_Normalized`, `Denial Description`, `Denial Type`, `Action Code`,
`Recommended Action`, `Task Guidance`).

| Measure | Definition |
| --- | --- |
| `# of Denial` | Line rows in the group |
| `# of Claims` | Distinct non-blank `Visit Number` |
| `Total Balance ($)` | Sum of `Insurance Balance`, 2 dp |
| `Highest $ Impact - Insurance` | The `PayerName Normalized` with the largest balance sum |
| `Ins. Balance ($)` | That payer's balance sum |
| `$ Impact (%)` | `Ins. Balance / Total Balance × 100`, or `0%` when the total is zero |
| `Observation` | First keyword found across `Notes / Comments`: `UTI` → `UTI Panel`, `Wound` → `Wound Panel`, `RPP` → `RPP Panel`, else `General` |

Output is sorted by `Total Balance ($)` descending, then `Ins. Balance ($)` descending.

---

## 6. Functional requirements — persistence

### 6.1 Reconciliation

Before any bulk copy, a single transaction against the **lab** database reconciles the previous
state with the current run. Two temp tables (`#CurrentTaskKeys`, `#CurrentClaimUIDs`) carry the
current run's identities and are indexed before use. Every statement runs with **no command
timeout**.

Ordered effects:

1. Record `ClaimUID`s of currently **unassigned** tasks into `#DeletedUnassignedClaimUIDs`.
2. Delete `DenialLineItem` rows whose claim has a `Closed` task.
3. Delete `Closed` tasks.
4. For assigned, non-closed tasks **absent from the current run**: insert a
   `Verification Pending` row into `dbo.DenialVerification` — guarded by `OBJECT_ID` and
   `COL_LENGTH` checks so the statement is a no-op where the table is absent, and de-duplicated on
   `ClaimUID + UniqueTrackId + RunId`.
5. Update those same tasks to `WorkFlowStatus = 'Verification Pending'`, `ClaimFrom = 'Old Run'`,
   `IsCurrentDenial = 0`, `RunId = @RunId`.
6. Update their line items to `ClaimFrom = 'Old Run'`, `WorkFlowStatus = 'Verification Pending'`.
7. Delete line items for current-run claims not marked `Old Run`, and all line items for
   previously-unassigned claims.
8. Delete tasks that are unassigned, closed, or present in the current run — they are about to be
   re-inserted.

**The net requirement: after reconciliation the board retains only assigned, non-closed tasks that
did not recur in this run.** Everything else is deleted and rewritten from the bulk copy.

Task matching in every statement accepts either the stored `UniqueTrackId` or a `CONCAT` rebuilt
from `ClaimUID|CPTCode|DenialCode`, so rows written before `UniqueTrackId` existed still match.

A failure must roll back; an `InvalidOperationException` from the rollback itself is swallowed so
the original reconcile exception surfaces (SQL Server may already have aborted the transaction).

### 6.2 Bulk load

Three writers, each against the lab connection, each driven by a JSON mapper deployed beside the
executable:

| Table | Mapper |
| --- | --- |
| `dbo.DenialInsight` | `MapperJon/DenialInsightMapper.json` |
| `dbo.DenialLineItem` | `MapperJon/DenialLineItemMapper.json` |
| `dbo.DenialTaskBoard` | `MapperJon/DenialTaskBoardMapper.json` |

Column mapping resolves the SQL column name first, then the Excel/display name. **At least one
mapping must resolve or the writer throws.** `SqlBulkCopy` uses `TableLock | CheckConstraints`,
batch size 500 000, no timeout.

Value coercion before load: percentage strings lose the `%` and become decimals; `PaymentDays` /
`Payment Days` accept integers only (a date or anything else becomes `NULL`); blank becomes `NULL`.

### 6.3 Run-logging contract (LRNMaster)

All central writes go through stored procedures — never direct table writes.

| Step | Procedure | Notes |
| --- | --- | --- |
| Get RunId | `dbo.sp_GetRecentSuccessRunByLab` | §FR-2 |
| Progress trail | `dbo.usp_ReportRunIdInfoLog_Insert` | `Start` / `Info` / `Warning` / `Error` / `End` |
| Outcome | `dbo.usp_ReportsWorkflowTracker_Upsert` | Idempotent on RunId + Lab + Report; called twice by design |

`@ReportName` must match `dbo.ReportTypeMaster` character for character. `@LabId` and `@WeekFolder`
are deliberately **omitted** — the procedure resolves both from the RunId. `@Remarks` is truncated
to 400 characters and flattened to one line; the full exception text belongs in the info log.

Outcomes:

| Status | When |
| --- | --- |
| `Success` | All three tables loaded |
| `Skipped` | No rows for the run, no denied rows, or already in `DenialAnalysisRunLog` — always with a reason |
| `Failed` | The pass threw; one-line `{ExceptionType}: {message}` in remarks |

**A tracker row must always exist.** An absent row is indistinguishable from a crashed process, so
even a decision to do nothing is recorded.

---

## 7. Non-functional requirements

### 7.1 Configuration and secrets

`appsettings.json` holds **no secrets** and is safe to commit. Provider order in `Program.cs`:

```
appsettings.json  →  Azure Key Vault  →  appsettings.Secrets.json  →  environment
```

Vault secret names replace `:` with `--`. Required secrets:

| Secret | Key |
| --- | --- |
| `ConnectionStrings--DenialDatabase` | `LRNMaster` |
| `ConnectionStrings--<LabDbConnectionKey>` | one per lab |
| `DenialDatabaseProcessor--SharePoint--TenantId` / `--ClientId` / `--ClientSecret` | Graph app registration |

- **NFR-1** Each lab's connection string is resolved at startup from `LabDbConnectionKey`. A
  literal `LabConnectionString` in configuration wins, for throwaway local overrides only.
- **NFR-2** An unresolvable key must throw at **startup**, naming the lab, the `LabId` and the exact
  vault secret to create — not fail later inside a repository.
- **NFR-3** Authentication is `DefaultAzureCredential`; the identity needs **Key Vault Secrets User**
  on the RBAC-enabled vault.
- **NFR-4** `KeyVault:VaultUri = ""` must skip the vault entirely and fall back to file and
  environment configuration.
- **NFR-5** The content root must be `AppContext.BaseDirectory`, not the process working directory
  — a Windows Service starts in `System32` and would otherwise find no configuration files.

### 7.2 Settings reference

`DenialDatabaseProcessor` section:

| Key | Default | Purpose |
| --- | --- | --- |
| `RunOnceOnStartup` | `true` | One pass over all labs, then stop. `false` loops on `IntervalMinutes` — see §11.1 |
| `OutputRoot` | `C:\LRN-Files\Automation\LRN-Output\DenialDatabase` | Export root |
| `LogCsvPath` | `…\LRN-Logs\DenialDatabaseProcessor_Log.csv` | Step log |
| `PayerValidationReportTable` | `dbo.PayerValidationReport` | Must be `schema.table`; validated and bracket-quoted |
| `DeniedPayStatus` | `Denied` | The only status imported |
| `ProcessLatestRunOnly` | `true` | `false` reads every denied row, stamped with the current RunId |
| `GenerateOutputFiles` | `false` | Master switch for xlsx/csv/zip |
| `UploadOutputsToSharePoint` | `false` | Ignored when the above is false |
| `ReportName` | `Denial Report` | Must match `dbo.ReportTypeMaster` exactly |
| `ReportLogCreatedBy` | `Denial Database Processor` | Process identity, never a person |
| `RecentSuccessRunProcedure` | `dbo.sp_GetRecentSuccessRunByLab` | |
| `SqlCommandTimeoutSeconds` | `600` | Lab copy path; `0` = unlimited |
| `SharePoint:Enabled` / `:SiteUrl` | | Graph target |

`Labs[]` entries: `LabName`, `LabId`, `LabDbConnectionKey`, `ClaimActionMapper` (folder),
`SharePointUploadPath`. (`PayerPolicyFile` is retained but unused — §11.6.)

### 7.3 Performance

- **NFR-6** Every statement in the lab copy path must run with an explicit command timeout.
  ADO.NET's implicit 30 s is unusable here: these tables grow without bound and the largest lab
  reads its entire task board in one statement.
- **NFR-7** `GetExistingTasksAsync` must remain narrow (ten columns). Adding a column requires
  updating the covering index in `Sql_Add_Denial_Performance_Indexes.sql` or the query reverts to a
  base-table scan.
- **NFR-8** Reader ordinals are resolved once per query, not per field per row.
- **NFR-9** Supporting indexes are **not** applied automatically. `Sql_Add_Denial_Performance_Indexes.sql`
  must be reviewed and applied per lab database during a maintenance window.

### 7.4 Observability and resilience

- **NFR-10** Logging must never break processing. Both central loggers and the CSV step logger
  swallow their own exceptions and fall back to the host logger.
- **NFR-11** The failure path uses `CancellationToken.None`, so a host shutdown cannot leave the
  tracker stranded on `InProgress`.
- **NFR-12** **No patient data in any log message.** Counts, file names, table names, RunIds and
  durations only — never names, DOBs, addresses, member/policy numbers or SSNs.
- **NFR-13** The CSV step log is serialized by a process-wide semaphore, appends with
  `FileShare.Read`, auto-detects the legacy 9-column header versus the current 10-column format,
  and never passes the cancellation token to the write itself (partial lines are worse than a
  missing one).

### 7.5 Deployment

Publish framework-dependent `win-x64`; install with `sc.exe create "LRN - Denial Database
Processor"`. Console and Windows Event Log providers are registered; the default provider set is
cleared.

---

## 8. Data contracts

### 8.1 Input — `dbo.PayerValidationReport` (lab database)

Wide table written by the upstream Payer Policy Validation process. Required columns for this
worker: `RunId`, `PayStatus`, `WeekFolder`, `SourceFullPath`, `InsertedDateTime`, plus the ~100
data columns mapped in §FR-10.2. Critical fields: `DenialCode`, `VisitNumber`, `AccessionNo`,
`CPTCode`, `DateOfService`, `InsuranceBalance`, `BilledAmount`, `PayerNameNormalized`,
`CoverageStatus`, `ICDComplianceStatus`.

### 8.2 Input — mapper workbook

Sheet `Denial Classifier`. Header matching is fuzzy: alphanumeric-only, lowercased, and accepts
equality, prefix **or substring**. Recognized columns: `Denial Code` / `Denial Code_Prefix`,
`Denial Description`, `Denial Classification`, `Coverage Status`, `ICD Compliance Status`,
`Denial Validity`, `Action Code` / `Status Action Code`, `Recommended Action`, `Action Category`,
`Task` / `Task Guidance`, `Short Category`, `Priority`, `SLA (Days)`, `Notes / Comments`.

Rows without a denial code are skipped. A blank ICD compliance status is indexed as `N/A`.

### 8.3 Output tables (lab database)

| Table | Grain |
| --- | --- |
| `dbo.DenialInsight` | One row per denial-code/action grouping |
| `dbo.DenialLineItem` | One row per denied line with a non-blank original denial code |
| `dbo.DenialTaskBoard` | One row per (line × denial code) |
| `dbo.DenialVerification` | One row per task that disappeared from the run while assigned |

`Sql_Add_DenialTaskBoard_NewColumns.sql` is the idempotent forward migration: it adds `ICDCodes`,
`CoverageStatus`, `ICDComplianceStatus`, `DenialValidity`, `ClaimUID`, `WorkFlowStatus`,
`ClaimFrom`, `Units`, `Modifier`, `Source`, `PatName`, `SubscriberId` to the task board;
`ClaimUID`, `AssignedTo`, `WorkFlowStatus`, `ClaimFrom`, `Source`, `PatName`, `SubscriberId` to
line items; and creates `DenialVerification` when absent.

### 8.4 Output — step log CSV

`LabName, LabId, StepDescription, LogType, PayerPolicyFilePath, ClaimActionMapperFilePath,
PolicyActionMapperFilePath, ErrorInfo, LogDateTime, OutputPath`

`PayerPolicyFilePath` now carries the SQL source label, e.g.
`NWL_LRN.dbo.PayerValidationReport (RunId=…, PayStatus=Denied, Rows=…)`.

---

## 9. Operational requirements

### 9.1 Verifying a run

```sql
SELECT RunId, LabName, ReportName, Status, [RowCount], StartedOn, CompletedOn, Remarks
FROM   dbo.ReportsWorkflowTracker
WHERE  RunId = 'R20260805INH0073'
ORDER  BY ReportName;

SELECT LogType, LogMessage, CreatedOn
FROM   dbo.ReportRunIdInfoLog
WHERE  RunId = 'R20260805INH0073' AND ReportType = 'Denial Report'
ORDER  BY ReportRunIdInfoLogId;
```

A correct pass shows a `Start`, at least one `Info`, an `End`, and exactly one tracker row that is
no longer `InProgress`.

### 9.2 Known failure mode — "Execution Timeout Expired" on one lab

Observed on Certus, August 2026, in `GetExistingTasksAsync`. Three causes, all addressed: the
implicit 30 s timeout, a 34-column select including two `NVARCHAR(MAX)` columns, and no index on
`DenialTaskBoard (LabId)`. It surfaces on the largest lab first because that read grows with
everything the lab has ever accumulated, not with the size of the current run.

If it recurs: identify the statement from the info log / `LRN_Error_Log` / step CSV, size the tables
per §NFR-9's sizing queries, then review indexes. Raising the timeout stops the exception; indexes
are what make it fast.

---

## 10. Traceability

| Requirement | Implementation |
| --- | --- |
| FR-1 … FR-20 | [Worker/DenialDatabaseWorker.cs](../../LRN.DenialDatabaseWorker/Worker/DenialDatabaseWorker.cs) `ProcessLabAsync` |
| FR-2 | [Services/ReportLogging/RecentSuccessRunProvider.cs](../../LRN.DenialDatabaseWorker/Services/ReportLogging/RecentSuccessRunProvider.cs) |
| FR-3, FR-20, §6.3 | [Services/ReportLogging/ReportsWorkflowTrackerRepository.cs](../../LRN.DenialDatabaseWorker/Services/ReportLogging/ReportsWorkflowTrackerRepository.cs) |
| FR-4, §6.3 | [Services/ReportLogging/ReportRunIdInfoLogger.cs](../../LRN.DenialDatabaseWorker/Services/ReportLogging/ReportRunIdInfoLogger.cs) |
| FR-5, FR-10 | [Services/PayerValidationReportRepository.cs](../../LRN.DenialDatabaseWorker/Services/PayerValidationReportRepository.cs) |
| FR-6, FR-18 | [Services/DenialAnalysisRunLogRepository.cs](../../LRN.DenialDatabaseWorker/Services/DenialAnalysisRunLogRepository.cs) |
| FR-7, FR-8 | [Services/FileResolver.cs](../../LRN.DenialDatabaseWorker/Services/FileResolver.cs) |
| FR-9, §6.1 | [Services/DenialTaskBoardRepository.cs](../../LRN.DenialDatabaseWorker/Services/DenialTaskBoardRepository.cs) |
| §4.1 | [Normalizers/DenialCodeNormalizer.cs](../../LRN.DenialDatabaseWorker/Normalizers/DenialCodeNormalizer.cs) |
| §4.2, §4.3 | [Builders/DenialDatabaseBuilder.cs](../../LRN.DenialDatabaseWorker/Builders/DenialDatabaseBuilder.cs) |
| §4.2 matching | [Normalizers/CoverageIcdNormalizer.cs](../../LRN.DenialDatabaseWorker/Normalizers/CoverageIcdNormalizer.cs) |
| §4.4 | [Builders/TaskBoardBuilder.cs](../../LRN.DenialDatabaseWorker/Builders/TaskBoardBuilder.cs) |
| §5 | [Builders/DenialInsightBuilder.cs](../../LRN.DenialDatabaseWorker/Builders/DenialInsightBuilder.cs) |
| §6.2 | [BulkWriters/BulkWriterBase.cs](../../LRN.DenialDatabaseWorker/BulkWriters/BulkWriterBase.cs), [Builders/DenialLineItemTableBuilder.cs](../../LRN.DenialDatabaseWorker/Builders/DenialLineItemTableBuilder.cs) |
| FR-19 | [Services/SharePoint/SharePointUploader.cs](../../LRN.DenialDatabaseWorker/Services/SharePoint/SharePointUploader.cs), [Services/SharePoint/SharePointGraphClient.cs](../../LRN.DenialDatabaseWorker/Services/SharePoint/SharePointGraphClient.cs) |
| §7.1 | [Program.cs](../../LRN.DenialDatabaseWorker/Program.cs) |
| §8.2 | [Services/ClaimActionMapperIndex.cs](../../LRN.DenialDatabaseWorker/Services/ClaimActionMapperIndex.cs) |
| §8.4, NFR-13 | [Services/CsvStepLogger.cs](../../LRN.DenialDatabaseWorker/Services/CsvStepLogger.cs) |

---

## 11. Open issues and drift

> **Superseded in part.** Items 11.1, 11.2, 11.5, 11.6 and the `LabId` half of 11.7 were fixed
> when the Rev 3.1 architecture spec was implemented; see
> [Sql_Spec_R31_Migration.sql](../../LRN.ReportsApi/Sql/DenialChanges/01_Denial_Spec_R31_Migration.sql) and §12 below for what remains. 11.3,
> 11.4, 11.8 and 11.9 still stand. The findings are kept here because they record why the code
> looks the way it does.

**11.1 `IntervalMinutes` has no configured value.** `ProcessorOptions.IntervalMinutes` is a `double`
with no initializer and is absent from `appsettings.json`, so it binds to `0`. Setting
`RunOnceOnStartup = false` today produces `Task.Delay(TimeSpan.FromMinutes(0))` — a continuous hot
loop over every lab. The continuous-mode path is effectively unusable until a default and a
configured value exist.

**11.2 Teams notifications are inert.** `TeamsWebhookNotifier.TeamsNotificationOptions` is never
`Configure<>`d in `Program.cs`, so `TeamsNotification:Enabled` and the webhook URL in
`appsettings.Secrets.json` are read by nothing. Already noted in the README; binding it would start
sending messages that are not being sent today, so it is a deliberate deferral rather than an
oversight.

**11.3 The rebill "Closed" rule never reaches the task board.** `DenialDatabaseBuilder` computes
`Task Status` (`Open`/`Closed`) from the rebill action code and the
`FirstBilledDate > ExpectedPaymentDate` test, but `TaskBoardBuilder` starts from its own `"New"` and
never reads that column, and the insight builder does not use it either. The column is written to
the enriched row and then dropped.

**11.4 Dead workflow-API path.** `IDenialWorkflowApiClient` is registered and injected into the
worker but never called; `BuildWorkflowImportRequest` (≈50 lines) is unreferenced. Task-board rows
are bulk-copied directly instead, deliberately, to avoid duplicates and a hard dependency on
LRN.ReportsApi being up.

**11.5 Task ID collision risk.** `newTaskCounter` restarts at `1` for every lab pass, so a task
created in run 2 can be issued `TSK-00001` while a surviving task from run 1 already holds it.
`TaskID` is not the identity key (`UniqueTrackId` is), so this does not corrupt reconciliation, but
it makes `TaskID` unsafe as a human-facing reference.

**11.6 Dead configuration and members.** `Labs[].PayerPolicyFile` and
`FileResolver.GetLatestPayerPolicyFile` survive from the retired workbook-based source and are
unreferenced. `ProcessorOptions.DatabaseConnectionString` is commented "REQUIRED BY BULK WRITERS"
but is never set or read — the writers take the lab connection string via constructor.
`ProcessorOptions.Configuration` is populated in `PostConfigure` and never read.
`NotifyFileSynchronizedAsync` / `NotifyFileUploadFailedAsync` are private and uncalled.

**11.7 `LabId` disagrees with LRN.MasterFileProcessorWorker.** Four labs differ: PCR_Dx_AL (7 here,
6 there), PCR_Dx_CO (8 / 7), Augustus Labs (19 / 24), NorthWest (20 / 23). The mapping here was made
by database name, which is unambiguous. Because §FR-13 keys the insurance-balance rule off
`LabId ∈ {18,19,20}`, this divergence is load-bearing — reconciling the ids requires updating that
rule in the same change.

**11.8 `LRNMaster` is reachable under two secret names.** `ConnectionStrings--DenialDatabase` here
and `ConnectionStrings--DefaultConnection` in the Master File Processor point at the same database
and must be rotated together. Consolidating means renaming six `GetConnectionString("DenialDatabase")`
call sites.

**11.9 README drift.** The README states mapped columns are written as `CODE - Value` joined with
comma+space; the code emits `CODE: Value` (§4.3). It also describes normalization as splitting "by
comma" and joining with comma, while `DenialCode_Normalized` is joined with `;` (§4.1). The README's
step 3 column list also omits `Denial Validity`, `Action Category`, `Short Category`, `Priority`,
`SLA (Days)` and `Notes / Comments`, which the builder does populate.

---

## 12. Deviations from the Rev 3.1 architecture spec

Recorded where the implementation and the spec disagree, and why.

**12.1 The archive is `dbo.DenialClosureLog`, not `dbo.DenialClosedClaims` (§3.3, MG-01).**
A table of the spec's name already exists, created per lab by `LRN.ReportsApi`. It is claim-grain
with `UNIQUE(LabId, ClaimId)` and backs the reviewer close-claim feature together with
`DenialClosedClaimsHistory`. The spec's archive is denial-event grain and append-only — AR-05
requires several rows per `UniqueTrackId` — which that unique index forbids. Renamed rather than
merged; the existing table is untouched. **The spec needs an erratum.**

**12.2 MG-08 and MG-09 are not needed.** The B1 bucket archives every closed task immediately
before deleting it, so the first run under these rules preserves that history by itself. The
one-way door is gone.

**12.3 RC-11 (B4, carried + assigned) is NOT implemented.** The spec says a recurring assigned task
is updated in place, preserving `ReviewerComments`, `ReviewerUpdatedOn/By` and the workflow app's
own columns. The load path bulk-copies into `DenialTaskBoard` after deleting everything in the
current run, so those columns are lost and re-defaulted on every pass — a real data-loss bug that
RC-11 exists to fix. `TaskBoardBuilder` carries forward `TaskID`, `DateOpened`, `DateCompleted`,
`Status`, `AssignedTo` and `WorkFlowStatus`, so the *workflow state* survives; anything the builder
does not know about does not. Fixing it properly means bulk-copying to a staging table and MERGEing
into the board, which also delivers RC-02's single transaction across reconcile **and** load.
Deliberately out of scope here — it is a load-path refactor, not a rule change.

**12.4 §6.2 ships disabled.** `EnableResubmissionCheck` defaults to `false` pending confirmation of
the line-level table name and grain (spec §12.1). The code is written and probed; enabling it is a
config change. `FirstBilledDate` is read from the task board rather than `DenialLineItem` — same
value, one fewer join.

**12.5 Verification dedupe key.** VF-03 specifies `ClaimUID + UniqueTrackId + RunId`. `ClaimUID` is
not in the guaranteed base schema of `dbo.DenialVerificationTask`, so the implementation uses
`UniqueTrackId + MissingDetectedRunId`. `UniqueTrackId` embeds the `ClaimUID`, so the key is no
weaker, and `MissingDetectedRunId` is the column that actually carries the run in which the denial
went missing.

**12.6 DD-07 governs `Status`, not `WorkFlowStatus`.** There are two status axes in the live
system. `DenialTaskBoard.Status` follows `dbo.DenialStatusMaster`, which seeds exactly the seven
human statuses D-4 builds on; the three system statuses were added to it. `WorkFlowStatus` carries
the workflow app's escalation vocabulary (`Internal Escalation`, `Response Escalation`,
`Closed Claim`, `Assigned To AR Reviewer`, `WriteOffApproved`, …) and is untouched. DD-07's "no
component may introduce an eleventh" must not be read as applying to that second axis, or it
deletes working features.

**12.7 RC-13 vs. the shipped API.** The worker keeps an orphaned assigned task on the board flagged
`Verification Pending`, as RC-13 requires. `LRN.ReportsApi.MoveActiveToVerificationAsync` still
deletes the task from the board on the reviewer-triggered duplicate path. Two entry points, two
lifecycles — documented, not reconciled, by decision.

**12.8 Existing-but-unassigned closed tasks keep `Closed`.** §4.9 sends existing + unassigned to
`New` regardless of status, which is only safe because §7 archives closed denials first. Carry-
forward runs against a snapshot taken *before* reconciliation, so `Closed` is short-circuited to
avoid resurrecting finished work inside the same pass.

