# InHealthDTR Column Mismatch Issue - Fix Summary

## Problem Description

The ClaimLineCSVDataCapture application is failing to import InHealthDTR lab data with the following errors:

```
2026-06-08 10:52:44 [ERROR] [Claim Level] Trying to pass a table-valued parameter with 72 column(s) 
							where the corresponding user-defined table type requires 54 column(s).

2026-06-08 10:52:51 [ERROR] [Line Level] Trying to pass a table-valued parameter with 74 column(s) 
							where the corresponding user-defined table type requires 64 column(s).
```

## Root Cause

The InHealthDTR lab configuration has a field mapping JSON file (`InHealthDTRFieldMappings.json`) that defines:
- **ClaimLevel**: 65 fields + 7 system columns = **72 total columns**
- **LineLevel**: 67 fields + 7 system columns = **74 total columns**

However, the database **Table-Valued Parameters (TVP)** and **Stored Procedures** were never created to match this mapping. The existing TVPs only have:
- **ClaimLevelDataTVP**: 54 columns (missing 18 columns)
- **LineLevelDataTVP**: 64 columns (missing 10 columns)

This mismatch causes the SQL Server to reject the bulk insert operations.

## Solution Overview

To fix this issue, we need to:

1. **Add missing columns** to the `ClaimLevelData` and `LineLevelData` tables
2. **Recreate the TVPs** with the correct column definitions matching the JSON mapping
3. **Recreate the stored procedures** that use these TVPs

## Files Created

### SQL Scripts (Execute in Order)

1. **02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql**
   - Adds 18 missing columns to `ClaimLevelData` table
   - Columns: DOE_Year, DOE_Month, AgingBucket, BilledUnbilled, Modifier, CPTCode, Units, etc.
   - Safe to re-run (uses `IF NOT EXISTS` checks)

2. **03_InHealthDTR_Alter_LineLevelData_AddFields.sql**
   - Adds 10 missing columns to `LineLevelData` table
   - Columns: PaymentPostedDate, ResponsibleParty, SubscriberID, EndDOS, BillOccurance, etc.
   - Safe to re-run (uses `IF NOT EXISTS` checks)

3. **04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql**
   - Drops and recreates `ClaimLevelDataTVP` with 72 columns
   - Drops and recreates `usp_BulkInsertClaimLevelData` stored procedure
   - Column order matches `InHealthDTRFieldMappings.json` exactly

4. **05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql**
   - Drops and recreates `LineLevelDataTVP` with 74 columns
   - Drops and recreates `usp_BulkInsertLineLevelData` stored procedure
   - Column order matches `InHealthDTRFieldMappings.json` exactly

### Documentation & Deployment

5. **00_README_FIX_INSTRUCTIONS.sql**
   - Comprehensive instructions for manual deployment
   - Verification queries to check TVP column counts
   - Detailed notes and explanations

6. **Deploy_InHealthDTR_Fix.ps1**
   - Automated PowerShell deployment script
   - Supports both Windows and SQL authentication
   - Includes error handling and rollback guidance

7. **FIX_SUMMARY.md** (this file)
   - Complete documentation of the issue and fix

## Deployment Instructions

### Option 1: Automated Deployment (Recommended)

```powershell
cd ClaimLineCSVDataCapture\Sql\InHealthDTR

# Using Windows Authentication
.\Deploy_InHealthDTR_Fix.ps1 -ServerName "YOUR_SERVER" -DatabaseName "YOUR_DATABASE"

# Using SQL Authentication
.\Deploy_InHealthDTR_Fix.ps1 -ServerName "YOUR_SERVER" -DatabaseName "YOUR_DATABASE" `
							  -Username "sa" -Password "YourPassword" -UseWindowsAuth:$false
```

### Option 2: Manual Deployment

Execute each SQL script in order using SQL Server Management Studio (SSMS) or Azure Data Studio:

1. Open SSMS and connect to your database
2. Execute `02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql`
3. Execute `03_InHealthDTR_Alter_LineLevelData_AddFields.sql`
4. Execute `04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql`
5. Execute `05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql`

## Verification

After deployment, run these queries to verify the fix:

```sql
-- Check ClaimLevelDataTVP column count (should return 72)
SELECT 
	t.name AS TypeName,
	COUNT(c.column_id) AS ColumnCount
