-- =====================================================================
-- InHealthDTR Column Mismatch Fix - Database Deployment Instructions
-- =====================================================================
-- 
-- ISSUE:
-- The InHealthDTR lab data import is failing with column count mismatches:
--   - [Claim Level] 72 columns passed vs 54 expected in TVP
--   - [Line Level] 74 columns passed vs 64 expected in TVP
--
-- ROOT CAUSE:
-- The InHealthDTRFieldMappings.json contains 66 fields for ClaimLevel and 
-- 67 fields for LineLevel, but the database TVPs (Table-Valued Parameters) 
-- and stored procedures were never created to match the mapping.
--
-- SOLUTION:
-- Execute the following SQL scripts IN ORDER on the target database:
--
-- =====================================================================

-- STEP 1: Add missing columns to tables
-- This adds columns defined in the mapping JSON that don't exist in the base schema
EXEC('ClaimLineCSVDataCapture\Sql\InHealthDTR\02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql');
EXEC('ClaimLineCSVDataCapture\Sql\InHealthDTR\03_InHealthDTR_Alter_LineLevelData_AddFields.sql');

-- STEP 2: Create/Recreate TVPs and Stored Procedures
-- This creates the TVPs with the correct column count and order matching the JSON
EXEC('ClaimLineCSVDataCapture\Sql\InHealthDTR\04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql');
EXEC('ClaimLineCSVDataCapture\Sql\InHealthDTR\05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql');

-- =====================================================================
-- VERIFICATION:
-- After running the scripts, verify the TVP definitions:
-- =====================================================================

-- Check ClaimLevelDataTVP column count (should be 72 total: 7 system + 65 mapped)
SELECT 
	t.name AS TypeName,
	COUNT(c.column_id) AS ColumnCount
FROM sys.table_types t
INNER JOIN sys.columns c ON t.type_table_object_id = c.object_id
WHERE t.name = 'ClaimLevelDataTVP'
GROUP BY t.name;

-- Check LineLevelDataTVP column count (should be 74 total: 7 system + 67 mapped)
SELECT 
	t.name AS TypeName,
	COUNT(c.column_id) AS ColumnCount
FROM sys.table_types t
INNER JOIN sys.columns c ON t.type_table_object_id = c.object_id
WHERE t.name = 'LineLevelDataTVP'
GROUP BY t.name;

-- List all columns in ClaimLevelDataTVP
SELECT 
	c.column_id,
	c.name AS ColumnName,
	TYPE_NAME(c.user_type_id) AS DataType,
	c.max_length
FROM sys.table_types t
INNER JOIN sys.columns c ON t.type_table_object_id = c.object_id
WHERE t.name = 'ClaimLevelDataTVP'
ORDER BY c.column_id;

-- List all columns in LineLevelDataTVP
SELECT 
	c.column_id,
	c.name AS ColumnName,
	TYPE_NAME(c.user_type_id) AS DataType,
	c.max_length
FROM sys.table_types t
INNER JOIN sys.columns c ON t.type_table_object_id = c.object_id
WHERE t.name = 'LineLevelDataTVP'
ORDER BY c.column_id;

-- =====================================================================
-- NOTES:
-- =====================================================================
-- 1. The TVP column order MUST match the field order in 
--    InHealthDTRFieldMappings.json exactly.
--
-- 2. The scripts are safe to re-run. They drop and recreate the TVPs 
--    and stored procedures.
--
-- 3. After deployment, test with the InHealthDTR CSV files to verify 
--    the data imports successfully.
--
-- 4. The column counts include:
--    - System columns: FileLogId, RunId, WeekFolder, SourceFullPath, 
--                      FileName, FileType, RowHash (7 columns)
--    - CSV-mapped columns: As defined in the JSON mapping
-- =====================================================================
