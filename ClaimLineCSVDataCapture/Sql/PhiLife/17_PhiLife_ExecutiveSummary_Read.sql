-- ============================================================
-- PhiLife – Executive Summary Read SP
-- File : 17_PhiLife_ExecutiveSummary_Read.sql
-- DB   : PhiLife_LRN
--
-- Fresh rewrite mirroring PCRLabsofAmerica\17_PCRLOA_ExecutiveSummary_Read.sql.
-- Run 15_PhiLife_ExecutiveSummary_Tables.sql first to create the five
-- Phi_ES_* tables. Supersedes the previous single-table PhiLife suite
-- (old 15-18: Phi_ES_Data + 2 DetailRows SPs) — ignore those.
--
-- Returns the 6-column contract:
--
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
--   Any filter           → live re-aggregate ALL FOUR categories
--                          (LIS + PMS + Cash + Avg) from dbo.ClaimLevelData.
--
-- Unlike PCRLOA (where LIS is sourced from dbo.LIMSMaster on a different
-- period system and therefore stays read from the aggregate tables even
-- when filtered), PhiLife's LIS Breakdown is sourced from the SAME
-- dbo.ClaimLevelData / DateofService #Base as PMS/Cash/Avg — so the
-- filtered path here re-derives LIS live as well, porting the Metrics
-- logic from the old 15_PhiLife_ExecutiveSummary.sql / the new
-- 19_PhiLife_ExecutiveSummary_LIS_Alt.sql.
--
-- @YearFrom/@YearTo/@MonthFrom/@MonthTo are independent range filters on
-- the Year/Month components of DateofService (matches PCRLOA semantics).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_ExecutiveSummary
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
			-- LIS header rows
			SELECT RoleID                              AS RowCode,
				   'LIS'                               AS Category,
				   Description,
				   ESYear                              AS BillYear,
				   ESMonth                             AS BillMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue
			FROM   dbo.Phi_ES_LIS

			UNION ALL

			-- LIS panel sub-rows (A.<Panelname>)
			SELECT RoleID, 'LIS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.Phi_ES_LIS_Panel

			UNION ALL

			-- PMS
			SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.Phi_ES_PMS

			UNION ALL

			-- Cash (uses dollar amount)
			SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.Phi_ES_Cash

			UNION ALL

			-- Avg (uses dollar amount)
			SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.Phi_ES_Avg
		) all_rows
		ORDER BY BillYear, BillMonth, RowCode;
		RETURN;
	END;

	-- ───────────────────────────────────────────────────────────────────────
	--  FILTERED PATH – live re-aggregation for LIS + PMS + Cash + Avg.
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

	-- LIS filter: Panel, Clinic, and Provider are applied to LIMSMaster for PhiLife.
	-- SalesRep is not available for PhiLife LIS → always skipped.
	-- Date parameters are also ignored for LIMSMaster (LIS uses its own period system).
	DECLARE @HasLisFilter BIT = CASE
		WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
		THEN 1 ELSE 0 END;

	DROP TABLE IF EXISTS #Base;

	SELECT
		AccessionNumber,
		YEAR (TRY_CAST(DateofService AS DATE)) AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE)) AS ESMonth,
		ISNULL(BilledUnbilled, '')               AS BilledUnbilled,
		ISNULL(LTRIM(RTRIM(ClaimStatus)), '')    AS ClaimStatus,
		ISNULL(LTRIM(RTRIM(Panelname)), '')      AS Panelname,
		ISNULL(LTRIM(RTRIM(PayerType)), '')      AS PayerType,
		ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
		ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
		ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
		ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
		ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
		ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
		ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance,
		CASE
			WHEN FirstBilledDate IS NOT NULL THEN 1
			WHEN ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> '' THEN 1
			ELSE 0
		END AS IsResulted
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
	  AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(Panelname,          ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels + ',') COLLATE DATABASE_DEFAULT) > 0)
	  AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics + ',') COLLATE DATABASE_DEFAULT) > 0)
	  AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider,  ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
	  AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,       ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps + ',') COLLATE DATABASE_DEFAULT) > 0);

	-- Periods: every (Year,Month) present in #Base PLUS a (0,0) grand-total sentinel.
	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	-- ───────────────────────────────────────────────────────────────────────
	--  'R' Billed-Mismatch support: pre-aggregate Billed counts.
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #BaseBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT AccessionNumber) AS BilledCount
	INTO #BaseBilledCount
	FROM #Base
	WHERE BilledUnbilled = 'Billed'
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT AccessionNumber) FROM #Base WHERE BilledUnbilled = 'Billed';

	-- ── LIS dimension filter via LIMSMaster ─────────────────────────────────
	--    Build an accession whitelist from LIMSMaster when Panel / Clinic /
	--    Provider filter is active.  Date parameters are intentionally NOT
	--    applied to LIMSMaster (LIS uses its own period system).
	--    SalesRep is not available for PhiLife LIS — always skipped.
	-- ────────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #LisFilterAccessions;
	CREATE TABLE #LisFilterAccessions
	(
	    Accession     NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
	    PanelCategory NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL   -- populated when @HasPanelFilter = 1
	);

	DECLARE @LisMasterFiltered BIT = 0;   -- 1 when whitelist was successfully built

	IF @HasLisFilter = 1 AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
	BEGIN
		DECLARE @LisAccCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('Accession','AccessionNumber','AccessionNo','OrderID')
			ORDER BY CASE name
				WHEN 'Accession'       THEN 0 WHEN 'AccessionNumber' THEN 1
				WHEN 'AccessionNo'     THEN 2 WHEN 'OrderID'         THEN 3 ELSE 4 END);

		-- Keep in sync with 19_PhiLife_ExecutiveSummary_LIS_Alt.sql @PanelCatCol detection.
		DECLARE @LisPanelCatCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('PanelCategory','Panel','PanelName','PanelType','PanelGroup')
			ORDER BY CASE name
				WHEN 'PanelCategory' THEN 0 WHEN 'Panel'     THEN 1
				WHEN 'PanelName'     THEN 2 WHEN 'PanelType' THEN 3 WHEN 'PanelGroup' THEN 4 ELSE 5 END);

		DECLARE @LisFacilityCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('Facility','FacilityName','ClinicName','Clinic','FacilityID')
			ORDER BY CASE name
				WHEN 'Facility'     THEN 0 WHEN 'FacilityName' THEN 1
				WHEN 'ClinicName'   THEN 2 WHEN 'Clinic'       THEN 3 WHEN 'FacilityID' THEN 4 ELSE 5 END);

		DECLARE @LisProviderCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('Provider','PhysicianName','ProviderName','ReferringProvider','ReferringPhysician')
			ORDER BY CASE name
				WHEN 'Provider'            THEN 0 WHEN 'PhysicianName'      THEN 1
				WHEN 'ProviderName'        THEN 2 WHEN 'ReferringProvider'  THEN 3
				WHEN 'ReferringPhysician'  THEN 4 ELSE 5 END);

		-- Build whitelist only when the accession column AND at least one
		-- dimension column matching the active filter could be found.
		IF @LisAccCol IS NOT NULL
		   AND ((@HasPanelFilter    = 1 AND @LisPanelCatCol IS NOT NULL)
			 OR (@HasClinicFilter   = 1 AND @LisFacilityCol IS NOT NULL)
			 OR (@HasProviderFilter = 1 AND @LisProviderCol IS NOT NULL))
		BEGIN
			-- PanelCategory expression: select the panel column value when panel filter is active.
			DECLARE @LisPanelCatExpr NVARCHAR(MAX) =
				CASE WHEN @HasPanelFilter = 1 AND @LisPanelCatCol IS NOT NULL
				     THEN 'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisPanelCatCol + ']), '''')))'
				     ELSE 'NULL'
				END;

			DECLARE @LisFilterSql NVARCHAR(MAX) = N'
				INSERT INTO #LisFilterAccessions (Accession, PanelCategory)
				SELECT DISTINCT
					LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LisAccCol + N']))),
					' + @LisPanelCatExpr + N'
				FROM dbo.LIMSMaster
				WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LisAccCol + N']))), '''') IS NOT NULL';

			-- COLLATE DATABASE_DEFAULT prevents collation conflicts in CHARINDEX.
			-- Date parameters intentionally omitted — LIS ignores date filter.
			IF @HasPanelFilter = 1 AND @LisPanelCatCol IS NOT NULL
				SET @LisFilterSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisPanelCatCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iPanels + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasClinicFilter = 1 AND @LisFacilityCol IS NOT NULL
				SET @LisFilterSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisFacilityCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iClinics + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasProviderFilter = 1 AND @LisProviderCol IS NOT NULL
				SET @LisFilterSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisProviderCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iProviders + '','') COLLATE DATABASE_DEFAULT) > 0';

			SET @LisFilterSql += N';';

			EXEC sp_executesql @LisFilterSql,
				N'@iPanels NVARCHAR(MAX), @iClinics NVARCHAR(MAX), @iProviders NVARCHAR(MAX)',
				@iPanels = @Panels, @iClinics = @Clinics, @iProviders = @Providers;

			SET @LisMasterFiltered = 1;
		END
	END

	-- ── #LisBilled ────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #LisBilled;
	CREATE TABLE #LisBilled
	(
		Accession      NVARCHAR(100) NOT NULL,
		BilledUnbilled NVARCHAR(50)  NOT NULL,
		ESYear         INT           NOT NULL,
		ESMonth        INT           NOT NULL
	);

	IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
	BEGIN
		INSERT INTO #LisBilled (Accession, BilledUnbilled, ESYear, ESMonth)
		SELECT
			LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))),
			LTRIM(RTRIM(ISNULL(BilledorNot, ''))),
			YEAR (TRY_CAST(RequestCollectDate AS DATE)),
			MONTH(TRY_CAST(RequestCollectDate AS DATE))
		FROM dbo.LIMSMaster
		WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL
		  -- When a LIS dimension whitelist was built, restrict to matching accessions.
		  AND (@LisMasterFiltered = 0 OR EXISTS (
				SELECT 1 FROM #LisFilterAccessions fa
				WHERE fa.Accession COLLATE DATABASE_DEFAULT
				      = LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))) COLLATE DATABASE_DEFAULT
		  ));
	END

	DROP TABLE IF EXISTS #LisBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT Accession) AS BilledCount
	INTO #LisBilledCount
	FROM #LisBilled
	WHERE BilledUnbilled = 'Billed'
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT Accession) FROM #LisBilled WHERE BilledUnbilled = 'Billed';

	-- ── #LisBase + #LisPeriods : source tables for the Lis / LisPanel CTEs ──
	--    When @LisMasterFiltered = 1, rebuild ClaimLevelData without date
	--    filters, restricted only to accessions in the LIMSMaster whitelist.
	--    Otherwise mirror #Base directly so existing behaviour is unchanged.
	--
	--    NOTE: CREATE TABLE + INSERT INTO is used (instead of SELECT INTO) to
	--    avoid SQL Server compile-time error 2714 ("object already exists") that
	--    is raised when two SELECT INTO #SameName statements appear in the same
	--    procedure scope, even inside separate IF / ELSE branches.
	DROP TABLE IF EXISTS #LisBase;
	CREATE TABLE #LisBase
	(
		AccessionNumber      NVARCHAR(200) NOT NULL,
		ESYear               INT           NULL,
		ESMonth              INT           NULL,
		BilledUnbilled       NVARCHAR(100) NOT NULL,
		ClaimStatus          NVARCHAR(200) NOT NULL,
		Panelname            NVARCHAR(200) NOT NULL,
		PayerType            NVARCHAR(200) NOT NULL,
		ChargeAmount         DECIMAL(18,2) NOT NULL,
		InsurancePayment     DECIMAL(18,2) NOT NULL,
		PatientPayment       DECIMAL(18,2) NOT NULL,
		InsuranceAdjustments DECIMAL(18,2) NOT NULL,
		PatientAdjustments   DECIMAL(18,2) NOT NULL,
		InsuranceBalance     DECIMAL(18,2) NOT NULL,
		PatientBalance       DECIMAL(18,2) NOT NULL,
		IsResulted           INT           NOT NULL
	);

	IF @LisMasterFiltered = 1
	BEGIN
		-- No date-range parameters applied here — LIS ignores the date filter.
		INSERT INTO #LisBase
		       (AccessionNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
		        Panelname, PayerType, ChargeAmount, InsurancePayment, PatientPayment,
		        InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance,
		        IsResulted)
		SELECT
			AccessionNumber,
			YEAR (TRY_CAST(DateofService AS DATE)),
			MONTH(TRY_CAST(DateofService AS DATE)),
			ISNULL(BilledUnbilled, ''),
			ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
			ISNULL(LTRIM(RTRIM(Panelname)), ''),
			ISNULL(LTRIM(RTRIM(PayerType)), ''),
			ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0),
			CASE
				WHEN FirstBilledDate IS NOT NULL THEN 1
				WHEN ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> '' THEN 1
				ELSE 0
			END
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
		  AND EXISTS (
				SELECT 1 FROM #LisFilterAccessions fa
				WHERE fa.Accession COLLATE DATABASE_DEFAULT
				      = LTRIM(RTRIM(AccessionNumber)) COLLATE DATABASE_DEFAULT
		  );
	END
	ELSE
	BEGIN
		INSERT INTO #LisBase
		       (AccessionNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
		        Panelname, PayerType, ChargeAmount, InsurancePayment, PatientPayment,
		        InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance,
		        IsResulted)
		SELECT AccessionNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
		       Panelname, PayerType, ChargeAmount, InsurancePayment, PatientPayment,
		       InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance,
		       IsResulted
		FROM #Base;
	END

	SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #LisBase
	UNION ALL SELECT 0, 0;

	-- Distinct Panelnames for A.<Panelname> sub-rows.
	-- When @LisMasterFiltered = 1 AND @HasPanelFilter = 1, use the PanelCategory values from
	-- the LIMSMaster whitelist (individual panel labels, e.g. "ABR Panel") so they match
	-- what the user selected — ClaimLevelData Panelname is a compound label ("ABR Panel, UTI Panel, ...")
	-- that would never equal a single selection.  Otherwise use the ClaimLevelData Panelname directly.
	--
	-- CREATE TABLE + INSERT INTO avoids SQL Server compile-time error 2714 that is raised
	-- when two SELECT INTO #SameName statements appear in IF / ELSE branches.
	DROP TABLE IF EXISTS #Panels;
	CREATE TABLE #Panels (Panelname NVARCHAR(200) NOT NULL);

	IF @LisMasterFiltered = 1 AND @HasPanelFilter = 1
	BEGIN
	    INSERT INTO #Panels (Panelname)
	    SELECT DISTINCT PanelCategory
	    FROM #LisFilterAccessions
	    WHERE PanelCategory IS NOT NULL AND PanelCategory <> '';
	END
	ELSE
	BEGIN
	    INSERT INTO #Panels (Panelname)
	    SELECT DISTINCT Panelname FROM #LisBase WHERE IsResulted = 1 AND Panelname <> '';
	END

	-- Lis / LisPanel use #LisBase + #LisPeriods so the LIS aggregation reflects
	-- the LIMSMaster-based dimension filter (when active).
	-- PMS / Cash / AvgRows below continue to use #Base + #Periods â untouched.
	;WITH Lis AS
	(
		-- Total  Total Samples
		SELECT p.ESYear, p.ESMonth, 'Total' AS RowCode, 'Total Samples' AS Description,
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) AS MetricValue
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- A  Billable Samples - Resulted
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A', 'Billable Samples - Resulted',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth)) AND b.IsResulted = 1
		GROUP BY p.ESYear, p.ESMonth

		-- A1  Billed to Insurance
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A1', '  Billed to Insurance',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.ClaimStatus = 'Billed' AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A1.1  Billed in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A1.1', '    Billed in AMD',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.ClaimStatus = 'Billed' AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A2  Not Entered in AMD (Insurance Unbilled)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A2', '  Not Entered in AMD (Insurance Unbilled)',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.ClaimStatus = 'Not Entered in AMD' AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance'
		GROUP BY p.ESYear, p.ESMonth

		-- A2.1  Received
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A2.1', '    Received',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD')
		GROUP BY p.ESYear, p.ESMonth

		-- A2.2  Billing Review Required
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A2.2', '    Billing Review Required',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Billing Review Required'
		GROUP BY p.ESYear, p.ESMonth

		-- A2.3  Collected
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A2.3', '    Collected',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Collected'
		GROUP BY p.ESYear, p.ESMonth

		-- A3  Unbilled Not Released to Payer (EDI Hold)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A3', '  Unbilled Not Released to Payer (EDI Hold)',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Entered'
		GROUP BY p.ESYear, p.ESMonth

		-- A4  Client Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A4', '  Client Bill',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType = 'Client Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- A4.1  Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A4.1', '    Not Entered in AMD',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType = 'Client Bill' AND b.ClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- A4.2  Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A4.2', '    Billed',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType = 'Client Bill' AND b.ClaimStatus = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A5  Self Pay
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A5', '  Self Pay',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType = 'Self Pay'
		GROUP BY p.ESYear, p.ESMonth

		-- A5.1  Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A5.1', '    Billed',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType = 'Self Pay' AND b.ClaimStatus = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A5.2  Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A5.2', '    Not Entered in AMD',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType = 'Self Pay' AND b.ClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- A6  Test Entries
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A6', '  Test Entries',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType <> 'No Bill' AND b.ClaimStatus = 'Test Entries'
		GROUP BY p.ESYear, p.ESMonth

		-- A6.1  Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A6.1', '    Not Entered in AMD',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType <> 'No Bill' AND b.ClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- A6.2  Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A6.2', '    Billed',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType <> 'No Bill' AND b.ClaimStatus = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A7  Rejected Sample
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A7', '  Rejected Sample',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.ClaimStatus = 'Rejected'
		GROUP BY p.ESYear, p.ESMonth

		-- A7.1  Not Entered in AMD
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A7.1', '    Not Entered in AMD',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.ClaimStatus = 'Not Entered in AMD'
		GROUP BY p.ESYear, p.ESMonth

		-- A7.2  Billed (Rejected)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A7.2', '    Billed (Rejected)',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.ClaimStatus = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- A8  Payment Method No Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'A8', '  Payment Method No Bill',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 1 AND b.PayerType = 'No Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- B  Not Resulted
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B', 'Not Resulted',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth)) AND b.IsResulted = 0
		GROUP BY p.ESYear, p.ESMonth

		-- B1  Not Entered in AMD (Not Resulted)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B1', '  Not Entered in AMD (Not Resulted)',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 0 AND b.ClaimStatus = 'Not Entered in AMD' AND b.PayerType = 'Insurance'
		GROUP BY p.ESYear, p.ESMonth

		-- B1.1  Received
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B1.1', '    Received',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD')
		GROUP BY p.ESYear, p.ESMonth

		-- B1.2  Collected
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B1.2', '    Collected',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Collected'
		GROUP BY p.ESYear, p.ESMonth

		-- B2  Client Bill (Not Resulted)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B2', '  Client Bill (Not Resulted)',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 0 AND b.PayerType = 'Client Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- B3  Test Entries (Not Resulted)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B3', '  Test Entries (Not Resulted)',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Test Entries'
		GROUP BY p.ESYear, p.ESMonth

		-- B4  Rejected Sample (Not Resulted)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B4', '  Rejected Sample (Not Resulted)',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Rejected'
		GROUP BY p.ESYear, p.ESMonth

		-- B5  Payment Method No Bill (Not Resulted)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B5', '  Payment Method No Bill (Not Resulted)',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #LisPeriods p LEFT JOIN #LisBase b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.IsResulted = 0 AND b.PayerType = 'No Bill'
		GROUP BY p.ESYear, p.ESMonth
	),
	LisPanel AS
	(
		-- A.<Panelname> sub-rows under "Billable Samples - Resulted"
		--
		-- Path A (LIMSMaster panel filter active): match via #LisFilterAccessions.PanelCategory.
		--   #Panels.Panelname contains individual LIMSMaster PanelCategory values.
		--   Join to #LisBase through the whitelist: accession is in the whitelist AND
		--   the whitelist row carries the selected PanelCategory that matches this sub-row.
		--
		-- Path B (no LIMSMaster panel filter): direct ClaimLevelData Panelname match.
		--   Only used when no PanelCategory values are present in the whitelist.
		SELECT p.ESYear, p.ESMonth, 'A.' + pn.Panelname AS RowCode, '  ' + pn.Panelname AS Description,
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) AS MetricValue
		FROM #Panels pn
		CROSS JOIN #LisPeriods p
		LEFT JOIN #LisBase b
		       ON (p.ESYear = 0 OR (b.ESYear = p.ESYear AND b.ESMonth = p.ESMonth))
		      AND b.IsResulted = 1
		      AND (
		              -- Path A: match via LIMSMaster PanelCategory whitelist
		              EXISTS (
		                  SELECT 1 FROM #LisFilterAccessions fa
		                  WHERE fa.Accession       COLLATE DATABASE_DEFAULT = b.AccessionNumber COLLATE DATABASE_DEFAULT
		                    AND fa.PanelCategory   COLLATE DATABASE_DEFAULT = pn.Panelname      COLLATE DATABASE_DEFAULT
		              )
		              OR
		              -- Path B: direct Panelname match when no PanelCategory in whitelist
		              (
		                  NOT EXISTS (SELECT 1 FROM #LisFilterAccessions WHERE PanelCategory IS NOT NULL)
		                  AND b.Panelname COLLATE DATABASE_DEFAULT = pn.Panelname COLLATE DATABASE_DEFAULT
		              )
		          )
		GROUP BY pn.Panelname, p.ESYear, p.ESMonth
	),
	PMS AS
	(
		-- Q  Billed - Includes all Claims Billed in AMD
		SELECT p.ESYear, p.ESMonth, 'Q' AS RowCode, 'Billed - Includes all Claims Billed in AMD' AS Description,
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- R  Billed Mismatches - Non Diagnose LIS Samples (degenerates to R = Q without LIMSMaster)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'R', 'Billed Mismatches - Non Diagnose LIS Samples',
			   CAST(ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #BaseBilledCount bb ON bb.ESYear = p.ESYear AND bb.ESMonth = p.ESMonth
		LEFT JOIN #LisBilledCount  ll ON ll.ESYear = p.ESYear AND ll.ESMonth = p.ESMonth

		-- S  Unbilled - Entered to AMD - Yet to be released to Payer
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'S', 'Unbilled - Entered to AMD - Yet to be released to Payer',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Unbilled'
		GROUP BY p.ESYear, p.ESMonth

		-- T  Fully Paid - Insurance Pay
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'T', 'Fully Paid - Insurance Pay',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- U  Fully Adjusted (Complete W/O)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U', 'Fully Adjusted (Complete W/O)',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Complete W/O'
		GROUP BY p.ESYear, p.ESMonth

		-- V  Patient Responsibility
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'V', 'Patient Responsibility',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility'
		GROUP BY p.ESYear, p.ESMonth

		-- W  Partially Paid
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'W', 'Partially Paid',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- X  Patient Payment
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X', 'Patient Payment',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment'
		GROUP BY p.ESYear, p.ESMonth

		-- Y  Insurance Balance (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y', 'Insurance Balance',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- Y.1  Fully Denied
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y.1', '  Fully Denied',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- Y.2  No Response
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y.2', '  No Response',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth

		-- Y.3  Partially Denied (Partially Adjusted + Partially Denied)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Y.3', '  Partially Denied',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth
	),
	Cash AS
	(
		-- Z  Total Billed ($)
		SELECT p.ESYear, p.ESMonth, 'Z' AS RowCode, 'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount), 0) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AA  Unbilled ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AA', 'Unbilled ($)',
			   ISNULL(SUM(b.ChargeAmount), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Unbilled'
		GROUP BY p.ESYear, p.ESMonth

		-- AB  Insurance Payment (Fully Paid) ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AB', 'Insurance Payment (Fully Paid) ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- AC  Partially Paid ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AC', 'Partially Paid ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- AD  Patient Payment ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AD', 'Patient Payment ($)',
			   ISNULL(SUM(b.PatientPayment), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AE  Fully Adjusted (Complete W/O) ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AE', 'Fully Adjusted (Complete W/O) ($)',
			   ISNULL(SUM(b.InsuranceAdjustments), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Complete W/O'
		GROUP BY p.ESYear, p.ESMonth

		-- AF  Contractual Obligation W/O ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AF', 'Contractual Obligation W/O ($)',
			   ISNULL(SUM(b.InsuranceAdjustments), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus <> 'Complete W/O'
		GROUP BY p.ESYear, p.ESMonth

		-- AG  Patient Balance ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AG', 'Patient Balance ($)',
			   ISNULL(SUM(b.PatientBalance), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AH  Patient WO ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AH', 'Patient WO ($)',
			   ISNULL(SUM(b.PatientAdjustments), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AI  Insurance Balance ($) (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AI', 'Insurance Balance ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- AI.1  Fully Denied ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AI.1', '  Fully Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- AI.2  No Response ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AI.2', '  No Response ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth

		-- AI.3  Partially Denied ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AI.3', '  Partially Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('No Response','Fully Denied')
		GROUP BY p.ESYear, p.ESMonth
	),
	AvgRows AS
	(
		-- AJ/AK/AL are derived from the Cash (AB,AC,AD) and PMS (Q / T,W,X /
		-- T,U,V,W,X,Y.1,Y.3) CTE values above - no ClaimStatus re-derivation here.
		--   Numerator (all three) = AB + AC + AD
		--   AJ denom = Q
		--   AK denom = T + W + X
		--   AL denom = T + U + V + W + X + Y.1 + Y.3

		-- AJ  Avg Payment ($) Total Pay / Billed Claims  = (AB+AC+AD) / Q
		SELECT p.ESYear, p.ESMonth, 'AJ' AS RowCode, 'Avg Payment ($) Total Pay / Billed Claims' AS Description,
			   ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(dq.DenomCount, 0), 2), 0) AS MetricValue
		FROM #Periods p
		LEFT JOIN (SELECT ESYear, ESMonth, SUM(MetricValue) AS NumValue FROM Cash WHERE RowCode IN ('AB','AC','AD') GROUP BY ESYear, ESMonth) n
			   ON n.ESYear = p.ESYear AND n.ESMonth = p.ESMonth
		LEFT JOIN (SELECT ESYear, ESMonth, MetricValue AS DenomCount FROM PMS WHERE RowCode = 'Q') dq
			   ON dq.ESYear = p.ESYear AND dq.ESMonth = p.ESMonth

		-- AK  Avg Payment ($) Total Pay / Paid Claims  = (AB+AC+AD) / (T+W+X)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AK', 'Avg Payment ($) Total Pay / Paid Claims',
			   ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(dak.DenomCount, 0), 2), 0)
		FROM #Periods p
		LEFT JOIN (SELECT ESYear, ESMonth, SUM(MetricValue) AS NumValue FROM Cash WHERE RowCode IN ('AB','AC','AD') GROUP BY ESYear, ESMonth) n
			   ON n.ESYear = p.ESYear AND n.ESMonth = p.ESMonth
		LEFT JOIN (SELECT ESYear, ESMonth, SUM(MetricValue) AS DenomCount FROM PMS WHERE RowCode IN ('T','W','X') GROUP BY ESYear, ESMonth) dak
			   ON dak.ESYear = p.ESYear AND dak.ESMonth = p.ESMonth

		-- AL  Avg Payment ($) Total Pay / Adjudicated Claims  = (AB+AC+AD) / (T+U+V+W+X+Y.1+Y.3)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AL', 'Avg Payment ($) Total Pay / Adjudicated Claims',
			   ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(dal.DenomCount, 0), 2), 0)
		FROM #Periods p
		LEFT JOIN (SELECT ESYear, ESMonth, SUM(MetricValue) AS NumValue FROM Cash WHERE RowCode IN ('AB','AC','AD') GROUP BY ESYear, ESMonth) n
			   ON n.ESYear = p.ESYear AND n.ESMonth = p.ESMonth
		LEFT JOIN (SELECT ESYear, ESMonth, SUM(MetricValue) AS DenomCount FROM PMS WHERE RowCode IN ('T','U','V','W','X','Y.1','Y.3') GROUP BY ESYear, ESMonth) dal
			   ON dal.ESYear = p.ESYear AND dal.ESMonth = p.ESMonth
	)
	SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
	FROM
	(
		SELECT RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth, MetricValue FROM Lis
		UNION ALL
		SELECT RowCode, 'LIS', Description, ESYear, ESMonth, MetricValue FROM LisPanel
		UNION ALL
		SELECT RowCode, 'PMS', Description, ESYear, ESMonth, MetricValue FROM PMS
		UNION ALL
		SELECT RowCode, 'Cash', Description, ESYear, ESMonth, MetricValue FROM Cash
		UNION ALL
		SELECT RowCode, 'Avg', Description, ESYear, ESMonth, MetricValue FROM AvgRows
	) all_rows
	ORDER BY BillYear, BillMonth, RowCode;

	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #LisBilledCount;
	DROP TABLE IF EXISTS #Panels;
	DROP TABLE IF EXISTS #LisFilterAccessions;
	DROP TABLE IF EXISTS #LisBase;
	DROP TABLE IF EXISTS #LisPeriods;
END;
GO

PRINT '17_PhiLife_ExecutiveSummary_Read.sql completed.';
GO
