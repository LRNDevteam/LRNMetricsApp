# Report Control Board

The landing page at **`/ReportBoard`** ("Home Dashboard" in the navbar). One row per lab showing
every report produced by that lab's latest run, with each green cell linking straight to the report
and each red cell linking to the error log for that run.

The original Home page (`/Home/Index`, the file-probing lab tiles) is unchanged and still reachable —
this is a second landing page, not a replacement.

## Where the data comes from

```
LRNMaster
  └─ dbo.usp_ReportsWorkflowTracker_Pivot @Mode = 'Latest'
        │  one row per lab; 4 fixed columns + N report columns
        ▼
LRN.ReportsApi   ReportAuditLogService.GetRunsAsync   →  GET /api/report-board/latest
        ▼
LabMetricsDashboard   ReportBoardApiClient (2-minute IMemoryCache)
        ▼
ReportBoardController.Index → Views/ReportBoard/Index.cshtml
```

The SP returns `Lab`, `Synced on`, `RunID`, `Week`, then **one column per row of
`dbo.ReportTypeMaster`**. Report types are data, so the column list is discovered from the reader
schema at runtime — nothing in this feature hard-codes 14 columns or their order.

`GET /api/report-board/run-errors` backs the error page, reading `dbo.LRN_Error_Log` (pipeline
failures: step, error code, recommended action, owning team) and the `Error` rows of
`dbo.ReportRunIdInfoLog` (per-report messages).

## Adding a report type

Three steps, in order. Step 1 alone is enough for the report to *appear*; steps 2–3 make it
clickable.

### 1. Add the report type to the tracker (SQL, no code)

```sql
INSERT dbo.ReportTypeMaster (ReportTypeName, IsActive, DisplayOrder)
VALUES (N'Cash Posting Summary', 1, 15);
```

The board picks it up on the next cache expiry (2 minutes) as a **status-only column**: the header is
the raw column name, cells show Success / Failed / not-configured, and nothing is clickable. This is
the deliberate fallback — a new report type never breaks the page.

### 2. Map it to a page — `LabMetricsDashboard/Services/ReportCatalog.cs`

Add one entry to `ReportCatalog.Entries`, in the position you want it displayed:

```csharp
new("Cash Posting Summary",   // TrackerColumn — must match ReportTypeName EXACTLY (the join key)
    "Cash Posting Summary",   // DisplayName   — tooltips, cards, drawer
    "Cash",                   // ShortName     — matrix column header, keep it ~8 chars
    "bi-cash-coin",           // Icon          — bootstrap-icons class
    GroupSummary,             // Group         — GroupSource | GroupSummary | GroupAnalytics
    "CashPosting",            // Controller    — null for status-only
    "Index",                  // Action        — null for status-only
    "EnableCashPosting"),     // FeatureFlag   — a bool property name on LabCsvConfig, or null
```

Entries are displayed in catalog order (not SP order); unknown columns are appended after them.
Group order in the list drives the coloured band row above the matrix, so keep same-group entries
adjacent.

### 3. Add the feature flag (only if the report is per-lab optional)

`FeatureFlag` is the **property name** of a `bool` on `LabCsvConfig`, resolved reflectively. A test
(`Every_catalog_flag_is_a_real_bool_property_on_LabCsvConfig`) fails if you name a flag that does not
exist, so a renamed flag cannot silently disable a column. `null` means the page is always available.

### 4. Menu access

The link is also gated on `IMenuService.CanAccessAsync` for the target route. If the new page is
managed by the menu master, map it in **Admin → Role Menu Mapping**, or the cell renders as
"Ready but not available to you" (purple) for roles without the mapping.

## When is a cell clickable?

A cell links to its report only when **all four** hold:

1. the tracker status is `Success`;
2. the catalog entry has a Controller *and* Action;
3. the lab's `FeatureFlag` on `LabCsvConfig` is true (or the entry has no flag);
4. the signed-in user's role can reach that route.

Otherwise it renders as a non-link with `BlockedReason` as the tooltip. `Failed` cells always link to
`/ReportBoard/RunErrors`.

| Cell | Meaning |
|---|---|
| green | Success — opens the report with `?lab=…&runId=…` |
| red | Failed — opens the run's error log |
| amber | Pending / In Progress |
| purple | Success, but no route, flag off, or role not permitted |
| grey | Not produced for this lab |

## Lab name resolution

The tracker writes the pipeline's display name (`PCR Labs of America`); every `?lab=` route wants the
`LabSettings` config key (`PCRLabsofAmerica`). `LabNameResolver` tries, in order:

1. exact key match (case-insensitive);
2. squashed match — spaces, `_`, `.` and `-` removed from both sides;
3. `LabCsvConfig.DbLabName`.

No match logs a Warning and the row renders read-only with an "unmapped" badge (admins only — for
anyone else the row is hidden, since we cannot prove the lab is theirs). All 12 current labs are
covered by a test.

## Caching and failure

- 2-minute `IMemoryCache` entry, key `ReportBoard_Latest`. `?refresh=1` bypasses it.
- The last good copy is kept for 12 hours under `ReportBoard_LastGood`.
- A tracker outage never 500s: the page shows an error card with the reason, the timestamp of the
  stale copy it is displaying, and a Retry link.

## Security

- `/api/report-board` is listed in the auth middleware allow-list in `LRN.ReportsApi/Program.cs`.
  **Any path not in that list runs unauthenticated** — do not add sibling routes outside it.
- Row-level: admins see every lab; everyone else sees only labs on their `LabName` claims.
- Link-level: the four conditions above.

## Files

| File | Role |
|---|---|
| `LRN.ReportsApi/Controllers/ReportBoardController.cs` | API: `latest`, `run-errors` |
| `LRN.ReportsApi/Services/ReportAuditLogService.cs` | SP calls + dynamic column discovery |
| `LabMetricsDashboard/Services/ReportCatalog.cs` | tracker column → route map |
| `LabMetricsDashboard/Services/LabNameResolver.cs` | display name → config key |
| `LabMetricsDashboard/Services/ReportBoardApiClient.cs` | HTTP + cache + degrade-on-failure |
| `LabMetricsDashboard/Controllers/ReportBoardController.cs` | model building, gating, sorting |
| `LabMetricsDashboard/Views/ReportBoard/Index.cshtml` | matrix / cards / drawer |
| `LabMetricsDashboard/Views/ReportBoard/RunErrors.cshtml` | error detail for one run |
| `tests/LabMetricsDashboard.Tests/ReportBoardTests.cs` | status parsing, catalog, lab names, gating |
