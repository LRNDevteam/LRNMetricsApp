# InHealthDTR & PhiLife — Automatic Production Summary Refresh

## Overview

✅ **YES** — Both **InHealthDTR** and **PhiLife** production summary reports **will automatically regenerate** when new files are processed by the ClaimLineCSVDataCapture application.

## How It Works

### Automatic Refresh Flow

```
1. CSV File Dropped → Weekly Folder
2. ClaimLineCSVDataCapture Processes File
3. Bulk Insert into ClaimLevelData / LineLevelData
4. ✅ AUTOMATIC: Production Report Refresh SPs Execute
5. ✅ AUTOMATIC: Collection Summary Refresh SPs Execute
6. Production Summary Tables Updated
7. Dashboard Shows Fresh Data
```

## Integration Details

### ClaimLineCSVDataCapture Application

**File**: `ClaimLineCSVDataCapture\Program.cs` (lines ~636-710)

After bulk insert completes for each lab, the application automatically calls lab-specific refresh methods:

#### PhiLife
```csharp
if (lab.LabName.Equals("PhiLife", StringComparison.OrdinalIgnoreCase))
{
	// ✅ Production Reports (7 SPs)
	var phiResults = db.RefreshPhiLifeProductionReports();

	// ✅ Collection Summary (13 SPs)
	db.RefreshPhiLifeCollectionReports();

	// ✅ Executive Summary (1 SP)
	db.RefreshPhiLifeExecutiveSummary();
}
```

#### InHealthDTR
```csharp
if (lab.LabName.Equals("InHealthDTR", StringComparison.OrdinalIgnoreCase))
{
	// ✅ Production Reports (7 SPs) — NEWLY ADDED
	var inhResults = db.RefreshInHealthDTRProductionReports();

	// ✅ Collection Summary (13 SPs)
	db.RefreshInHealthDTRCollectionReports();
}
```

### Database Service

**File**: `ClaimLineCSVDataCapture\Services\ClaimLineDbService.cs`

#### PhiLife Production Reports (lines ~503-517)
```csharp
public List<(string SpName, long ElapsedMs, string? Error)> RefreshPhiLifeProductionReports()
{
	string[] procedures =
	[
		"dbo.usp_RefreshPhi_MonthlyBilledProductionSummary",
		"dbo.usp_RefreshPhi_WeeklyBilledProductionSummary",
		"dbo.usp_RefreshPhi_PayerBreakdown",
		"dbo.usp_RefreshPhi_PayerByPanel",
		"dbo.usp_RefreshPhi_CodingBreakdown_Billed",
		"dbo.usp_RefreshPhi_UnbilledAging",
		"dbo.usp_RefreshPhi_CPTBreakdown",
	];
	return RunProductionReportSPs(procedures);
}
```

#### InHealthDTR Production Reports (lines ~621-639) — **NEWLY ADDED**
```csharp
public List<(string SpName, long ElapsedMs, string? Error)> RefreshInHealthDTRProductionReports()
{
	string[] procedures =
	[
		"dbo.usp_RefreshInH_MonthlyBilledProductionSummary",
		"dbo.usp_RefreshInH_WeeklyBilledProductionSummary",
		"dbo.usp_RefreshInH_PayerBreakdown",
		"dbo.usp_RefreshInH_PayerByPanel",
		"dbo.usp_RefreshInH_CodingBreakdown_Billed",
		"dbo.usp_RefreshInH_UnbilledAging",
		"dbo.usp_RefreshInH_CPTBreakdown",
	];
	return RunProductionReportSPs(procedures);
}
```

## What Tables Are Refreshed?

### PhiLife
| # | Table | Refresh SP |
|---|-------|-----------|
| 1 | `Phi_MonthlyBilledProductionSummary` | `usp_RefreshPhi_MonthlyBilledProductionSummary` |
| 2 | `Phi_WeeklyBilledProductionSummary` | `usp_RefreshPhi_WeeklyBilledProductionSummary` |
| 3 | `Phi_PayerBreakdown` | `usp_RefreshPhi_PayerBreakdown` |
| 4 | `Phi_PayerByPanel` | `usp_RefreshPhi_PayerByPanel` |
| 5 | `Phi_CodingPanelSummary` | `usp_RefreshPhi_CodingBreakdown_Billed` |
| 6 | `Phi_CodingCPTDetail` | ↑ (same SP) |
| 7 | `Phi_UnbilledAging` | `usp_RefreshPhi_UnbilledAging` |
| 8 | `Phi_CPTBreakdown` | `usp_RefreshPhi_CPTBreakdown` |

