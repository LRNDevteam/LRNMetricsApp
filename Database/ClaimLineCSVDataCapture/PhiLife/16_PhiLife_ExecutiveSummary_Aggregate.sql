-- ============================================================
-- PhiLife – Executive Summary Refresh ("Aggregate") SP – PMS / Cash / Avg
-- File : 16_PhiLife_ExecutiveSummary_Aggregate.sql
-- DB   : PhiLife_LRN
--
-- Fresh rewrite mirroring PCRLabsofAmerica\16_PCRLOA_ExecutiveSummary_Aggregate.sql.
-- Run 15_PhiLife_ExecutiveSummary_Tables.sql first to create the five
-- Phi_ES_* tables. Supersedes the previous single-table PhiLife suite
-- (old 15-18: Phi_ES_Data + 2 DetailRows SPs) — ignore those.
--
-- This SP owns dbo.Phi_ES_PMS, dbo.Phi_ES_Cash and dbo.Phi_ES_Avg and
-- TRUNCATEs all three at the start of every run. The LIS breakdown
-- (dbo.Phi_ES_LIS / dbo.Phi_ES_LIS_Panel) is owned by
-- 19_PhiLife_ExecutiveSummary_LIS_Alt.sql (usp_RefreshPhi_ExecutiveSummary_LIS_Alt)
-- and is NOT touched here.
--
-- Source: dbo.ClaimLevelData (AccessionNumber, DateofService-based period).
--
-- RoleID scheme:
--   PMS  : Q, R (Billed Mismatches - cross-table), S, T, U, V, W, X, Y (+ Y.1-Y.3)
--   Cash : Z, AA-AI (+ AI.1-AI.3)
--   Avg  : AJ, AK, AL
--
-- 'R' (Billed Mismatches - Non Diagnose LIS Samples) compares Billed counts
-- in #Base (ClaimLevelData) vs. dbo.LIMSMaster:
--   R = Q (Billed - Includes all Claims Billed in AMD, ClaimLevelData)
--     - LIMSMaster Billed count (BilledorNot = 'Billed')
-- If dbo.LIMSMaster does not exist, the LIMSMaster count is 0 and R = Q
-- (guarded by OBJECT_ID('dbo.LIMSMaster','U')).
--
-- NOTE: All PMS rows (Q,R,S,T,U,V,W,X,Y,Y.1-Y.3) and the #BaseBilledCount
-- grand-total row count DISTINCT ClaimID (not AccessionNumber), matching
-- the live deployed proc. #Base now carries ClaimID alongside AccessionNumber.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_ExecutiveSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.Phi_ES_PMS;
	TRUNCATE TABLE dbo.Phi_ES_Cash;
	TRUNCATE TABLE dbo.Phi_ES_Avg;

	-- ───────────────────────────────────────────────────────────────────────
	--  #Base – one row per billable accession, DateofService-based period.
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #Base;

	SELECT
		AccessionNumber,
		ClaimID,
		YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
		ISNULL(BilledUnbilled, '')               AS BilledUnbilled,
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
	--  'R' Billed-Mismatch support: pre-aggregate Billed counts.
	--  #BaseBilledCount – ClaimLevelData Billed claims (ClaimID) per period.
	--  #LisBilled/#LisBilledCount – LIMSMaster rows where BilledorNot='Billed',
	--  per period (empty when dbo.LIMSMaster does not exist, so R degenerates
	--  to R = Q).
	--  R = Q (Billed - Includes all Claims Billed in AMD, ClaimLevelData)
	--      - LIMSMaster Billed count (BilledorNot = 'Billed').
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #BaseBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT ClaimID) AS BilledCount
	INTO #BaseBilledCount
	FROM #Base
	WHERE BilledUnbilled = 'Billed'
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT ClaimID) FROM #Base WHERE BilledUnbilled = 'Billed';

	DROP TABLE IF EXISTS #LisBilled;
	CREATE TABLE #LisBilled
	(
		Accession      NVARCHAR(100) NOT NULL,
		BilledorNot    NVARCHAR(50)  NOT NULL,
		ESYear         INT           NOT NULL,
		ESMonth        INT           NOT NULL
	);

	IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
	BEGIN
		INSERT INTO #LisBilled (Accession, BilledorNot, ESYear, ESMonth)
		SELECT
			LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))),
			LTRIM(RTRIM(ISNULL(BilledorNot, ''))),
			YEAR (TRY_CAST(RequestCollectDate AS DATE)),
			MONTH(TRY_CAST(RequestCollectDate AS DATE))
		FROM dbo.LIMSMaster
		WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL;
	END

	-- LIMSMaster Billed count: Select BilledorNot from LIMSMaster where BilledorNot='Billed'
	DROP TABLE IF EXISTS #LisBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT Accession) AS BilledCount
	INTO #LisBilledCount
	FROM #LisBilled
	WHERE BilledorNot = 'Billed'
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT Accession) FROM #LisBilled WHERE BilledorNot = 'Billed';

	-- ───────────────────────────────────────────────────────────────────────
	--  Phi_ES_PMS – Q, R, S, T, U, V, W, X, Y, Y.1, Y.2, Y.3
	-- ───────────────────────────────────────────────────────────────────────
	INSERT INTO dbo.Phi_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
	FROM
	(
		-- Q  Billed - Includes all Claims Billed in AMD
		SELECT p.ESYear, p.ESMonth, 'Q' AS RoleID, 'Billed - Includes all Claims Billed in AMD' AS Description,
			   COUNT(DISTINCT b.ClaimID) AS ClaimCount
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- R  Billed Mismatches - Non Diagnose LIS Samples (degenerates to R = Q without LIMSMaster)
		--   = Q (Billed - Includes all Claims Billed in AMD, ClaimLevelData)
		--   - LIMSMaster Billed count (BilledorNot = 'Billed')
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'R', 'Billed Mismatches - Non Diagnose LIS Samples',
			   ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0)
		FROM #Periods p
		LEFT JOIN #BaseBilledCount bb ON bb.ESYear = p.ESYear AND bb.ESMonth = p.ESMonth
		LEFT JOIN #LisBilledCount  ll ON ll.ESYear = p.ESYear AND ll.ESMonth = p.ESMonth

		-- S  Unbilled - Entered to AMD - Yet to be released to Payer
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'S', 'Unbilled - Entered to AMD - Yet to be released to Payer',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Unbilled'
		GROUP BY p.ESYear, p.ESMonth

		-- T  Fully Paid - Insurance Pay
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'T', 'Fully Paid - Insurance Pay',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- U  Fully Adjusted (Complete W/O)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U', 'Fully Adjusted (Complete W/O)',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Complete W/O'
		GROUP BY p.ESYear, p.ESMonth

		-- V  Patient Responsibility
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'V', 'Patient Responsibility',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility'
		GROUP BY p.ESYear, p.ESMonth

		-- W  Partially Paid
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'W', 'Partially Paid',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- X  Patient Payment
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X', 'Patient Payment',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment'
		GROUP BY p.ESYear, p.ESMonth

		-- Y  Insurance Balance (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y', 'Insurance Balance',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- Y.1  Insurance Balance - Fully Denied
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y.1', '  Fully Denied',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- Y.2  Insurance Balance - No Response
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y.2', '  No Response',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth

		-- Y.3  Insurance Balance - Partially Denied (Partially Adjusted + Partially Denied)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y.3', '  Partially Denied',
			   COUNT(DISTINCT b.ClaimID)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth
	) pms;

	-- ───────────────────────────────────────────────────────────────────────
	--  Phi_ES_Cash – Z, AA, AB, AC, AD, AE, AF, AG, AH, AI, AI.1, AI.2, AI.3
	-- ───────────────────────────────────────────────────────────────────────
	INSERT INTO dbo.Phi_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeValue, GETDATE()
	FROM
	(
		-- Z  Total Billed ($)
		SELECT p.ESYear, p.ESMonth, 'Z' AS RoleID, 'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount), 0) AS ChargeValue
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AA  Unbilled ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AA', 'Unbilled ($)',
			   ISNULL(SUM(b.ChargeAmount), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Unbilled'
		GROUP BY p.ESYear, p.ESMonth

		-- AB  Insurance Payment (Fully Paid) ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AB', 'Insurance Payment (Fully Paid) ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- AC  Partially Paid ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AC', 'Partially Paid ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- AD  Patient Payment ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AD', 'Patient Payment ($)',
			   ISNULL(SUM(b.PatientPayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AE  Fully Adjusted (Complete W/O) ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AE', 'Fully Adjusted (Complete W/O) ($)',
			   ISNULL(SUM(b.InsuranceAdjustments), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Complete W/O'
		GROUP BY p.ESYear, p.ESMonth

		-- AF  Contractual Obligation W/O ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AF', 'Contractual Obligation W/O ($)',
			   ISNULL(SUM(b.InsuranceAdjustments), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus <> 'Complete W/O'
		GROUP BY p.ESYear, p.ESMonth

		-- AG  Patient Balance ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AG', 'Patient Balance ($)',
			   ISNULL(SUM(b.PatientBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AH  Patient WO ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AH', 'Patient WO ($)',
			   ISNULL(SUM(b.PatientAdjustments), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AI  Insurance Balance ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AI', 'Insurance Balance ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AI.1  Insurance Balance - Fully Denied ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AI.1', '  Fully Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- AI.2  Insurance Balance - No Response ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AI.2', '  No Response ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth

		-- AI.3  Insurance Balance - Partially Denied ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AI.3', '  Partially Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('No Response','Fully Denied')
		GROUP BY p.ESYear, p.ESMonth
	) cash;

	-- ───────────────────────────────────────────────────────────────────────
	--  Phi_ES_Avg – AJ, AK, AL
	--  Built from the already-aggregated Phi_ES_Cash / Phi_ES_PMS rows
	--  (no ClaimStatus re-derivation here):
	--    Numerator (all three) = AB + AC + AD
	--       = Insurance Payment (Fully Paid) ($) + Partially Paid ($) + Patient Payment ($)
	--       from Phi_ES_Cash.ESMonthChargeAmount
	--    AJ denominator = Q.ESMonthClaimCount
	--       (Billed - Includes all Claims Billed in AMD)
	--    AK denominator = SUM(T, W, X .ESMonthClaimCount)
	--       (Fully Paid, Partially Paid, Patient Payment)
	--    AL denominator = SUM(T, U, V, W, X, Y.1, Y.3 .ESMonthClaimCount)
	--       (Fully Paid, Fully Adjusted/Complete W/O, Patient Responsibility,
	--        Partially Paid, Patient Payment, Fully Denied, Partially Denied/Adjusted)
	-- ───────────────────────────────────────────────────────────────────────
	;WITH AvgNum AS (
		SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
		FROM dbo.Phi_ES_Cash
		WHERE RoleID IN ('AB','AC','AD')
		GROUP BY ESYear, ESMonth
	),
	AvgDenomAJ AS (
		SELECT ESYear, ESMonth, ESMonthClaimCount AS DenomCount
		FROM dbo.Phi_ES_PMS
		WHERE RoleID = 'Q'
	),
	AvgDenomAK AS (
		SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS DenomCount
		FROM dbo.Phi_ES_PMS
		WHERE RoleID IN ('T','W','X')
		GROUP BY ESYear, ESMonth
	),
	AvgDenomAL AS (
		SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS DenomCount
		FROM dbo.Phi_ES_PMS
		WHERE RoleID IN ('T','U','V','W','X','Y.1','Y.3')
		GROUP BY ESYear, ESMonth
	)
	INSERT INTO dbo.Phi_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, AvgValue, GETDATE()
	FROM
	(
		-- AJ  Avg Payment ($) Total Pay / Billed Claims
		--     = (AB + AC + AD) / Q
		SELECT p.ESYear, p.ESMonth, 'AJ' AS RoleID, 'Avg Payment ($) Total Pay / Billed Claims' AS Description,
			   ISNULL(d.DenomCount, 0) AS ClaimCount,
			   ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0) AS AvgValue
		FROM #Periods p
		LEFT JOIN AvgNum     n ON n.ESYear = p.ESYear AND n.ESMonth = p.ESMonth
		LEFT JOIN AvgDenomAJ d ON d.ESYear = p.ESYear AND d.ESMonth = p.ESMonth

		-- AK  Avg Payment ($) Total Pay / Paid Claims
		--     = (AB + AC + AD) / (T + W + X)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AK', 'Avg Payment ($) Total Pay / Paid Claims',
			   ISNULL(d.DenomCount, 0),
			   ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0)
		FROM #Periods p
		LEFT JOIN AvgNum     n ON n.ESYear = p.ESYear AND n.ESMonth = p.ESMonth
		LEFT JOIN AvgDenomAK d ON d.ESYear = p.ESYear AND d.ESMonth = p.ESMonth

		-- AL  Avg Payment ($) Total Pay / Adjudicated Claims
		--     = (AB + AC + AD) / (T + U + V + W + X + Y.1 + Y.3)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AL', 'Avg Payment ($) Total Pay / Adjudicated Claims',
			   ISNULL(d.DenomCount, 0),
			   ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0)
		FROM #Periods p
		LEFT JOIN AvgNum     n ON n.ESYear = p.ESYear AND n.ESMonth = p.ESMonth
		LEFT JOIN AvgDenomAL d ON d.ESYear = p.ESYear AND d.ESMonth = p.ESMonth
	) avgrows;

	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #LisBilledCount;

	PRINT 'usp_RefreshPhi_ExecutiveSummary completed.';
END;
GO

PRINT '16_PhiLife_ExecutiveSummary_Aggregate.sql completed.';
GO
