# Coding Validation — Output Template v1.4 alignment (tag: `CVTPL-1.4`)

**Version:** 1.4 (git tag `CVTPL-1.4`) · **Status:** Deployed · **Date:** 2026-07-27

Aligns the Coding Validation report to **Coding Validation Output Template_v1.4.xlsx**.
Every code change is wrapped in `>>> CVTPL-1.4 CHANGE` / `<<< END CVTPL-1.4 CHANGE`
markers with inline REVERT instructions, so the whole change set is reversible.

## What changed (per the template)

1. **Net Impact = Revenue at Risk − Lost Revenue** (was Lost − At Risk). Applied to
   YTD Summary, YTD Insights, WTD Insights, WTD Summary and the drill-down modal.
2. **Lost Revenue / Revenue at Risk = SUM of Average *Allowed* Amount**
   (`MissingCPT_AvgAllowedAmount` / `AdditionalCPT_AvgAllowedAmount`) — was Average *Paid* Amount.
3. **WTD Summary expanded to the full 10-column template**: added Distinct claims with
   Additional CPTs, Total Billed Charges for Additional CPTs, Lost Revenue, Revenue at Risk,
   Net Impact. (Previously showed only an Avg Allowed Amount for Missing CPTs column.)

## Deployment order

### 1. Database (run per lab database)
Run the updated script, then rebuild the aggregates:

```
:r CaptureDataApp\Sql\04_CodingAggregates.sql        -- creates cols + CREATE OR ALTER procs
EXEC dbo.usp_RefreshCodingAggregates @LabName = '<lab>';
```

Stored procedures replaced (CREATE OR ALTER — safe to re-run):
- `usp_RefreshCodingAggregates`   (recomputes all 4 aggregate tables; new WTD Summary logic + Allowed basis + Net Impact sign)
- `usp_GetCodingAggWtdSummary`    (now returns the 5 new WTD Summary columns)
- (unchanged procs re-created as-is: `usp_GetCodingAggYtdInsights`, `usp_GetCodingAggYtdSummary`, `usp_GetCodingAggWtdInsights`, `usp_GetCodingFinancialSummary`, `usp_GetCodingValidationDetail`, `usp_ClearCodingValidationFileLog`)

Table altered (idempotent `ALTER TABLE ... ADD` guards in the script):
- `dbo.CodingAgg_WtdSummary` gains: `DistinctClaimsWithAdditionalCpts`,
  `TotalBilledChargesForAdditionalCpts`, `LostRevenue`, `RevenueAtRisk`, `NetImpact`.

> The DB script must be deployed **before** the apps, because the dashboard/export now read the 5 new columns.

### 2. Applications to redeploy
- **LabMetricsDashboard** (web UI) — model, repository, `Views/Coding/Summary.cshtml`,
  `_CodingCalculationDetail.cshtml`, `CodingExcelExportBuilder`.
- **LRN.ReportWorker** (async report generator) — references the same
  `CodingExcelExportBuilder` / repository, so it must be rebuilt/redeployed too.
- **CaptureDataApp** — owns `04_CodingAggregates.sql`; ships/executes the DB script and refresh.

## Files changed
| File | Layer |
|------|-------|
| `CaptureDataApp/Sql/04_CodingAggregates.sql` | DB (tables + procs) |
| `LabMetricsDashboard/Models/CodingValidationModels.cs` | model |
| `LabMetricsDashboard/Services/SqlCodingValidationRepository.cs` | data access |
| `LabMetricsDashboard/Services/CodingExcelExportBuilder.cs` | Excel export |
| `LabMetricsDashboard/Views/Coding/Summary.cshtml` | UI |
| `LabMetricsDashboard/Views/Coding/_CodingCalculationDetail.cshtml` | UI (drill-down) |

## How to revert
1. In code, search all files for `CVTPL-1.4` and follow each block's REVERT note
   (delete added lines / restore the pre-1.4 expression shown in the comment).
2. Re-run `04_CodingAggregates.sql` and `EXEC dbo.usp_RefreshCodingAggregates`.
   The 5 added `CodingAgg_WtdSummary` columns are harmless if left in place; drop them
   only if a clean schema is required.
3. Rebuild & redeploy LabMetricsDashboard + LRN.ReportWorker.

## Billed-date basis (tag: `CVBILL-1.4`)
The date-window notes are now implemented. All Year/Week ranges key off **FirstBillDate**
(billed date), not DateofService or the source-folder WeekFolder:

- `usp_RefreshCodingAggregates` builds a `#cv` working set that, per claim, computes the
  billed date, its 7-day billed-date **week range** ("MM/dd/yyyy to MM/dd/yyyy", anchored on
  MAX(FirstBillDate)), and a Scope of WTD / YTD.
- **WTD** = the latest **2 Friday→Thursday** weeks (the week containing MAX(FirstBillDate) + the prior
  week). Verified against client file `20260723R0155` — all 11 YTD panel rows and 7 WTD groups reconcile
  exactly (e.g. ABR, UTI PCR Reflex: YTD 2026=72, 2025=46). `@WtdWeeks` is a proc constant (=2); the spec
  text says 4, but the client's actual report spans 2 — change the constant if the cadence differs.
- **YTD** = **all** billed-date years for claims billed **before** the WTD window (grouped by
  YEAR(FirstBillDate); excludes the WTD weeks). Not restricted to a single year.
- **Claim counts** are **DISTINCT VisitNumber** (template: "unique visit numbers"), replacing the
  previous COUNT(*) / DISTINCT AccessionNo.

### Deviation-only inclusion (tag: `CVDEV-1.4`)
Per the template's top rule ("summary is presented only for claims that have a Missing or Additional
CPT"), a panel is shown **only if it has at least one deviation claim** — but its Total No. of Claims
still counts **all** its claims (clean + deviation). Panels whose claims are all "No Deviation found"
(e.g. `Fungal Nail Panel, Wound Panel`) are dropped. Coding-Insights rows are limited to deviation
combos. Verified against client file `20260723R0155`: all 11 panel-year groups match on every column
(Total, Distinct Missing/Additional, Lost Revenue, Revenue at Risk). REVERT: search `CVDEV-1.4`.
- WTD read procs order by the week's end date; the dashboard/view/export sort weeks chronologically
  (C# `WeekEnd` helper) since the labels are date ranges, not lexically sortable strings.

Deploy: re-run `04_CodingAggregates.sql` + `EXEC dbo.usp_RefreshCodingAggregates`, and redeploy
LabMetricsDashboard + LRN.ReportWorker (view/export ordering). REVERT: search `CVBILL-1.4`.

The existing YTD Summary still keeps an extra "Total Billed Charges" column not present in the
template (informational; left in place).
