-- ============================================================
-- Elixir – LIS Breakdown Refresh ("Alt") SP
-- File : 19_Elixir_ExecutiveSummary_LIS_Alt.sql
-- DB   : Elixir_LRN
--
-- Run order: AFTER ingestion of LIMSMaster (independent of
-- usp_RefreshElix_ExecutiveSummary / ClaimLevelData, which only
-- populates the PMS/Cash/Avg breakdowns in
-- 16_Elixir_ExecutiveSummary_Aggregate.sql). Wired into
-- ClaimLineCSVDataCapture's generic prefix-driven Executive Summary
-- refresh (RefreshExecutiveSummaryByPrefix), same as PhiLife/PCRLOA's
-- *_LIS_Alt procs.
--
-- This SP fully owns dbo.Elix_ES_LIS and TRUNCATEs it at the start of
-- every run. There is no LIS_Panel table for Elixir (see
-- 15_Elixir_ExecutiveSummary_Tables.sql).
--
-- RoleID scheme (from the Elixir LIS Breakdown spec image):
--   A      Total Samples              -> COUNT(AccessionNo)
--   B      Billable Samples           -> A + NewStatus = 'Billable'
--   B.xxx  Panel sub-rows             -> B broken down by Panel value (dynamic)
--   C      Billed                     -> B + BillCategory = 'Billed'
--   D      Unbilled                   -> B + BillCategory = 'Not Billed'
--   D.1    Resulted yet to be billed  -> D + ResultStatus = 'Resulted'
--   E      Other Samples              -> NewStatus <> 'Billable'
--   E.1    Client Bill                -> NewStatus = 'Client Bill'
--   E.2    Self Pay                   -> NewStatus = 'Self Pay'
--   E.3    System Test                -> NewStatus = 'System Test'
--   E.4    Deleted/Rejected           -> NewStatus = 'Deleted/Rejected'
--   E.5    CIP/Pending                -> NewStatus = 'CIP/Pending'
--   E.6    Yet to be validated        -> NewStatus = 'Yet to be validated'
--
-- Period bucket: LIMSMaster's own date column (auto-detected — always
-- collection-date columns first: DateOfCollection / RequestCollectDate /
-- CollectionDate, then DateofService / ServiceDate / AccessionDate as
-- fallback), independent of the DateofService-based #Periods used by
-- PMS/Cash/Avg — same "different period system" precedent followed by
-- 17_Elixir_ExecutiveSummary_Read.sql's filtered LIS path.
--
-- Column auto-detection (sys.columns, same priority-ordered candidate
-- lists used elsewhere in the Elixir suite):
--   @AccCol          : AccessionNumber, Accession, AccessionNo
--   @DateCol         : DateOfCollection, RequestCollectDate, CollectionDate, DateofService, ServiceDate, AccessionDate
--   @NewStatusCol    : NewStatus, Status
--   @BillCategoryCol : BillCategory, Bill_Category, BillingCategory, BillStatus
--   @ResultStatusCol : ResultStatus, Result_Status, ResultedStatus, RessultedStatus, IsResulted
--   @PanelCol        : Panel, PanelName, PanelType, TestPanel  (optional — no B.x rows if absent)
--
-- If dbo.LIMSMaster does not exist, or any required column cannot be
-- located, the SP TRUNCATEs Elix_ES_LIS, prints a diagnostic, and
-- RETURNs (graceful no-op — same pattern as 16's 'I' degeneration).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_ExecutiveSummary_LIS_Alt
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.Elix_ES_LIS;

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
	BEGIN
		PRINT 'usp_RefreshElix_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
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

	DECLARE @NewStatusCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('NewStatus','Status')
		ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 ELSE 2 END);

	DECLARE @BillCategoryCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus')
		ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

	DECLARE @ResultStatusCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('ResultStatus','Result_Status','ResultedStatus','RessultedStatus','IsResulted')
		ORDER BY CASE name
			WHEN 'ResultStatus' THEN 0 WHEN 'Result_Status' THEN 1
			WHEN 'ResultedStatus' THEN 2 WHEN 'RessultedStatus' THEN 3
			WHEN 'IsResulted' THEN 4 ELSE 5 END);

	-- Optional — absence means no B.x panel sub-rows, SP still runs normally.
	DECLARE @PanelCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('Panel','PanelName','PanelType','TestPanel')
		ORDER BY CASE name WHEN 'Panel' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'PanelType' THEN 2 WHEN 'TestPanel' THEN 3 ELSE 4 END);

	IF @AccCol IS NULL OR @DateCol IS NULL OR @NewStatusCol IS NULL OR @BillCategoryCol IS NULL OR @ResultStatusCol IS NULL
	BEGIN
		PRINT 'usp_RefreshElix_ExecutiveSummary_LIS_Alt: could not locate Accession/Date/NewStatus/BillCategory/ResultStatus columns on dbo.LIMSMaster - skipping.';
		RETURN;
	END

	-- ── Build #Lis (real table - must survive past sp_executesql) ───────────
	DROP TABLE IF EXISTS #Lis;
	CREATE TABLE #Lis
	(
		Accession    NVARCHAR(100) NOT NULL,
		ESYear       INT           NOT NULL,
		ESMonth      INT           NOT NULL,
		NewStatus    NVARCHAR(100) NOT NULL,
		BillCategory NVARCHAR(100) NOT NULL,
		ResultStatus NVARCHAR(100) NOT NULL,
		Panel        NVARCHAR(300) NOT NULL  -- '' when @PanelCol not found
	);

	-- IsResulted is sometimes a bit/flag column rather than a status string;
	-- normalize it to 'Resulted' / 'Not Resulted' so the D.1 filter
	-- (ResultStatus = 'Resulted') works regardless of the underlying type.
	DECLARE @ResultExpr NVARCHAR(400);
	IF @ResultStatusCol = 'IsResulted'
		SET @ResultExpr = N'(CASE WHEN TRY_CAST([' + @ResultStatusCol + N'] AS INT) = 1 THEN ''Resulted''
								   WHEN CONVERT(NVARCHAR(20), [' + @ResultStatusCol + N']) IN (''Y'',''Yes'',''True'',''Resulted'') THEN ''Resulted''
								   ELSE ''Not Resulted'' END)';
	ELSE
		SET @ResultExpr = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ResultStatusCol + N']), '''')))';

	-- Panel expression: use detected column or empty string if column absent
	DECLARE @PanelExpr NVARCHAR(200) =
		CASE WHEN @PanelCol IS NOT NULL
		     THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol + N']), '''')))'
		     ELSE N'CAST('''' AS NVARCHAR(300))'
		END;

	DECLARE @LisSql NVARCHAR(MAX) = N'
		INSERT INTO #Lis (Accession, ESYear, ESMonth, NewStatus, BillCategory, ResultStatus, Panel)
		SELECT
			LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
			YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
			MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)),
			LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol + N']), ''''))),
			LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))),
			' + @ResultExpr + N',
			' + @PanelExpr + N'
		FROM dbo.LIMSMaster
		WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL;';

	EXEC sp_executesql @LisSql;

	-- LIS-specific periods (LIMSMaster date-based) PLUS grand-total sentinel.
	DROP TABLE IF EXISTS #LisPeriods;
	SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
	UNION ALL SELECT 0, 0;

	-- ───────────────────────────────────────────────────────────────────────
	--  Elix_ES_LIS - A, B, C, D, D.1, E, E.1-E.6
	-- ───────────────────────────────────────────────────────────────────────
	INSERT INTO dbo.Elix_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
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
						 AND l.NewStatus = 'Billable'
		GROUP BY p.ESYear, p.ESMonth

		-- C  Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'C', 'Billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Billable'
						 AND l.BillCategory = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- D  Unbilled
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D', 'Unbilled',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Billable'
						 AND l.BillCategory = 'Not Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- D.1  Resulted yet to be billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D.1', '  Resulted yet to be billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultStatus = 'Resulted'
						 AND l.NewStatus = 'Billable'
						 AND l.BillCategory = 'Not Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- E  Other Samples
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E', 'Other Samples',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus <> 'Billable'
		GROUP BY p.ESYear, p.ESMonth

		-- E.1  Client Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.1', '  Client Bill',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Client Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- E.2  Self Pay
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.2', '  Self Pay',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Self Pay'
		GROUP BY p.ESYear, p.ESMonth

		-- E.3  System Test
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.3', '  System Test',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'System Test'
		GROUP BY p.ESYear, p.ESMonth

		-- E.4  Deleted/Rejected
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.4', '  Deleted/Rejected',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Deleted/Rejected'
		GROUP BY p.ESYear, p.ESMonth

		-- E.5  CIP/Pending
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.5', '  CIP/Pending',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'CIP/Pending'
		GROUP BY p.ESYear, p.ESMonth

		-- E.6  Yet to be validated
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.6', '  Yet to be validated',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Yet to be validated'
		GROUP BY p.ESYear, p.ESMonth
	) lis;

	-- ── B.x  Panel sub-rows (Billable Samples by Panel) ─────────────────────
	-- Only inserted when @PanelCol was found; graceful no-op otherwise.
	IF @PanelCol IS NOT NULL
	BEGIN
		INSERT INTO dbo.Elix_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
		SELECT
			'B.' + l.Panel,
			'  '  + l.Panel,
			p.ESYear,
			p.ESMonth,
			COUNT(DISTINCT l.Accession),
			0,
			GETDATE()
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
		                 AND l.NewStatus = 'Billable'
		                 AND l.Panel     <> ''
		WHERE l.Panel IS NOT NULL AND l.Panel <> ''
		GROUP BY p.ESYear, p.ESMonth, l.Panel;
	END

	DROP TABLE IF EXISTS #Lis;
	DROP TABLE IF EXISTS #LisPeriods;

	PRINT 'usp_RefreshElix_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '19_Elixir_ExecutiveSummary_LIS_Alt.sql completed.';
GO
