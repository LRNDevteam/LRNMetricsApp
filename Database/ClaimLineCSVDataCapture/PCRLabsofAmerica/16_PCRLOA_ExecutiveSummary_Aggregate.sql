-- ============================================================
-- RisingTides – Executive Summary Refresh SP
-- File : 16_RisingTides_ExecutiveSummary_Aggregate.sql
-- DB   : Rising_Tides
--
-- Run order: AFTER ingestion of ClaimLevelData.
-- Called by ClaimLineCSVDataCapture via usp_RefreshPCR_ExecutiveSummary.
--
-- NOTE: The LIS Breakdown (dbo.PCR_ES_LIS / dbo.PCR_ES_LIS_Panel, populated
-- from dbo.LIMSMaster — RoleIDs A..I5 plus the 'B.<PanelName>' sub-rows) has
-- been MOVED to usp_RefreshPCR_ExecutiveSummary_LIS_Alt
-- (19_PCRLOA_ExecutiveSummary_LIS_Alt.sql). That keeps the LIMSMaster-derived
-- LIS Breakdown fully separate from the ClaimLevelData-derived PMS/Cash/Avg
-- breakdowns below. This SP no longer truncates or populates PCR_ES_LIS or
-- PCR_ES_LIS_Panel — see 19_PCRLOA_ExecutiveSummary_LIS_Alt.sql for that
-- logic and its A..I5 RoleID rules.
--
-- dbo.LIMSMaster IS still read here (read-only, via #LisBilled) for the
-- 'J  Billed Mismatch' cross-table comparison in the PMS Breakdown below.
--
-- Visit Number = ClaimID (per spec).
-- Year / Month bucket  = DateofService.
--
-- PMS BREAKDOWN  (PCR_ES_PMS)  – fully populated from dbo.ClaimLevelData
-- RoleID scheme revised (replaces the previous O..W3 scheme). Rows 'Paid -
-- Client' (old R) and 'Patient Payment' (old X) have been removed.
--   I    Billed                       → Billed
--   J    Billed Mismatch              → COUNT(DISTINCT VisitNumber WHERE Billed) in ClaimLevelData
--                                          MINUS COUNT(DISTINCT Accession WHERE BilledorNot='Billed') in dbo.LIMSMaster
--                                          (matched by ESYear/ESMonth; LIMSMaster bucketed by RequestCollectDate)
--   K    Unbilled - Entered in AMD    → Unbilled
--   L    Fully Paid - Insurance Pay   → Billed AND ClaimStatus='Fully Paid'
--   M    Fully Adjusted               → Billed AND ClaimStatus='Complete W/O'
--   N    Patient Responsibility       → Billed AND ClaimStatus='Patient Responsibility'
--   O    Partially Paid               → Billed AND ClaimStatus='Partially Paid'
--   P    Insurance Balance            → Billed AND ClaimStatus IN ('Fully Denied','No Response','Partially Adjusted','Partially Denied')
--   P.1    No Response                → Billed AND ClaimStatus='No Response'
--   P.2    Fully Denied               → Billed AND ClaimStatus='Fully Denied'
--   P.3    Partially Denied           → Billed AND ClaimStatus IN ('Partially Adjusted','Partially Denied')
--
-- CASH BREAKDOWN (PCR_ES_Cash) – fully populated from dbo.ClaimLevelData
-- RoleID scheme revised (replaces the previous X..AG3 scheme). The former
-- 'Patient Payment ($)' row (old AB) has been removed.
--   Q    Total Billed ($)             → SUM(ChargeAmount)         WHERE Billed
--   R    Unbilled ($)                 → SUM(ChargeAmount)         WHERE Unbilled
--   S    Insurance Payment (fully paid) ($) → SUM(InsurancePayment) WHERE Billed AND ClaimStatus='Fully Paid'
--   T    Partially Paid ($)           → SUM(InsurancePayment)     WHERE Billed AND ClaimStatus='Partially Paid'
--   U    Fully Adjusted (Complete W/O) ($) → SUM(InsuranceAdjustments) WHERE Billed AND ClaimStatus='Complete W/O'
--   V    Contractual Obligation W/O ($) → SUM(InsuranceAdjustments) WHERE Billed AND ClaimStatus<>'Complete W/O'
--   W    Patient Balance ($)          → SUM(PatientBalance)       WHERE Billed
--   X    Patient WO ($)               → SUM(PatientAdjustments)   WHERE Billed
--   Y    Insurance Balance ($)        → SUM(InsuranceBalance)     WHERE Billed   (no ClaimStatus filter; = Y.1+Y.2+Y.3)
--   Y.1    No Response ($)            → SUM(InsuranceBalance)     WHERE Billed AND ClaimStatus='No Response'
--   Y.2    Fully Denied ($)           → SUM(InsuranceBalance)     WHERE Billed AND ClaimStatus='Fully Denied'
--   Y.3    Partially Denied ($)       → SUM(InsuranceBalance)     WHERE Billed AND ClaimStatus NOT IN ('No Response','Fully Denied')
--
-- AVERAGE PAYMENT PER CLAIM (PCR_ES_Avg) – derived from #Base/#Periods
--   TotalPay = SUM(InsurancePayment WHERE Billed AND ClaimStatus IN
--              ('Fully Paid','Partially Paid')) + SUM(PatientPayment WHERE Billed)
--              (i.e. Cash rows S + T, plus the PatientPayment column that no
--              longer has its own dedicated Cash row)
--   AH   Average Payment ($) - Total Pay/Billed Claims
--          → TotalPay / COUNT(DISTINCT VisitNumber WHERE Billed)        (same pop. as PMS row I)
--   AI1  Average Payment ($) - Total Pay/Paid Claims
--          → TotalPay / COUNT(DISTINCT VisitNumber WHERE Billed AND
--            ClaimStatus IN ('Fully Paid','Partially Paid','Patient Payment'))
--            (same pop. as PMS L+O, plus the 'Patient Payment' status which
--            no longer has its own PMS row)
--   AJ   Average Payment ($) - Total Pay/Adjudicated Claims
--          → TotalPay / COUNT(DISTINCT VisitNumber WHERE Billed AND
--            ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
--            'Partially Paid','Patient Payment','Fully Denied','Partially Adjusted','Partially Denied'))
--            (same pop. as PMS L+M+N+O+P.2+P.3, plus the 'Patient Payment'
--            status; 'Partially Adjusted' added to mirror the broadened
--            P.3 definition above)
--   ESMonthClaimCount = denominator (claim count); ESMonthChargeAmount = average $ (0 if denominator=0).
--
-- Grand-total sentinel row: ESYear=0, ESMonth=0.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_ExecutiveSummary
AS
BEGIN
	SET NOCOUNT ON;

	-- ───────────────────────────────────────────────────────────────────────
	--  Working set – one row per ClaimLevelData row, with normalised values.
	--  Visit Number = ClaimID.
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #Base;

	SELECT
		LTRIM(RTRIM(ISNULL(ClaimID, '')))                                  AS VisitNumber,
		YEAR (TRY_CAST(DateofService AS DATE))                             AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE))                             AS ESMonth,
		LTRIM(RTRIM(ISNULL(BilledUnbilled, '')))                           AS BilledUnbilled,
		LTRIM(RTRIM(ISNULL(ClaimStatus,    '')))                           AS ClaimStatus,
		ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0)        AS ChargeAmount,
		ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0)        AS InsurancePayment,
		ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0)        AS PatientPayment,
		ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0)        AS InsuranceAdjustments,
		ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0)        AS PatientAdjustments,
		ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0)        AS InsuranceBalance,
		ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0)        AS PatientBalance
	INTO #Base
	FROM dbo.ClaimLevelData
	WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
	  AND NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL;

	-- Periods: every (Year,Month) present in #Base PLUS a (0,0) grand-total sentinel.
	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	-- ───────────────────────────────────────────────────────────────────────
	--  #LisBilled – lightweight per-Accession billed flag from dbo.LIMSMaster,
	--  used only by PMS row 'J' (Billed Mismatch) below. Bucketed by
	--  RequestCollectDate (independent of the DateofService-based #Periods),
	--  matched to #Periods by (ESYear,ESMonth) so the per-period and
	--  grand-total comparisons line up with the other PMS/Cash rows.
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #LisBilled;
	CREATE TABLE #LisBilled
	(
		Accession      NVARCHAR(100) NOT NULL,
		ESYear         INT           NOT NULL,
		ESMonth        INT           NOT NULL,
		BilledUnbilled NVARCHAR(100) NOT NULL
	);

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
	BEGIN
		INSERT INTO #LisBilled (Accession, ESYear, ESMonth, BilledUnbilled)
		SELECT
			LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))),
			YEAR (TRY_CAST(RequestCollectDate AS DATE)),
			MONTH(TRY_CAST(RequestCollectDate AS DATE)),
			LTRIM(RTRIM(ISNULL(BilledorNot, '')))
		FROM dbo.LIMSMaster
		WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL;
	END
	-- If dbo.LIMSMaster is missing, #LisBilled stays empty and PMS row 'J'
	-- simply equals row 'I' (every billed claim reported as unmatched).

	-- ───────────────────────────────────────────────────────────────────────
	--  Pre-aggregated "Billed" counts (one row per period present in #Base,
	--  PLUS a (0,0) grand-total row) for #Base and #LisBilled, used by PMS
	--  row 'J' below. Pre-aggregating each side separately and joining the
	--  small result sets to #Periods by equality avoids joining #Base and
	--  #LisBilled to #Periods in the same query — that pattern produces a
	--  Cartesian product between every matching #Base row and every matching
	--  #LisBilled row for each period (and a full #Base x #LisBilled cross
	--  join for the ESYear=0 grand-total row), which is the main cause of
	--  multi-minute refresh times on larger datasets.
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #BaseBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT VisitNumber) AS BilledCount
	INTO #BaseBilledCount
	FROM #Base
	WHERE BilledUnbilled='Billed'
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT VisitNumber)
	FROM #Base
	WHERE BilledUnbilled='Billed';

	DROP TABLE IF EXISTS #LisBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT Accession) AS BilledCount
	INTO #LisBilledCount
	FROM #LisBilled
	WHERE BilledUnbilled='Billed'
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT Accession)
	FROM #LisBilled
	WHERE BilledUnbilled='Billed';

	-- ───────────────────────────────────────────────────────────────────────
	--  1.  PMS Breakdown  (RoleIDs I, J, K..P, P.1-P.3)
	-- ───────────────────────────────────────────────────────────────────────
	TRUNCATE TABLE dbo.PCR_ES_PMS;

	INSERT INTO dbo.PCR_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
	FROM
	(
		-- I  Billed
		SELECT p.ESYear, p.ESMonth, 'I' AS RoleID, 'Billed' AS Description,
			   COUNT(DISTINCT b.VisitNumber) AS ClaimCount
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- J  Billed Mismatch = (Billed claims in ClaimLevelData) MINUS (Billed samples in LIMSMaster)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'J', 'Billed Mismatch',
			   ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0)
		FROM #Periods p
		LEFT JOIN #BaseBilledCount bb ON bb.ESYear=p.ESYear AND bb.ESMonth=p.ESMonth
		LEFT JOIN #LisBilledCount  ll ON ll.ESYear=p.ESYear AND ll.ESMonth=p.ESMonth

		-- K  Unbilled - Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'K', 'Unbilled',
			   COUNT(DISTINCT b.VisitNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Unbilled'
		GROUP BY p.ESYear, p.ESMonth

		-- L  Fully Paid - Insurance Pay
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'L', 'Fully Paid - Insurance Pay',
			   COUNT(DISTINCT b.VisitNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- M  Fully Adjusted (Complete W/O)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'M', 'Fully Adjusted',
			   COUNT(DISTINCT b.VisitNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='Complete W/O'
		GROUP BY p.ESYear, p.ESMonth

		-- N  Patient Responsibility
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N', 'Patient Responsibility',
			   COUNT(DISTINCT b.VisitNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='Patient Responsibility'
		GROUP BY p.ESYear, p.ESMonth

		-- O  Partially Paid
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'O', 'Partially Paid',
			   COUNT(DISTINCT b.VisitNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- P  Insurance Balance (parent total = sum of P.1+P.2+P.3)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P', 'Insurance Balance',
			   COUNT(DISTINCT b.VisitNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- P.1  No Response
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.1', '  No Response',
			   COUNT(DISTINCT b.VisitNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='No Response'
		GROUP BY p.ESYear, p.ESMonth

		-- P.2  Fully Denied
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.2', '  Fully Denied',
			   COUNT(DISTINCT b.VisitNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='Fully Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- P.3  Partially Denied (Partially Adjusted + Partially Denied)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.3', '  Partially Denied',
			   COUNT(DISTINCT b.VisitNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth
	) pms;

	-- ───────────────────────────────────────────────────────────────────────
	--  2.  Cash Breakdown  (RoleIDs Q..Y, Y.1-Y.3)
	-- ───────────────────────────────────────────────────────────────────────
	TRUNCATE TABLE dbo.PCR_ES_Cash;

	INSERT INTO dbo.PCR_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, 0, MetricAmount, GETDATE()
	FROM
	(
		-- Q  Total Billed ($)
		SELECT p.ESYear, p.ESMonth, 'Q' AS RoleID, 'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount), 0) AS MetricAmount
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- R  Unbilled ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'R', 'Unbilled ($)',
			   ISNULL(SUM(b.ChargeAmount), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Unbilled'
		GROUP BY p.ESYear, p.ESMonth

		-- S  Insurance Payment (fully paid) ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'S', 'Insurance Payment (fully paid) ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- T  Partially Paid ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'T', 'Partially Paid ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- U  Fully Adjusted (Complete W/O) ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U', 'Fully Adjusted (Complete W/O) ($)',
			   ISNULL(SUM(b.InsuranceAdjustments), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='Complete W/O'
		GROUP BY p.ESYear, p.ESMonth

		-- V  Contractual Obligation W/O ($)
		--     Sum(InsuranceAdjustments) WHERE Billed AND ClaimStatus <> 'Complete W/O'
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'V', 'Contractual Obligation W/O ($)',
			   ISNULL(SUM(b.InsuranceAdjustments), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus <> 'Complete W/O'
		GROUP BY p.ESYear, p.ESMonth

		-- W  Patient Balance ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'W', 'Patient Balance ($)',
			   ISNULL(SUM(b.PatientBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- X  Patient WO ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X', 'Patient WO ($)',
			   ISNULL(SUM(b.PatientAdjustments), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- Y  Insurance Balance ($) parent (no ClaimStatus filter; = Y.1+Y.2+Y.3)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y', 'Insurance Balance ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- Y.1  No Response ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y.1', '  No Response ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='No Response'
		GROUP BY p.ESYear, p.ESMonth

		-- Y.2  Fully Denied ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y.2', '  Fully Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus='Fully Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- Y.3  Partially Denied ($) – everything else with InsuranceBalance not
		--      attributable to 'No Response' or 'Fully Denied'
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y.3', '  Partially Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						  AND b.BilledUnbilled='Billed'
						  AND b.ClaimStatus NOT IN ('No Response','Fully Denied')
		GROUP BY p.ESYear, p.ESMonth
	) cash;

	-- ───────────────────────────────────────────────────────────────────────
	--  3.  Average Payment Per Claim (PCR_ES_Avg)  [TABLE-DRIVEN]
	--
	--  Z   Average Payment ($) - Total Pay/Billed Claims
	--      Numerator  : S + T + W  (Insurance Payment fully paid + Partially Paid + Patient Balance)
	--      Denominator: I          (Billed)
	--
	--  AA  Average Payment ($) - Total Pay/Paid Claims
	--      Numerator  : S + T      (Insurance Payment fully paid + Partially Paid)
	--      Denominator: L + O      (Fully Paid - Insurance Pay + Partially Paid)
	--
	--  AB  Average Payment ($) - Total Pay/Adjudicated Claims
	--      Numerator  : S + T + W  (Insurance Payment fully paid + Partially Paid + Patient Balance)
	--      Denominator: L+M+N+O+P.2+P.3
	--                   (Fully Paid + Fully Adjusted + Patient Responsibility +
	--                    Partially Paid + Fully Denied + Partially Denied)
	-- ───────────────────────────────────────────────────────────────────────
	TRUNCATE TABLE dbo.PCR_ES_Avg;

	;WITH
	AvgNumST AS
	(
		-- AA Numerator: S + T
		-- Insurance Payment (fully paid) ($) + Partially Paid ($)
		SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
		FROM dbo.PCR_ES_Cash
		WHERE RoleID IN ('S','T')
		GROUP BY ESYear, ESMonth
	),
	AvgNumSTW AS
	(
		-- Z & AB Numerator: S + T + W
		-- Insurance Payment (fully paid) ($) + Partially Paid ($) + Patient Balance ($)
		SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
		FROM dbo.PCR_ES_Cash
		WHERE RoleID IN ('S','T','W')
		GROUP BY ESYear, ESMonth
	),
	DenZ AS
	(
		-- Z Denominator: I — all Billed claims
		SELECT ESYear, ESMonth, ESMonthClaimCount AS DenomCount
		FROM dbo.PCR_ES_PMS
		WHERE RoleID = 'I'
	),
	DenAA AS
	(
		-- AA Denominator: L + O — Fully Paid + Partially Paid
		SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS DenomCount
		FROM dbo.PCR_ES_PMS
		WHERE RoleID IN ('L','O')
		GROUP BY ESYear, ESMonth
	),
	DenAB AS
	(
		-- AB Denominator: L+M+N+O+P.2+P.3
		-- Fully Paid + Fully Adjusted + Patient Responsibility +
		-- Partially Paid + Fully Denied + Partially Denied
		SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS DenomCount
		FROM dbo.PCR_ES_PMS
		WHERE RoleID IN ('L','M','N','O','P.2','P.3')
		GROUP BY ESYear, ESMonth
	)
	INSERT INTO dbo.PCR_ES_Avg
	(
		RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt
	)
	-- Z: (S + T + W) / I
	SELECT
		'Z',
		'Average Payment ($) - Total Pay/Billed Claims',
		p.ESYear, p.ESMonth,
		ISNULL(d.DenomCount, 0),
		ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN AvgNumSTW n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
	LEFT JOIN DenZ      d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth

	UNION ALL
	-- AA: (S + T) / (L + O)
	SELECT
		'AA',
		'Average Payment ($) - Total Pay/Paid Claims',
		p.ESYear, p.ESMonth,
		ISNULL(d.DenomCount, 0),
		ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN AvgNumST n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
	LEFT JOIN DenAA    d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth

	UNION ALL
	-- AB: (S + T + W) / (L + M + N + O + P.2 + P.3)
	SELECT
		'AB',
		'Average Payment ($) - Total Pay/Adjudicated Claims',
		p.ESYear, p.ESMonth,
		ISNULL(d.DenomCount, 0),
		ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN AvgNumSTW n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
	LEFT JOIN DenAB     d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth;

	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilledCount;

	PRINT 'usp_RefreshPCR_ExecutiveSummary completed.';
END;
GO

PRINT '16_PCRLOA_ExecutiveSummary_Aggregate.sql completed.';
GO
