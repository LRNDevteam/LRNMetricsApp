-- ============================================================
-- Certus – Executive Summary Read SP
-- File : 17_Certus_ExecutiveSummary_Read.sql
-- DB   : Certus_LRN
--
-- usp_GetCert_ExecutiveSummary(@YearFrom,@YearTo,@MonthFrom,@MonthTo,...)
--   @HasFilter = 1 if any date/dimension parameter is set.
--
-- No-filter path (fast read): UNION ALL of the 4 aggregate tables
-- (Certus_ES_LIS, Certus_ES_PMS, Certus_ES_Cash, Certus_ES_Avg),
-- each row already bucketed by (ESYear, ESMonth) with a (0,0) grand-total
-- sentinel, returned as (RowCode, Category, Description, BillYear, BillMonth,
-- MetricValue).
--
-- Filtered path (live re-aggregation): re-derives ALL RowCodes from
-- dbo.LIMSMaster (LIS) and dbo.ClaimLevelData (PMS/Cash/Avg), bucketed by
-- (Year, Month) of the active date column (DateofService/ReqCollectDate in
-- DOS mode, FirstBilledDate/BilledDate in Billed mode) PLUS a (0,0)
-- grand-total row per RowCode - same convention as the no-filter aggregate
-- tables.
-- PREVIOUSLY this path collapsed everything straight into a single (0,0)
-- row with no monthly breakdown, so filtering a wide DOS range (e.g.
-- Jan-Jun) showed one lump total instead of a Jan/Feb/.../Jun split. Fixed
-- by pre-aggregating #Lis/#Base per (Year, Month) - mirrors the pattern
-- already used in Cove\17_Cove_ExecutiveSummary_Read.sql.
--
-- ── Date-mode switch (ported from Cove\17_Cove_ExecutiveSummary_Read.sql) ──
-- DateofService and FirstBilledDate are mutually exclusive filter modes:
--   @UseBilledDate = 0 (default / DOS mode) - both #Lis and #Base bucket by
--     and require their DateofService-equivalent column to be non-null,
--     filtered by @DosFrom/@DosTo (+ @YearFrom/@YearTo/@MonthFrom/@MonthTo
--     on the LIS side).
--   @UseBilledDate = 1 (only @BilledFrom/@BilledTo set, no @DosFrom/@DosTo) -
--     #Base and #Lis bucket by and require FirstBilledDate non-null,
--     filtered by @BilledFrom/@BilledTo instead of DateofService.
--
-- ── Column mapping (per lab spec - do not use Cove's own column names) ──────
-- Pass the following to dbo.LIMSMaster (LIS Breakdown):
--   Panel                 -> PanelName / Panelname / PanelType / PanelCategory / ... (dynamic, existing candidates)
--   DateofService         -> ReqCollectDate (priority 0)
--   FirstBilledDate       -> BilledDate (priority 0)
--   ClinicName            -> ReqLocationName (priority 0)
--   ReferringProviderName -> DoctorFullName (priority 0)
-- Pass the following to dbo.ClaimLevelData (PMS/Cash/Avg Breakdown):
--   Panel                 -> Panelname   (was incorrectly filtering on PanelType, a column
--                                         that doesn't exist on ClaimLevelData for Certus)
--   DateofService         -> DateofService
--   FirstBilledDate       -> FirstBilledDate
--   ClinicName            -> ClinicName  (already correct)
--   ReferringProviderName -> ReferringProvider (already correct)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCert_ExecutiveSummary
(
    @YearFrom     INT           = 0,
    @YearTo       INT           = 0,
    @MonthFrom    INT           = 0,
    @MonthTo      INT           = 0,
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

    DECLARE @HasFilter BIT = CASE
        WHEN ISNULL(@YearFrom,  0) <> 0 THEN 1
        WHEN ISNULL(@YearTo,    0) <> 0 THEN 1
        WHEN ISNULL(@MonthFrom, 0) <> 0 THEN 1
        WHEN ISNULL(@MonthTo,   0) <> 0 THEN 1
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

    -- DateofService vs FirstBilledDate are mutually exclusive (see header note).
    DECLARE @UseBilledDate BIT = CASE
        WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
         AND  @DosFrom IS NULL AND @DosTo IS NULL
        THEN 1 ELSE 0 END;

    -- ════════════════════════════════════════════════════════════════════
    --  NO FILTER  -  fast read from the 4 aggregate tables
    -- ════════════════════════════════════════════════════════════════════
    IF @HasFilter = 0
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
        FROM
        (
            SELECT RoleID AS RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue,
                   1 AS CatOrder, Id AS SortId
            FROM dbo.Certus_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
                   2, Id
            FROM dbo.Certus_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   3, Id
            FROM dbo.Certus_ES_Cash

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   4, Id
            FROM dbo.Certus_ES_Avg
        ) x
        ORDER BY BillYear, BillMonth, CatOrder, SortId;

        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  FILTERED  -  live re-aggregation, bucketed by (Year, Month) + (0,0) grand total
    -- ════════════════════════════════════════════════════════════════════

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

    -- ── LIS: build #Lis from dbo.LIMSMaster ─────────────────────────────────
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession     NVARCHAR(100) NOT NULL,
        BillTo        NVARCHAR(200) NOT NULL,
        BillingStatus NVARCHAR(200) NOT NULL,
        FinalStatus   NVARCHAR(200) NOT NULL,
        PanelName     NVARCHAR(200) NOT NULL,
        LISYear       INT           NOT NULL DEFAULT 0,
        LISMonth      INT           NOT NULL DEFAULT 0
    );

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        DECLARE @AccCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('AccessionNumber','Accession','AccessionNo')
            ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

        -- DateofService -> ReqCollectDate (priority 0) for Certus
        DECLARE @DateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ReqCollectDate','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'ReqCollectDate' THEN 0 WHEN 'RequestCollectDate' THEN 1
                WHEN 'DateOfCollection' THEN 2 WHEN 'DateofService' THEN 3
                WHEN 'CollectionDate' THEN 4 WHEN 'ServiceDate' THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

        -- FirstBilledDate -> BilledDate (priority 0) for Certus
        DECLARE @BilledDateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BilledDate','FirstBilledDate','BilledOn','BillDate','FirstBillDate')
            ORDER BY CASE name
                WHEN 'BilledDate'    THEN 0 WHEN 'FirstBilledDate' THEN 1
                WHEN 'BilledOn'      THEN 2 WHEN 'BillDate'        THEN 3
                WHEN 'FirstBillDate' THEN 4 ELSE 5 END);

        DECLARE @BillToCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillTo','BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
            ORDER BY CASE name WHEN 'BillTo' THEN 0 WHEN 'BillCategory' THEN 1 WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3 WHEN 'BilledorNot' THEN 4 WHEN 'BillStatus' THEN 5 ELSE 6 END);

        DECLARE @BillingStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillingStatus','NewStatus','Status','BillStatus')
            ORDER BY CASE name WHEN 'BillingStatus' THEN 0 WHEN 'NewStatus' THEN 1 WHEN 'Status' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

        DECLARE @FinalStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('FinalStatus','SubStatus','Sub_Status','ClientStatus')
            ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'SubStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);

        -- Panel -> PanelName (priority 0) for Certus
        DECLARE @PanelNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelName','Panelname','PanelType','PanelCategory','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
            ORDER BY CASE name
                WHEN 'PanelName'       THEN 0 WHEN 'Panelname'       THEN 1 WHEN 'PanelType'       THEN 2
                WHEN 'PanelCategory'   THEN 3 WHEN 'TestPanel'        THEN 4 WHEN 'TestPanelName'   THEN 5
                WHEN 'Panel'           THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'        THEN 8
                WHEN 'Test_Panel'      THEN 9 WHEN 'TestPanelname'    THEN 10 ELSE 11 END);

        -- ClinicName -> ReqLocationName (priority 0) for Certus
        DECLARE @ClinicCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ReqLocationName','FacilityName','Facility','ClinicName','Clinic')
            ORDER BY CASE name
                WHEN 'ReqLocationName' THEN 0 WHEN 'FacilityName' THEN 1
                WHEN 'Facility'        THEN 2 WHEN 'ClinicName'   THEN 3 WHEN 'Clinic' THEN 4 ELSE 5 END);

        -- ReferringProviderName -> DoctorFullName (priority 0) for Certus
        DECLARE @ProviderCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('DoctorFullName','PhysicianName','Physician','ReferringPhysician','ReferringProvider','Provider')
            ORDER BY CASE name
                WHEN 'DoctorFullName'     THEN 0 WHEN 'PhysicianName'      THEN 1
                WHEN 'Physician'          THEN 2 WHEN 'ReferringPhysician' THEN 3
                WHEN 'ReferringProvider'  THEN 4 WHEN 'Provider'           THEN 5 ELSE 6 END);

        IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @BillToCol IS NOT NULL AND @BillingStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        BEGIN
            DECLARE @PanelExpr NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol + N']), '''')))'
                ELSE N'''''' END;

            -- Period bucket: BilledDate mode uses @BilledDateCol, DOS mode (default)
            -- uses @DateCol - mirrors #Base's ESYear/ESMonth switch below.
            DECLARE @LisPeriodExpr NVARCHAR(300) = CASE WHEN @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
                THEN N'TRY_CAST([' + @BilledDateCol + N'] AS DATE)'
                ELSE N'TRY_CAST([' + @DateCol + N'] AS DATE)' END;

            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (Accession, BillTo, BillingStatus, FinalStatus, PanelName, LISYear, LISMonth)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
                    ' + @PanelExpr + N',
                    ISNULL(YEAR(' + @LisPeriodExpr + N'), 0),
                    ISNULL(MONTH(' + @LisPeriodExpr + N'), 0)
                FROM dbo.LIMSMaster
                WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
                  AND (ISNULL(@iYearFrom,0)=0  OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iYearFrom)
                  AND (ISNULL(@iYearTo,0)=0    OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iYearTo)
                  AND (ISNULL(@iMonthFrom,0)=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iMonthFrom)
                  AND (ISNULL(@iMonthTo,0)=0   OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iMonthTo)
                  AND (@iDosFrom IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) >= @iDosFrom)
                  AND (@iDosTo   IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) <= @iDosTo)';

            -- FirstBilledDate range filter (BilledDate col), applied whenever set -
            -- independent of DOS mode/Billed mode (only one is populated from the UI
            -- at a time, per the "one date range at a time" rule enforced client-side).
            IF @BilledDateCol IS NOT NULL
                SET @LisSql += N'
                  AND (@iBilledFrom IS NULL OR TRY_CAST([' + @BilledDateCol + N'] AS DATE) >= @iBilledFrom)
                  AND (@iBilledTo   IS NULL OR TRY_CAST([' + @BilledDateCol + N'] AS DATE) <= @iBilledTo)';

            -- Panel filter: Panels -> PanelName
            IF @PanelNameCol IS NOT NULL
                SET @LisSql += N'
                  AND (@iHasPanelFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelNameCol + N']), ''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iPanels + '','') > 0)';

            -- Clinic filter: Clinics -> ReqLocationName
            IF @ClinicCol IS NOT NULL
                SET @LisSql += N'
                  AND (@iHasClinicFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol + N']), ''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iClinics + '','') > 0)';

            -- Provider filter: Providers -> DoctorFullName
            IF @ProviderCol IS NOT NULL
                SET @LisSql += N'
                  AND (@iHasProviderFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), ''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iProviders + '','') > 0)';

            SET @LisSql += N';';

            EXEC sp_executesql @LisSql,
                N'@iYearFrom INT, @iYearTo INT, @iMonthFrom INT, @iMonthTo INT,
                  @iDosFrom DATE, @iDosTo DATE, @iBilledFrom DATE, @iBilledTo DATE,
                  @iHasPanelFilter BIT, @iPanels NVARCHAR(MAX),
                  @iHasClinicFilter BIT, @iClinics NVARCHAR(MAX),
                  @iHasProviderFilter BIT, @iProviders NVARCHAR(MAX)',
                @iYearFrom=@YearFrom, @iYearTo=@YearTo, @iMonthFrom=@MonthFrom, @iMonthTo=@MonthTo,
                @iDosFrom=@DosFrom, @iDosTo=@DosTo, @iBilledFrom=@BilledFrom, @iBilledTo=@BilledTo,
                @iHasPanelFilter=@HasPanelFilter, @iPanels=@Panels,
                @iHasClinicFilter=@HasClinicFilter, @iClinics=@Clinics,
                @iHasProviderFilter=@HasProviderFilter, @iProviders=@Providers;
        END
    END

    -- ── PMS/Cash/Avg: build #Base from dbo.ClaimLevelData ───────────────────
    -- Split into two mutually exclusive branches (DOS mode vs FirstBilledDate
    -- mode) so a Billed-date-only filter doesn't require DateofService to be
    -- populated. Each branch also stamps ESYear/ESMonth from its own active
    -- date column, so the final result can be grouped per month (not just a
    -- single collapsed total).
    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        AccessionNumber      NVARCHAR(100) NOT NULL,
        ClaimStatus          NVARCHAR(200) NOT NULL,
        ChargeAmount         DECIMAL(18,2) NOT NULL,
        InsurancePayment     DECIMAL(18,2) NOT NULL,
        PatientPayment       DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL,
        ESYear               INT           NOT NULL DEFAULT 0,
        ESMonth              INT           NOT NULL DEFAULT 0
    );

    IF @UseBilledDate = 0
    BEGIN
        INSERT INTO #Base (AccessionNumber, ClaimStatus, ChargeAmount, InsurancePayment, PatientPayment,
                           InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance,
                           ESYear, ESMonth)
        SELECT
            AccessionNumber,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
            ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0),
            ISNULL(YEAR (TRY_CAST(DateofService AS DATE)), 0),
            ISNULL(MONTH(TRY_CAST(DateofService AS DATE)), 0)
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
          AND (ISNULL(@YearFrom,0)=0  OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
          AND (ISNULL(@YearTo,0)=0    OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
          AND (ISNULL(@MonthFrom,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
          AND (ISNULL(@MonthTo,0)=0   OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
          AND (@DosFrom    IS NULL OR TRY_CAST(DateofService AS DATE) >= @DosFrom)
          AND (@DosTo      IS NULL OR TRY_CAST(DateofService AS DATE) <= @DosTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(Panelname,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels    + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics   + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps      + ',') COLLATE DATABASE_DEFAULT) > 0);
    END
    ELSE  -- @UseBilledDate = 1 : filter/bucket on FirstBilledDate instead of DateofService
    BEGIN
        INSERT INTO #Base (AccessionNumber, ClaimStatus, ChargeAmount, InsurancePayment, PatientPayment,
                           InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance,
                           ESYear, ESMonth)
        SELECT
            AccessionNumber,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
            ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0),
            ISNULL(YEAR (TRY_CAST(FirstBilledDate AS DATE)), 0),
            ISNULL(MONTH(TRY_CAST(FirstBilledDate AS DATE)), 0)
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
          AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
          AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(Panelname,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels    + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics   + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps      + ',') COLLATE DATABASE_DEFAULT) > 0);
    END

    -- ════════════════════════════════════════════════════════════════════
    --  Pre-aggregate #Lis and #Base per (Year, Month) + a (0,0) grand-total
    --  row, so every RowCode gets both a monthly breakdown and a total -
    --  same convention as the no-filter aggregate tables.
    -- ════════════════════════════════════════════════════════════════════
    DROP TABLE IF EXISTS #LisAgg;
    SELECT
        LISYear AS ESYear, LISMonth AS ESMonth,
        COUNT(DISTINCT Accession) AS cntA,
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' THEN Accession END) AS cntB,
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Billed' THEN Accession END) AS cntC,
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Not Billed' THEN Accession END) AS cntD,
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Not Billed' AND FinalStatus='Claim Entered in Daqbilling' THEN Accession END) AS cntD1,
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Not Billed' AND FinalStatus='Resulted yet to be billed' THEN Accession END) AS cntD2,
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Not Billed' AND FinalStatus='D/L Isomer' THEN Accession END) AS cntD3,
        COUNT(DISTINCT CASE WHEN BillTo <> 'Insurance Bill' THEN Accession END) AS cntE,
        COUNT(DISTINCT CASE WHEN BillTo='Duplicate' THEN Accession END) AS cntE1,
        COUNT(DISTINCT CASE WHEN BillTo='Client Bill' THEN Accession END) AS cntE2,
        COUNT(DISTINCT CASE WHEN BillTo='Yet to be Validated' THEN Accession END) AS cntE3,
        COUNT(DISTINCT CASE WHEN BillTo='Selfpay' THEN Accession END) AS cntE4,
        COUNT(DISTINCT CASE WHEN BillTo='Rejection' THEN Accession END) AS cntE5,
        COUNT(DISTINCT CASE WHEN BillTo='System Test' THEN Accession END) AS cntE6,
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Billed' THEN Accession END) AS cntBilled
    INTO #LisAgg
    FROM #Lis
    GROUP BY LISYear, LISMonth
    UNION ALL
    SELECT
        0, 0,
        COUNT(DISTINCT Accession),
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Billed' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Not Billed' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Not Billed' AND FinalStatus='Claim Entered in Daqbilling' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Not Billed' AND FinalStatus='Resulted yet to be billed' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Not Billed' AND FinalStatus='D/L Isomer' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo <> 'Insurance Bill' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Duplicate' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Client Bill' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Yet to be Validated' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Selfpay' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Rejection' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='System Test' THEN Accession END),
        COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' AND BillingStatus='Billed' THEN Accession END)
    FROM #Lis;

    DROP TABLE IF EXISTS #LisPanelAgg;
    SELECT LISYear AS ESYear, LISMonth AS ESMonth, PanelName,
           COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' THEN Accession END) AS cnt
    INTO #LisPanelAgg
    FROM #Lis
    WHERE NULLIF(PanelName, '') IS NOT NULL
    GROUP BY LISYear, LISMonth, PanelName
    UNION ALL
    SELECT 0, 0, PanelName,
           COUNT(DISTINCT CASE WHEN BillTo='Insurance Bill' THEN Accession END)
    FROM #Lis
    WHERE NULLIF(PanelName, '') IS NOT NULL
    GROUP BY PanelName;

    DROP TABLE IF EXISTS #BaseAgg;
    SELECT
        ESYear, ESMonth,
        COUNT(DISTINCT CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END) AS cntF,
        COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END) AS cntG,
        COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END) AS cntI,
        COUNT(DISTINCT CASE WHEN ClaimStatus='Patient Responsibility' THEN AccessionNumber END) AS cntJ,
        COUNT(DISTINCT CASE WHEN ClaimStatus='Patient Payment' THEN AccessionNumber END) AS cntK,
        COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Adjusted' THEN AccessionNumber END) AS cntL,
        COUNT(DISTINCT CASE WHEN ClaimStatus='Test Patient' THEN AccessionNumber END) AS cntM,
        COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Adjusted' THEN AccessionNumber END) AS cntN,
        COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Paid' THEN AccessionNumber END) AS cntO,
        COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Denied','No Response','Partially Denied') THEN AccessionNumber END) AS cntP,
        COUNT(DISTINCT CASE WHEN ClaimStatus='Denied' THEN AccessionNumber END) AS cntP1,
        COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Denied' THEN AccessionNumber END) AS cntP2,
        COUNT(DISTINCT CASE WHEN ClaimStatus='No Response' THEN AccessionNumber END) AS cntP3,
        SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN ChargeAmount ELSE 0 END) AS sumQ,
        SUM(CASE WHEN ClaimStatus IN ('Unbilled','Unbilled - PB') THEN ChargeAmount ELSE 0 END) AS sumR,
        SUM(CASE WHEN ClaimStatus='Fully Paid' THEN InsurancePayment ELSE 0 END) AS sumS,
        SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN PatientBalance ELSE 0 END) AS sumT,
        SUM(InsuranceAdjustments + PatientAdjustments) AS sumU,
        SUM(CASE WHEN PatientPayment > 0 THEN PatientPayment ELSE 0 END) AS sumV,
        SUM(CASE WHEN ClaimStatus='Partially Paid' THEN InsurancePayment ELSE 0 END) AS sumW,
        SUM(InsuranceBalance) AS sumX,
        SUM(CASE WHEN ClaimStatus='Denied' THEN InsuranceBalance ELSE 0 END) AS sumX1,
        SUM(CASE WHEN ClaimStatus='Partially Denied' THEN InsuranceBalance ELSE 0 END) AS sumX2,
        SUM(CASE WHEN ClaimStatus='No Response' THEN InsuranceBalance ELSE 0 END) AS sumX3,
        SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN InsurancePayment + PatientPayment ELSE 0 END) AS sumYNum,
        SUM(CASE WHEN ClaimStatus='Fully Paid' THEN InsurancePayment + PatientPayment ELSE 0 END) AS sumZNum
    INTO #BaseAgg
    FROM #Base
    GROUP BY ESYear, ESMonth
    UNION ALL
    SELECT
        0, 0,
        COUNT(DISTINCT CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='Patient Responsibility' THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='Patient Payment' THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Adjusted' THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='Test Patient' THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Adjusted' THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Paid' THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Denied','No Response','Partially Denied') THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='Denied' THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Denied' THEN AccessionNumber END),
        COUNT(DISTINCT CASE WHEN ClaimStatus='No Response' THEN AccessionNumber END),
        SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN ChargeAmount ELSE 0 END),
        SUM(CASE WHEN ClaimStatus IN ('Unbilled','Unbilled - PB') THEN ChargeAmount ELSE 0 END),
        SUM(CASE WHEN ClaimStatus='Fully Paid' THEN InsurancePayment ELSE 0 END),
        SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN PatientBalance ELSE 0 END),
        SUM(InsuranceAdjustments + PatientAdjustments),
        SUM(CASE WHEN PatientPayment > 0 THEN PatientPayment ELSE 0 END),
        SUM(CASE WHEN ClaimStatus='Partially Paid' THEN InsurancePayment ELSE 0 END),
        SUM(InsuranceBalance),
        SUM(CASE WHEN ClaimStatus='Denied' THEN InsuranceBalance ELSE 0 END),
        SUM(CASE WHEN ClaimStatus='Partially Denied' THEN InsuranceBalance ELSE 0 END),
        SUM(CASE WHEN ClaimStatus='No Response' THEN InsuranceBalance ELSE 0 END),
        SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN InsurancePayment + PatientPayment ELSE 0 END),
        SUM(CASE WHEN ClaimStatus='Fully Paid' THEN InsurancePayment + PatientPayment ELSE 0 END)
    FROM #Base;

    -- ────────────────────────────────────────────────────────────────────
    --  Assemble final rows, one section at a time, each bucketed by
    --  (ESYear, ESMonth) with a (0,0) grand-total row already included
    --  in #LisAgg / #LisPanelAgg / #BaseAgg above.
    -- ────────────────────────────────────────────────────────────────────
    ;WITH Lis AS
    (
        SELECT ESYear, ESMonth, v.RowCode, v.Description, v.MetricValue
        FROM #LisAgg
        CROSS APPLY (VALUES
            ('A',   'Total Samples',                  CAST(cntA  AS DECIMAL(18,2))),
            ('B',   'Billable Samples',                CAST(cntB  AS DECIMAL(18,2))),
            ('C',   '  Billed',                        CAST(cntC  AS DECIMAL(18,2))),
            ('D',   '  Unbilled',                      CAST(cntD  AS DECIMAL(18,2))),
            ('D.1', '    Claim Entered in Daqbilling', CAST(cntD1 AS DECIMAL(18,2))),
            ('D.2', '    Resulted yet to be billed',   CAST(cntD2 AS DECIMAL(18,2))),
            ('D.3', '    D/L Isomer',                  CAST(cntD3 AS DECIMAL(18,2))),
            ('E',   'Other Samples',                   CAST(cntE  AS DECIMAL(18,2))),
            ('E.1', '  Duplicate',                     CAST(cntE1 AS DECIMAL(18,2))),
            ('E.2', '  Client Bill',                   CAST(cntE2 AS DECIMAL(18,2))),
            ('E.3', '  Yet to be Validated',            CAST(cntE3 AS DECIMAL(18,2))),
            ('E.4', '  Selfpay',                        CAST(cntE4 AS DECIMAL(18,2))),
            ('E.5', '  Rejection',                      CAST(cntE5 AS DECIMAL(18,2))),
            ('E.6', '  System Test',                    CAST(cntE6 AS DECIMAL(18,2)))
        ) v(RowCode, Description, MetricValue)
    ),
    LisPanels AS
    (
        SELECT ESYear, ESMonth, 'B1.' + PanelName AS RowCode, '  ' + PanelName AS Description,
               CAST(cnt AS DECIMAL(18,2)) AS MetricValue
        FROM #LisPanelAgg
    ),
    PMS AS
    (
        SELECT ESYear, ESMonth, v.RowCode, v.Description, v.MetricValue
        FROM #BaseAgg
        CROSS APPLY (VALUES
            ('F',   'No. of Billed Claims',                  CAST(cntF  AS DECIMAL(18,2))),
            ('G',   'Unbilled Claims',                        CAST(cntG  AS DECIMAL(18,2))),
            ('I',   'No. of Fully Paid Claims',                CAST(cntI  AS DECIMAL(18,2))),
            ('J',   'No. of Patient Responsibility Claims',    CAST(cntJ  AS DECIMAL(18,2))),
            ('K',   'No. of Patient Paid Claims',               CAST(cntK  AS DECIMAL(18,2))),
            ('L',   'No. of Adjusted/Written Off Claims',       CAST(cntL  AS DECIMAL(18,2))),
            ('M',   'Test Patients',                            CAST(cntM  AS DECIMAL(18,2))),
            ('N',   'No. of Partially Adjusted Claims',         CAST(cntN  AS DECIMAL(18,2))),
            ('O',   'No. of Partially Paid Claims',             CAST(cntO  AS DECIMAL(18,2))),
            ('P',   'No. of Insurance Balance Claims',          CAST(cntP  AS DECIMAL(18,2))),
            ('P.1', '  No. of Fully Denied Claims',             CAST(cntP1 AS DECIMAL(18,2))),
            ('P.2', '  No. of Partially Denied Claims',         CAST(cntP2 AS DECIMAL(18,2))),
            ('P.3', '  No. of No Response from Payor Claims',   CAST(cntP3 AS DECIMAL(18,2)))
        ) v(RowCode, Description, MetricValue)
        UNION ALL
        -- H  Billed Mismatches - Other Samples Billed
        -- (PMS "billed" count minus LIS "Insurance Bill & Billed" count, matched
        -- by period; FULL OUTER JOIN since #Base and #Lis are independent scans
        -- and may not have identical (Year,Month) sets.)
        SELECT COALESCE(b.ESYear, l.ESYear), COALESCE(b.ESMonth, l.ESMonth),
               'H', 'Billed Mismatches - Other Samples Billed',
               CAST(ISNULL(b.cntF, 0) AS DECIMAL(18,2)) - CAST(ISNULL(l.cntBilled, 0) AS DECIMAL(18,2))
        FROM #BaseAgg b
        FULL OUTER JOIN #LisAgg l ON l.ESYear = b.ESYear AND l.ESMonth = b.ESMonth
    ),
    Cash AS
    (
        SELECT ESYear, ESMonth, v.RowCode, v.Description, v.MetricValue
        FROM #BaseAgg
        CROSS APPLY (VALUES
            ('Q',   'Total Billed ($)',           sumQ),
            ('R',   'Unbilled Claims ($)',         sumR),
            ('S',   'Insurance Payment ($)',       sumS),
            ('T',   'Patient Responsibility ($)',  sumT),
            ('U',   'Adjustments / Write Off ($)', sumU),
            ('V',   'Patient Paid ($)',             sumV),
            ('W',   'Partially Paid ($)',           sumW),
            ('X',   'Insurance Balance ($)',        sumX),
            ('X.1', '  Denials',                    sumX1),
            ('X.2', '  Partially Denied',           sumX2),
            ('X.3', '  No Response from Payor',     sumX3)
        ) v(RowCode, Description, MetricValue)
    ),
    AvgRows AS
    (
        SELECT ESYear, ESMonth, v.RowCode, v.Description, v.MetricValue
        FROM #BaseAgg
        CROSS APPLY (VALUES
            ('Y',  'Average Payment ($) - Total Pay/Billed Claims',      CASE WHEN cntF > 0 THEN sumYNum / cntF ELSE 0 END),
            ('Z',  'Average Payment ($) - Total Pay/Paid Claims',        CASE WHEN cntI > 0 THEN sumZNum / cntI ELSE 0 END),
            ('AA', 'Average Payment ($) - Total Pay/Adjudicated Claims', CASE WHEN cntF > 0 THEN sumYNum / cntF ELSE 0 END)
        ) v(RowCode, Description, MetricValue)
    )
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM
    (
        SELECT RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth, MetricValue, 1 AS CatOrder FROM Lis
        UNION ALL
        SELECT RowCode, 'LIS', Description, ESYear, ESMonth, MetricValue, 1 FROM LisPanels
        UNION ALL
        SELECT RowCode, 'PMS',  Description, ESYear, ESMonth, MetricValue, 2 FROM PMS
        UNION ALL
        SELECT RowCode, 'Cash', Description, ESYear, ESMonth, MetricValue, 3 FROM Cash
        UNION ALL
        SELECT RowCode, 'Avg',  Description, ESYear, ESMonth, MetricValue, 4 FROM AvgRows
    ) result
    ORDER BY BillYear, BillMonth, CatOrder, RowCode;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #LisAgg;
    DROP TABLE IF EXISTS #LisPanelAgg;
    DROP TABLE IF EXISTS #BaseAgg;
END;
GO

PRINT '17_Certus_ExecutiveSummary_Read.sql completed.';
GO
