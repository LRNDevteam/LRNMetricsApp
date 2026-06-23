-- ============================================================
-- Elixir – Executive Summary Refresh ("Aggregate") SP – PMS / Cash / Avg
-- File : 16_Elixir_ExecutiveSummary_Aggregate.sql
-- DB   : Elixir_LRN
--
-- Mirrors PhiLife\16_PhiLife_ExecutiveSummary_Aggregate.sql, but uses the
-- SIMPLER RoleID scheme from the Elixir LIS/PMS/Cash/Avg breakdown spec.
-- Run 15_Elixir_ExecutiveSummary_Tables.sql first to create the four
-- Elix_ES_* tables.
--
-- This SP owns dbo.Elix_ES_PMS, dbo.Elix_ES_Cash and dbo.Elix_ES_Avg and
-- TRUNCATEs all three at the start of every run. The LIS breakdown
-- (dbo.Elix_ES_LIS) is owned by 19_Elixir_ExecutiveSummary_LIS_Alt.sql
-- (usp_RefreshElix_ExecutiveSummary_LIS_Alt) and is NOT touched here.
--
-- Source: dbo.ClaimLevelData (AccessionNumber, DateofService-based period,
-- BilledUnbilled, ClaimStatus, ChargeAmount, InsurancePayment,
-- PatientPayment, InsuranceAdjustments, PatientAdjustments,
-- InsuranceBalance, PatientBalance).
--
-- RoleID scheme:
--   PMS  : F, G, H, I (Billed Mismatches - cross-table vs LIMSMaster),
--          J, K, L, M, N, O, P (+ P.1-P.3)
--   Cash : Q, R, S, T, U, V, W, X (+ X.1-X.3)
--   Avg  : Y, Z, AA
--
-- 'I' (Billed Mismatches - LIS Accession Cannot be Matched) compares
-- Billed counts in #Base (ClaimLevelData, BilledUnbilled='Billed') vs.
-- dbo.LIMSMaster (NewStatus='Billable' AND BillCategory='Billed'). The
-- LIMSMaster Accession/Date/NewStatus/BillCategory column NAMES are
-- auto-detected via sys.columns (same candidate-list technique used in
-- 19_Elixir_ExecutiveSummary_LIS_Alt.sql). If dbo.LIMSMaster does not
-- exist, or the columns cannot be located, 'I' degenerates to I = F
-- (no mismatch detectable), guarded by OBJECT_ID('dbo.LIMSMaster','U').
--
-- Notes on rows where the spec text was ambiguous or left blank:
--   H  "Voided claims" – the spec provided NO formula. Implemented as
--      COUNT(DISTINCT AccessionNumber) WHERE ClaimStatus = 'Voided'
--      (best-effort guess pending confirmation; returns 0 if no rows
--      have that ClaimStatus value).
--   X.2 "Partially Denied ($)" – spec lists FOUR ClaimStatus values
--      (Partially Denied, Partially Paid, Partially Adjusted, Patient
--      Responsibility) combined via IN(...).
--   Y/Z/AA "Average Payment Per Claim" – numerators/denominators built
--      from #Base via CASE-based SUM/COUNT(DISTINCT) expressions; AA's
--      denominator uses a single COUNT(DISTINCT AccessionNumber) over the
--      union of ClaimStatus values (Fully Paid, Fully Adjusted, Patient
--      Responsibility, Partially Paid, Fully Denied, Partially Denied) to
--      avoid double-counting the same accession across categories,
--      mirroring PhiLife's AL pattern.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_ExecutiveSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.Elix_ES_PMS;
	TRUNCATE TABLE dbo.Elix_ES_Cash;
	TRUNCATE TABLE dbo.Elix_ES_Avg;

	-- ───────────────────────────────────────────────────────────────────────
	--  #Base – one row per billable accession, DateofService-based period.
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #Base;

	SELECT
		AccessionNumber,
		YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
		ISNULL(BillStatus, '')               AS BilledUnbilled,
		ISNULL(LTRIM(RTRIM(ClaimStatus)), '')    AS ClaimStatus,
		ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
		ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
		ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
		ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
		ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
		ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
		ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance
	INTO #Base
	FROM dbo.ClaimLevelData
	WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
	  AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL;

	-- Periods: every (Year,Month) present in #Base PLUS a (0,0) grand-total sentinel.
	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	-- ───────────────────────────────────────────────────────────────────────
	--  'I' Billed-Mismatch support: pre-aggregate Billed counts.
	--  #BaseBilledCount – ClaimLevelData Billed accessions per period.
	--  #LisBilled/#LisBilledCount – LIMSMaster accessions with
	--  NewStatus='Billable' AND BillCategory='Billed' per period
	--  (empty when dbo.LIMSMaster or the required columns don't exist,
	--  so I degenerates to I = F).
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #BaseBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT AccessionNumber) AS BilledCount
	INTO #BaseBilledCount
	FROM #Base
	WHERE BilledUnbilled = 'Billed'
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT AccessionNumber) FROM #Base WHERE BilledUnbilled = 'Billed';

	DROP TABLE IF EXISTS #LisBilled;
	CREATE TABLE #LisBilled
	(
		Accession NVARCHAR(100) NOT NULL,
		ESYear    INT           NOT NULL,
		ESMonth   INT           NOT NULL
	);

	IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
	BEGIN
		DECLARE @AccCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('AccessionNumber','Accession','AccessionNo')
			ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

		DECLARE @DateCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('RequestCollectDate','DateofService','CollectionDate','ServiceDate','AccessionDate')
			ORDER BY CASE name
				WHEN 'RequestCollectDate' THEN 0 WHEN 'DateofService' THEN 1
				WHEN 'CollectionDate' THEN 2 WHEN 'ServiceDate' THEN 3
				WHEN 'AccessionDate' THEN 4 ELSE 5 END);

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

		IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @NewStatusCol IS NOT NULL AND @BillCategoryCol IS NOT NULL
		BEGIN
			DECLARE @LisBilledSql NVARCHAR(MAX) = N'
				INSERT INTO #LisBilled (Accession, ESYear, ESMonth)
				SELECT
					LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
					YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
					MONTH(TRY_CAST([' + @DateCol + N'] AS DATE))
				FROM dbo.LIMSMaster
				WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
				  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
				  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol + N']), ''''))) = ''Billable''
				  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))) = ''Billed'';';

			EXEC sp_executesql @LisBilledSql;
		END
		ELSE
		BEGIN
			PRINT 'usp_RefreshElix_ExecutiveSummary: could not locate Accession/Date/NewStatus/BillCategory columns on dbo.LIMSMaster - ''I'' will degenerate to I = F.';
		END
	END

	DROP TABLE IF EXISTS #LisBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT Accession) AS BilledCount
	INTO #LisBilledCount
	FROM #LisBilled
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT Accession) FROM #LisBilled;

	-- ───────────────────────────────────────────────────────────────────────
	--  Elix_ES_PMS – F, G, H, I, J, K, L, M, N, O, P, P.1, P.2, P.3
	-- ───────────────────────────────────────────────────────────────────────
	INSERT INTO dbo.Elix_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
	FROM
	(
		-- F  No. of Billed Claims
		SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'No. of Billed Claims' AS Description,
			   COUNT(DISTINCT b.AccessionNumber) AS ClaimCount
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled')
		GROUP BY p.ESYear, p.ESMonth

		-- G  Unbilled Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G', 'Unbilled Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus IN ('Unbilled','Unbilled - PB')
		GROUP BY p.ESYear, p.ESMonth

		-- H  Voided claims (spec gave no formula - see header note)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H', 'Voided claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Voided'
		GROUP BY p.ESYear, p.ESMonth

		-- I  Billed Mismatches - LIS Accession Cannot be Matched (degenerates to I = F without LIMSMaster)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I', 'Billed Mismatches - LIS Accession Cannot be Matched',
			   ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0)
		FROM #Periods p
		LEFT JOIN #BaseBilledCount bb ON bb.ESYear = p.ESYear AND bb.ESMonth = p.ESMonth
		LEFT JOIN #LisBilledCount  ll ON ll.ESYear = p.ESYear AND ll.ESMonth = p.ESMonth

		-- J  No. of Fully Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'J', 'No. of Fully Paid Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- K  No. of Fully Patient Responsibility Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'K', 'No. of Fully Patient Responsibility Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility'
		GROUP BY p.ESYear, p.ESMonth

		-- L  No. of Patient Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'L', 'No. of Patient Paid Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment'
		GROUP BY p.ESYear, p.ESMonth

		-- M  No. of Adjusted/Written Off Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'M', 'No. of Adjusted/Written Off Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		-- N  No. of Partially Adjusted claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Adjusted claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		-- O  No. of Partially Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'O', 'No. of Partially Paid Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- P  No. of Insurance Balance Claims (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P', 'No. of Insurance Balance Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus IN ('Denied','No Response','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- P.1  No. of Fully Denied Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.1', '  No. of Fully Denied Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- P.2  No. of Partially Adjusted + Partially Denied Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.2', '  No. of Partially Denied Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- P.3  No. of No Response from Payor Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.3', '  No. of No Response from Payor Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth
	) pms;

	-- ───────────────────────────────────────────────────────────────────────
	--  Elix_ES_Cash – Q, R, S, T, U, V, W, X, X.1, X.2, X.3
	-- ───────────────────────────────────────────────────────────────────────
	INSERT INTO dbo.Elix_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeValue, GETDATE()
	FROM
	(
		-- Q  Total Billed ($)
		SELECT p.ESYear, p.ESMonth, 'Q' AS RoleID, 'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount), 0) AS ChargeValue
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0')
		GROUP BY p.ESYear, p.ESMonth

		-- R  Unbilled Claims ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'R', 'Unbilled Claims ($)',
			   ISNULL(SUM(b.ChargeAmount), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Unbilled'
		GROUP BY p.ESYear, p.ESMonth

		-- S  Insurance Payment ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'S', 'Insurance Payment ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- T  Patient Responsibility ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'T', 'Patient Responsibility ($)',
			   ISNULL(SUM(b.PatientBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- U  Adjustments / Write Off ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U', 'Adjustments / Write Off ($)',
			   ISNULL(SUM(b.InsuranceAdjustments), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- V  Patient Paid ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'V', 'Patient Paid ($)',
			   ISNULL(SUM(b.PatientPayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- W  Partially Paid ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'W', 'Partially Paid ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- X  Insurance Balance ($) (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X', 'Insurance Balance ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0')
		GROUP BY p.ESYear, p.ESMonth

		-- X.1  Denials ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X.1', '  Denials ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- X.2  Partially Denied ($) (Partially Denied + Partially Paid + Partially Adjusted + Patient Responsibility)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X.2', '  Partially Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus IN ('Partially Denied','Partially Paid','Partially Adjusted','Patient Responsibility')
		GROUP BY p.ESYear, p.ESMonth

		-- X.3  No Response from Payor ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X.3', '  No Response from Payor ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth
	) cash;

	-- ───────────────────────────────────────────────────────────────────────
	--  Elix_ES_Avg – Y, Z, AA
	-- ───────────────────────────────────────────────────────────────────────
	INSERT INTO dbo.Elix_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, AvgValue, GETDATE()
	FROM
	(
		-- Y  Average Payment ($) - Total Pay/Billed Claims
		--    Numerator: Sum(InsurancePayment) where ClaimStatus IN (Fully Paid, Partially Paid)
		--    Denominator: count of Billed claims (= F)
		SELECT p.ESYear, p.ESMonth, 'Y' AS RoleID, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
			   COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled') THEN b.AccessionNumber END) AS ClaimCount,
			   ISNULL(ROUND(SUM(CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Fully Paid','Partially Paid') THEN b.InsurancePayment ELSE 0 END)
					 / NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled') THEN b.AccessionNumber END), 0), 2), 0) AS AvgValue
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- Z  Average Payment ($) - Total Pay/Paid Claims
		--    Numerator: Sum(InsurancePayment) where ClaimStatus = Fully Paid (= S)
		--    Denominator: count of Fully Paid claims (= J)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Z', 'Average Payment ($) - Total Pay/Paid Claims',
			   COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid' THEN b.AccessionNumber END),
			   ISNULL(ROUND(SUM(CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment ELSE 0 END)
					 / NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid' THEN b.AccessionNumber END), 0), 2), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- AA  Average Payment ($) - Total Pay/Adjudicated Claims
		--    Numerator: Sum(InsurancePayment where ClaimStatus IN (Fully Paid, Partially Paid)) + Sum(PatientPayment where Billed)
		--    Denominator: count of accessions across (Fully Paid, Fully Adjusted, Patient Responsibility,
		--                 Partially Paid, Fully Denied, Partially Denied) - see header note.
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
			   COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed'
									 AND b.ClaimStatus IN ('Fully Paid','Fully Adjusted','Patient Responsibility','Partially Paid','Fully Denied','Partially Denied')
								THEN b.AccessionNumber END),
			   ISNULL(ROUND(
						(SUM(CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Fully Paid','Partially Paid') THEN b.InsurancePayment ELSE 0 END)
						 + SUM(CASE WHEN b.BilledUnbilled = 'Billed' THEN b.PatientPayment ELSE 0 END))
						/ NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed'
													   AND b.ClaimStatus IN ('Fully Paid','Fully Adjusted','Patient Responsibility','Partially Paid','Fully Denied','Partially Denied')
												  THEN b.AccessionNumber END), 0), 2), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth
	) avgrows;

	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #LisBilledCount;

	PRINT 'usp_RefreshElix_ExecutiveSummary completed.';
END;
GO

PRINT '16_Elixir_ExecutiveSummary_Aggregate.sql completed.';
GO
