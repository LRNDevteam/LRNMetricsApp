# RPT-01 — AR Follow-up Activity Detail: implementation notes

Implements RPT-01 from *Denial Workflow Management — AR Follow-up Reporting Requirements v1.0*
(section 3.1), and stands up the report catalog the rest of the suite will hang off.

Companion documents: `Denial_Workflow_AR_Reporting_Requirements_v1.0.pdf` (the specification) and
`Denial_AR_Reports_Data_Readiness_v1.0.html` (the gap audit this build works from).

---

## 1. What shipped

| Layer | Artefact |
| --- | --- |
| Schema (per lab DB) | `LRN.ReportsApi/Sql/ArReports/RPT01_ActivityDetail_Setup.sql` |
| API | `Controllers/ArReportsController.cs` — routes under `api/denialworkflow/reports` |
| Query | `Services/ArReports/SqlArActivityReportRepository.cs` |
| Export | `Services/ArReports/ArActivityReportExcelBuilder.cs` |
| Models | `Models/ArReportModels.cs` |
| React report | `LRN.WebUI/src/pages/reports/Rpt01ActivityDetailPage.jsx` |
| React catalog | `LRN.WebUI/src/pages/reports/ReportCatalogPage.jsx` |
| Tests | `tests/LRN.ReportsApi.Tests/ArActivityReportTests.cs`, `ArActivityReportExcelTests.cs` |

### Menu

`Reports` is now a parent with a submenu. **Report Catalog** is the old Reports landing page,
rebuilt to read `dbo.DenialReportCatalog`; **RPT-01 Activity Detail** is the live report. RPT-02 …
RPT-09 appear as disabled entries so the shape of the suite is visible without being reachable.
Activating a later report is a status change in that table plus its page — not a menu edit.

---

## 2. The activity spine

There is no single activity table. A qualifying activity (spec section 2.5) lives in one of three
places, so the report unions them and prefixes each id by source — the three tables have
independent identity sequences and a bare id would collide:

| Prefix | Source | Events |
| --- | --- | --- |
| `H:` | `dbo.DenialTaskHistory` | assignment, status update, manager response, write-off decision, closure |
| `N:` | `dbo.DenialClaimNotes` | work notes, follow-up scheduling |
| `E:` | `dbo.DenialClaimEscalations` | escalations raised |

**History rows with `ActionType = 'Escalation'` are excluded on purpose.** Raising one escalation
writes one `DenialClaimEscalations` row *and one history row per affected task*, so counting the
history rows would inflate "escalations raised" on every multi-line claim. The escalation record is
also the only place the reason, recipient and `EscalationId` actually live.

Passive navigation writes to none of the three, so the spec's exclusion of it holds for free.

---

## 3. Schema added

All additive. Every `ALTER` adds a nullable column (or a `bit` with a default), so each one is a
metadata-only change in SQL Server — no table rewrite, no long schema-modification lock, even on a
large `DenialTaskHistory`.

**Columns**

- `DenialClaimNotes`: `ContactMethod`, `FollowUpCategory`, `BalanceSnapshot`, `IsInternalOnly`
- `DenialTaskHistory`: `ContactMethod`, `BalanceSnapshot`
- `DenialClaimEscalations`: `UpdateSource`, `UploadBatchId`, `BalanceSnapshot`, `ClaimIdNormalized`

**Tables**

| Table | Why |
| --- | --- |
| `DenialActivityContactMethod` | Contact method is a required Activity column and configuration, not a constant in code. |
| `DenialFollowUpCategoryMaster` | Follow-up category, with the compliance group RPT-05 will separate on. |
| `DenialActionCompletionEvent` | `DenialTaskBoard.ActionCompleted` is a flag overwritten in place — no completed-by, no timestamp, no history. This is the immutable event the spec asks for, and the object RPT-04 is blocked on. Append-only: a correction is a new row with `AmendsCompletionEventId`, never an `UPDATE`. |
| `DenialReportRunLog` | FR-001 / NFR-003. One row per run; the run id on screen and in the workbook traces back to the exact filters and as-of instant. |
| `DenialReportSavedView` | Saved views, scoped to `(ReportCode, LabId, OwnerUserName)` so one can never cross a lab boundary. |
| `DenialReportCatalog` | Which reports exist and which are live, per lab. Status is set on INSERT only, so a redeploy cannot undo an operations decision. |

**Indexes**: `(LabId, event date)` on all three event tables. None of them had one — they are indexed
for per-claim reads, so a 90-day report previously scanned all three end to end.

