-- ============================================================
-- PCR Labs of America – LIS Breakdown Refresh ("Alt") SP
-- File : 19_PCRLOA_ExecutiveSummary_LIS_Alt.sql
-- DB   : PCRLabsofAmerica
--
-- Run order: AFTER ingestion of LIMSMaster (independent of
-- usp_RefreshPCR_ExecutiveSummary / ClaimLevelData, which now only
-- populates the PMS/Cash/Avg breakdowns). Called by ClaimLineCSVDataCapture
-- via ClaimLineDbService.RefreshPCRLabsExecutiveSummary().
--
-- This SP fully owns dbo.PCR_ES_LIS and dbo.PCR_ES_LIS_Panel and TRUNCATEs
-- both at the start of every run, then rebuilds them in two parts:
--
-- PART 1 – LIS BREAKDOWN (PCR_ES_LIS), populated from dbo.LIMSMaster.
--   Period bucket = RequestCollectDate (independent of the DateofService-based
--   #Periods/#Base used by PMS/Cash/Avg in 16_PCRLOA_ExecutiveSummary_Aggregate.sql).
--   ESMonthClaimCount = COUNT(DISTINCT Accession); ESMonthChargeAmount = 0
--   (LIS rows are claim counts, not $).
--   A    Total Samples                → no filter
--   B    Resulted                     → RessultedStatus='Resulted'
--   C    Billed                     → B + ClientStatus='' AND BilledorNot='Billed'
--   D    Client Bill                → B + ClientStatus='Client Bill'
--   D1       Billed                   → D + BilledorNot='Billed'
--   D2       Not Entered in AMD       → D + Unbilled AND ClaimStatus='Not Entered in AMD'
--   D3       Entered                  → D + Unbilled AND ClaimStatus='Entered'
--   E    Not Entered in AMD         → B + ClientStatus IN ('Billing Review Required','') AND ClaimStatus='Not Entered in AMD'
--   E1       Completed                → E + OrderStatus='Completed'
--   E2       Billing Review Required  → B + ClientStatus='Billing Review Required' AND ClaimStatus='Not Entered in AMD'
--   E3       In Transit                → E + OrderStatus='In Transit'
--   F    Unbilled - Not Released to Payer (EDI Hold)
--                                      → B + ClientStatus='' AND Unbilled AND ClaimStatus='Entered' AND OrderStatus='Completed'
--   G    Test Entries               → B + ClientStatus='Test Entries'
--   G1       Not Entered in AMD       → G + Unbilled AND ClaimStatus='Not Entered in AMD'
--   H    Rejected Sample            → B + ClientStatus='Rejected Sample'
--   H1       Not Entered in AMD       → H + Unbilled AND ClaimStatus='Not Entered in AMD'
--   I    Not Resulted                 → RessultedStatus<>'Resulted'
--   I1     Not Entered in AMD         → I + ClientStatus='' AND Unbilled AND ClaimStatus='Not Entered in AMD'
--   I2     Client Bill                → I + ClientStatus='Client Bill'
--   I3     Test Entries               → I + ClientStatus='Test Entries'
--   I4     Rejected Sample            → I + ClientStatus='Rejected Sample'
--   I5     Self Pay                   → I + ClientStatus='Self Pay'
--   NOTE: OrderStatus is referenced by the LIS layout image (E1/E3/F) but is not
--   among the confirmed dbo.LIMSMaster columns; it is auto-detected via
--   sys.columns and treated as '' if absent — verify against real PCR data.
--
-- PART 2 – B.<PanelName> SUB-ROWS (PCR_ES_LIS_Panel), one indented sub-row
--   per distinct panel value found on dbo.LIMSMaster among Resulted samples,
--   e.g. UTI Panel, Fungal Nail Panel, Wound Panel, ABR/UTI PCR Reflex,
--   H Pylori PCR, Nail PCR Reflex, Fungal Nail Panel/Wound PCR Reflex,
--   ABR/Wound PCR Reflex, ABR/Nail PCR Reflex/Wound PCR Reflex,
--   Fungal Nail Panel/UTI Panel, ...
--   17_PCRLOA_ExecutiveSummary_Read.sql already UNIONs PCR_ES_LIS_Panel into
--   the LIS category. RoleID 'B.<PanelName>' sorts immediately after 'B' and
--   before 'C' (string comparison: 'B' is a prefix of 'B.xxx', and 'B.' < 'C'),
--   so the panel rows render directly under "Resulted" as indented
--   ('    '-prefixed) sub-row entries — exactly as in the Excel layout and
--   matching the RisingTides web report's expand/collapse behaviour under
--   "Resulted". Panel column auto-detection mirrors
--   18_PCRLOA_ExecutiveSummary_Detail.sql's @PanelCol
--   (PanelCategory / PanelName / Panelname / TestPanel / ... ).
--   Period bucket = RequestCollectDate, with a (0,0) grand-total sentinel row.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_ExecutiveSummary_LIS_Alt
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.PCR_ES_LIS;
	TRUNCATE TABLE dbo.PCR_ES_LIS_Panel;

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
	BEGIN
		PRINT 'usp_RefreshPCR_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found – nothing to do.';
		RETURN;
	END

	-- ───────────────────────────────────────────────────────────────────────
	--  PART 1 – LIS Breakdown (dbo.PCR_ES_LIS), A..I5.
	-- ───────────────────────────────────────────────────────────────────────

	-- OrderStatus is referenced by the LIS layout image (rows E1/E3/F) but is
	-- not part of the confirmed dbo.LIMSMaster columns, so it is auto-detected
	-- and treated as '' if absent.
	DECLARE @HasOrderStatus BIT = CASE WHEN EXISTS (
		SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'OrderStatus'
	) THEN 1 ELSE 0 END;
	DECLARE @OrderStatusExpr NVARCHAR(200) =
		CASE WHEN @HasOrderStatus = 1
			 THEN N'LTRIM(RTRIM(ISNULL(OrderStatus,'''')))'
			 ELSE N'''''' END;

	DROP TABLE IF EXISTS #Lis;

	-- NOTE: must be a real CREATE TABLE (not SELECT...INTO inside the dynamic
	-- SQL below) — a temp table created via SELECT...INTO inside
	-- sp_executesql lives only in that nested scope and is dropped the
	-- moment sp_executesql returns, leaving #Lis invisible to the rest of
	-- this procedure ("Invalid object name '#Lis'").
	CREATE TABLE #Lis
	(
		Accession       NVARCHAR(100) NOT NULL,
		ESYear          INT           NOT NULL,
		ESMonth         INT           NOT NULL,
		ResultedNot     NVARCHAR(100) NOT NULL,
		LisClientStatus NVARCHAR(100) NOT NULL,
		BilledUnbilled  NVARCHAR(100) NOT NULL,
		LisClaimStatus  NVARCHAR(100) NOT NULL,
		LisOrderStatus  NVARCHAR(100) NOT NULL
	);

	DECLARE @LisSql NVARCHAR(MAX) = N'
		INSERT INTO #Lis (Accession, ESYear, ESMonth, ResultedNot, LisClientStatus, BilledUnbilled, LisClaimStatus, LisOrderStatus)
		SELECT
			LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))),
			YEAR (TRY_CAST(RequestCollectDate AS DATE)),
			MONTH(TRY_CAST(RequestCollectDate AS DATE)),
			LTRIM(RTRIM(ISNULL(RessultedStatus, ''''))),
			LTRIM(RTRIM(ISNULL(ClientStatus,    ''''))),
			LTRIM(RTRIM(ISNULL(BilledorNot,     ''''))),
			LTRIM(RTRIM(ISNULL(ClaimStatus,     ''''))),
			' + @OrderStatusExpr + N'
		FROM dbo.LIMSMaster
		WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '''') IS NOT NULL;';

	EXEC sp_executesql @LisSql;

	-- LIS-specific periods (RequestCollectDate-based) PLUS grand-total sentinel.
	DROP TABLE IF EXISTS #LisPeriods;
	SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
	UNION ALL SELECT 0, 0;

	INSERT INTO dbo.PCR_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
	FROM
	(
		-- A  Total Samples
		SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
			   COUNT(DISTINCT l.Accession) AS ClaimCount
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- B  Resulted
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B', 'Resulted',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
		GROUP BY p.ESYear, p.ESMonth

		-- C  Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'C', 'Billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = ''
						 AND l.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- D  Client Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D', ' Client Bill',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = 'Client Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- D1  Client Bill - Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D1', '  Billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = 'Client Bill'
						 AND l.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- D2  Client Bill - Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D2', '  Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = 'Client Bill'
						 AND l.BilledUnbilled = 'Unbilled'
						 AND l.LisClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- D3  Client Bill - Entered
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D3', '  Entered',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = 'Client Bill'
						 AND l.BilledUnbilled = 'Unbilled'
						 AND l.LisClaimStatus = 'Entered'
		GROUP BY p.ESYear, p.ESMonth

		-- E  Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E', 'Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus IN ('Billing Review Required','')
						 AND l.LisClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- E1  Completed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E1', '  Completed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus IN ('Billing Review Required','')
						 AND l.LisClaimStatus = 'Not Entered in AMD'
						 AND l.LisOrderStatus = 'Completed'
		GROUP BY p.ESYear, p.ESMonth

		-- E2  Billing Review Required
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E2', '  Billing Review Required',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = 'Billing Review Required'
						 AND l.LisClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- E3  In Transit
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E3', '  In Transit',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus IN ('Billing Review Required','')
						 AND l.LisClaimStatus = 'Not Entered in AMD'
						 AND l.LisOrderStatus = 'In Transit'
		GROUP BY p.ESYear, p.ESMonth

		-- F  Unbilled - Not Released to Payer (EDI Hold)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'F', 'Unbilled - Not Released to Payer (EDI Hold)',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = ''
						 AND l.BilledUnbilled = 'Unbilled'
						 AND l.LisClaimStatus = 'Entered'
						 AND l.LisOrderStatus = 'Completed'
		GROUP BY p.ESYear, p.ESMonth

		-- G  Test Entries
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G', '  Test Entries',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = 'Test Entries'
		GROUP BY p.ESYear, p.ESMonth

		-- G1  Test Entries - Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G1', '  Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = 'Test Entries'
						 AND l.BilledUnbilled = 'Unbilled'
						 AND l.LisClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- H  Rejected Sample
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H', 'Rejected Sample',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = 'Rejected Sample'
		GROUP BY p.ESYear, p.ESMonth

		-- H1  Rejected Sample - Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H1', '  Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
						 AND l.LisClientStatus = 'Rejected Sample'
						 AND l.BilledUnbilled = 'Unbilled'
						 AND l.LisClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- I  Not Resulted
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I', 'Not Resulted',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot <> 'Resulted'
		GROUP BY p.ESYear, p.ESMonth

		-- I1  Not Resulted - Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I1', '  Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot <> 'Resulted'
						 AND l.LisClientStatus = ''
						 AND l.BilledUnbilled = 'Unbilled'
						 AND l.LisClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- I2  Not Resulted - Client Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I2', '  Client Bill',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot <> 'Resulted'
						 AND l.LisClientStatus = 'Client Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- I3  Not Resulted - Test Entries
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I3', '  Test Entries',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot <> 'Resulted'
						 AND l.LisClientStatus = 'Test Entries'
		GROUP BY p.ESYear, p.ESMonth

		-- I4  Not Resulted - Rejected Sample
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I4', '  Rejected Sample',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot <> 'Resulted'
						 AND l.LisClientStatus = 'Rejected Sample'
		GROUP BY p.ESYear, p.ESMonth

		-- I5  Not Resulted - Self Pay
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I5', '  Self Pay',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot <> 'Resulted'
						 AND l.LisClientStatus = 'Self Pay'
		GROUP BY p.ESYear, p.ESMonth
	) lis;

	DROP TABLE IF EXISTS #Lis;
	DROP TABLE IF EXISTS #LisPeriods;

	-- ───────────────────────────────────────────────────────────────────────
	--  PART 2 – B.<PanelName> sub-rows (dbo.PCR_ES_LIS_Panel).
	-- ───────────────────────────────────────────────────────────────────────

	-- Auto-detect the panel-name column on dbo.LIMSMaster (same candidate
	-- list / priority order as 18_PCRLOA_ExecutiveSummary_Detail.sql's @PanelCol).
	DECLARE @PanelCol2 SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
		ORDER BY CASE name
			WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2
			WHEN 'TestPanelName' THEN 3 WHEN 'TestPanelname' THEN 4 WHEN 'TestPanel' THEN 5
			WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8 ELSE 9 END);

	IF @PanelCol2 IS NULL
	BEGIN
		PRINT 'usp_RefreshPCR_ExecutiveSummary_LIS_Alt: no panel-name column found on dbo.LIMSMaster – skipping B.<PanelName> sub-rows.';
	END
	ELSE
	BEGIN
		DECLARE @PanelExpr2 NVARCHAR(400) =
			'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol2 + N']), '''')))';

		DROP TABLE IF EXISTS #Lis2;
		CREATE TABLE #Lis2
		(
			Accession   NVARCHAR(100) NOT NULL,
			ESYear      INT           NOT NULL,
			ESMonth     INT           NOT NULL,
			ResultedNot NVARCHAR(100) NOT NULL,
			PanelName   NVARCHAR(300) NOT NULL
		);

		DECLARE @Lis2Sql NVARCHAR(MAX) = N'
			INSERT INTO #Lis2 (Accession, ESYear, ESMonth, ResultedNot, PanelName)
			SELECT
				LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))),
				YEAR (TRY_CAST(RequestCollectDate AS DATE)),
				MONTH(TRY_CAST(RequestCollectDate AS DATE)),
				LTRIM(RTRIM(ISNULL(RessultedStatus, ''''))),
				' + @PanelExpr2 + N'
			FROM dbo.LIMSMaster
			WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
			  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '''') IS NOT NULL;';

		EXEC sp_executesql @Lis2Sql;

		-- Periods: every (Year,Month) present in #Lis2 PLUS a (0,0) grand-total sentinel.
		DROP TABLE IF EXISTS #LisPeriods2;
		SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods2 FROM #Lis2
		UNION ALL SELECT 0, 0;

		-- Distinct panel names among Resulted samples, for the B.<PanelName> sub-rows.
		DROP TABLE IF EXISTS #LisPanels2;
		SELECT DISTINCT PanelName INTO #LisPanels2
		FROM #Lis2
		WHERE ResultedNot = 'Resulted' AND PanelName <> '';

		-- ── B.<PanelName> sub-rows (panel-wise breakdown of "Resulted") ──────────
		INSERT INTO dbo.PCR_ES_LIS_Panel (RoleID, PanelName, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
		SELECT 'B.' + pn.PanelName, pn.PanelName, '    ' + pn.PanelName,
		       p.ESYear, p.ESMonth, COUNT(DISTINCT l.Accession), 0, GETDATE()
		FROM #LisPanels2 pn
		CROSS JOIN #LisPeriods2 p
		LEFT JOIN #Lis2 l
		       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
		      AND l.ResultedNot = 'Resulted'
		      AND l.PanelName = pn.PanelName
		GROUP BY pn.PanelName, p.ESYear, p.ESMonth;

		DROP TABLE IF EXISTS #Lis2;
		DROP TABLE IF EXISTS #LisPeriods2;
		DROP TABLE IF EXISTS #LisPanels2;
	END

	PRINT 'usp_RefreshPCR_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '19_PCRLOA_ExecutiveSummary_LIS_Alt.sql completed.';
GO
