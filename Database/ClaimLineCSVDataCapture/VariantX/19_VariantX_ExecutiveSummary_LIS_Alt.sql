/* =============================================================================
   VariantX Labs — Executive Summary LIS Breakdown Refresh
   Prefix: VarX_ / VarX_ES_
   Refresh: usp_RefreshVarX_ExecutiveSummary_LIS_Alt
   Source: dbo.LIMSMaster
   =============================================================================
   RoleID scheme (client Executive Summary sheet):
     A      Total Samples
     B      Billable Samples              SampleStatus = Billable
     B.xxx  TestType sub-rows             Billable AND TestType = xxx
     C      Billed                        Billable AND BillCategory = Billed
     D      Other Samples                 SampleStatus <> Billable
     D.xxx  Other-status sub-rows         SampleStatus = xxx (e.g. System Test)

   Period: RequestCollectDate / DateOfCollection (collection date), independent
   of FirstBilledDate used by PMS/Cash/Avg in file 16.
   ============================================================================= */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_ExecutiveSummary_LIS_Alt
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.VarX_ES_LIS;

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
	BEGIN
		PRINT 'usp_RefreshVarX_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
		RETURN;
	END

	DECLARE @AccCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('AccessionNumber','Accession','AccessionNo')
		ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

	DECLARE @DateCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('DateOfCollection','RequestCollectDate','CollectionDate','DateofService','ServiceDate','AccessionDate')
		ORDER BY CASE name
			WHEN 'DateOfCollection'   THEN 0
			WHEN 'RequestCollectDate' THEN 1
			WHEN 'CollectionDate'     THEN 2
			WHEN 'DateofService'      THEN 3
			WHEN 'ServiceDate'        THEN 4
			WHEN 'AccessionDate'      THEN 5
			ELSE 6 END);

	-- SampleStatus is the VariantX column; NewStatus/Status kept for clone compatibility.
	DECLARE @SampleStatusCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('SampleStatus','NewStatus','Status','LRNSampleStatus')
		ORDER BY CASE name
			WHEN 'SampleStatus' THEN 0 WHEN 'LRNSampleStatus' THEN 1
			WHEN 'NewStatus' THEN 2 WHEN 'Status' THEN 3 ELSE 4 END);

	DECLARE @BillCategoryCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus','LRNBillCategory')
		ORDER BY CASE name
			WHEN 'BillCategory' THEN 0 WHEN 'LRNBillCategory' THEN 1
			WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3
			WHEN 'BillStatus' THEN 4 ELSE 5 END);

	-- Optional — absence means no B.x TestType sub-rows.
	DECLARE @TestTypeCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('TestType','Panel','PanelName','PanelType','TestPanel')
		ORDER BY CASE name
			WHEN 'TestType' THEN 0 WHEN 'Panel' THEN 1
			WHEN 'PanelName' THEN 2 WHEN 'PanelType' THEN 3
			WHEN 'TestPanel' THEN 4 ELSE 5 END);

	IF @AccCol IS NULL OR @DateCol IS NULL OR @SampleStatusCol IS NULL OR @BillCategoryCol IS NULL
	BEGIN
		PRINT 'usp_RefreshVarX_ExecutiveSummary_LIS_Alt: could not locate Accession/Date/SampleStatus/BillCategory columns on dbo.LIMSMaster - skipping.';
		RETURN;
	END

	DROP TABLE IF EXISTS #Lis;
	CREATE TABLE #Lis
	(
		Accession     NVARCHAR(100) NOT NULL,
		ESYear        INT           NOT NULL,
		ESMonth       INT           NOT NULL,
		SampleStatus  NVARCHAR(100) NOT NULL,
		BillCategory  NVARCHAR(100) NOT NULL,
		TestType      NVARCHAR(300) NOT NULL
	);

	DECLARE @TestTypeExpr NVARCHAR(200) =
		CASE WHEN @TestTypeCol IS NOT NULL
		     THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @TestTypeCol + N']), '''')))'
		     ELSE N'CAST('''' AS NVARCHAR(300))'
		END;

	DECLARE @LisSql NVARCHAR(MAX) = N'
		INSERT INTO #Lis (Accession, ESYear, ESMonth, SampleStatus, BillCategory, TestType)
		SELECT
			LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
			YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
			MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)),
			LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @SampleStatusCol + N']), ''''))),
			LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))),
			' + @TestTypeExpr + N'
		FROM dbo.LIMSMaster
		WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL;';

	EXEC sp_executesql @LisSql;

	DROP TABLE IF EXISTS #LisPeriods;
	SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
	UNION ALL SELECT 0, 0;

	INSERT INTO dbo.VarX_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
	FROM
	(
		-- A  Total Samples
		SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
			   COUNT(DISTINCT l.Accession) AS ClaimCount
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- B  Billable Samples
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.SampleStatus = 'Billable'
		GROUP BY p.ESYear, p.ESMonth

		-- C  Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'C', 'Billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.SampleStatus = 'Billable'
						 AND l.BillCategory = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- D  Other Samples
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D', 'Other Samples',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.SampleStatus <> 'Billable'
						 AND l.SampleStatus <> ''
		GROUP BY p.ESYear, p.ESMonth
	) lis;

	-- B.xxx  Billable Samples by TestType
	IF @TestTypeCol IS NOT NULL
	BEGIN
		INSERT INTO dbo.VarX_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
		SELECT
			'B.' + l.TestType,
			'  ' + l.TestType,
			p.ESYear,
			p.ESMonth,
			COUNT(DISTINCT l.Accession),
			0,
			GETDATE()
		FROM #LisPeriods p
		INNER JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
		WHERE l.SampleStatus = 'Billable'
		  AND l.TestType <> ''
		GROUP BY p.ESYear, p.ESMonth, l.TestType;
	END

	-- D.xxx  Other Samples by SampleStatus (includes System Test / System Tests)
	INSERT INTO dbo.VarX_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT
		'D.' + l.SampleStatus,
		'  ' + l.SampleStatus,
		p.ESYear,
		p.ESMonth,
		COUNT(DISTINCT l.Accession),
		0,
		GETDATE()
	FROM #LisPeriods p
	INNER JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
	WHERE l.SampleStatus <> 'Billable'
	  AND l.SampleStatus <> ''
	GROUP BY p.ESYear, p.ESMonth, l.SampleStatus;

	DROP TABLE IF EXISTS #Lis;
	DROP TABLE IF EXISTS #LisPeriods;

	IF OBJECT_ID('dbo.usp_VarX_ES_UpdatePmsBilledMismatch', 'P') IS NOT NULL
		EXEC dbo.usp_VarX_ES_UpdatePmsBilledMismatch;

	PRINT 'usp_RefreshVarX_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '19_VariantX_ExecutiveSummary_LIS_Alt.sql completed.';
GO
