-- ============================================================
-- PhiLife – LIS Breakdown Refresh ("Alt") SP
-- File : 19_PhiLife_ExecutiveSummary_LIS_Alt.sql
-- DB   : PhiLife_LRN
--
-- REWRITE (v2): PhiLife_LRN DOES have dbo.LIMSMaster. The LIS Breakdown is
-- now sourced from dbo.LIMSMaster (mirroring PCRLOA's
-- 19_PCRLOA_ExecutiveSummary_LIS_Alt.sql), using the following fields per
-- the latest layout:
--   RessultedStatus  -> 'Resulted' / 'Not Resulted'
--   ClaimStatus      -> 'Billed' / 'Not Entered in AMD' / 'Entered' / etc.
--   ClientStatus     -> '' (Blank) / 'Client Bill' / 'Self Pay' /
--                        'Test Entries' / 'Rejected Sample' /
--                        'Billing Review Required'
--   PaymentMethod    -> 'Insurance' / 'No Bill' / ...
--   SampleStatus     -> 'Received' / 'Collected'
--
-- Column NAMES on dbo.LIMSMaster are auto-detected via sys.columns (same
-- pattern as PCRLOA's @HasOrderStatus / @PanelCol2 auto-detection), with a
-- short candidate list per field and a safe '' fallback if no candidate is
-- found, so the SP never errors even if a column is missing or named
-- slightly differently — it just returns 0 for predicates that depend on
-- that field. PRINTs at the top report which physical column was bound to
-- each logical field; check these against real PhiLife_LRN data if any
-- row looks wrong.
--
-- Period bucket = the first available of RequestCollectDate /
-- DateofService / CollectionDate / ServiceDate / AccessionDate on
-- dbo.LIMSMaster (independent of the DateofService-based #Periods/#Base
-- used by PMS/Cash/Avg in 16_PhiLife_ExecutiveSummary_Aggregate.sql).
--
-- This SP fully owns dbo.Phi_ES_LIS and dbo.Phi_ES_LIS_Panel and TRUNCATEs
-- both at the start of every run, then rebuilds them in two parts:
--
-- PART 1 – LIS BREAKDOWN (Phi_ES_LIS).
--   ESMonthClaimCount = COUNT(DISTINCT Accession); ESMonthChargeAmount = 0
--   (LIS rows are sample counts, not $).
--   Total  Total Samples            -> no filter
--   A      Billable Samples-Resulted-> RessultedStatus='Resulted'
--   A1         Billed to Insurance       -> A + ClaimStatus='Billed' AND ClientStatus=''
--   A1.1           Billed In AMD             -> same as A1
--   A2         Not Entered in AMD       -> A + ClaimStatus='Not Entered in AMD' AND ClientStatus IN ('Billing Review Required','') AND PaymentMethod='Insurance'
--   A2.1           Received                  -> A2 narrowed to ClientStatus='Billing Review Required'
--   A2.2           Billing Review Required  -> A2.1 + SampleStatus='Received'
--   A2.3           Collected                 -> A2 narrowed to ClientStatus='' AND SampleStatus='Collected'
--   A3         Unbilled                  -> A + ClientStatus='' AND ClaimStatus='Entered'
--   A4         Client Bill               -> A + ClientStatus='Client Bill'
--   A4.1           Not Entered in AMD        -> A4 + ClaimStatus='Not Entered in AMD'
--   A4.2           Billed                    -> A4 + ClaimStatus='Billed'
--   A5         Self Pay                  -> A + ClientStatus='Self Pay'
--   A5.1           Billed                    -> A5 + ClaimStatus='Billed'
--   A5.2           Not Entered in AMD        -> A5 + ClaimStatus='Not Entered in AMD'
--   A6         Test Entries              -> A + ClientStatus='Test Entries' AND PaymentMethod<>'No Bill'
--   A6.1           Not Entered in AMD        -> A6 + ClaimStatus='Not Entered in AMD'
--   A6.2           Billed                    -> A6 + ClaimStatus='Billed'
--   A7         Rejected Sample           -> A + ClientStatus='Rejected Sample'
--   A7.1           Not Entered in AMD        -> A7 + ClaimStatus='Not Entered in AMD'
--   A7.2           Billed                    -> A7 + ClaimStatus='Billed'
--   A8         PaymentMethod No Bill     -> A + PaymentMethod='No Bill'
--   B      Not Resulted              -> RessultedStatus='Not Resulted'
--   B1         Not Entered in AMD        -> B + ClaimStatus='Not Entered in AMD' AND ClientStatus='' AND PaymentMethod='Insurance'
--   B1.1           Received                  -> B1 + SampleStatus='Received'
--   B1.2           Collected                 -> B1 + SampleStatus='Collected'
--   B2         Client Bill               -> B + ClientStatus='Client Bill'
--   B3         Test Entries              -> B + ClientStatus='Test Entries' AND PaymentMethod='Insurance'
--   B4         Rejected Sample           -> B + ClientStatus='Rejected Sample' AND PaymentMethod='Insurance'
--   B5         PaymentMethod No Bill     -> B + PaymentMethod='No Bill'
--
-- PART 2 – A.<PanelName> SUB-ROWS (Phi_ES_LIS_Panel), one indented sub-row
--   per distinct panel value found on dbo.LIMSMaster among Resulted
--   samples (panel column auto-detected: PanelCategory / PanelName /
--   Panelname / TestPanel / ...). 17_PhiLife_ExecutiveSummary_Read.sql
--   UNIONs Phi_ES_LIS_Panel into the LIS category. RoleID 'A.<PanelName>'
--   sorts immediately after 'A' and before 'A1' (string comparison: 'A'
--   is a prefix of 'A.xxx', and 'A.' < 'A1'), so the panel rows render
--   directly under "Billable Samples - Resulted" as indented sub-rows.
-- ============================================================
SET NOCOUNT ON;
GO

Create or ALTER   PROCEDURE [dbo].[usp_RefreshPhi_ExecutiveSummary_LIS_Alt]
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.Phi_ES_LIS;
	TRUNCATE TABLE dbo.Phi_ES_LIS_Panel;

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
	BEGIN
		PRINT 'usp_RefreshPhi_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
		RETURN;
	END

	-- ───────────────────────────────────────────────────────────────────────
	--  Auto-detect dbo.LIMSMaster column names for each logical field.
	-- ───────────────────────────────────────────────────────────────────────
	DECLARE @AccCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('AccessionNumber','Accession')
		ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 ELSE 2 END);

	DECLARE @DateCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('RequestCollectDate','DateofService','CollectionDate','ServiceDate','AccessionDate')
		ORDER BY CASE name
			WHEN 'RequestCollectDate' THEN 0 WHEN 'DateofService' THEN 1
			WHEN 'CollectionDate' THEN 2 WHEN 'ServiceDate' THEN 3
			WHEN 'AccessionDate' THEN 4 ELSE 5 END);

	DECLARE @ResultedCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('RessultedStatus','ResultedStatus','ResultStatus','IsResulted')
		ORDER BY CASE name
			WHEN 'RessultedStatus' THEN 0 WHEN 'ResultedStatus' THEN 1
			WHEN 'ResultStatus' THEN 2 WHEN 'IsResulted' THEN 3 ELSE 4 END);

	DECLARE @ClaimStatusCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'ClaimStatus');

	DECLARE @ClientStatusCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('ClientStatus','Client_Status','Client')
		ORDER BY CASE name WHEN 'ClientStatus' THEN 0 WHEN 'Client_Status' THEN 1 WHEN 'Client' THEN 2 ELSE 3 END);

	DECLARE @PaymentMethodCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('PaymentMethod','PayerType','PaymentType','BilledorNot')
		ORDER BY CASE name
			WHEN 'PaymentMethod' THEN 0 WHEN 'PayerType' THEN 1
			WHEN 'PaymentType' THEN 2 WHEN 'BilledorNot' THEN 3 ELSE 4 END);

	DECLARE @SampleStatusCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('SampleStatus','Sample_Status')
		ORDER BY CASE name WHEN 'SampleStatus' THEN 0 WHEN 'Sample_Status' THEN 1 ELSE 2 END);

	IF @AccCol IS NULL OR @DateCol IS NULL
	BEGIN
		PRINT 'usp_RefreshPhi_ExecutiveSummary_LIS_Alt: could not locate an Accession/AccessionNumber column and/or a date column (RequestCollectDate/DateofService/CollectionDate/ServiceDate/AccessionDate) on dbo.LIMSMaster - nothing to do.';
		RETURN;
	END

	PRINT 'usp_RefreshPhi_ExecutiveSummary_LIS_Alt: Accession=' + @AccCol
		+ ', Date=' + @DateCol
		+ ', RessultedStatus=' + ISNULL(@ResultedCol, '(none-defaults to '''')')
		+ ', ClaimStatus=' + ISNULL(@ClaimStatusCol, '(none-defaults to '''')')
		+ ', ClientStatus=' + ISNULL(@ClientStatusCol, '(none-defaults to '''')')
		+ ', PaymentMethod=' + ISNULL(@PaymentMethodCol, '(none-defaults to '''')')
		+ ', SampleStatus=' + ISNULL(@SampleStatusCol, '(none-defaults to '''')');

	DECLARE @AccExpr           NVARCHAR(300) = N'LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N'])))';
	DECLARE @DateExpr          NVARCHAR(300) = N'TRY_CAST([' + @DateCol + N'] AS DATE)';
	DECLARE @ResultedExpr      NVARCHAR(300) = CASE WHEN @ResultedCol     IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ResultedCol     + N']), '''')))' ELSE N'''''' END;
	DECLARE @ClaimStatusExpr   NVARCHAR(300) = CASE WHEN @ClaimStatusCol  IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ClaimStatusCol  + N']), '''')))' ELSE N'''''' END;
	DECLARE @ClientStatusExpr  NVARCHAR(300) = CASE WHEN @ClientStatusCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ClientStatusCol + N']), '''')))' ELSE N'''''' END;
	DECLARE @PaymentMethodExpr NVARCHAR(300) = CASE WHEN @PaymentMethodCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @PaymentMethodCol + N']), '''')))' ELSE N'''''' END;
	DECLARE @SampleStatusExpr  NVARCHAR(300) = CASE WHEN @SampleStatusCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @SampleStatusCol + N']), '''')))' ELSE N'''''' END;

	-- ───────────────────────────────────────────────────────────────────────
	--  PART 1 – LIS Breakdown (dbo.Phi_ES_LIS), Total/A/A1-A8 (+subs)/B/B1-B5 (+subs).
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #Lis;

	-- NOTE: must be a real CREATE TABLE (not SELECT...INTO inside the dynamic
	-- SQL below) — a temp table created via SELECT...INTO inside
	-- sp_executesql lives only in that nested scope and is dropped the
	-- moment sp_executesql returns, leaving #Lis invisible to the rest of
	-- this procedure ("Invalid object name '#Lis'").
	CREATE TABLE #Lis
	(
		Accession   NVARCHAR(100) NOT NULL,
		ESYear      INT           NOT NULL,
		ESMonth     INT           NOT NULL,
		ResultedNot NVARCHAR(100) NOT NULL,
		ClaimStat   NVARCHAR(100) NOT NULL,
		ClientStat  NVARCHAR(100) NOT NULL,
		PayMethod   NVARCHAR(100) NOT NULL,
		SampleStat  NVARCHAR(100) NOT NULL
	);

	DECLARE @LisSql NVARCHAR(MAX) = N'
		INSERT INTO #Lis (Accession, ESYear, ESMonth, ResultedNot, ClaimStat, ClientStat, PayMethod, SampleStat)
		SELECT
			' + @AccExpr + N',
			YEAR (' + @DateExpr + N'),
			MONTH(' + @DateExpr + N'),
			' + @ResultedExpr + N',
			' + @ClaimStatusExpr + N',
			' + @ClientStatusExpr + N',
			' + @PaymentMethodExpr + N',
			' + @SampleStatusExpr + N'
		FROM dbo.LIMSMaster
		WHERE ' + @DateExpr + N' IS NOT NULL
		  AND NULLIF(' + @AccExpr + N', '''') IS NOT NULL;';

	EXEC sp_executesql @LisSql;

	-- Periods: every (Year,Month) present in #Lis PLUS a (0,0) grand-total sentinel.
	DROP TABLE IF EXISTS #LisPeriods;
	SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
	UNION ALL SELECT 0, 0;

	INSERT INTO dbo.Phi_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
	FROM
	(
		-- Total  Total Samples
		SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
			   COUNT(DISTINCT l.Accession) AS ClaimCount
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- A  Billable Samples - Resulted
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples - Resulted',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted'
		GROUP BY p.ESYear, p.ESMonth

		-- A1  Billed to Insurance
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'C', 'Billed to Insurance',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClaimStat = 'Billed' AND l.ClientStat = ''
		GROUP BY p.ESYear, p.ESMonth

		-- A1.1  Billed In AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'C.1', '  Billed In AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClaimStat = 'Billed' AND l.ClientStat = ''
		GROUP BY p.ESYear, p.ESMonth

		-- A2  Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D', 'Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClaimStat = 'Not Entered in AMD'
						 AND l.ClientStat IN ('Billing Review Required','') AND l.PayMethod = 'Insurance'
		GROUP BY p.ESYear, p.ESMonth

		-- A2.1  Received
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D.1', '  Received',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClaimStat = 'Not Entered in AMD'
						 AND l.ClientStat = 'Billing Review Required' AND l.PayMethod = 'Insurance'
		GROUP BY p.ESYear, p.ESMonth

		-- A2.2  Billing Review Required
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D.2', '  Billing Review Required',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClaimStat = 'Not Entered in AMD'
						 AND l.ClientStat = 'Billing Review Required' AND l.PayMethod = 'Insurance' AND l.SampleStat = 'Received'
		GROUP BY p.ESYear, p.ESMonth

		-- A2.3  Collected
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D.3', '  Collected',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClaimStat = 'Not Entered in AMD'
						 AND l.ClientStat = '' AND l.PayMethod = 'Insurance' AND l.SampleStat = 'Collected'
		GROUP BY p.ESYear, p.ESMonth

		-- A3  Unbilled
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E', 'Unbilled',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = '' AND l.ClaimStat = 'Entered'
		GROUP BY p.ESYear, p.ESMonth

		-- A4  Client Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'F', 'Client Bill',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Client Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- A4.1  Client Bill - Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'F.1', '  Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Client Bill' AND l.ClaimStat = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- A4.2  Client Bill - Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'F.2', '  Billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Client Bill' AND l.ClaimStat = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A5  Self Pay
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G', 'Self Pay',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Self Pay'
		GROUP BY p.ESYear, p.ESMonth

		-- A5.1  Self Pay - Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G.1', '  Billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Self Pay' AND l.ClaimStat = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A5.2  Self Pay - Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G.2', '  Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Self Pay' AND l.ClaimStat = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- A6  Test Entries
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H', 'Test Entries',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Test Entries' AND l.PayMethod <> 'No Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- A6.1  Test Entries - Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H.1', '  Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Test Entries' AND l.PayMethod <> 'No Bill' AND l.ClaimStat = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- A6.2  Test Entries - Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H.2', '  Billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Test Entries' AND l.PayMethod <> 'No Bill' AND l.ClaimStat = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A7  Rejected Sample
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I', 'Rejected Sample',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Rejected Sample'
		GROUP BY p.ESYear, p.ESMonth

		-- A7.1  Rejected Sample - Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I.1', '  Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Rejected Sample' AND l.ClaimStat = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- A7.2  Rejected Sample - Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I.2', '  Billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.ClientStat = 'Rejected Sample' AND l.ClaimStat = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A8  PaymentMethod No Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'J', 'PaymentMethod No Bill',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Resulted' AND l.PayMethod = 'No Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- B  Not Resulted
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'K', 'Not Resulted',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Not Resulted'
		GROUP BY p.ESYear, p.ESMonth

		-- B1  Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'L', 'Not Entered in AMD',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Not Resulted' AND l.ClaimStat = 'Not Entered in AMD' AND l.ClientStat = '' AND l.PayMethod = 'Insurance'
		GROUP BY p.ESYear, p.ESMonth

		-- B1.1  Received
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'L.1', '  Received',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Not Resulted' AND l.ClaimStat = 'Not Entered in AMD' AND l.ClientStat = '' AND l.PayMethod = 'Insurance' AND l.SampleStat = 'Received'
		GROUP BY p.ESYear, p.ESMonth

		-- B1.2  Collected
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'L.2', '  Collected',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Not Resulted' AND l.ClaimStat = 'Not Entered in AMD' AND l.ClientStat = '' AND l.PayMethod = 'Insurance' AND l.SampleStat = 'Collected'
		GROUP BY p.ESYear, p.ESMonth

		-- B2  Client Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'M', 'Client Bill',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Not Resulted' AND l.ClientStat = 'Client Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- B3  Test Entries
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N', 'Test Entries',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Not Resulted' AND l.ClientStat = 'Test Entries' AND l.PayMethod = 'Insurance'
		GROUP BY p.ESYear, p.ESMonth

		-- B4  Rejected Sample
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'O', 'Rejected Sample',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Not Resulted' AND l.ClientStat = 'Rejected Sample' AND l.PayMethod = 'Insurance'
		GROUP BY p.ESYear, p.ESMonth

		-- B5  PaymentMethod No Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P', 'PaymentMethod No Bill',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultedNot = 'Not Resulted' AND l.PayMethod = 'No Bill'
		GROUP BY p.ESYear, p.ESMonth
	) lis;

	DROP TABLE IF EXISTS #Lis;
	DROP TABLE IF EXISTS #LisPeriods;

	-- ───────────────────────────────────────────────────────────────────────
	--  PART 2 – A.<PanelName> sub-rows (dbo.Phi_ES_LIS_Panel).
	-- ───────────────────────────────────────────────────────────────────────
	DECLARE @PanelCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
		ORDER BY CASE name
			WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2
			WHEN 'TestPanelName' THEN 3 WHEN 'TestPanelname' THEN 4 WHEN 'TestPanel' THEN 5
			WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8 ELSE 9 END);

	IF @PanelCol IS NULL
	BEGIN
		PRINT 'usp_RefreshPhi_ExecutiveSummary_LIS_Alt: no panel-name column found on dbo.LIMSMaster - skipping A.<PanelName> sub-rows.';
	END
	ELSE
	BEGIN
		DECLARE @PanelExpr NVARCHAR(400) =
			N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol + N']), '''')))';

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
				' + @AccExpr + N',
				YEAR (' + @DateExpr + N'),
				MONTH(' + @DateExpr + N'),
				' + @ResultedExpr + N',
				' + @PanelExpr + N'
			FROM dbo.LIMSMaster
			WHERE ' + @DateExpr + N' IS NOT NULL
			  AND NULLIF(' + @AccExpr + N', '''') IS NOT NULL;';

		EXEC sp_executesql @Lis2Sql;

		-- Periods: every (Year,Month) present in #Lis2 PLUS a (0,0) grand-total sentinel.
		DROP TABLE IF EXISTS #LisPeriods2;
		SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods2 FROM #Lis2
		UNION ALL SELECT 0, 0;

		-- Distinct panel names among Resulted samples, for the A.<PanelName> sub-rows.
		DROP TABLE IF EXISTS #LisPanels2;
		SELECT DISTINCT PanelName INTO #LisPanels2
		FROM #Lis2
		WHERE ResultedNot = 'Resulted' AND PanelName <> '';

		-- ── A.<PanelName> sub-rows (panel-wise breakdown of "Resulted") ──────────
		INSERT INTO dbo.Phi_ES_LIS_Panel (RoleID, PanelName, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
		SELECT 'B.' + pn.PanelName, pn.PanelName, '  ' + pn.PanelName,
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

	PRINT 'usp_RefreshPhi_ExecutiveSummary_LIS_Alt completed.';
END;

GO

PRINT '19_PhiLife_ExecutiveSummary_LIS_Alt.sql completed.';
GO
