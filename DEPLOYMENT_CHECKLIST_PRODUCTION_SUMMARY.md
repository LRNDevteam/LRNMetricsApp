# Production Summary Report - Deployment Checklist

## ✅ COMPLETED (Code Changes)

### 1. SQL Files Created for InHealthDTR
- [x] `06_InHealthDTR_MonthlyBilledProductionSummary.sql`
  - Creates table: `dbo.InH_MonthlyBilledProductionSummary`
  - Creates SP: `dbo.usp_RefreshInH_MonthlyBilledProductionSummary`
  - Aggregates: Panel × Payer × ChargeEnteredDate (month)

- [x] `07_InHealthDTR_WeeklyBilledProductionSummary.sql`
  - Creates table: `dbo.InH_WeeklyBilledProductionSummary`
  - Creates SP: `dbo.usp_RefreshInH_WeeklyBilledProductionSummary`
  - Aggregates: Last 4 weeks (Mon-Sun)

### 2. C# Code Updates
- [x] `LabSummaryTableConfig.cs` - Added configs for both labs
  ```csharp
  public static readonly LabSummaryTableConfig PhiLife
  public static readonly LabSummaryTableConfig InHealthDTR
  ```

- [x] `Program.cs` - Registered in DI container
  ```csharp
  ["Phi_Life"] = new SqlLabProductionSummaryRepository(...)
  ["Inhealth_DTR"] = new SqlLabProductionSummaryRepository(...)
  ```

---

## ⚠️ PENDING (Deployment Tasks)

### Step 1: Deploy SQL Scripts to InHealthDTR Database

**Database**: `InHealthDTRLRN` (connection string: `InHealthConn`)

**Execute these scripts in order**:
```sql
-- From: E:\LRN-GitHub\2026\LRNDevTeam\ClaimLineCSVDataCapture\Sql\InHealthDTR\
-- 1. Monthly Summary
EXEC sp_executesql N'
  /* Content of 06_InHealthDTR_MonthlyBilledProductionSummary.sql */
'

-- 2. Weekly Summary
EXEC sp_executesql N'
  /* Content of 07_InHealthDTR_WeeklyBilledProductionSummary.sql */
'
```

**Verify execution**:
```sql
-- Check tables exist
SELECT * FROM sys.tables WHERE name LIKE 'InH_%'

-- Check SPs exist
SELECT * FROM sys.objects WHERE name LIKE 'usp_RefreshInH_%' AND type = 'P'

-- Refresh data
EXEC dbo.usp_RefreshInH_MonthlyBilledProductionSummary
EXEC dbo.usp_RefreshInH_WeeklyBilledProductionSummary

-- Verify data load
SELECT COUNT(*) FROM dbo.InH_MonthlyBilledProductionSummary
SELECT COUNT(*) FROM dbo.InH_WeeklyBilledProductionSummary
```

---

### Step 2: Verify Phi_Life SQL Scripts

**Database**: `Phi_Life`

**Verify existing tables and SPs**:
```sql
-- Check tables exist
SELECT * FROM sys.tables 
WHERE name IN ('Phi_MonthlyBilledProductionSummary', 'Phi_WeeklyBilledProductionSummary')

-- Check SPs exist
SELECT * FROM sys.objects 
WHERE name IN (
  'usp_RefreshPhi_MonthlyBilledProductionSummary',
  'usp_RefreshPhi_WeeklyBilledProductionSummary'
) AND type = 'P'

-- Run refresh if needed
EXEC dbo.usp_RefreshPhi_MonthlyBilledProductionSummary
EXEC dbo.usp_RefreshPhi_WeeklyBilledProductionSummary
```

---

### Step 3: Update Lab Configuration Files

**Location**: `E:\LRN-Data\PayerPolicy_v2\2026\ReportsDashboard\Application\Configs\`

#### File: `Phi_Life.json`
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

#### File: `Inhealth_DTR.json`
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

**Configuration explanation**:
- `EnableProductionSummaryReport: true` - Enables the UI feature
- `Rule: "Rule1"` - Uses ChargeEnteredDate grouping
- `WeekRange` - Aligns with lab's week boundaries in SQL

---

### Step 4: Rebuild & Deploy Application

```bash
# From LabMetricsDashboard folder
dotnet clean
dotnet build
dotnet publish -c Release
```

---

## 🧪 Testing Checklist

### Pre-Testing
- [ ] All SQL scripts executed successfully in respective databases
- [ ] Tables contain data (row counts > 0)
- [ ] Application rebuilt and deployed
- [ ] Lab config files updated
- [ ] App restarted to load new config

### Functional Testing

**Navigate to**: `Dashboard` → `Production Summary Report`

- [ ] **Lab Selection**: Both "Phi Life" and "InHealth DTR" appear in dropdown
- [ ] **Data Loading**: Monthly table loads without filters
  - [ ] Claim counts visible
  - [ ] Total charges visible
  - [ ] Payer breakdown shows (top payers per panel)
- [ ] **Weekly View**: Last 4 weeks display
  - [ ] Week labels show correct date ranges
  - [ ] Claim counts accurate
- [ ] **Filtering**: Apply payer/panel filters
  - [ ] Results update correctly
  - [ ] "Live Query" indicator shows (lightning bolt icon)
- [ ] **Excel Export**: Download works
  - [ ] File opens without errors
  - [ ] Data matches UI display
- [ ] **Performance**: Pages load in <2 seconds without filters

### Data Validation

For each lab:

```sql
-- Compare snapshot vs live query
-- Run refresh SP
EXEC dbo.usp_RefreshInH_MonthlyBilledProductionSummary

-- Query snapshot
SELECT SUM(ClaimCount) as SnapshotClaims FROM dbo.InH_MonthlyBilledProductionSummary

-- Query live (should match for current period)
SELECT COUNT(DISTINCT ClaimID) as LiveClaims FROM dbo.ClaimLevelData
WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
```

---

## 📋 Documentation

Created/Updated files:
1. ✅ `docs/PRODUCTION_SUMMARY_REPORT_IMPLEMENTATION.md` - Full implementation details
2. ✅ `DEPLOYMENT_CHECKLIST_PRODUCTION_SUMMARY.md` - This file

---

## 🚨 Troubleshooting

### Lab Not Appearing in Dropdown
- [ ] Check `appsettings.json` - lab name must be in Labs array
- [ ] Verify `EnableProductionSummaryReport: true` in lab config JSON
- [ ] Check DI registration in Program.cs for typos in lab name

### No Data Showing
- [ ] Verify SPs executed: `SELECT @@ROWCOUNT` from last EXEC
- [ ] Check ClaimLevelData has records with valid FirstBilledDate
- [ ] Run refresh SP manually: `EXEC dbo.usp_RefreshInH_*`

### SQL Error on Page Load
- [ ] Verify table/SP names match config prefix ("InH_" for InHealthDTR, "Phi_" for PhiLife)
- [ ] Check database connection string is correct
- [ ] Run SPs manually to verify they execute without error

### Config Not Loading
- [ ] Verify JSON file path is correct
- [ ] Check JSON syntax (use JSONLint if unsure)
- [ ] Restart application after config changes
- [ ] Check application logs for config load errors

---

## 📞 Support

For issues during deployment:

1. Check SQL script execution - verify no errors
2. Verify lab config JSON syntax
3. Review application logs in `Logs/` folder
4. Compare with working labs (Cove, Certus, Elixir) for reference

---

**Estimated Deployment Time**: 15-30 minutes  
**Risk Level**: Low (new tables, no existing data changes)  
**Rollback Plan**: Drop new tables, revert config files to disable feature

---

Last Updated: June 8, 2026
