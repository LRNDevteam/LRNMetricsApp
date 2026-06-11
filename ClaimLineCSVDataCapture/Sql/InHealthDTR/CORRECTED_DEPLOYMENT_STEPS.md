# InHealthDTR Fix - CORRECTED Deployment Steps

## ⚠️ IMPORTANT: What Went Wrong

You received these errors:
```
Invalid column name 'PatientName'.
Invalid column name 'BilledWeek'.
Invalid column name 'PostedWeek'.
```

**Root Cause:** Scripts 04 and 05 were run BEFORE scripts 02 and 03, so the required columns don't exist yet in the database tables.

## ✅ CORRECT Deployment Order

### Step 1: Verify Current State

Run this to see what's missing in your database:

```powershell
# Connect to your database and run:
sqlcmd -S YOUR_SERVER -d YOUR_DATABASE -i "01_Verify_Columns.sql"
```

OR manually execute `01_Verify_Columns.sql` in SSMS.

### Step 2: Add Missing Columns (CRITICAL - Do This First!)

These scripts add the columns that the TVPs need:

```sql
-- Execute in SSMS or via sqlcmd:
-- Script 02: Adds columns to ClaimLevelData table
02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql

-- Script 03: Adds columns to LineLevelData table  
03_InHealthDTR_Alter_LineLevelData_AddFields.sql
```

### Step 3: Recreate TVPs and Stored Procedures

ONLY after Step 2 is complete, run these:

```sql
-- Script 04: Recreates ClaimLevel TVP and SP
04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql

-- Script 05: Recreates LineLevel TVP and SP
05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql
```

### Step 4: Verify the Fix

```sql
-- Should return ClaimLevelDataTVP=72, LineLevelDataTVP=74
SELECT 
	t.name AS TypeName,
	COUNT(c.column_id) AS ColumnCount
FROM sys.table_types t
INNER JOIN sys.columns c ON t.type_table_object_id = c.object_id
WHERE t.name IN ('ClaimLevelDataTVP', 'LineLevelDataTVP')
GROUP BY t.name;
```

## 🚀 Automated Deployment (Recommended)

The PowerShell script will run all 4 scripts in the correct order:

```powershell
cd E:\LRN-GitHub\2026\LRNDevTeam\ClaimLineCSVDataCapture\Sql\InHealthDTR

# Run the deployment script
.\Deploy_InHealthDTR_Fix.ps1 -ServerName "YOUR_SERVER" -DatabaseName "YOUR_DATABASE"
```

**The script automatically runs:**
1. ✅ 02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql
2. ✅ 03_InHealthDTR_Alter_LineLevelData_AddFields.sql
3. ✅ 04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql
4. ✅ 05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql

## 🔧 Manual Deployment (Step-by-Step)

If you prefer to run each script manually in SSMS:

### Using SQL Server Management Studio (SSMS):

1. **Open SSMS** and connect to your database
2. **Open and execute** `02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql`
3. **Wait for completion** (should show "02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql completed.")
4. **Open and execute** `03_InHealthDTR_Alter_LineLevelData_AddFields.sql`
5. **Wait for completion** (should show "03_InHealthDTR_Alter_LineLevelData_AddFields.sql completed.")
6. **Open and execute** `04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql`
7. **Wait for completion** (should show "InHealthDTR ClaimLevel TVP/SP recreate script completed.")
8. **Open and execute** `05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql`
9. **Wait for completion** (should show "InHealthDTR LineLevel TVP/SP recreate script completed.")

### Using sqlcmd:

```powershell
cd E:\LRN-GitHub\2026\LRNDevTeam\ClaimLineCSVDataCapture\Sql\InHealthDTR

# Run each script in order
sqlcmd -S YOUR_SERVER -d YOUR_DATABASE -i "02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql"
sqlcmd -S YOUR_SERVER -d YOUR_DATABASE -i "03_InHealthDTR_Alter_LineLevelData_AddFields.sql"
sqlcmd -S YOUR_SERVER -d YOUR_DATABASE -i "04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql"
sqlcmd -S YOUR_SERVER -d YOUR_DATABASE -i "05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql"
```

## ❓ What Each Script Does

| Script | Purpose | Changes |
|--------|---------|---------|
| **02** | Alter ClaimLevelData table | Adds 17 columns (DOE_Year, DOE_Month, AgingBucket, etc.) |
| **03** | Alter LineLevelData table | Adds 10 columns (PatientName, PaymentPostedDate, ResponsibleParty, etc.) |
| **04** | Create ClaimLevel TVP/SP | Creates TVP with 72 columns, recreates stored procedure |
| **05** | Create LineLevel TVP/SP | Creates TVP with 74 columns, recreates stored procedure |

## ✅ Expected Results

After successful deployment, you should see:

```
✓ 02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql completed.
✓ 03_InHealthDTR_Alter_LineLevelData_AddFields.sql completed.
✓ Dropping stored procedure dbo.usp_BulkInsertClaimLevelData if it exists...
✓ Dropping type dbo.ClaimLevelDataTVP if it exists...
✓ Creating type dbo.ClaimLevelDataTVP (InHealthDTR)...
✓ InHealthDTR ClaimLevel TVP/SP recreate script completed.
✓ Dropping stored procedure dbo.usp_BulkInsertLineLevelData if it exists...
✓ Dropping type dbo.LineLevelDataTVP if it exists...
✓ Creating type dbo.LineLevelDataTVP (InHealthDTR)...
✓ InHealthDTR LineLevel TVP/SP recreate script completed.
```

**NO ERROR MESSAGES** about invalid column names!

## 🧪 Testing

After deployment:

1. **Restart** the ClaimLineCSVDataCapture application
2. **Process** an InHealthDTR CSV file:
   - Claim Level file: `20260312R0545_Inhealth_DTR_Claim Level_*.csv`
   - Line Level file: `20260312R0545_Inhealth_DTR_Line Level_*.csv`
3. **Check logs** for successful import messages

## 🆘 Troubleshooting

### Still getting "Invalid column name" errors?

**Check if scripts 02 and 03 actually ran:**

```sql
-- This should return rows for all the new columns
SELECT name FROM sys.columns 
WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
AND name IN ('DOE_Year', 'DOE_Month', 'AgingBucket', 'BilledUnbilled', 'Modifier', 
			 'PaymentPercent', 'FullyPaidCount', 'FullyPaidAmount', 'AdjudicatedCount', 
			 'AdjudicatedAmount', 'Days30Count', 'Days30Amount', 'Days60Count', 'Days60Amount');

SELECT name FROM sys.columns 
WHERE object_id = OBJECT_ID('dbo.LineLevelData')
AND name IN ('PatientName', 'PaymentPostedDate', 'ResponsibleParty', 'SubscriberID', 
			 'EndDOS', 'BillOccurance', 'EntryUser', 'CPTUnits', 'CPTMOD', 'CPTs', 'PostedWeek');
```

If columns are missing, run scripts 02 and 03 again.

### Scripts fail with permission errors?

Your database user needs these permissions:
- `ALTER TABLE` on `dbo.ClaimLevelData` and `dbo.LineLevelData`
- `CREATE TYPE` and `DROP TYPE` on database
- `CREATE PROCEDURE` and `DROP PROCEDURE` on database

Contact your DBA for assistance.

---

**Document Created:** 2026-06-08  
**Issue:** Column mismatch in InHealthDTR TVPs  
**Status:** Ready for deployment
