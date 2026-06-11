# InHealthDTR Column Mismatch Fix - Quick Start Guide

## 🚨 Problem
```
ERROR: [Claim Level] Trying to pass 72 columns but TVP expects 54 columns
ERROR: [Line Level] Trying to pass 74 columns but TVP expects 64 columns
```

## ✅ Solution
Run the database deployment scripts to update the TVPs and stored procedures.

## 🚀 Quick Deployment (3 Steps)

### Step 1: Navigate to the SQL folder
```powershell
cd E:\LRN-GitHub\2026\LRNDevTeam\ClaimLineCSVDataCapture\Sql\InHealthDTR
```

### Step 2: Run the deployment script
```powershell
# Replace YOUR_SERVER and YOUR_DATABASE with actual values
.\Deploy_InHealthDTR_Fix.ps1 -ServerName "YOUR_SERVER" -DatabaseName "YOUR_DATABASE"
```

### Step 3: Restart the application and test
- Stop the ClaimLineCSVDataCapture application
- Run the deployment script above
- Start the application
- Process an InHealthDTR CSV file

## 📋 What Gets Fixed

| File Type | Before | After | Status |
|-----------|--------|-------|--------|
| Claim Level TVP | 54 columns | 72 columns | ✅ Fixed |
| Line Level TVP | 64 columns | 74 columns | ✅ Fixed |

## 📁 Files Created

1. **04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql** - Creates TVP with 72 columns
2. **05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql** - Creates TVP with 74 columns
3. **Deploy_InHealthDTR_Fix.ps1** - Automated deployment script
4. **FIX_SUMMARY.md** - Detailed documentation

## ⚠️ Important Notes

- ✅ Safe to re-run - Scripts are idempotent
- ✅ No data loss - Only schema changes
- ✅ Takes < 1 minute to run
- ⚠️ Stop the application before deploying
- ⚠️ Backup your database first (recommended)

## 🔍 Verify the Fix

After deployment, run this query to verify:

```sql
-- Should return 72 for ClaimLevel, 74 for LineLevel
SELECT 
	t.name AS TypeName,
	COUNT(c.column_id) AS ColumnCount
FROM sys.table_types t
INNER JOIN sys.columns c ON t.type_table_object_id = c.object_id
WHERE t.name IN ('ClaimLevelDataTVP', 'LineLevelDataTVP')
GROUP BY t.name;
```

## 📞 Troubleshooting

### Issue: "Script not found" error
**Solution**: Make sure you're in the correct directory:
```powershell
cd ClaimLineCSVDataCapture\Sql\InHealthDTR
```

### Issue: "Permission denied" error
**Solution**: Your database user needs permission to CREATE/DROP types and stored procedures. Contact your DBA.

### Issue: Still getting column mismatch after deployment
**Solution**: 
1. Verify the scripts ran successfully
2. Restart the application
3. Check if you're pointing to the correct database
4. Run the verification query above

### Issue: Different column count error
**Solution**: The InHealthDTRFieldMappings.json may have been modified. Review the mapping file and regenerate the SQL scripts if needed.

## 📚 More Information

See `FIX_SUMMARY.md` for complete documentation including:
- Root cause analysis
- Column details
- Rollback procedures
- Testing procedures

---

**Need Help?** Check the application logs at:
- Location: [Your application log path]
- Look for: `[ERROR]` or `[Claim Level]` or `[Line Level]` entries
