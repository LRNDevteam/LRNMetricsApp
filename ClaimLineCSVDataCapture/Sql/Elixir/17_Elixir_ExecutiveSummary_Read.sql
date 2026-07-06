
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
--                          dbo.ClaimLevelData (same as PhiLife). LIS rows:
--                            • No LIS-applicable filter (Year/Month/DOS only) →
--                              filtered/re-summed from the pre-computed
--                              dbo.Elix_ES_LIS table (fast).  @DosFrom/@DosTo
--                              are converted to year+month bounds applied to
--                              ESYear/ESMonth so the LIS aggregate is bounded
--                              to the same period selected in the UI.
--                            • Panel/Clinic/Provider filter OR billed-date
--                              mode (@UseBilledDate=1) → live scan of
--                              dbo.LIMSMaster so the period/dimension basis
--                              is honoured (@HasLisFilter=1 path).
--
-- @YearFrom/@YearTo/@MonthFrom/@MonthTo are independent range filters on
-- the Year/Month components of the relevant period column (DateofService
-- for PMS/Cash/Avg, the LIMSMaster date column for LIS).
--
-- LIS @DateCol priority (collection-date columns always preferred):
--   DateOfCollection (0) > RequestCollectDate (1) > CollectionDate (2) >
--   DateofService (3) > ServiceDate (4) > AccessionDate (5).
--
-- Date mode (DOS vs FirstBilledDate) — mutually exclusive in the UI:
--   DOS mode (@DosFrom/@DosTo, or no date filter):
--     PMS/Cash/Avg bucket by DateofService; LIS buckets by DateOfCollection.
--   BilledDate mode (@BilledFrom/@BilledTo set, DOS NULL → @UseBilledDate=1):
--     PMS/Cash/Avg re-bucket #Base by FirstBilledDate; LIS/row-I re-bucket by
--     the LIMSMaster BilledDate column (triggers a live LIMSMaster scan).
--   Mirrors 17_Cove_ExecutiveSummary_Read.sql's @UseBilledDate behaviour.
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

	-- Date mode: DOS vs FirstBilledDate are mutually exclusive in the UI.
	-- @UseBilledDate = 1  → FirstBilledDate filter is active (@BilledFrom/@BilledTo set, @DosFrom/@DosTo NULL).
	--   #Base : ESYear/ESMonth derived from FirstBilledDate (not DateofService).
	--   LIS   : LISYear/LISMonth derived from BilledDate in LIMSMaster; live scan triggered.
	-- @UseBilledDate = 0  → DOS mode (or no date filter) — existing behaviour unchanged.
	DECLARE @UseBilledDate BIT = CASE
		WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
		 AND  @DosFrom IS NULL AND @DosTo IS NULL
		THEN 1 ELSE 0 END;

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

	-- @HasLisFilter: 1 when Panel/Clinic/Provider/Rep filter(s) are active OR BilledDate mode is active.
	-- DOS date params are intentionally NOT applied to LIMSMaster for Elixir (independent period system).
	-- @UseBilledDate = 1 forces a live LIMSMaster scan so LISYear/LISMonth are bucketed by
	--   BilledDate (not DateOfCollection) and @BilledFrom/@BilledTo bound the scan.
	-- SalesRep (@HasRepFilter) now included: LIMSMaster has a SaleRepName column
	-- (confirmed present), so a Rep-only filter must also trigger the live scan
	-- for it to take effect on the LIS section (see @RepCol below).
	DECLARE @HasLisFilter BIT = CASE
		WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
		  OR @HasRepFilter = 1 OR @UseBilledDate = 1
		THEN 1 ELSE 0 END;

	-- ── LIMSMaster column detection (shared by #Lis LIS scan and #LisBilled) ──
	DECLARE @AccCol          SYSNAME = NULL;
	DECLARE @DateCol         SYSNAME = NULL;
	DECLARE @NewStatusCol    SYSNAME = NULL;
	DECLARE @BillCategoryCol SYSNAME = NULL;
	DECLARE @ResultStatusCol SYSNAME = NULL;
	DECLARE @PanelCol        SYSNAME = NULL;
	DECLARE @ClinicCol       SYSNAME = NULL;
	DECLARE @ProviderCol     SYSNAME = NULL;
	DECLARE @RepCol          SYSNAME = NULL;
	DECLARE @BilledDateCol   SYSNAME = NULL;

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
	BEGIN
		SET @AccCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('AccessionNumber','Accession','AccessionNo')
			ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

		SET @DateCol = (
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

		SET @NewStatusCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('NewStatus','Status')
			ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 ELSE 2 END);

		SET @BillCategoryCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus')
			ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

		SET @ResultStatusCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('ResultStatus','Result_Status','ResultedStatus','RessultedStatus','IsResulted')
			ORDER BY CASE name
				WHEN 'ResultStatus' THEN 0 WHEN 'Result_Status' THEN 1
				WHEN 'ResultedStatus' THEN 2 WHEN 'RessultedStatus' THEN 3
				WHEN 'IsResulted' THEN 4 ELSE 5 END);

		-- Dimension filter columns (Panels → PanelName, Clinics → FacilityName, Provider → PhysicianName)
		-- PanelName is the confirmed/correct LIMSMaster column for the Panel filter.
		-- It is now prioritized first: it was previously ranked behind 'Panel', and
		-- when a same-named 'Panel' column exists but doesn't carry the values the
		-- UI passes (which come from ClaimLevelData.PanelType via the FilterOptions
		-- SP), the CHARINDEX predicate below never matches — causing the entire LIS
		-- breakdown to disappear whenever a Panel filter is applied.
		SET @PanelCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('PanelName','Panel','PanelType','TestPanel')
			ORDER BY CASE name WHEN 'PanelName' THEN 0 WHEN 'Panel' THEN 1 WHEN 'PanelType' THEN 2 WHEN 'TestPanel' THEN 3 ELSE 4 END);

		SET @ClinicCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('FacilityName','ClinicName','Clinic','FacilityID')
			ORDER BY CASE name WHEN 'FacilityName' THEN 0 WHEN 'ClinicName' THEN 1 WHEN 'Clinic' THEN 2 WHEN 'FacilityID' THEN 3 ELSE 4 END);

		SET @ProviderCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('PhysicianName','ReferringProvider','ReferringPhysician','ProviderName')
			ORDER BY CASE name WHEN 'PhysicianName' THEN 0 WHEN 'ReferringProvider' THEN 1 WHEN 'ReferringPhysician' THEN 2 WHEN 'ProviderName' THEN 3 ELSE 4 END);

		SET @RepCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('SaleRepName','SalesRepName','SalesRep','Rep')
			ORDER BY CASE name WHEN 'SaleRepName' THEN 0 WHEN 'SalesRepName' THEN 1 WHEN 'SalesRep' THEN 2 WHEN 'Rep' THEN 3 ELSE 4 END);

		-- BilledDate: maps @BilledFrom/@BilledTo → LIMSMaster BilledDate column (billed-date mode).
		SET @BilledDateCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('BilledDate','FirstBilledDate','BilledOn','BillDate','FirstBillDate')
			ORDER BY CASE name
				WHEN 'BilledDate'    THEN 0 WHEN 'FirstBilledDate' THEN 1
				WHEN 'BilledOn'      THEN 2 WHEN 'BillDate'        THEN 3
				WHEN 'FirstBillDate' THEN 4 ELSE 5 END);
	END

	-- ── LIS rows ─────────────────────────────────────────────────────────────
	-- #LisOut holds all LIS rows; populated from aggregate (fast path) or
	-- live LIMSMaster scan (dimension-filtered path).
	-- Created before any branching so LisFinal CTE always has a valid source.
	DROP TABLE IF EXISTS #LisOut;
	CREATE TABLE #LisOut
	(
		RowCode     NVARCHAR(420) NOT NULL,
		Description NVARCHAR(420) NOT NULL,
		ESYear      INT           NOT NULL,
		ESMonth     INT           NOT NULL,
		MetricValue DECIMAL(18,2) NOT NULL
	);

	IF @HasLisFilter = 0
	BEGIN
		-- No LIS-applicable dimension filter → re-sum aggregate by Year/Month only.
		-- Also apply DOS date year/month bounds when @DosFrom/@DosTo are set so that
		-- selecting a DOS range (e.g. Jan–Jul 2026) restricts LIS to the same period
		-- (month-level granularity, matching the aggregate's ESYear/ESMonth bucketing).
		DROP TABLE IF EXISTS #LisFiltered;
		SELECT RoleID, Description, ESYear, ESMonth, ESMonthClaimCount
		INTO #LisFiltered
		FROM dbo.Elix_ES_LIS
		WHERE ESYear <> 0
		  AND (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
		  AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
		  AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
		  AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo)
		  -- DOS lower bound: keep rows whose (ESYear,ESMonth) >= (DosFrom year, DosFrom month)
		  AND (@DosFrom IS NULL
			   OR ESYear  > YEAR (CAST(@DosFrom AS DATE))
			   OR (ESYear = YEAR (CAST(@DosFrom AS DATE)) AND ESMonth >= MONTH(CAST(@DosFrom AS DATE))))
		  -- DOS upper bound: keep rows whose (ESYear,ESMonth) <= (DosTo year, DosTo month)
		  AND (@DosTo   IS NULL
			   OR ESYear  < YEAR (CAST(@DosTo   AS DATE))
			   OR (ESYear = YEAR (CAST(@DosTo   AS DATE)) AND ESMonth <= MONTH(CAST(@DosTo   AS DATE))));

		INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
		SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
		FROM #LisFiltered
		UNION ALL
		SELECT RoleID, MAX(Description), 0, 0, CAST(SUM(ESMonthClaimCount) AS DECIMAL(18,2))
		FROM #LisFiltered
		GROUP BY RoleID;
	END
	ELSE
	BEGIN
		-- Panel/Clinic/Provider filter OR billed-date mode active → scan LIMSMaster.
		--   DOS mode        : LISYear/LISMonth from DateOfCollection (no date bounds — independent period system).
		--   BilledDate mode : LISYear/LISMonth from BilledDate, bounded by @BilledFrom/@BilledTo.
		IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL
		   AND @NewStatusCol IS NOT NULL AND @BillCategoryCol IS NOT NULL AND @ResultStatusCol IS NOT NULL
		BEGIN
			-- ResultStatus normalizer (IsResulted may be a bit/flag column)
			DECLARE @ResultExpr NVARCHAR(400);
			IF @ResultStatusCol = 'IsResulted'
				SET @ResultExpr = N'(CASE WHEN TRY_CAST([' + @ResultStatusCol + N'] AS INT) = 1 THEN ''Resulted''
										   WHEN CONVERT(NVARCHAR(20), [' + @ResultStatusCol + N']) IN (''Y'',''Yes'',''True'',''Resulted'') THEN ''Resulted''
										   ELSE ''Not Resulted'' END)';
			ELSE
				SET @ResultExpr = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ResultStatusCol + N']), '''')))';

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

			-- Panel SELECT expression: use detected column or empty string if column absent
			DECLARE @PanelExpr NVARCHAR(200) =
				CASE WHEN @PanelCol IS NOT NULL
					 THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol + N']), '''')))'
					 ELSE N'CAST('''' AS NVARCHAR(300))'
				END;

			-- Period expression for LISYear/LISMonth:
			--   BilledDate mode → TRY_CAST([BilledDate] AS DATE)  (period bucketed by billed date)
			--   DOS mode        → TRY_CAST([DateOfCollection] AS DATE)
			-- TRY_CAST is used in both modes because LIMSMaster date columns may be stored as
			-- strings in some Elixir environments (same defensive pattern as the DOS path).
			DECLARE @LisPeriodExpr NVARCHAR(200) =
				CASE WHEN @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
					 THEN N'TRY_CAST([' + @BilledDateCol + N'] AS DATE)'
					 ELSE N'TRY_CAST([' + @DateCol + N'] AS DATE)' END;

			DECLARE @LisSql NVARCHAR(MAX) = N'
				INSERT INTO #Lis (Accession, ESYear, ESMonth, NewStatus, BillCategory, ResultStatus, Panel)
				SELECT
					LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
					YEAR (' + @LisPeriodExpr + N'),
					MONTH(' + @LisPeriodExpr + N'),
					LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol + N']), ''''))),
					LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))),
					' + @ResultExpr + N',
					' + @PanelExpr + N'
				FROM dbo.LIMSMaster
				WHERE ' + @LisPeriodExpr + N' IS NOT NULL
				  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL';

			-- Dimension filter predicates — COLLATE DATABASE_DEFAULT on both sides to avoid
			-- collation conflicts between LIMSMaster columns and NVARCHAR(MAX) parameters.
			IF @HasPanelFilter = 1 AND @PanelCol IS NOT NULL
				SET @LisSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iPanels + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasClinicFilter = 1 AND @ClinicCol IS NOT NULL
				SET @LisSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iClinics + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasProviderFilter = 1 AND @ProviderCol IS NOT NULL
				SET @LisSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iProviders + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasRepFilter = 1 AND @RepCol IS NOT NULL
				SET @LisSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @RepCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iReps + '','') COLLATE DATABASE_DEFAULT) > 0';

			-- FirstBilledDate bound: only in billed-date mode. Bounds the LIMSMaster scan by BilledDate.
			IF @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
				SET @LisSql += N'
				  AND (@iBilledFrom IS NULL OR ' + @LisPeriodExpr + N' >= @iBilledFrom)
				  AND (@iBilledTo   IS NULL OR ' + @LisPeriodExpr + N' <= @iBilledTo)';

			SET @LisSql += N';';

			EXEC sp_executesql @LisSql,
				N'@iPanels     NVARCHAR(MAX),
				  @iClinics    NVARCHAR(MAX),
				  @iProviders  NVARCHAR(MAX),
				  @iReps       NVARCHAR(MAX),
				  @iBilledFrom DATE,
				  @iBilledTo   DATE',
				@iPanels     = @Panels,
				@iClinics    = @Clinics,
				@iProviders  = @Providers,
				@iReps       = @Reps,
				@iBilledFrom = @BilledFrom,
				@iBilledTo   = @BilledTo;

			-- Aggregate #Lis into #LisOut, one row per (RowCode, ESYear, ESMonth)
			INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
			-- A  Total Samples
			SELECT 'A',   'Total Samples',                ESYear, ESMonth, CAST(COUNT(DISTINCT Accession) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- B  Billable Samples
			UNION ALL
			SELECT 'B',   'Billable Samples',             ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable'                                                           THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- C  Billed
			UNION ALL
			SELECT 'C',   'Billed',                       ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable' AND BillCategory = 'Billed'                             THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- D  Unbilled
			UNION ALL
			SELECT 'D',   'Unbilled',                     ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable' AND BillCategory = 'Not Billed'                         THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- D.1  Resulted yet to be billed
			UNION ALL
			SELECT 'D.1', '  Resulted yet to be billed', ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable' AND BillCategory = 'Not Billed' AND ResultStatus = 'Resulted' THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E  Other Samples
			UNION ALL
			SELECT 'E',   'Other Samples',                ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus <> 'Billable'                                                          THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.1  Client Bill
			UNION ALL
			SELECT 'E.1', '  Client Bill',                ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Client Bill'         THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.2  Self Pay
			UNION ALL
			SELECT 'E.2', '  Self Pay',                   ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Self Pay'            THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.3  System Test
			UNION ALL
			SELECT 'E.3', '  System Test',                ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'System Test'         THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.4  Deleted/Rejected
			UNION ALL
			SELECT 'E.4', '  Deleted/Rejected',           ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Deleted/Rejected'    THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.5  CIP/Pending
			UNION ALL
			SELECT 'E.5', '  CIP/Pending',                ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'CIP/Pending'         THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.6  Yet to be validated
			UNION ALL
			SELECT 'E.6', '  Yet to be validated',        ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Yet to be validated' THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth;

			-- B.x  Panel sub-rows (Billable Samples by Panel, displayed under row B)
			INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
			SELECT 'B.' + Panel, '  ' + Panel, ESYear, ESMonth,
			       CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable' THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis
			WHERE NewStatus = 'Billable' AND Panel <> ''
			GROUP BY Panel, ESYear, ESMonth;

			-- Grand-total sentinel (0,0) rows — sums all per-period rows, including B.x
			INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
			SELECT RowCode, MAX(Description), 0, 0, SUM(MetricValue)
			FROM #LisOut
			WHERE ESYear <> 0
			GROUP BY RowCode;
		END
	END

	-- PMS/Cash/Avg: live re-aggregation from ClaimLevelData, same #Base shape as file 16.
	-- Pre-create #Base so the two date-mode branches use INSERT (SELECT…INTO twice would
	-- raise Msg 2714 at compile time regardless of the IF/ELSE branch actually run).
	DROP TABLE IF EXISTS #Base;
	CREATE TABLE #Base
	(
		AccessionNumber      NVARCHAR(100)  COLLATE DATABASE_DEFAULT NOT NULL,
		ESYear               INT            NOT NULL DEFAULT 0,
		ESMonth              INT            NOT NULL DEFAULT 0,
		BilledUnbilled       NVARCHAR(200)  COLLATE DATABASE_DEFAULT NOT NULL DEFAULT '',
		ClaimStatus          NVARCHAR(200)  COLLATE DATABASE_DEFAULT NOT NULL DEFAULT '',
		ChargeAmount         DECIMAL(18,2)  NOT NULL DEFAULT 0,
		InsurancePayment     DECIMAL(18,2)  NOT NULL DEFAULT 0,
		PatientPayment       DECIMAL(18,2)  NOT NULL DEFAULT 0,
		InsuranceAdjustments DECIMAL(18,2)  NOT NULL DEFAULT 0,
		PatientAdjustments   DECIMAL(18,2)  NOT NULL DEFAULT 0,
		InsuranceBalance     DECIMAL(18,2)  NOT NULL DEFAULT 0,
		PatientBalance       DECIMAL(18,2)  NOT NULL DEFAULT 0
	);

	-- DOS mode        : ESYear/ESMonth from DateofService,   filter by @DosFrom/@DosTo.
	-- BilledDate mode : ESYear/ESMonth from FirstBilledDate, filter by @BilledFrom/@BilledTo.
	IF @UseBilledDate = 0
	BEGIN
		INSERT INTO #Base (AccessionNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
						   ChargeAmount, InsurancePayment, PatientPayment,
						   InsuranceAdjustments, PatientAdjustments,
						   InsuranceBalance, PatientBalance)
		SELECT
			AccessionNumber,
			ISNULL(YEAR (TRY_CAST(DateofService AS DATE)), 0),
			ISNULL(MONTH(TRY_CAST(DateofService AS DATE)), 0),
			ISNULL(BillStatus, ''),
			ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
			ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
		  AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
		  AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
		  AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
		  AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
		  AND (@DosFrom    IS NULL OR TRY_CAST(DateofService AS DATE) >= @DosFrom)
		  AND (@DosTo      IS NULL OR TRY_CAST(DateofService AS DATE) <= @DosTo)
		  AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(Panelname,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps + ',') COLLATE DATABASE_DEFAULT) > 0);
	END
	ELSE  -- @UseBilledDate = 1 : period + filter on FirstBilledDate
	BEGIN
		INSERT INTO #Base (AccessionNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
						   ChargeAmount, InsurancePayment, PatientPayment,
						   InsuranceAdjustments, PatientAdjustments,
						   InsuranceBalance, PatientBalance)
		SELECT
			AccessionNumber,
			ISNULL(YEAR (TRY_CAST(FirstBilledDate AS DATE)), 0),
			ISNULL(MONTH(TRY_CAST(FirstBilledDate AS DATE)), 0),
			ISNULL(BillStatus, ''),
			ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
			ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
		  AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
		  AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
		  AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(Panelname,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps + ',') COLLATE DATABASE_DEFAULT) > 0)
		OPTION (RECOMPILE);  -- lets optimizer use actual @BilledFrom/@BilledTo values,
							 -- eliminates dead IS-NULL branches, enables parallel scan
							 -- of ClaimLevelData (FirstBilledDate is NVARCHAR → full scan)
	END

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

	-- Reuses @AccCol / @DateCol / @NewStatusCol / @BillCategoryCol / @PanelCol / @ClinicCol / @ProviderCol / @RepCol
	-- detected in the shared column-detection block above.
	-- When @HasLisFilter = 1, dimension filters are also applied so the
	-- Billed-Mismatch count (row I) stays consistent with the filtered LIS rows.
	IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @NewStatusCol IS NOT NULL AND @BillCategoryCol IS NOT NULL
	BEGIN
		-- Period expression for #LisBilled buckets — keeps row-I (Billed Mismatch)
		-- period basis consistent with #Base and #LisOut:
		--   BilledDate mode → TRY_CAST([BilledDate] AS DATE), bounded by @BilledFrom/@BilledTo
		--   DOS mode        → TRY_CAST([DateOfCollection] AS DATE), bounded by Year/Month range
		DECLARE @LisBilledPeriodExpr NVARCHAR(200) =
			CASE WHEN @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
				 THEN N'TRY_CAST([' + @BilledDateCol + N'] AS DATE)'
				 ELSE N'TRY_CAST([' + @DateCol + N'] AS DATE)' END;

		DECLARE @LisBilledSql NVARCHAR(MAX) = N'
			INSERT INTO #LisBilled (Accession, ESYear, ESMonth)
			SELECT
				LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
				YEAR (' + @LisBilledPeriodExpr + N'),
				MONTH(' + @LisBilledPeriodExpr + N')
			FROM dbo.LIMSMaster
			WHERE ' + @LisBilledPeriodExpr + N' IS NOT NULL
			  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
			  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol + N']), ''''))) = ''Billable''
			  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))) = ''Billed''';

		-- Date bounds differ by mode: BilledDate range (billed mode) vs Year/Month range (DOS mode).
		IF @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND (@iBilledFrom IS NULL OR ' + @LisBilledPeriodExpr + N' >= @iBilledFrom)
			  AND (@iBilledTo   IS NULL OR ' + @LisBilledPeriodExpr + N' <= @iBilledTo)';
		ELSE
			SET @LisBilledSql += N'
			  AND (' + ISNULL(CONVERT(NVARCHAR(20), @YearFrom), 'NULL') + N' IS NULL OR YEAR (' + @LisBilledPeriodExpr + N') >= ' + ISNULL(CONVERT(NVARCHAR(20), @YearFrom), '0') + N')
			  AND (' + ISNULL(CONVERT(NVARCHAR(20), @YearTo), 'NULL') + N' IS NULL OR YEAR (' + @LisBilledPeriodExpr + N') <= ' + ISNULL(CONVERT(NVARCHAR(20), @YearTo), '0') + N')
			  AND (' + ISNULL(CONVERT(NVARCHAR(20), @MonthFrom), 'NULL') + N' IS NULL OR MONTH(' + @LisBilledPeriodExpr + N') >= ' + ISNULL(CONVERT(NVARCHAR(20), @MonthFrom), '0') + N')
			  AND (' + ISNULL(CONVERT(NVARCHAR(20), @MonthTo), 'NULL') + N' IS NULL OR MONTH(' + @LisBilledPeriodExpr + N') <= ' + ISNULL(CONVERT(NVARCHAR(20), @MonthTo), '0') + N')';

		-- When LIS dimension filters are active, apply them here too for consistent row-I mismatch count.
		-- COLLATE DATABASE_DEFAULT prevents collation conflicts between LIMSMaster columns and parameters.
		IF @HasPanelFilter = 1 AND @PanelCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iPanels + '','') COLLATE DATABASE_DEFAULT) > 0';

		IF @HasClinicFilter = 1 AND @ClinicCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iClinics + '','') COLLATE DATABASE_DEFAULT) > 0';

		IF @HasProviderFilter = 1 AND @ProviderCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iProviders + '','') COLLATE DATABASE_DEFAULT) > 0';

		IF @HasRepFilter = 1 AND @RepCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @RepCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iReps + '','') COLLATE DATABASE_DEFAULT) > 0';

		SET @LisBilledSql += N';';

		EXEC sp_executesql @LisBilledSql,
			N'@iPanels     NVARCHAR(MAX),
			  @iClinics    NVARCHAR(MAX),
			  @iProviders  NVARCHAR(MAX),
			  @iReps       NVARCHAR(MAX),
			  @iBilledFrom DATE,
			  @iBilledTo   DATE',
			@iPanels     = @Panels,
			@iClinics    = @Clinics,
			@iProviders  = @Providers,
			@iReps       = @Reps,
			@iBilledFrom = @BilledFrom,
			@iBilledTo   = @BilledTo;
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
		-- Reads from #LisOut which is populated by either the aggregate fast-path
		-- (no LIS-applicable filter) or the live LIMSMaster scan (filtered path).
		-- Grand-total (0,0) sentinel rows are already present in #LisOut.
		SELECT RowCode, Description, ESYear, ESMonth, MetricValue
		FROM #LisOut
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

	DROP TABLE IF EXISTS #LisOut;
	DROP TABLE IF EXISTS #LisFiltered;
	DROP TABLE IF EXISTS #Lis;
	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #LisBilledCount;
END;
GO

PRINT '17_Elixir_ExecutiveSummary_Read.sql completed.';
GO
