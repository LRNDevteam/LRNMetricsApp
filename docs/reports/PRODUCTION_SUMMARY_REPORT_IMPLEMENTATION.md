# Production Summary Report Implementation for Phi_Life and InHealthDTR

**Version:** 1.0 · **Status:** In progress — see Status Summary below · **Last reviewed:** 2026-08-16

> Two sibling files also cover this feature:
> [PRODUCTION_SUMMARY_REPORT_STATUS.md](PRODUCTION_SUMMARY_REPORT_STATUS.md) (status) and
> [DEPLOYMENT_CHECKLIST_PRODUCTION_SUMMARY.md](DEPLOYMENT_CHECKLIST_PRODUCTION_SUMMARY.md)
> (deployment). Both link here for technical detail. They lived at the repository root until the
> 2026-08-27 cleanup; folding the three into one document is still worth doing.

## Overview

This document tracks the implementation of the **Production Summary Report** feature for **Phi_Life** and **InHealthDTR** labs. The Production Summary Report is an optimized, pre-aggregated view of monthly and weekly claim production data backed by stored procedures.

---

## Status Summary

| Lab | Monthly SP | Weekly SP | Config | DI Registration | UI Enabled | Notes |
|-----|-----------|-----------|--------|-----------------|-----------|-------|
| **Phi_Life** | ✅ Exists | ✅ Exists | ⚠️ Pending | ✅ Done | ⚠️ Pending | Already had SQL files; added config & DI |
| **InHealthDTR** | ✅ Created | ✅ Created | ⚠️ Pending | ✅ Done | ⚠️ Pending | Created SQL files; added config & DI |

---

## Implementation Details

### 1. SQL Stored Procedures Created

#### InHealthDTR Monthly Summary
- **File**: `06_InHealthDTR_MonthlyBilledProductionSummary.sql`
- **Table**: `dbo.InH_MonthlyBilledProductionSummary`
- **SP**: `dbo.usp_RefreshInH_MonthlyBilledProductionSummary`
- **Logic**: Groups ClaimLevelData by Panel × Payer × ChargeEnteredDate (year-month)
- **Filter**: FirstBilledDate IS NOT NULL

#### InHealthDTR Weekly Summary
- **File**: `07_InHealthDTR_WeeklyBilledProductionSummary.sql`
- **Table**: `dbo.InH_WeeklyBilledProductionSummary`
- **SP**: `dbo.usp_RefreshInH_WeeklyBilledProductionSummary`
- **Logic**: Last 4 complete weeks (Mon–Sun boundaries)
- **Aggregation**: Panel × Payer × Week with ClaimCount and TotalCharges

### 2. Code Changes

#### LabSummaryTableConfig.cs
**Location**: `LabMetricsDashboard/Services/LabSummaryTableConfig.cs`

Added two new static configurations:

```csharp
/// <summary>Phi Life – prefix <c>Phi_</c>. Supports filtered monthly/weekly SPs.</summary>
public static readonly LabSummaryTableConfig PhiLife =
    new("Phi_",  "PanelName",  "AgingBucket", UnbilledAgingHasCharges: true,  HasCodingTables: true)
    { SupportsFilteredMonthlyWeeklySp = true };

/// <summary>InHealth DTR – prefix <c>InH_</c>. Supports filtered monthly/weekly SPs.</summary>
public static readonly LabSummaryTableConfig InHealthDTR =
    new("InH_",  "PanelName",  "AgingBucket", UnbilledAgingHasCharges: true,  HasCodingTables: true)
    { SupportsFilteredMonthlyWeeklySp = true };
```

**Key fields**:
- **Prefix**: Table name prefix (`Phi_`, `InH_`)
- **UnbilledAgingRowKey**: `"PanelName"` for both labs
- **UnbilledAgingBucketCol**: `"AgingBucket"` (standard)
- **HasCodingTables**: `true` (coding tables exist)
- **SupportsFilteredMonthlyWeeklySp**: `true` (read SPs accept filter parameters)

#### Program.cs Dependency Injection
**Location**: `LabMetricsDashboard/Program.cs` (line ~359–371)

Registered both labs in the keyed DI container:

```csharp
builder.Services.AddSingleton<IReadOnlyDictionary<string, ILabProductionSummaryRepository>>(sp =>
{
    var logger = sp.GetRequiredService<ILogger<SqlLabProductionSummaryRepository>>();
    return new Dictionary<string, ILabProductionSummaryRepository>(StringComparer.OrdinalIgnoreCase)
    {
        // ... existing labs ...
        ["Phi_Life"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.PhiLife),
        ["Inhealth_DTR"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.InHealthDTR),
    };
});
```

---

## Remaining Tasks

### 1. **Enable ProductionSummaryReport in Lab Configuration**

Each lab needs its configuration file updated to enable the Production Summary Report feature.

#### For Phi_Life

**Path**: `E:\LRN-Data\PayerPolicy_v2\2026\ReportsDashboard\Application\Configs\Phi_Life.json`

Add or update:
```json
{
  "EnableProductionSummaryReport": true,
  "ProductionSummary": {
    "Rule": "Rule1",
    "WeekRule": "Rule1",
    "WeekRange": "Thu to Wed"
  }
}
```

**Rationale**: 
- `Rule1` uses ChargeEnteredDate grouping with FirstBilledDate IS NOT NULL filter
- `WeekRange: "Thu to Wed"` matches Phi_Life's week boundaries (defined in SQL)

