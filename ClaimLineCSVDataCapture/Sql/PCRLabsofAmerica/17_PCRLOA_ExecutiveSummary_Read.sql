-- ============================================================
-- RisingTides – Executive Summary Read SP
-- File : 17_RisingTides_ExecutiveSummary_Read.sql
-- DB   : Rising_Tides
--
-- Consumed by LabMetricsDashboard.SqlPhiExecutiveSummaryRepository
-- via ExecutiveSummaryController – returns the 6-column contract:
--
--   RowCode      NVARCHAR(20)
--   Category     NVARCHAR(50)   – 'LIS' | 'PMS' | 'Cash' | 'Avg'
--   Description  NVARCHAR(300)
--   BillYear     INT
--   BillMonth    INT             – 0,0 = grand total sentinel row
--   MetricValue  DECIMAL(18,2)
--
-- MetricValue mapping:
--   LIS / PMS  → ESMonthClaimCount  (visit count)
--   Cash / Avg → ESMonthChargeAmount (dollar value)
--
-- Filter behaviour:
--   No filter (all NULL) → read straight from the aggregate tables (instant).
--   Any filter           → re-aggregate live from dbo.ClaimLevelData for
--                          PMS + Cash + Avg (LIS rows still come from the
--                          aggregate tables, filtered by ESYear/ESMonth).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_ExecutiveSummary
(
	@YearFrom     INT           = NULL,
	@YearTo       INT           = NULL,
	@MonthFrom    INT           = NULL,
	@MonthTo      INT           = NULL,
	@DosFrom      DATE          = NULL,
	@DosTo        DATE          = NULL,
	@ReceivedFrom DATE          = NULL,
	@ReceivedTo   DATE          = NULL,
	@BilledFrom   DATE          = NULL,
	@BilledTo     DATE          = NULL,
	@PostedFrom   DATE          = NULL,
	@PostedTo     DATE          = NULL,
	@Panels       NVARCHAR(MAX) = NULL,
	@Clinics      NVARCHAR(MAX) = NULL,
	@Providers    NVARCHAR(MAX) = NULL,
	@Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN @YearFrom     IS NOT NULL THEN 1
			WHEN @YearTo       IS NOT NULL THEN 1
			WHEN @MonthFrom    IS NOT NULL THEN 1
			WHEN @MonthTo      IS NOT NULL THEN 1
			WHEN @DosFrom      IS NOT NULL THEN 1
			WHEN @DosTo        IS NOT NULL THEN 1
			WHEN @ReceivedFrom IS NOT NULL THEN 1
			WHEN @ReceivedTo   IS NOT NULL THEN 1
			WHEN @BilledFrom   IS NOT NULL THEN 1
			WHEN @BilledTo     IS NOT NULL THEN 1
			WHEN @PostedFrom   IS NOT NULL THEN 1
			WHEN @PostedTo     IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL THEN 1
			ELSE 0
		END;

	-- ───────────────────────────────────────────────────────────────────────
	--  NO-FILTER PATH – fast path; read straight from aggregate tables.
	-- ───────────────────────────────────────────────────────────────────────
	IF @HasFilter = 0
	BEGIN
		SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
		FROM
		(
			-- LIS header rows
			SELECT RoleID                              AS RowCode,
				   'LIS'                               AS Category,
				   Description,
				   ESYear                              AS BillYear,
				   ESMonth                             AS BillMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue
			FROM   dbo.PCR_ES_LIS

			UNION ALL

			-- LIS panel sub-rows
			SELECT RoleID, 'LIS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.PCR_ES_LIS_Panel

			UNION ALL

			-- PMS
			SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.PCR_ES_PMS

			UNION ALL

			-- Cash (uses dollar amount)
			SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.PCR_ES_Cash

			UNION ALL

			-- Avg (uses dollar amount)
			SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.PCR_ES_Avg
		) all_rows
		ORDER BY BillYear, BillMonth, RowCode;
		RETURN;
	END;

	-- ───────────────────────────────────────────────────────────────────────
	--  FILTERED PATH – live re-aggregation for PMS + Cash.
	--  LIS rows are still served from the aggregate tables (filtered by Year/Month).
	-- ───────────────────────────────────────────────────────────────────────

	-- Dimension filter staging tables
	CREATE TABLE #FilterPanels   (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	CREATE TABLE #FilterClinics  (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	CREATE TABLE #FilterProviders(Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	CREATE TABLE #FilterReps     (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);

	IF NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL
		INSERT INTO #FilterPanels(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Panels, ',') WHERE LTRIM(RTRIM(value)) <> '';
	IF NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL
		INSERT INTO #FilterClinics(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Clinics, ',') WHERE LTRIM(RTRIM(value)) <> '';
	IF NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL
		INSERT INTO #FilterProviders(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Providers, ',') WHERE LTRIM(RTRIM(value)) <> '';
	IF NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL
		INSERT INTO #FilterReps(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Reps, ',') WHERE LTRIM(RTRIM(value)) <> '';

	DECLARE @HasPanelFilter    BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterPanels)    THEN 1 ELSE 0 END;
	DECLARE @HasClinicFilter   BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterClinics)   THEN 1 ELSE 0 END;
	DECLARE @HasProviderFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterProviders) THEN 1 ELSE 0 END;
	DECLARE @HasRepFilter      BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterReps)      THEN 1 ELSE 0 END;

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
	  AND NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
	  AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
	  AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
	  AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
	  AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
	  AND (@DosFrom    IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
	  AND (@DosTo      IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
	  AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
	  AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
	  AND (@PostedFrom IS NULL OR TRY_CAST(PostedDate      AS DATE) >= @PostedFrom)
	  AND (@PostedTo   IS NULL OR TRY_CAST(PostedDate      AS DATE) <= @PostedTo)
	  AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(PanelType,         ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterPanels))
	  AND (@HasClinicFilter   = 0 OR LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterClinics))
	  AND (@HasProviderFilter = 0 OR LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterProviders))
	  AND (@HasRepFilter      = 0 OR LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterReps));

	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	-- #LisBilled – per-Accession billed flag from dbo.LIMSMaster, bucketed by
	-- RequestCollectDate, used only by PMS row 'J' (Billed Mismatch) below.
	-- Mirrors 16_PCRLOA_ExecutiveSummary_Aggregate.sql.
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

	-- Pre-aggregated "Billed" counts (one row per period in #Base/#LisBilled,
	-- PLUS a (0,0) grand-total row), used by PMS row 'J' below. Joining these
	-- small per-period summaries to #Periods by equality avoids joining
	-- #Base and #LisBilled to #Periods in the same query, which would produce
	-- a Cartesian product between the two tables for every matching period
	-- (and a full #Base x #LisBilled cross join for the ESYear=0 grand-total
	-- row). Mirrors 16_PCRLOA_ExecutiveSummary_Aggregate.sql.
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

	;WITH PMS AS
	(
		-- I  Billed
		SELECT p.ESYear,p.ESMonth,'I' AS RowCode,'Billed - Includes all Claims Billed in AMD' AS Description,
			   COUNT(DISTINCT b.VisitNumber) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b
		  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		 AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear,p.ESMonth

		-- J  Billed Mismatch = (Billed claims in ClaimLevelData) MINUS (Billed samples in LIMSMaster)
		UNION ALL SELECT p.ESYear,p.ESMonth,'J','Billed Mismatch',
			ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0)
			FROM #Periods p
			LEFT JOIN #BaseBilledCount bb ON bb.ESYear=p.ESYear AND bb.ESMonth=p.ESMonth
			LEFT JOIN #LisBilledCount  ll ON ll.ESYear=p.ESYear AND ll.ESMonth=p.ESMonth

		-- K  Unbilled - Entered in AMD
		UNION ALL SELECT p.ESYear,p.ESMonth,'K','Unbilled - Entered in AMD - Yet to be released to Payer',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Unbilled'
			GROUP BY p.ESYear,p.ESMonth

		-- L  Fully Paid - Insurance Pay
		UNION ALL SELECT p.ESYear,p.ESMonth,'L','Fully Paid - Insurance Pay',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Paid'
			GROUP BY p.ESYear,p.ESMonth

		-- M  Fully Adjusted (Complete W/O)
		UNION ALL SELECT p.ESYear,p.ESMonth,'M','Fully Adjusted',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Complete W/O'
			GROUP BY p.ESYear,p.ESMonth

		-- N  Patient Responsibility
		UNION ALL SELECT p.ESYear,p.ESMonth,'N','Patient Responsibility',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Patient Responsibility'
			GROUP BY p.ESYear,p.ESMonth

		-- O  Partially Paid
		UNION ALL SELECT p.ESYear,p.ESMonth,'O','Partially Paid',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Paid'
			GROUP BY p.ESYear,p.ESMonth

		-- P  Insurance Balance (parent total = sum of P.1+P.2+P.3)
		UNION ALL SELECT p.ESYear,p.ESMonth,'P','Insurance Balance',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Adjusted','Partially Denied')
			GROUP BY p.ESYear,p.ESMonth

		-- P.1  No Response
		UNION ALL SELECT p.ESYear,p.ESMonth,'P.1','  No Response',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='No Response'
			GROUP BY p.ESYear,p.ESMonth

		-- P.2  Fully Denied
		UNION ALL SELECT p.ESYear,p.ESMonth,'P.2','  Fully Denied',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Denied'
			GROUP BY p.ESYear,p.ESMonth

		-- P.3  Partially Denied (Partially Adjusted + Partially Denied)
		UNION ALL SELECT p.ESYear,p.ESMonth,'P.3','  Partially Denied',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied')
			GROUP BY p.ESYear,p.ESMonth
	),
	Cash AS
	(
		-- Q  Total Billed ($)
		SELECT p.ESYear,p.ESMonth,'Q' AS RowCode,'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount),0) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b
		  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		 AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear,p.ESMonth

		-- R  Unbilled ($)
		UNION ALL SELECT p.ESYear,p.ESMonth,'R','Unbilled ($)',ISNULL(SUM(b.ChargeAmount),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Unbilled' GROUP BY p.ESYear,p.ESMonth

		-- S  Insurance Payment (fully paid) ($)
		UNION ALL SELECT p.ESYear,p.ESMonth,'S','Insurance Payment (fully paid) ($)',ISNULL(SUM(b.InsurancePayment),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Paid' GROUP BY p.ESYear,p.ESMonth

		-- T  Partially Paid ($)
		UNION ALL SELECT p.ESYear,p.ESMonth,'T','Partially Paid ($)',ISNULL(SUM(b.InsurancePayment),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Paid' GROUP BY p.ESYear,p.ESMonth

		-- U  Fully Adjusted (Complete W/O) ($)
		UNION ALL SELECT p.ESYear,p.ESMonth,'U','Fully Adjusted (Complete W/O) ($)',ISNULL(SUM(b.InsuranceAdjustments),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Complete W/O' GROUP BY p.ESYear,p.ESMonth

		-- V  Contractual Obligation W/O ($)
		UNION ALL SELECT p.ESYear,p.ESMonth,'V','Contractual Obligation W/O ($)',ISNULL(SUM(b.InsuranceAdjustments),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus <> 'Complete W/O' GROUP BY p.ESYear,p.ESMonth

		-- W  Patient Balance ($)
		UNION ALL SELECT p.ESYear,p.ESMonth,'W','Patient Balance ($)',ISNULL(SUM(b.PatientBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

		-- X  Patient WO ($)
		UNION ALL SELECT p.ESYear,p.ESMonth,'X','Patient WO ($)',ISNULL(SUM(b.PatientAdjustments),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

		-- Y  Insurance Balance ($) parent (no ClaimStatus filter; = Y.1+Y.2+Y.3)
		UNION ALL SELECT p.ESYear,p.ESMonth,'Y','Insurance Balance ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

		-- Y.1  No Response ($)
		UNION ALL SELECT p.ESYear,p.ESMonth,'Y.1','  No Response ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='No Response' GROUP BY p.ESYear,p.ESMonth

		-- Y.2  Fully Denied ($)
		UNION ALL SELECT p.ESYear,p.ESMonth,'Y.2','  Fully Denied ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Denied' GROUP BY p.ESYear,p.ESMonth

		-- Y.3  Partially Denied ($) – everything else with InsuranceBalance not
		--      attributable to 'No Response' or 'Fully Denied'
		UNION ALL SELECT p.ESYear,p.ESMonth,'Y.3','  Partially Denied ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus NOT IN ('No Response','Fully Denied') GROUP BY p.ESYear,p.ESMonth
	),
	AvgBase AS
	(
		SELECT
			p.ESYear, p.ESMonth,
			ISNULL(SUM(CASE WHEN b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Fully Paid','Partially Paid')
							THEN b.InsurancePayment ELSE 0 END), 0)
			  + ISNULL(SUM(CASE WHEN b.BilledUnbilled='Billed' THEN b.PatientPayment ELSE 0 END), 0) AS TotalPay,
			COUNT(DISTINCT CASE WHEN b.BilledUnbilled='Billed'
								 THEN b.VisitNumber END) AS BilledClaims,
			COUNT(DISTINCT CASE WHEN b.BilledUnbilled='Billed'
								  AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Patient Payment')
								 THEN b.VisitNumber END) AS PaidClaims,
			COUNT(DISTINCT CASE WHEN b.BilledUnbilled='Billed'
								  AND b.ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
														 'Partially Paid','Patient Payment','Fully Denied',
														 'Partially Adjusted','Partially Denied')
								 THEN b.VisitNumber END) AS AdjudicatedClaims
		FROM #Periods p LEFT JOIN #Base b
		  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth
	),
	AvgRows AS
	(
		SELECT ESYear, ESMonth, 'AH' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
			   CASE WHEN BilledClaims = 0 THEN 0 ELSE TotalPay / BilledClaims END AS MetricValue
		FROM AvgBase

		UNION ALL SELECT ESYear, ESMonth, 'AI1', 'Average Payment ($) - Total Pay/Paid Claims',
			   CASE WHEN PaidClaims = 0 THEN 0 ELSE TotalPay / PaidClaims END
		FROM AvgBase

		UNION ALL SELECT ESYear, ESMonth, 'AJ', 'Average Payment ($) - Total Pay/Adjudicated Claims',
			   CASE WHEN AdjudicatedClaims = 0 THEN 0 ELSE TotalPay / AdjudicatedClaims END
		FROM AvgBase
	)
	SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
	FROM
	(
		-- LIS rows from aggregate table (filtered by period)
		SELECT RoleID AS RowCode,'LIS' AS Category, Description,
			   ESYear AS BillYear, ESMonth AS BillMonth,
			   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue
		FROM dbo.PCR_ES_LIS
		WHERE (ESYear=0 AND ESMonth=0)
		   OR ( (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
			AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
			AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
			AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo))

		UNION ALL
		SELECT RoleID,'LIS', Description, ESYear, ESMonth,
			   CAST(ESMonthClaimCount AS DECIMAL(18,2))
		FROM dbo.PCR_ES_LIS_Panel
		WHERE (ESYear=0 AND ESMonth=0)
		   OR ( (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
			AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
			AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
			AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo))

		UNION ALL
		SELECT RowCode,'PMS', Description, ESYear, ESMonth,
			   CAST(MetricValue AS DECIMAL(18,2))
		FROM PMS

		UNION ALL
		SELECT RowCode,'Cash', Description, ESYear, ESMonth, MetricValue
		FROM Cash

		UNION ALL
		SELECT RowCode,'Avg', Description, ESYear, ESMonth, MetricValue
		FROM AvgRows
	) all_rows
	ORDER BY BillYear, BillMonth, RowCode;

	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilledCount;
END;
GO

PRINT '17_PCRLOA_ExecutiveSummary_Read.sql completed.';
GO
