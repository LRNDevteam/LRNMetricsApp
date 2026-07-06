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
--   No filter (all NULL)           → read straight from the 5 aggregate tables (instant).
--   Date / Rep filter only         → re-aggregate PMS+Cash+Avg live from ClaimLevelData;
--                                    LIS still served from aggregate tables (period-filtered).
--   Panel / Clinic / Provider filter → additionally re-aggregate LIS live from LIMSMaster
--                                    via #LisBase (dimension-filtered, date-independent).
--                                    SalesRep is not available for LIS; Date is ignored.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRT_ExecutiveSummary
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
			FROM   dbo.RT_ES_LIS

			UNION ALL

			-- LIS panel sub-rows
			SELECT RoleID, 'LIS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.RT_ES_LIS_Panel

			UNION ALL

			-- PMS
			SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.RT_ES_PMS

			UNION ALL

			-- Cash (uses dollar amount)
			SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.RT_ES_Cash

			UNION ALL

			-- Avg (uses dollar amount)
			SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.RT_ES_Avg
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

	-- Date mode: DOS vs FirstBilledDate are mutually exclusive in the UI (same
	-- convention as Cove/Elixir). @UseBilledDate = 1 → FirstBilledDate filter is
	-- active (@BilledFrom/@BilledTo set, @DosFrom/@DosTo NULL) — LIS period basis
	-- switches from RequestCollectDate to AMDLBD. @UseBilledDate = 0 → DOS mode
	-- (or no date filter) — LIS period basis stays RequestCollectDate.
	DECLARE @UseBilledDate BIT = CASE
		WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
		 AND  @DosFrom IS NULL AND @DosTo IS NULL
		THEN 1 ELSE 0 END;

	-- ── LIS dimension filter via LIMSMaster ─────────────────────────────────────
	--    When Panel / Clinic / Provider filter is active, OR a DOS / FirstBilledDate
	--    range is set, re-aggregate LIS rows live from dbo.LIMSMaster (filtered)
	--    instead of the pre-built aggregate tables.
	--    DateofService   → LIMSMaster.RequestCollectDate
	--    FirstBilledDate → LIMSMaster.AMDLBD — mixed content: real dates, the
	--      literal text 'Not Entered in AMD', and blanks. TRY_CAST(... AS DATE)
	--      returns NULL for the latter two, so those rows are excluded from
	--      billed-date filtering/period bucketing automatically — no special-
	--      casing of the text value is needed.
	--    SalesRep is not available for RisingTides LIS — always skipped.
	-- ────────────────────────────────────────────────────────────────────────────
	DECLARE @HasLisFilter BIT = CASE
		WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
		  OR @DosFrom IS NOT NULL OR @DosTo IS NOT NULL
		  OR @UseBilledDate = 1
		THEN 1 ELSE 0 END;

	-- #LisBase: mirrors #Lis2 in usp_RefreshRT_ExecutiveSummary_LIS_Alt (file 29).
	-- Populated from LIMSMaster when @HasLisFilter = 1; empty otherwise.
	DROP TABLE IF EXISTS #LisBase;
	CREATE TABLE #LisBase
	(
		Accession     NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		ESYear        INT           NOT NULL,
		ESMonth       INT           NOT NULL,
		ResultedNot   NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
		ClientStatus  NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		BilledNot     NVARCHAR(20)  COLLATE DATABASE_DEFAULT NOT NULL,
		BillingStatus NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		ClaimStatus   NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		OrderStatus   NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		PaymentMethod NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		SampleStatus  NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		PanelName     NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL
	);

	DECLARE @LisMasterFiltered BIT = 0;   -- 1 when #LisBase was populated from LIMSMaster

	IF @HasLisFilter = 1 AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
	BEGIN
		-- Auto-detect dimension columns on dbo.LIMSMaster.
		-- Panel column: same candidate list / priority as usp_RefreshRT_ExecutiveSummary_LIS_Alt.
		DECLARE @LisPanelCatCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName',
			               'Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
			ORDER BY CASE name
				WHEN 'PanelCategory'   THEN 0 WHEN 'PanelName'      THEN 1 WHEN 'Panelname'      THEN 2
				WHEN 'TestPanelName'   THEN 3 WHEN 'TestPanelname'  THEN 4 WHEN 'TestPanel'      THEN 5
				WHEN 'Panel'           THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'      THEN 8 ELSE 9 END);

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
				WHEN 'Provider'           THEN 0 WHEN 'PhysicianName'     THEN 1
				WHEN 'ProviderName'       THEN 2 WHEN 'ReferringProvider' THEN 3
				WHEN 'ReferringPhysician' THEN 4 ELSE 5 END);

		-- FirstBilledDate: RisingTides' LIMSMaster billed-date column is AMDLBD
		-- (fixed name, confirmed present) — mixed date/text/blank content, handled
		-- via TRY_CAST at point of use (see @LisPeriodExpr below).
		DECLARE @LisBilledDateCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'AMDLBD');

		-- Only proceed when each active filter dimension has a matching column.
		IF (@HasPanelFilter    = 0 OR @LisPanelCatCol  IS NOT NULL)
		   AND (@HasClinicFilter   = 0 OR @LisFacilityCol  IS NOT NULL)
		   AND (@HasProviderFilter = 0 OR @LisProviderCol  IS NOT NULL)
		BEGIN
			DECLARE @LisPanelExpr NVARCHAR(400) = ISNULL(
				'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisPanelCatCol + ']), '''')))', '''''');

			-- LIS period basis:
			--   DOS mode (default)   → TRY_CAST(RequestCollectDate AS DATE)
			--   FirstBilledDate mode → TRY_CAST([AMDLBD] AS DATE) — TRY_CAST returns NULL
			--     for the non-date content ('Not Entered in AMD' text, blanks), and the
			--     WHERE clause below requires the period expression to be NOT NULL, so
			--     those rows are naturally excluded rather than mis-parsed.
			DECLARE @LisPeriodExpr NVARCHAR(200) =
				CASE WHEN @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
					 THEN N'TRY_CAST([' + @LisBilledDateCol + N'] AS DATE)'
					 ELSE N'TRY_CAST(RequestCollectDate AS DATE)' END;

			-- Build base SELECT from LIMSMaster.
			DECLARE @LisBaseSql NVARCHAR(MAX) = N'
			INSERT INTO #LisBase
			       (Accession, ESYear, ESMonth, ResultedNot, ClientStatus, BilledNot,
			        BillingStatus, ClaimStatus, OrderStatus, PaymentMethod, SampleStatus, PanelName)
			SELECT
			    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), Accession), ''''))),
			    YEAR (' + @LisPeriodExpr + N'),
			    MONTH(' + @LisPeriodExpr + N'),
			    LTRIM(RTRIM(ISNULL(RessultedStatus, ''''))),
			    LTRIM(RTRIM(ISNULL(ClientStatus,    ''''))),
			    CASE WHEN LTRIM(RTRIM(ISNULL(BillingStatus, ''''))) = ''Billed'' THEN ''Billed'' ELSE ''Unbilled'' END,
			    LTRIM(RTRIM(ISNULL(BillingStatus,   ''''))),
			    LTRIM(RTRIM(ISNULL(ClaimStatus,     ''''))),
			    LTRIM(RTRIM(ISNULL(OrderStatus,     ''''))),
			    LTRIM(RTRIM(ISNULL(PaymentMethod,   ''''))),
			    LTRIM(RTRIM(ISNULL(SampleStatus,    ''''))),
			    ' + @LisPanelExpr + N'
			FROM dbo.LIMSMaster
			WHERE ' + @LisPeriodExpr + N' IS NOT NULL
			  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '''') IS NOT NULL';

			-- Date predicates: DOS mode filters/bounds on RequestCollectDate;
			-- FirstBilledDate mode filters/bounds on AMDLBD (TRY_CAST — invalid/blank
			-- values already excluded by the period-basis WHERE clause above).
			IF @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
				SET @LisBaseSql += N'
			  AND (@iBilledFrom IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) >= @iBilledFrom)
			  AND (@iBilledTo   IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) <= @iBilledTo)';
			ELSE
				SET @LisBaseSql += N'
			  AND (@iDosFrom IS NULL OR TRY_CAST(RequestCollectDate AS DATE) >= @iDosFrom)
			  AND (@iDosTo   IS NULL OR TRY_CAST(RequestCollectDate AS DATE) <= @iDosTo)';

			-- Append dimension predicates (COLLATE DATABASE_DEFAULT prevents collation conflicts).
			IF @HasPanelFilter = 1 AND @LisPanelCatCol IS NOT NULL
				SET @LisBaseSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisPanelCatCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iPanels + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasClinicFilter = 1 AND @LisFacilityCol IS NOT NULL
				SET @LisBaseSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisFacilityCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iClinics + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasProviderFilter = 1 AND @LisProviderCol IS NOT NULL
				SET @LisBaseSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisProviderCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iProviders + '','') COLLATE DATABASE_DEFAULT) > 0';

			SET @LisBaseSql += N';';

			EXEC sp_executesql @LisBaseSql,
				N'@iPanels NVARCHAR(MAX), @iClinics NVARCHAR(MAX), @iProviders NVARCHAR(MAX),
				  @iDosFrom DATE, @iDosTo DATE, @iBilledFrom DATE, @iBilledTo DATE',
				@iPanels = @Panels, @iClinics = @Clinics, @iProviders = @Providers,
				@iDosFrom = @DosFrom, @iDosTo = @DosTo, @iBilledFrom = @BilledFrom, @iBilledTo = @BilledTo;

			SET @LisMasterFiltered = 1;
		END
	END

	-- #LisPeriods: distinct (ESYear,ESMonth) from filtered LIMSMaster + (0,0) sentinel.
	-- Only meaningful when @LisMasterFiltered = 1; left empty otherwise.
	DROP TABLE IF EXISTS #LisPeriods;
	CREATE TABLE #LisPeriods (ESYear INT NOT NULL, ESMonth INT NOT NULL);

	-- #LisPanels: distinct panel names for L_A.<PanelName> sub-rows.
	DROP TABLE IF EXISTS #LisPanels;
	CREATE TABLE #LisPanels (PanelName NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);

	IF @LisMasterFiltered = 1
	BEGIN
		INSERT INTO #LisPeriods (ESYear, ESMonth)
		SELECT DISTINCT ESYear, ESMonth FROM #LisBase
		UNION ALL SELECT 0, 0;

		INSERT INTO #LisPanels (PanelName)
		SELECT DISTINCT PanelName FROM #LisBase WHERE ResultedNot = 'Resulted' AND PanelName <> '';
	END

	-- #LisOut: final LIS rows (RowCode / Description / period / MetricValue).
	-- Populated either from live #LisBase aggregation (filtered) or aggregate tables (unfiltered).
	DROP TABLE IF EXISTS #LisOut;
	CREATE TABLE #LisOut
	(
		RowCode     NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,  -- widened: panel sub-rows = 'L_A.' + PanelName (up to 300 chars)
		Description NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
		ESYear      INT           NOT NULL,
		ESMonth     INT           NOT NULL,
		MetricValue DECIMAL(18,2) NOT NULL
	);

	IF @LisMasterFiltered = 1
	BEGIN
		-- Live aggregation from #LisBase — mirrors the L_* row logic in
		-- usp_RefreshRT_ExecutiveSummary_LIS_Alt (file 29, the authoritative source).
		INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
		SELECT RowCode, Description, ESYear, ESMonth, CAST(SampleCount AS DECIMAL(18,2))
		FROM
		(
			-- L_0  Total Samples
			SELECT p.ESYear, p.ESMonth, 'L_0' AS RowCode, 'Total Samples' AS Description,
			       COUNT(DISTINCT l.Accession) AS SampleCount
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A  Billable Samples - Resulted
			SELECT p.ESYear, p.ESMonth, 'L_A', 'Billable Samples - Resulted',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A1  Billed to Insurance
			SELECT p.ESYear, p.ESMonth, 'L_A1', 'Billed to Insurance',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A1a  Billed to Insurance – Billed In AMD
			SELECT p.ESYear, p.ESMonth, 'L_A1a', '    Billed In AMD',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
			      AND l.BilledNot = 'Billed'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A2  Not Entered in AMD
			SELECT p.ESYear, p.ESMonth, 'L_A2', 'Not Entered in AMD',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
			      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
			      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A2a  Not Entered in AMD – Received
			SELECT p.ESYear, p.ESMonth, 'L_A2a', '    Received',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
			      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
			      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
			      AND l.SampleStatus = 'Received'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A2b  Not Entered in AMD – Billing Review Required (identical to L_A2a per spec)
			SELECT p.ESYear, p.ESMonth, 'L_A2b', '    Billing Review Required',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
			      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
			      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
			      AND l.SampleStatus = 'Received'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A3  Unbilled
			SELECT p.ESYear, p.ESMonth, 'L_A3', 'Unbilled',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Entered'
			      AND l.BilledNot = 'Unbilled'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A4  Client Bill
			SELECT p.ESYear, p.ESMonth, 'L_A4', 'Client Bill',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
			      AND l.ClaimStatus IN ('Billed','Not Entered in AMD')
			      AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A4a  Client Bill – Not Entered in AMD
			SELECT p.ESYear, p.ESMonth, 'L_A4a', '    Not Entered in AMD',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
			      AND l.ClaimStatus = 'Not Entered in AMD' AND l.BilledNot = 'Unbilled'
			      AND l.ClientStatus = 'Client Bill'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A4b  Client Bill – Billed
			SELECT p.ESYear, p.ESMonth, 'L_A4b', '    Billed',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
			      AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
			      AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A5  Self Pay
			SELECT p.ESYear, p.ESMonth, 'L_A5', 'Self Pay',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
			      AND l.ClientStatus = 'Self Pay'
			      AND l.BillingStatus IN ('Billed','Not Ready To Bill')
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A5a  Self Pay – Billed
			SELECT p.ESYear, p.ESMonth, 'L_A5a', '    Billed',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
			      AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
			      AND l.ClientStatus = 'Self Pay' AND l.BillingStatus IN ('Billed','Not Ready To Bill')
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A5b  Self Pay – Not Entered in AMD
			SELECT p.ESYear, p.ESMonth, 'L_A5b', '    Not Entered in AMD',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
			      AND l.ClaimStatus = 'Not Entered in AMD' AND l.BilledNot = 'Unbilled'
			      AND l.ClientStatus = 'Self Pay'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A5c  Self Pay – Entered
			SELECT p.ESYear, p.ESMonth, 'L_A5c', '    Entered',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
			      AND l.ClaimStatus = 'Entered' AND l.BilledNot = 'Unbilled'
			      AND l.ClientStatus = 'Self Pay'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A6  Test Entries
			SELECT p.ESYear, p.ESMonth, 'L_A6', 'Test Entries',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			      AND l.BilledNot = 'Unbilled' AND l.ClientStatus = 'Test Entries'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A6a  Test Entries – Not Entered in AMD (identical to L_A6 per spec)
			SELECT p.ESYear, p.ESMonth, 'L_A6a', '    Not Entered in AMD',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			      AND l.BilledNot = 'Unbilled' AND l.ClientStatus = 'Test Entries'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A7  Billing Status – No Bill
			SELECT p.ESYear, p.ESMonth, 'L_A7', 'Billing Status - No Bill',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A7a  Billing Status – No Bill – Rejected
			SELECT p.ESYear, p.ESMonth, 'L_A7a', '    Rejected',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
			      AND l.OrderStatus = 'Rejected'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A7b  Billing Status – No Bill – Completed
			SELECT p.ESYear, p.ESMonth, 'L_A7b', '    Completed',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
			      AND l.OrderStatus = 'Completed'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_A7c  Billing Status – No Bill – Recollect Required
			SELECT p.ESYear, p.ESMonth, 'L_A7c', '    Recollect Required',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
			      AND l.OrderStatus = 'Recollect Required'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_B  Not Resulted
			SELECT p.ESYear, p.ESMonth, 'L_B', 'Not Resulted',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Not Resulted'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_B1  Not Resulted – Not Entered in AMD
			SELECT p.ESYear, p.ESMonth, 'L_B1', 'Not Entered in AMD',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_B1a  Not Entered in AMD – Collected
			SELECT p.ESYear, p.ESMonth, 'L_B1a', '    Collected',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			      AND l.SampleStatus = 'Collected'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_B1b  Not Entered in AMD – Received (identical to L_B1a per spec)
			SELECT p.ESYear, p.ESMonth, 'L_B1b', '    Received',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			      AND l.SampleStatus = 'Collected'
			GROUP BY p.ESYear, p.ESMonth

			UNION ALL
			-- L_B2  Not Resulted – Rejected Sample
			SELECT p.ESYear, p.ESMonth, 'L_B2', 'Rejected Sample',
			       COUNT(DISTINCT l.Accession)
			FROM #LisPeriods p LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			      AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			      AND l.SampleStatus = 'Rejected'
			GROUP BY p.ESYear, p.ESMonth
		) lis_rows;

		-- L_A.<PanelName> sub-rows (panel-wise breakdown of "Billable Samples - Resulted").
		INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
		SELECT 'L_A.' + pn.PanelName, '    ' + pn.PanelName,
		       p.ESYear, p.ESMonth, CAST(COUNT(DISTINCT l.Accession) AS DECIMAL(18,2))
		FROM #LisPanels pn
		CROSS JOIN #LisPeriods p
		LEFT JOIN #LisBase l
		       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
		      AND l.ResultedNot = 'Resulted'
		      AND l.PanelName COLLATE DATABASE_DEFAULT = pn.PanelName COLLATE DATABASE_DEFAULT
		GROUP BY pn.PanelName, p.ESYear, p.ESMonth;
	END
	ELSE
	BEGIN
		-- No LIS dimension filter: serve from pre-built aggregate tables filtered by period.
		INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
		SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
		FROM dbo.RT_ES_LIS
		WHERE (ESYear=0 AND ESMonth=0)
		   OR ( (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
			AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
			AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
			AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo))

		UNION ALL
		SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
		FROM dbo.RT_ES_LIS_Panel
		WHERE (ESYear=0 AND ESMonth=0)
		   OR ( (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
			AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
			AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
			AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo));
	END

	DROP TABLE IF EXISTS #Base;
	CREATE TABLE #Base
	(
		VisitNumber          NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		ESYear               INT           NOT NULL,
		ESMonth              INT           NOT NULL,
		BilledUnbilled       NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
		ClaimStatus          NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		ChargeAmount         DECIMAL(18,2) NOT NULL,
		InsurancePayment     DECIMAL(18,2) NOT NULL,
		PatientPayment       DECIMAL(18,2) NOT NULL,
		InsuranceAdjustments DECIMAL(18,2) NOT NULL,
		PatientAdjustments   DECIMAL(18,2) NOT NULL,
		InsuranceBalance     DECIMAL(18,2) NOT NULL,
		PatientBalance       DECIMAL(18,2) NOT NULL
	);

	-- PMS/Cash/Avg period basis now follows the same DOS vs FirstBilledDate mode as
	-- LIS (@UseBilledDate, declared earlier). Previously ESYear/ESMonth were ALWAYS
	-- derived from DateofService even when filtering by FirstBilledDate — rows that
	-- matched the FirstBilledDate WHERE bound still got bucketed under their
	-- (unrelated) DOS year/month, so a Billed-mode filter could show prior-year
	-- columns under a "DATA BASED ON BILLED DATE" header. Fixed by branching the
	-- period expression (and the date WHERE bound) on @UseBilledDate, same as Cove/
	-- Elixir's #Base construction.
	IF @UseBilledDate = 0
	BEGIN
		INSERT INTO #Base (VisitNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
		                    ChargeAmount, InsurancePayment, PatientPayment,
		                    InsuranceAdjustments, PatientAdjustments,
		                    InsuranceBalance, PatientBalance)
		SELECT
			LTRIM(RTRIM(ISNULL(ClaimID, ''))),
			YEAR (TRY_CAST(DateofService AS DATE)),
			MONTH(TRY_CAST(DateofService AS DATE)),
			LTRIM(RTRIM(ISNULL(BilledUnbilled, ''))),
			LTRIM(RTRIM(ISNULL(ClaimStatus,    ''))),
			ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0)
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
		  AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
		  AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
		  AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
		  AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
		  AND (@DosFrom   IS NULL OR TRY_CAST(DateofService AS DATE) >= @DosFrom)
		  AND (@DosTo     IS NULL OR TRY_CAST(DateofService AS DATE) <= @DosTo)
		  AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(PanelName,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps + ',') COLLATE DATABASE_DEFAULT) > 0);
	END
	ELSE  -- @UseBilledDate = 1 : period + filter on FirstBilledDate
	BEGIN
		INSERT INTO #Base (VisitNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
		                    ChargeAmount, InsurancePayment, PatientPayment,
		                    InsuranceAdjustments, PatientAdjustments,
		                    InsuranceBalance, PatientBalance)
		SELECT
			LTRIM(RTRIM(ISNULL(ClaimID, ''))),
			YEAR (TRY_CAST(FirstBilledDate AS DATE)),
			MONTH(TRY_CAST(FirstBilledDate AS DATE)),
			LTRIM(RTRIM(ISNULL(BilledUnbilled, ''))),
			LTRIM(RTRIM(ISNULL(ClaimStatus,    ''))),
			ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0)
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
		  AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
		  AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
		  AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(PanelName,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps + ',') COLLATE DATABASE_DEFAULT) > 0)
		OPTION (RECOMPILE);
	END

	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	;WITH PMS AS
	(
		SELECT p.ESYear,p.ESMonth,'O' AS RowCode,'Billed - Includes all Claims Billed in AMD' AS Description,
			   COUNT(DISTINCT b.VisitNumber) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b
		  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		 AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'P','Billed Mismatches - Non Diagnose US Samples',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Unbilled'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'Q','Unbilled - Entered in AMD - Yet to be released to Payer',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Unbilled'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'R','Paid - Client',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.ClaimStatus='Client Paid'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'S','Fully Paid - Insurance Pay',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Paid'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'T','Fully Adjusted',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Complete W/O'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'U','Patient Responsibility',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Patient Responsibility'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'V','Partially Paid',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Paid'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'X','Patient Payment',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Patient Payment'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'W','Insurance Balance',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied')
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'W1','  Fully Denied',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Denied'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'W2','  No Response',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='No Response'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'W3','  Partially Denied',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Denied'
			GROUP BY p.ESYear,p.ESMonth
	),
	Cash AS
	(
		SELECT p.ESYear,p.ESMonth,'X' AS RowCode,'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount),0) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b
		  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		 AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'Y','Unbilled ($)',ISNULL(SUM(b.ChargeAmount),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Unbilled' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'Z','Insurance Payment (fully paid) ($)',ISNULL(SUM(b.InsurancePayment),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Paid' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AA','Partially Paid ($)',ISNULL(SUM(b.InsurancePayment),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Paid' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AB','Patient Payment ($)',ISNULL(SUM(b.PatientPayment),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AC','Fully Adjusted (Complete W/O) ($)',ISNULL(SUM(b.InsuranceAdjustments),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Complete W/O' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AD','Contractual Obligation W/O ($)',ISNULL(SUM(b.InsuranceAdjustments),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus <> 'Complete W/O' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AE','Patient Balance ($)',ISNULL(SUM(b.PatientBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AF','Patient WO ($)',ISNULL(SUM(b.PatientAdjustments),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AG','Insurance Balance ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied') GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AG1','  No Response ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='No Response' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AG2','  Fully Denied ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Denied' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AG3','  Partially Denied ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Denied' GROUP BY p.ESYear,p.ESMonth
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
														 'Partially Paid','Patient Payment','Fully Denied','Partially Denied')
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
		-- LIS rows — populated from #LisOut (either live #LisBase aggregation when
		-- a dimension filter is active, or pre-built aggregate tables otherwise).
		SELECT RowCode, 'LIS' AS Category, Description,
			   ESYear AS BillYear, ESMonth AS BillMonth, MetricValue
		FROM #LisOut

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
	DROP TABLE IF EXISTS #LisBase;
	DROP TABLE IF EXISTS #LisPeriods;
	DROP TABLE IF EXISTS #LisPanels;
	DROP TABLE IF EXISTS #LisOut;
END;
GO

PRINT '17_RisingTides_ExecutiveSummary_Read.sql completed.';
GO