#### For InHealthDTR

**Path**: `E:\LRN-Data\PayerPolicy_v2\2026\ReportsDashboard\Application\Configs\Inhealth_DTR.json`

Add or update:
```json
{
  "EnableProductionSummaryReport": true,
  "ProductionSummary": {
    "Rule": "Rule1",
    "WeekRule": "Rule1",
    "WeekRange": "Mon to Sun"
  }
}
```

**Rationale**:
- `Rule1` uses ChargeEnteredDate grouping with FirstBilledDate IS NOT NULL filter
- `WeekRange: "Mon to Sun"` matches InHealthDTR's week boundaries (defined in SQL)

### 2. **Deploy SQL Scripts to InHealthDTR Database**

Execute in the **InHealthDTRLRN** database:

```sql
-- Run the newly created files in order:
-- 06_InHealthDTR_MonthlyBilledProductionSummary.sql
-- 07_InHealthDTR_WeeklyBilledProductionSummary.sql
```

This creates:
- Table: `dbo.InH_MonthlyBilledProductionSummary`
- SP: `dbo.usp_RefreshInH_MonthlyBilledProductionSummary`
- Table: `dbo.InH_WeeklyBilledProductionSummary`
- SP: `dbo.usp_RefreshInH_WeeklyBilledProductionSummary`

### 3. **Verify Phi_Life SQL Scripts**

Ensure Phi_Life's SQL files exist and are deployed:

- ✅ `06_PhiLife_MonthlyBilledProductionSummary.sql` (already exists)
- ✅ `07_PhiLife_WeeklyBilledProductionSummary.sql` (already exists)

Check that stored procedures are present in Phi_Life database:
- `dbo.usp_RefreshPhi_MonthlyBilledProductionSummary`
- `dbo.usp_RefreshPhi_WeeklyBilledProductionSummary`

### 4. **Optional: Create Supporting Reports (08–11)**

If needed in the future, create additional reporting tables:

- `08_*_PayerBreakdown.sql` — Payer × Month pivot
- `09_*_CodingBreakdown.sql` — CPT coding summary (if applicable)
- `10_*_UnbilledAging.sql` — Unbilled claim aging buckets
- `11_*_CPTBreakdown.sql` — CPT code × Month pivot

These are optional for the basic Production Summary Report but enable drill-down analytics in the UI.

---

## Testing Checklist

Once configuration is deployed:

- [ ] Navigate to Dashboard → Production Summary Report
- [ ] Verify both Phi_Life and Inhealth_DTR appear in the lab dropdown
- [ ] Load monthly production data without filters (should query snapshot tables)
- [ ] Verify claim counts and total charges match database
- [ ] Apply filters (payer, panel) and confirm live aggregation works
- [ ] Download Excel export and verify data completeness
- [ ] Test weekly view and confirm 4-week boundaries are correct
- [ ] Check that data refreshes when SPs are re-executed

---

## Architecture Notes

### Rule1 (Both Labs)

**Rule1** is selected for both labs because they:

1. **Use ChargeEnteredDate** as the billing date source (not FirstBilledDate)
2. **Require FirstBilledDate IS NOT NULL** as a data quality filter
3. **Rank payers** by COUNT(DISTINCT ClaimID) per panel descending
4. **Support live filtering** when filter parameters are supplied to read SPs

The read SPs (`usp_Get{Prefix}MonthlyBilledProductionSummary`) accept filter parameters and aggregate live from ClaimLevelData when any filter is active, falling back to snapshot tables when no filters are supplied.

### Table Schema

Both labs follow the standard schema:

```sql
CREATE TABLE dbo.{Prefix}_MonthlyBilledProductionSummary
(
    SummaryId       INT PRIMARY KEY IDENTITY(1,1),
    PanelType       NVARCHAR(MAX),     -- Panel name from ClaimLevelData.Panelname
    PayerName       NVARCHAR(500),     -- Payer from ClaimLevelData.PayerName_Raw
    PayerRank       TINYINT,           -- Rank within panel by claim count (dense)
    BilledYearMonth NVARCHAR(7),       -- 'yyyy-MM' from ChargeEnteredDate
    ClaimCount      INT,               -- COUNT(DISTINCT ClaimID)
    TotalCharges    DECIMAL(18,2),     -- SUM(ChargeAmount)
    RefreshedAt     DATETIME           -- Last refresh timestamp
);
```

---

## References

- **Controller**: `LabMetricsDashboard/Controllers/DashboardController.cs` → `ProductionSummaryReport()` action
- **View**: `LabMetricsDashboard/Views/Dashboard/ProductionSummaryReport.cshtml`
- **Repository Interface**: `LabMetricsDashboard/Services/ILabProductionSummaryRepository.cs`
- **Implementation**: `LabMetricsDashboard/Services/SqlLabProductionSummaryRepository.cs`
- **Config Model**: `LabMetricsDashboard/Models/LabConfig.cs` → `ProductionSummaryConfig`

---

## Summary

✅ **Completed**:
- Created SQL files for InHealthDTR (06, 07)
- Added LabSummaryTableConfig entries for both labs
- Registered labs in DI container
- Updated comments to reflect new labs

⚠️ **Pending**:
- Deploy SQL scripts to InHealthDTR database
- Update lab configuration files to enable feature
- Test end-to-end functionality
- Verify Phi_Life SQL deployment (if needed)

---

**Last Updated**: June 8, 2026  
**Created By**: Claude  
**Status**: Ready for deployment
