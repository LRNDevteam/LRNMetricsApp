-- =====================================================================
-- InHealthDTR Column Verification Script
-- Run this to check which columns exist in your database
-- =====================================================================

SET NOCOUNT ON;
GO

PRINT '============================================='
PRINT 'Checking ClaimLevelData columns...'
PRINT '============================================='

-- Check if required ClaimLevel columns exist
DECLARE @ClaimMissing TABLE (ColumnName NVARCHAR(200));

-- Note: PatientName, BilledWeek, PostedWeek, PaymentPercent, FullyPaidCount, 
-- FullyPaidAmount, and AdjudicatedAmount already exist in the base schema
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledUnbilled')
	INSERT INTO @ClaimMissing VALUES ('BilledUnbilled');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Modifier')
	INSERT INTO @ClaimMissing VALUES ('Modifier');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AgingBucket')
	INSERT INTO @ClaimMissing VALUES ('AgingBucket');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AdjudicatedCount')
	INSERT INTO @ClaimMissing VALUES ('AdjudicatedCount');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Days30Count')
	INSERT INTO @ClaimMissing VALUES ('Days30Count');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Days30Amount')
	INSERT INTO @ClaimMissing VALUES ('Days30Amount');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Days60Count')
	INSERT INTO @ClaimMissing VALUES ('Days60Count');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Days60Amount')
	INSERT INTO @ClaimMissing VALUES ('Days60Amount');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DOE_Year')
	INSERT INTO @ClaimMissing VALUES ('DOE_Year');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DOE_Month')
	INSERT INTO @ClaimMissing VALUES ('DOE_Month');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTCodeXUnitsXModifierOrginal')
	INSERT INTO @ClaimMissing VALUES ('CPTCodeXUnitsXModifierOrginal');

IF EXISTS (SELECT 1 FROM @ClaimMissing)
BEGIN
	PRINT '✗ MISSING ClaimLevelData columns:'
	SELECT '  - ' + ColumnName AS MissingColumn FROM @ClaimMissing;
	PRINT ''
	PRINT 'ACTION REQUIRED: Run 02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql'
END
ELSE
BEGIN
	PRINT '✓ All ClaimLevelData columns exist'
END

PRINT ''
PRINT '============================================='
PRINT 'Checking LineLevelData columns...'
PRINT '============================================='

-- Check if required LineLevel columns exist
DECLARE @LineMissing TABLE (ColumnName NVARCHAR(200));

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PatientName')
	INSERT INTO @LineMissing VALUES ('PatientName');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PaymentPostedDate')
	INSERT INTO @LineMissing VALUES ('PaymentPostedDate');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ResponsibleParty')
	INSERT INTO @LineMissing VALUES ('ResponsibleParty');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'SubscriberID')
	INSERT INTO @LineMissing VALUES ('SubscriberID');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'EndDOS')
	INSERT INTO @LineMissing VALUES ('EndDOS');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BillOccurance')
	INSERT INTO @LineMissing VALUES ('BillOccurance');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'EntryUser')
	INSERT INTO @LineMissing VALUES ('EntryUser');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTUnits')
	INSERT INTO @LineMissing VALUES ('CPTUnits');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTMOD')
	INSERT INTO @LineMissing VALUES ('CPTMOD');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTs')
	INSERT INTO @LineMissing VALUES ('CPTs');
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PostedWeek')
	INSERT INTO @LineMissing VALUES ('PostedWeek');

IF EXISTS (SELECT 1 FROM @LineMissing)
BEGIN
	PRINT '✗ MISSING LineLevelData columns:'
	SELECT '  - ' + ColumnName AS MissingColumn FROM @LineMissing;
	PRINT ''
	PRINT 'ACTION REQUIRED: Run 03_InHealthDTR_Alter_LineLevelData_AddFields.sql'
END
ELSE
BEGIN
	PRINT '✓ All LineLevelData columns exist'
END

PRINT ''
PRINT '============================================='
PRINT 'Checking TVPs...'
PRINT '============================================='

-- Check TVP column counts
SELECT 
	t.name AS TypeName,
	COUNT(c.column_id) AS ColumnCount,
	CASE 
		WHEN t.name = 'ClaimLevelDataTVP' AND COUNT(c.column_id) = 72 THEN '✓ Correct'
		WHEN t.name = 'LineLevelDataTVP' AND COUNT(c.column_id) = 74 THEN '✓ Correct'
		WHEN t.name = 'ClaimLevelDataTVP' THEN '✗ Expected 72, got ' + CAST(COUNT(c.column_id) AS VARCHAR)
		WHEN t.name = 'LineLevelDataTVP' THEN '✗ Expected 74, got ' + CAST(COUNT(c.column_id) AS VARCHAR)
		ELSE '?'
	END AS Status
FROM sys.table_types t
LEFT JOIN sys.columns c ON t.type_table_object_id = c.object_id
WHERE t.name IN ('ClaimLevelDataTVP', 'LineLevelDataTVP')
GROUP BY t.name;

PRINT ''
PRINT '============================================='
PRINT 'Summary:'
PRINT '============================================='
PRINT 'If any columns are missing:'
PRINT '  1. Run 02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql'
PRINT '  2. Run 03_InHealthDTR_Alter_LineLevelData_AddFields.sql'
PRINT '  3. Then run 04 and 05 to recreate TVPs'
PRINT '============================================='
GO
