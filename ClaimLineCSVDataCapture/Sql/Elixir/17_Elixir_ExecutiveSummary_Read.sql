-- ============================================================
-- Elixir – Executive Summary Read SP
-- File : 17_Elixir_ExecutiveSummary_Read.sql
-- DB   : Elixir_LRN
--
-- Mirrors PhiLife\17_PhiLife_ExecutiveSummary_Read.sql, but uses the
-- SIMPLER Elixir RoleID scheme (see 15_Elixir_ExecutiveSummary_Tables.sql):
--   LIS  : A, B, C, D (+D.1), E (+E.1-E.6)
--   PMS  : F-P (+P.1-P.3)
--   Cash : Q-X (+X.1-X.3)
--   Avg  : Y, Z, AA
--
-- Returns the 6-column contract:
--   RowCode      NVARCHAR(350)
--   Category     NVARCHAR(50)   – 'LIS' | 'PMS' | 'Cash' | 'Avg'
--   Description  NVARCHAR(300)
--   BillYear     INT
--   BillMonth    INT             – 0,0 = grand total sentinel row
--   MetricValue  DECIMAL(18,2)
--
-- MetricValue mapping:
--   LIS / PMS  → ESMonthClaimCount  (sample / claim count)
--   Cash / Avg → ESMonthChargeAmount (dollar value)
--
-- Filter behaviour:
--   No filter (all NULL) → read straight from the aggregate tables (instant).
--   Any filter           → PMS/Cash/Avg are live re-aggregated from
--                          dbo.ClaimLevelData (same as PhiLife). LIS is
--                          sourced from dbo.LIMSMaster on a DIFFERENT
--                          period system to ClaimLevelData, so - exactly
--                          like PCRLOA - LIS rows are filtered/re-summed
--                          from the pre-computed dbo.Elix_ES_LIS table
--                          rather than re-querying LIMSMaster.
--
-- @YearFrom/@YearTo/@MonthFrom/@MonthTo are independent range filters on
-- the Year/Month components of the relevant period column (DateofService
-- for PMS/Cash/Avg, the LIMSMaster date column for LIS).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetElix_ExecutiveSummary
(
	@YearFrom     INT           = NULL,
	@YearTo       INT           = NULL,
	@MonthFrom    INT           = NULL,
	@MonthTo      INT           = NULL,
	@DosFrom      DATE          = NULL,
	@DosTo        DATE          = NULL,
	@BilledFrom   DATE          = NULL,
	@BilledTo     DATE          = NULL,
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
			WHEN @BilledFrom   IS NOT NULL THEN 1
			WHEN @BilledTo     IS NOT NULL THEN 1
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
			SELECT RoleID AS RowCode, 'LIS' AS Category, Description,
				   ESYear AS BillYear, ESMonth AS BillMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue
			FROM   dbo.Elix_ES_LIS

			UNION ALL

			SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.Elix_ES_PMS

			UNION ALL

			SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.Elix_ES_Cash

			UNION ALL

			SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.Elix_ES_Avg
		) all_rows
		ORDER BY BillYear, BillMonth, RowCode;
		RETURN;
	END;

	-- ───────────────────────────────────────────────────────────────────────
	--  FILTERED PATH
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

	-- LIS: filter/re-sum the pre-computed aggregate table (different period
	-- system to ClaimLevelData – see header note).
	DROP TABLE IF EXISTS #LisFiltered;
	SELECT RoleID, Description, ESYear, ESMonth, ESMonthClaimCount
	INTO #LisFiltered
	FROM dbo.Elix_ES_LIS
	WHERE ESYear <> 0
	  AND (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
	  AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
	  AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
	  AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo);

	-- PMS/Cash/Avg: live re-aggregation from ClaimLevelData, same #Base shape as file 16.
	DROP TABLE IF EXISTS #Base;

	SELECT
		AccessionNumber,
		YEAR (TRY_CAST(DateofService AS DATE)) AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE)) AS ESMonth,
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
	  AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
	  AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
	  AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
	  AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
	  AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
	  AND (@DosFrom    IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
	  AND (@DosTo      IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
	  AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
	  AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
	  AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(PanelType,         ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterPanels))
	  AND (@HasClinicFilter   = 0 OR LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterClinics))
	  AND (@HasProviderFilter = 0 OR LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterProviders))
	  AND (@HasRepFilter      = 0 OR LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterReps));

	-- Periods: every (Year,Month) present in #Base PLUS a (0,0) grand-total sentinel.
	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	-- ───────────────────────────────────────────────────────────────────────
	--  'I' Billed-Mismatch support: pre-aggregate Billed counts (same
	--  auto-detect technique as 16_Elixir_ExecutiveSummary_Aggregate.sql,
	--  applied to the filtered #Base/#Periods).
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
				  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))) = ''Billed''
				  AND (' + ISNULL(CONVERT(NVARCHAR(20), @YearFrom), 'NULL') + N' IS NULL OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) >= ' + ISNULL(CONVERT(NVARCHAR(20), @YearFrom), '0') + N')
				  AND (' + ISNULL(CONVERT(NVARCHAR(20), @YearTo), 'NULL') + N' IS NULL OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) <= ' + ISNULL(CONVERT(NVARCHAR(20), @YearTo), '0') + N')
				  AND (' + ISNULL(CONVERT(NVARCHAR(20), @MonthFrom), 'NULL') + N' IS NULL OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) >= ' + ISNULL(CONVERT(NVARCHAR(20), @MonthFrom), '0') + N')
				  AND (' + ISNULL(CONVERT(NVARCHAR(20), @MonthTo), 'NULL') + N' IS NULL OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) <= ' + ISNULL(CONVERT(NVARCHAR(20), @MonthTo), '0') + N');';

			EXEC sp_executesql @LisBilledSql;
		END
	END

	DROP TABLE IF EXISTS #LisBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT Accession) AS BilledCount
	INTO #LisBilledCount
	FROM #LisBilled
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT Accession) FROM #LisBilled;

	;WITH LisFinal AS
	(
		SELECT RoleID AS RowCode, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue
		FROM #LisFiltered

		UNION ALL

		SELECT RoleID, MAX(Description), 0, 0, CAST(SUM(ESMonthClaimCount) AS DECIMAL(18,2))
		FROM #LisFiltered
		GROUP BY RoleID
	),
	PMS AS
	(
		-- F  No. of Billed Claims
		SELECT p.ESYear, p.ESMonth, 'F' AS RowCode, 'No. of Billed Claims' AS Description,
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) AS MetricValue
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled')
		GROUP BY p.ESYear, p.ESMonth

		-- G  Unbilled Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G', 'Unbilled Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus IN ('Unbilled','Unbilled - PB')
		GROUP BY p.ESYear, p.ESMonth

		-- H  Voided claims (spec gave no formula - see file 16 header note)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H', 'Voided claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Voided'
		GROUP BY p.ESYear, p.ESMonth

		-- I  Billed Mismatches - LIS Accession Cannot be Matched
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I', 'Billed Mismatches - LIS Accession Cannot be Matched',
			   CAST(ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #BaseBilledCount bb ON bb.ESYear = p.ESYear AND bb.ESMonth = p.ESMonth
		LEFT JOIN #LisBilledCount  ll ON ll.ESYear = p.ESYear AND ll.ESMonth = p.ESMonth

		-- J  No. of Fully Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'J', 'No. of Fully Paid Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- K  No. of Fully Patient Responsibility Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'K', 'No. of Fully Patient Responsibility Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility'
		GROUP BY p.ESYear, p.ESMonth

		-- L  No. of Patient Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'L', 'No. of Patient Paid Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment'
		GROUP BY p.ESYear, p.ESMonth

		-- M  No. of Adjusted/Written Off Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'M', 'No. of Adjusted/Written Off Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		-- N  No. of Partially Adjusted claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Adjusted claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		-- O  No. of Partially Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'O', 'No. of Partially Paid Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- P  No. of Insurance Balance Claims (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P', 'No. of Insurance Balance Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus IN ('Denied','No Response','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- P.1  No. of Fully Denied Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.1', '  No. of Fully Denied Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- P.2  No. of Partially Denied Claims (Partially Adjusted + Partially Denied)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.2', '  No. of Partially Denied Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- P.3  No. of No Response from Payor Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.3', '  No. of No Response from Payor Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth
	),
	Cash AS
	(
		-- Q  Total Billed ($)
		SELECT p.ESYear, p.ESMonth, 'Q' AS RowCode, 'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount), 0) AS MetricValue
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

		-- X.2  Partially Denied ($)
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
	),
	AvgRows AS
	(
		-- Y  Average Payment ($) - Total Pay/Billed Claims
		SELECT p.ESYear, p.ESMonth, 'Y' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
			   ISNULL(ROUND(SUM(CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Fully Paid','Partially Paid') THEN b.InsurancePayment ELSE 0 END)
					 / NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled') THEN b.AccessionNumber END), 0), 2), 0) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- Z  Average Payment ($) - Total Pay/Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Z', 'Average Payment ($) - Total Pay/Paid Claims',
			   ISNULL(ROUND(SUM(CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment ELSE 0 END)
					 / NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid' THEN b.AccessionNumber END), 0), 2), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- AA  Average Payment ($) - Total Pay/Adjudicated Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
			   ISNULL(ROUND(
						(SUM(CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Fully Paid','Partially Paid') THEN b.InsurancePayment ELSE 0 END)
						 + SUM(CASE WHEN b.BilledUnbilled = 'Billed' THEN b.PatientPayment ELSE 0 END))
						/ NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed'
													   AND b.ClaimStatus IN ('Fully Paid','Fully Adjusted','Patient Responsibility','Partially Paid','Fully Denied','Partially Denied')
												  THEN b.AccessionNumber END), 0), 2), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth
	)
	SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
	FROM
	(
		SELECT RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth, MetricValue FROM LisFinal
		UNION ALL
		SELECT RowCode, 'PMS', Description, ESYear, ESMonth, MetricValue FROM PMS
		UNION ALL
		SELECT RowCode, 'Cash', Description, ESYear, ESMonth, MetricValue FROM Cash
		UNION ALL
		SELECT RowCode, 'Avg', Description, ESYear, ESMonth, MetricValue FROM AvgRows
	) all_rows
	ORDER BY BillYear, BillMonth, RowCode;

	DROP TABLE IF EXISTS #LisFiltered;
	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #LisBilledCount;
END;
GO

PRINT '17_Elixir_ExecutiveSummary_Read.sql completed.';
GO