FROM sys.table_types t
INNER JOIN sys.columns c ON t.type_table_object_id = c.object_id
WHERE t.name = 'ClaimLevelDataTVP'
GROUP BY t.name;

-- Check LineLevelDataTVP column count (should return 74)
SELECT 
	t.name AS TypeName,
	COUNT(c.column_id) AS ColumnCount
FROM sys.table_types t
INNER JOIN sys.columns c ON t.type_table_object_id = c.object_id
WHERE t.name = 'LineLevelDataTVP'
GROUP BY t.name;
```

## Testing

After deployment:

1. **Restart the ClaimLineCSVDataCapture application** (if running)
2. **Process an InHealthDTR CSV file** (both Claim Level and Line Level)
3. **Monitor the application logs** for successful import
4. **Verify data** in the `ClaimLevelData` and `LineLevelData` tables

### Expected Results

The application should successfully import InHealthDTR CSV files without column mismatch errors. You should see log messages like:

```
[INFO] [Claim Level] File: 20260312R0545_Inhealth_DTR_Claim Level_02.24.2026 to 03.02.2026.csv
[INFO] [Claim Level] Successfully inserted 5432 rows
[INFO] [Line Level] File: 20260312R0545_Inhealth_DTR_Line Level_02.24.2026 to 03.02.2026.csv
[INFO] [Line Level] Successfully inserted 12345 rows
```

## Rollback Plan

If you need to rollback the changes:

1. The table alterations (scripts 02 and 03) only ADD columns - they don't remove or modify existing data
2. To rollback the TVPs and stored procedures, you would need to restore them from a backup or recreate them with the old definitions
3. **Recommendation**: Take a database backup before deployment

## Additional Notes

- **Safe to Re-run**: All scripts are idempotent and can be safely re-executed
- **No Data Loss**: The scripts only add columns and recreate TVPs/SPs - no data is modified or deleted
- **Performance Impact**: Minimal - only schema changes, no data migration
- **Downtime**: Recommended to stop the application during deployment to avoid conflicts
- **Other Labs**: This fix is specific to InHealthDTR and doesn't affect other lab configurations

## Column Details

### ClaimLevel Missing Columns (18 total)

| Column Name | Purpose |
|-------------|---------|
| PatientName | Patient identification |
| BilledUnbilled | Billing status flag |
| Modifier | CPT modifier codes |
| PaymentPercent | Payment percentage calculation |
| AgingBucket | Aging category (0-30, 31-60, etc.) |
| BilledWeek | Week when claim was billed |
| PostedWeek | Week when payment was posted |
| FullyPaidCount | Count of fully paid claims |
| FullyPaidAmount | Dollar amount of fully paid claims |
| AdjudicatedCount | Count of adjudicated claims |
| AdjudicatedAmount | Dollar amount of adjudicated claims |
| Days30Count | Count of claims in 30-day bucket |
| Days30Amount | Dollar amount in 30-day bucket |
| Days60Count | Count of claims in 60-day bucket |
| Days60Amount | Dollar amount in 60-day bucket |
| DOE_Year | Date of entry year |
| DOE_Month | Date of entry month |
| CPTCode | (Additional field for InHealthDTR) |
| Units | (Additional field for InHealthDTR) |

### LineLevel Missing Columns (10 total)

| Column Name | Purpose |
|-------------|---------|
| PaymentPostedDate | Date payment was posted |
| ResponsibleParty | Responsible party information |
| SubscriberID | Insurance subscriber ID |
| EndDOS | End date of service |
| BillOccurance | Billing occurrence code |
| EntryUser | User who entered the data |
| CPTUnits | CPT units (alternative format) |
| CPTMOD | CPT modifier (alternative format) |
| CPTs | Combined CPT codes |
| PostedWeek | Week when payment was posted |

## Support

If you encounter any issues during deployment or testing:

1. Check the SQL Server error log
2. Check the application log files
3. Verify the InHealthDTRFieldMappings.json file is correct
4. Ensure the database user has permissions to create/drop TVPs and stored procedures

---

**Document Version**: 1.0  
**Created**: 2026-06-08  
**Author**: GitHub Copilot  
**Related Files**: `InHealthDTRFieldMappings.json`, SQL scripts in `ClaimLineCSVDataCapture\Sql\InHealthDTR\`