Schema Pass A objects (`DenialStatusBucketMap`, `DenialAgingBucket`, `UpdateSource`/`UploadBatchId`
stamping) already shipped and are reused, not re-declared.

### Applying it

The repository applies this itself on first use of the report, per lab, once per process. Run
`Sql/ArReports/RPT01_ActivityDetail_Setup.sql` in a maintenance window if you would rather the
first user did not pay for the DDL. The script is parse-checked in CI (`DbaSetupScript_Parses`).

---

## 4. Requirement decisions worth knowing

**Due Status is an audit snapshot, not backlog.** Each row's due status is the state of the
follow-up date *that activity captured*, judged at the as-of instant. Current overdue workload is
RPT-05's job and must come from the latest open workflow record. The screen says so; so does the
export.

**Balance is a snapshot going forward, current before that.** Per-event balance could not be
reconstructed retrospectively — the task board is mutated in place — so notes now capture it at
write time. Rows that predate capture fall back to the current balance and are **marked** with `*`
on screen and `Current (not snapshot)` in the workbook. They are also counted on the Summary sheet.

**Balance worked is summed once per claim/analyst/activity date**, never once per note. Three notes
on one claim contribute one balance, not three.

**Action completion is labelled by its source.** Event-backed completions and completions read from
the current task-board flag are counted separately and distinguishable per row.

**Previous/New status stay blank unless the event *is* the status change** (spec section 4). A note
records the status it observed; that is kept as workflow-status context, not presented as a change.

**Manager and team come from `LRNMaster.dbo.LabUsers`,** which the lab-database query cannot join
to. A manager/team filter is resolved to a set of analyst user names *before* the query runs, so
paging stays correct; the columns are decorated in memory afterwards. There is deliberately no
"group by manager" — grouping by a dimension the query cannot see would silently group by something
else.

**Client-facing roles get masked notes, not missing rows.** Client Manager, Account Manager and Lab
User see `Restricted - internal note` in place of internal content. Masking rather than dropping
keeps the summary measures reconciling to the visible detail for every role. An escalation routed
*to* a Client or Account Manager is addressed to them and is not treated as internal.

**An unmapped status reads as `Unmapped`,** never dropped. A visible wrong bucket is correctable in
`DenialStatusBucketMap`; a row that vanished from every total is not.

---

## 5. Verification

`dotnet test tests/LRN.ReportsApi.Tests` — 176 tests. The RPT-01 ones cover:

- the generated T-SQL parsing under **every** grain / Latest-Activity-Only / grouping / analyst-scope
  combination, on both a fully migrated lab and one missing every optional column;
- the runtime schema batches and the DBA script parsing;
- the activity window rules (exclusive upper bound, defaults, inversion, 366-day cap);
- page-size clamping, including the raised export ceiling;
- role-based note visibility;
- the export workbook: sheets present, run metadata carried, and the Reconciliation sheet
  recomputing every measure from the detail rows with zero difference.

These prove the batch is well-formed and the arithmetic is right. **They do not touch a database.**
Before sign-off, run the spec's own acceptance test against one real lab:

> On a test claim, as one analyst on one day: add three notes, change status once, raise one
> escalation. Filter the report to that claim and date. Expect **5 activity events and 1 distinct
> claim-day worked**. Toggle Latest Activity Only — expect exactly one row. Export and confirm the
> Reconciliation sheet shows all zeroes. Repeat the status change through the CSV upload instead of
> the UI and confirm the two are distinguishable in the Source column.

Also worth checking on real data: that `DenialTaskBoard.Task`, `DateOfService` and `ClaimUID` are
actually populated for the lab in question. A nullable column that is null in every row fails a
report exactly as hard as a missing one.

---

## 6. Known limitations

- **Contact method is blank for historical activity.** The column exists and is written from the
  note save path; nothing backfills it, because the information was never captured.
- **`ActionCompleted` on rows without a completion event** reflects the *current* task-board flag.
  Once the completion event is written from the status-update path, RPT-04 becomes buildable and
  this fallback can be retired.
- **Original due date and reschedule count are derived** from note history (first due date, and the
  number of distinct due dates after it) rather than from a follow-up schedule table. That is
  accurate for RPT-01's audit purpose but is not the schedule-instance grain RPT-05 will need.
- **Exports run on the request thread**, capped at 100,000 rows. Beyond that the export belongs in
  the existing background job queue.