### InHealthDTR
| # | Table | Refresh SP |
|---|-------|-----------|
| 1 | `InH_MonthlyBilledProductionSummary` | `usp_RefreshInH_MonthlyBilledProductionSummary` |
| 2 | `InH_WeeklyBilledProductionSummary` | `usp_RefreshInH_WeeklyBilledProductionSummary` |
| 3 | `InH_PayerBreakdown` | `usp_RefreshInH_PayerBreakdown` |
| 4 | `InH_PayerByPanel` | `usp_RefreshInH_PayerByPanel` |
| 5 | `InH_CodingPanelSummary` | `usp_RefreshInH_CodingBreakdown_Billed` |
| 6 | `InH_CodingCPTDetail` | ↑ (same SP) |
| 7 | `InH_UnbilledAging` | `usp_RefreshInH_UnbilledAging` |
| 8 | `InH_CPTBreakdown` | `usp_RefreshInH_CPTBreakdown` |

## Execution Characteristics

### Independent Execution
- Each SP runs **independently** — if one fails, others still execute
- Failures are logged but don't stop the overall process

### Error Handling
```csharp
foreach (var (spName, elapsedMs, error) in results)
{
	if (error is null)
		log.Info($"  [InH Reports] {spName} — OK ({elapsedMs} ms).");
	else
		log.Error($"  [InH Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
}
```

### Timeout
- **30 minutes** (1800 seconds) per SP
- Configurable via `CommandTimeout` in `ClaimLineDbService.RunProductionReportSPs`

## Logging

When files are processed, you'll see log entries like:

### PhiLife
```
[Phi Reports] Running PhiLife production report SPs…
[Phi Reports] dbo.usp_RefreshPhi_MonthlyBilledProductionSummary — OK (1234 ms).
[Phi Reports] dbo.usp_RefreshPhi_WeeklyBilledProductionSummary — OK (987 ms).
[Phi Reports] dbo.usp_RefreshPhi_PayerBreakdown — OK (543 ms).
[Phi Reports] dbo.usp_RefreshPhi_PayerByPanel — OK (432 ms).
[Phi Reports] dbo.usp_RefreshPhi_CodingBreakdown_Billed — OK (678 ms).
[Phi Reports] dbo.usp_RefreshPhi_UnbilledAging — OK (345 ms).
[Phi Reports] dbo.usp_RefreshPhi_CPTBreakdown — OK (456 ms).
[Phi Reports] 7/7 SP(s) succeeded.
```

### InHealthDTR
```
[InH Reports] Running InHealthDTR production report SPs…
[InH Reports] dbo.usp_RefreshInH_MonthlyBilledProductionSummary — OK (1234 ms).
[InH Reports] dbo.usp_RefreshInH_WeeklyBilledProductionSummary — OK (987 ms).
[InH Reports] dbo.usp_RefreshInH_PayerBreakdown — OK (543 ms).
[InH Reports] dbo.usp_RefreshInH_PayerByPanel — OK (432 ms).
[InH Reports] dbo.usp_RefreshInH_CodingBreakdown_Billed — OK (678 ms).
[InH Reports] dbo.usp_RefreshInH_UnbilledAging — OK (345 ms).
[InH Reports] dbo.usp_RefreshInH_CPTBreakdown — OK (456 ms).
[InH Reports] 7/7 SP(s) succeeded.
```

## Dashboard Integration

### Read SPs
The `LabMetricsDashboard` web application calls read SPs to display data:

```csharp
// Fast path (no filters) — returns cached snapshot
var data = await repo.ExecuteStoredProcedure("dbo.usp_GetInH_MonthlyBilledProductionSummary");

// Live path (with filters) — aggregates on demand
var data = await repo.ExecuteStoredProcedure(
	"dbo.usp_GetInH_MonthlyBilledProductionSummary",
	new { PayerNames = "Payer1|Payer2", FirstBilledFrom = "2024-01-01" }
);
```

### Dual-Path Design
- **No filters** → Returns pre-aggregated snapshot (fast, from refresh SPs)
- **With filters** → Aggregates live from `ClaimLevelData`/`LineLevelData`

## Summary

✅ **InHealthDTR** — Production reports **WILL** auto-refresh (integration added)  
✅ **PhiLife** — Production reports **ALREADY** auto-refresh (existing integration)

Both labs follow the same pattern:
1. File processed → Data inserted
2. Refresh SPs automatically called
3. Summary tables updated
4. Dashboard reads fresh data

---

**Status**: ✅ **Fully Integrated**  
**Date**: 2025  
**Labs**: InHealthDTR, PhiLife  
**Files Modified**: `ClaimLineDbService.cs`, `Program.cs`
