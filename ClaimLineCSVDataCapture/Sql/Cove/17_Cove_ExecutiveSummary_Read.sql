-- ============================================================
-- Cove – Executive Summary Read SP
-- File : 17_Cove_ExecutiveSummary_Read.sql
-- DB   : Cove_LRN
--
-- usp_GetCove_ExecutiveSummary
--
-- Parameters (all optional / default to "no filter"):
--   @YearFrom      INT  = 0        DEPRECATED — ignored (not in UI)
--   @YearTo        INT  = 0        DEPRECATED — ignored (not in UI)
--   @MonthFrom     INT  = 0        DEPRECATED — ignored (not in UI)
--   @MonthTo       INT  = 0        DEPRECATED — ignored (not in UI)
--   @DosFrom       DATE = NULL     Date-of-Service lower bound (exact date)
--   @DosTo         DATE = NULL     Date-of-Service upper bound
--   @ReceivedFrom  DATE = NULL     Samples-Received (LIMSMaster date) lower bound
--   @ReceivedTo    DATE = NULL     Samples-Received upper bound
--   @BilledFrom    DATE = NULL     First-Billed-Date lower bound
--   @BilledTo      DATE = NULL     First-Billed-Date upper bound
--   @Panels        NVARCHAR(MAX) = NULL  Comma-separated PanelName list (NULL = all)
--   @Clinics       NVARCHAR(MAX) = NULL  Comma-separated ClinicName list
--   @Providers     NVARCHAR(MAX) = NULL  Comma-separated ReferringProvider list
--   @Reps          NVARCHAR(MAX) = NULL  Comma-separated SalesRepname list
--
-- No-filter path (fast read): UNION ALL of the 4 aggregate tables
-- (Cove_ES_LIS, Cove_ES_PMS, Cove_ES_Cash, Cove_ES_Avg) — unchanged from v1.
-- Used when ALL parameters are at their "no filter" default values.
--
-- Filtered path (live re-aggregation): re-derives all RowCodes directly
-- from dbo.LIMSMaster (LIS section) and dbo.ClaimLevelData (PMS/Cash/Avg)
-- applying every active filter. Returns (Year=0, Month=0) sentinel rows
-- (a single "filtered total" bucket) — same as the grand-total convention.
--
-- No inline queries — all SQL in this SP, sp_executesql used only for
-- dynamic column name resolution on LIMSMaster (schema varies per env).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_ExecutiveSummary
(
    -- DEPRECATED — Year/Month filters are not exposed in the UI and are no
    -- longer applied. Retained only so existing callers that still pass them
    -- don't break; they have no effect on the result.
    @YearFrom     INT           = 0,
    @YearTo       INT           = 0,
    @MonthFrom    INT           = 0,
    @MonthTo      INT           = 0,
    -- New exact date-range filters
    @DosFrom      DATE          = NULL,
    @DosTo        DATE          = NULL,
    @BilledFrom   DATE          = NULL,
    @BilledTo     DATE          = NULL,
    -- Dimension filters (comma-separated value lists; NULL = no filter)
    @Panels       NVARCHAR(MAX) = NULL,
    @Clinics      NVARCHAR(MAX) = NULL,
    @Providers    NVARCHAR(MAX) = NULL,
    @Reps         NVARCHAR(MAX) = NULL,
    -- Diagnostics: when 1, PRINTs the resolved LIMSMaster columns, the dynamic
    -- LIS query, and row counts at each stage. Default 0 (no effect on callers).
    @Debug        BIT           = 0
)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_WARNINGS OFF;

    DECLARE @DbgCnt INT;   -- scratch for @Debug row-count PRINTs

    -- Any non-default value forces the live re-aggregation path.
    -- ISNULL guards against C# sending DBNull for int params — NULL <> 0 is
    -- UNKNOWN in SQL, which would leave @HasFilter at 0 accidentally.
    DECLARE @HasFilter BIT = CASE
        WHEN @DosFrom     IS NOT NULL THEN 1
        WHEN @DosTo       IS NOT NULL THEN 1
        WHEN @BilledFrom  IS NOT NULL THEN 1
        WHEN @BilledTo    IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Panels)),    '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Clinics)),   '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Providers)), '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Reps)),      '') IS NOT NULL THEN 1
        ELSE 0
    END;

    -- Date mode: DOS vs FirstBilledDate are mutually exclusive in the UI.
    -- @UseBilledDate = 1  → FirstBilledDate filter is active (@BilledFrom/@BilledTo set, @DosFrom/@DosTo NULL).
    --   #Base  : ESYear/ESMonth derived from FirstBilledDate (not DateofService).
    --   LIS    : LISYear/LISMonth derived from BilledDate in LIMSMaster; live scan triggered.
    -- @UseBilledDate = 0  → DOS mode (or no date filter) — existing behaviour unchanged.
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
            SELECT RoleID AS RowCode, 'LIS' AS Category, Description,
                   ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue,
                   1 AS CatOrder, Id AS SortId
            FROM dbo.Cove_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)), 2, Id
            FROM dbo.Cove_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount, 3, Id
            FROM dbo.Cove_ES_Cash

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount, 4, Id
            FROM dbo.Cove_ES_Avg
        ) x
        ORDER BY BillYear, BillMonth, CatOrder, SortId;

        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  FILTERED  -  live re-aggregation from base tables
    -- ════════════════════════════════════════════════════════════════════

    -- ── Dimension filter staging: split comma-separated lists into temp tables ──
    DROP TABLE IF EXISTS #FilterPanels;
    DROP TABLE IF EXISTS #FilterClinics;
    DROP TABLE IF EXISTS #FilterProviders;
    DROP TABLE IF EXISTS #FilterReps;

    -- COLLATE DATABASE_DEFAULT pins the temp table to the database's collation,
    -- preventing conflicts when the server default collation differs (e.g.
    -- SQL_Latin1_General_CP1_CI_AS server vs Latin1_General_CI_AS database).
    CREATE TABLE #FilterPanels   (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterClinics  (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterProviders(Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterReps     (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@Panels)), '') IS NOT NULL
        INSERT INTO #FilterPanels(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Panels, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    IF NULLIF(LTRIM(RTRIM(@Clinics)), '') IS NOT NULL
        INSERT INTO #FilterClinics(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Clinics, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    IF NULLIF(LTRIM(RTRIM(@Providers)), '') IS NOT NULL
        INSERT INTO #FilterProviders(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Providers, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    IF NULLIF(LTRIM(RTRIM(@Reps)), '') IS NOT NULL
        INSERT INTO #FilterReps(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Reps, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @HasPanelFilter    BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterPanels)    THEN 1 ELSE 0 END;
    DECLARE @HasClinicFilter   BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterClinics)   THEN 1 ELSE 0 END;
    DECLARE @HasProviderFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterProviders) THEN 1 ELSE 0 END;
    DECLARE @HasRepFilter      BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterReps)      THEN 1 ELSE 0 END;

    -- @HasLisFilter: 1 when a dimension filter OR BilledDate mode is active.
    -- @UseBilledDate=1 → live LIMSMaster scan needed so LISYear/LISMonth are bucketed
    --   by BilledDate (not DateOfCollection). BilledDate is an indexed DATE column so
    --   the scan is a fast index seek (SARGable direct compare — no TRY_CAST).
    -- DOS (@DosFrom/@DosTo) → aggregate filtered by ESYear/ESMonth (no live scan).
    -- SalesRep (@HasRepFilter) now included: LIMSMaster has a SaleRepName column
    -- (confirmed present), so a Rep-only filter must also trigger the live scan
    -- for the Rep filter to actually take effect on the LIS section.
    DECLARE @HasLisFilter BIT = CASE
        WHEN @HasPanelFilter=1 OR @HasClinicFilter=1 OR @HasProviderFilter=1
          OR @HasRepFilter=1 OR @UseBilledDate = 1
        THEN 1 ELSE 0 END;

    -- ── Filter summary (always printed) ─────────────────────────────────────
    PRINT '=== usp_GetCove_ExecutiveSummary — Active Filters ===';
    PRINT '  Date mode      : ' + CASE
        WHEN @UseBilledDate = 1  THEN 'FirstBilledDate (BilledDate)'
        WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 'DateOfService (DOS)'
        ELSE 'None (no date filter)' END;
    PRINT '  BilledFrom     : ' + ISNULL(CONVERT(VARCHAR(10), @BilledFrom, 120), '(not set)');
    PRINT '  BilledTo       : ' + ISNULL(CONVERT(VARCHAR(10), @BilledTo,   120), '(not set)');
    PRINT '  DosFrom        : ' + ISNULL(CONVERT(VARCHAR(10), @DosFrom,    120), '(not set)');
    PRINT '  DosTo          : ' + ISNULL(CONVERT(VARCHAR(10), @DosTo,      120), '(not set)');
    PRINT '  Panels         : ' + CASE WHEN @HasPanelFilter    = 1 THEN ISNULL(@Panels,    '(set)') ELSE '(not set)' END;
    PRINT '  Clinics        : ' + CASE WHEN @HasClinicFilter   = 1 THEN ISNULL(@Clinics,   '(set)') ELSE '(not set)' END;
    PRINT '  Providers      : ' + CASE WHEN @HasProviderFilter = 1 THEN ISNULL(@Providers, '(set)') ELSE '(not set)' END;
    PRINT '  Reps           : ' + CASE WHEN @HasRepFilter      = 1 THEN ISNULL(@Reps,      '(set)') ELSE '(not set)' END;
    PRINT '  @UseBilledDate : ' + CAST(@UseBilledDate  AS VARCHAR(1));
    PRINT '  @HasLisFilter  : ' + CAST(@HasLisFilter   AS VARCHAR(1));
    PRINT '  @HasFilter     : ' + CAST(@HasFilter      AS VARCHAR(1));
    PRINT '======================================================';

    -- ── LIS: build #Lis from dbo.LIMSMaster ─────────────────────────────────
    -- Uses dynamic column name resolution (same as Aggregate SP) to stay
    -- resilient to schema differences across environments.
    DROP TABLE IF EXISTS #Lis;
    -- COLLATE DATABASE_DEFAULT pins these string columns to the database collation.
    -- Without it the columns inherit tempdb's (= server) collation; later the D/E
    -- blocks JOIN these columns to VALUES-derived literal columns (which carry the
    -- database collation), and when server <> database collation that join throws
    -- "Cannot resolve the collation conflict ... in the equal to operation".
    -- #LisPanelTypes/#LisDNB/#LisEOther are built via SELECT INTO from #Lis, so they
    -- inherit DATABASE_DEFAULT from here too.
    CREATE TABLE #Lis
    (
        Accession    NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        NewStatus    NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PanelType    NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        BillCategory NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        SubStatus    NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        LISYear      INT           NOT NULL DEFAULT 0,
        LISMonth     INT           NOT NULL DEFAULT 0
    );

    IF @HasLisFilter = 1 AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        DECLARE @AccCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('AccessionNumber','Accession','AccessionNo')
            ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

        DECLARE @DateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('DateOfCollection','RequestCollectDate','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'DateOfCollection'   THEN 0 WHEN 'RequestCollectDate' THEN 1
                WHEN 'DateofService'      THEN 2 WHEN 'CollectionDate'     THEN 3
                WHEN 'ServiceDate'        THEN 4 WHEN 'AccessionDate'      THEN 5 ELSE 6 END);

        DECLARE @NewStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('NewStatus','Status')
            ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 ELSE 2 END);

        DECLARE @PanelTypeCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelType','PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
            ORDER BY CASE name
                WHEN 'PanelType'        THEN 0 WHEN 'PanelCategory'   THEN 1 WHEN 'PanelName'      THEN 2
                WHEN 'Panelname'        THEN 3 WHEN 'TestPanel'       THEN 4 WHEN 'TestPanelName'  THEN 5
                WHEN 'Panel'            THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'      THEN 8
                WHEN 'Test_Panel'       THEN 9 WHEN 'TestPanelname'   THEN 10 ELSE 11 END);

        DECLARE @BillCategoryCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
            ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BilledorNot' THEN 3 WHEN 'BillStatus' THEN 4 ELSE 5 END);

        DECLARE @SubStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('SubStatus','Sub_Status','ClientStatus','FinalStatus')
            ORDER BY CASE name WHEN 'SubStatus' THEN 0 WHEN 'Sub_Status' THEN 1 WHEN 'ClientStatus' THEN 2 WHEN 'FinalStatus' THEN 3 ELSE 4 END);

        -- BilledDate: maps @BilledFrom/@BilledTo → LIMSMaster BilledDate column
        DECLARE @BilledDateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BilledDate','FirstBilledDate','BilledOn','BillDate','FirstBillDate')
            ORDER BY CASE name
                WHEN 'BilledDate'     THEN 0 WHEN 'FirstBilledDate' THEN 1
                WHEN 'BilledOn'       THEN 2 WHEN 'BillDate'        THEN 3
                WHEN 'FirstBillDate'  THEN 4 ELSE 5 END);

        -- Period expression for LISYear / LISMonth in @LisSql:
        --   BilledDate mode → [BilledDate] direct (native DATE column — SARGable, no TRY_CAST)
        --   DOS mode        → TRY_CAST([DateOfCollection] AS DATE)  (NVARCHAR column)
        DECLARE @LisPeriodExpr NVARCHAR(200) =
            CASE WHEN @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
                 THEN N'[' + @BilledDateCol + N']'
                 ELSE N'TRY_CAST([' + @DateCol + N'] AS DATE)' END;

        -- LIS dimension filter columns — Cove-specific mappings:
        --   Clinics   -> FacilityName
        --   Providers -> PhysicianName
        --   SalesRep  -> SaleRepName
        DECLARE @LisFacilityCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('FacilityName','Facility','ClinicName','Clinic')
            ORDER BY CASE name
                WHEN 'FacilityName' THEN 0 WHEN 'Facility'  THEN 1
                WHEN 'ClinicName'   THEN 2 WHEN 'Clinic'    THEN 3 ELSE 4 END);

        DECLARE @LisPhysicianCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PhysicianName','Physician','ReferringPhysician','ReferringProvider','Provider')
            ORDER BY CASE name
                WHEN 'PhysicianName'      THEN 0 WHEN 'Physician'         THEN 1
                WHEN 'ReferringPhysician' THEN 2 WHEN 'ReferringProvider' THEN 3
                WHEN 'Provider'           THEN 4 ELSE 5 END);

        DECLARE @LisSaleRepCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('SaleRepName','SalesRepName','SalesRep','Rep')
            ORDER BY CASE name
                WHEN 'SaleRepName'  THEN 0 WHEN 'SalesRepName' THEN 1
                WHEN 'SalesRep'     THEN 2 WHEN 'Rep'          THEN 3 ELSE 4 END);

        IF @Debug = 1
        BEGIN
            PRINT '=== LIMSMaster resolved columns ===';
            PRINT '  Accession    = ' + ISNULL(@AccCol,          '(none)');
            PRINT '  Date         = ' + ISNULL(@DateCol,         '(none)');
            PRINT '  NewStatus    = ' + ISNULL(@NewStatusCol,    '(none)');
            PRINT '  PanelType    = ' + ISNULL(@PanelTypeCol,    '(none)');
            PRINT '  BillCategory = ' + ISNULL(@BillCategoryCol, '(none)');
            PRINT '  SubStatus    = ' + ISNULL(@SubStatusCol,    '(none)');
            PRINT '  FacilityName = ' + ISNULL(@LisFacilityCol,  '(none)');
            PRINT '  PhysicianName= ' + ISNULL(@LisPhysicianCol, '(none)');
            PRINT '  SaleRepName  = ' + ISNULL(@LisSaleRepCol,   '(none)');
            PRINT '  BilledDate   = ' + ISNULL(@BilledDateCol,   '(none)');
            PRINT '  @HasPanelFilter    = ' + CAST(@HasPanelFilter    AS VARCHAR(1));
            PRINT '  @HasClinicFilter   = ' + CAST(@HasClinicFilter   AS VARCHAR(1));
            PRINT '  @HasProviderFilter = ' + CAST(@HasProviderFilter AS VARCHAR(1));
            PRINT '  @HasRepFilter      = ' + CAST(@HasRepFilter      AS VARCHAR(1));
        END

        IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @NewStatusCol IS NOT NULL
           AND @PanelTypeCol IS NOT NULL AND @BillCategoryCol IS NOT NULL AND @SubStatusCol IS NOT NULL
        BEGIN
            -- DOS filter (@DosFrom/@DosTo) → applied to @DateCol (DateOfCollection).
            -- BilledDate filter (@BilledFrom/@BilledTo) → applied to @BilledDateCol (BilledDate) if column exists.
            -- Dimension filters applied: Panels→PanelType, Clinics→FacilityName,
            --   Providers→PhysicianName, Reps→SaleRepName.
            -- @LisPeriodExpr drives LISYear/LISMonth:
            --   BilledDate mode → [BilledDate]  (indexed DATE — fast index seek)
            --   DOS mode        → TRY_CAST([DateOfCollection] AS DATE)
            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (Accession, NewStatus, PanelType, BillCategory, SubStatus, LISYear, LISMonth)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol       + N']))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @NewStatusCol    + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelTypeCol    + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol    + N']), ''''))),
                    ISNULL(YEAR (' + @LisPeriodExpr + N'), 0),
                    ISNULL(MONTH(' + @LisPeriodExpr + N'), 0)
                FROM dbo.LIMSMaster WITH (NOLOCK)
                WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL';

            -- Panel filter: Panels → PanelType
            SET @LisSql = @LisSql + N'
                  AND (@iHasPanelFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @PanelTypeCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iPanels + '','') > 0)';

            -- Clinic filter: Clinics → FacilityName
            IF @LisFacilityCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasClinicFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisFacilityCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iClinics + '','') > 0)';

            -- Provider filter: Providers → PhysicianName
            IF @LisPhysicianCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasProviderFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisPhysicianCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iProviders + '','') > 0)';

            -- Rep filter: Reps → SaleRepName
            IF @LisSaleRepCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasRepFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisSaleRepCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iReps + '','') > 0)';

            -- DOS filter: DateofService (@DosFrom/@DosTo) → DateOfCollection (= @DateCol)
            SET @LisSql = @LisSql + N'
                  AND (@iDosFrom IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) >= @iDosFrom)
                  AND (@iDosTo   IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) <= @iDosTo)';

            -- FirstBilledDate filter: @BilledFrom/@BilledTo → BilledDate
            -- BilledDate is a native DATE column → direct compare (SARGable, uses index).
            -- Do NOT wrap in TRY_CAST — that breaks index usage and causes full-table scan.
            IF @BilledDateCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iBilledFrom IS NULL OR [' + @BilledDateCol + N'] >= @iBilledFrom)
                  AND (@iBilledTo   IS NULL OR [' + @BilledDateCol + N'] <= @iBilledTo)';

            -- OPTION (RECOMPILE) lets the optimizer use the ACTUAL parameter values
            -- at run-time: when @iDosFrom / @iDosTo are NULL it eliminates the dead
            -- TRY_CAST(DateOfCollection) branch from the plan, so the BilledDate
            -- index seek is the only date predicate considered.
            SET @LisSql = @LisSql + N' OPTION (RECOMPILE);';

            IF @Debug = 1
            BEGIN
                PRINT '=== Dynamic LIS query (@LisSql) ===';
                PRINT @LisSql;
            END

            PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-1] Starting LIMSMaster scan (@LisSql)...';
            EXEC sp_executesql @LisSql,
                N'@iHasPanelFilter    BIT, @iPanels    NVARCHAR(MAX),
                  @iHasClinicFilter   BIT, @iClinics   NVARCHAR(MAX),
                  @iHasProviderFilter BIT, @iProviders NVARCHAR(MAX),
                  @iHasRepFilter      BIT, @iReps      NVARCHAR(MAX),
                  @iDosFrom DATE, @iDosTo DATE,
                  @iBilledFrom DATE, @iBilledTo DATE',
                @iHasPanelFilter    = @HasPanelFilter,    @iPanels    = @Panels,
                @iHasClinicFilter   = @HasClinicFilter,   @iClinics   = @Clinics,
                @iHasProviderFilter = @HasProviderFilter, @iProviders = @Providers,
                @iHasRepFilter      = @HasRepFilter,      @iReps      = @Reps,
                @iDosFrom    = @DosFrom,    @iDosTo    = @DosTo,
                @iBilledFrom = @BilledFrom, @iBilledTo = @BilledTo;

            SELECT @DbgCnt = COUNT(*) FROM #Lis;
            PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-2] #Lis loaded (' + CAST(@DbgCnt AS VARCHAR(20)) + ' rows). Building indexes...';
            CREATE CLUSTERED INDEX CIX_Lis ON #Lis(LISYear, LISMonth);

            -- Covering NC index: allows D.{n} and E.{n} cross-join blocks to do
            -- index seeks per (NewStatus, BillCategory, SubStatus) rather than
            -- full 200k-row scans × 20/7 VALUES. Without this, those COUNT DISTINCT
            -- cross-joins cause execution timeouts when #Lis is large (date-only filter).
            CREATE INDEX IX_Lis_NB ON #Lis
                (NewStatus, BillCategory, SubStatus, LISYear, LISMonth)
                INCLUDE (Accession, PanelType);
            PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-3] #Lis indexes built.';
        END
        ELSE IF @Debug = 1
        BEGIN
            PRINT '*** LIS skipped: one or more required LIMSMaster columns not found. ***';
        END
    END
    ELSE IF @Debug = 1
        PRINT '*** dbo.LIMSMaster not found. ***';

    IF @Debug = 1
    BEGIN
        SELECT @DbgCnt = COUNT(*) FROM #Lis;
        PRINT '#Lis rows after build (dimension filters applied): ' + CAST(@DbgCnt AS VARCHAR(20));
    END

    -- ════════════════════════════════════════════════════════════════════
    --  PMS / CASH / AVG  -  build #Base from dbo.ClaimLevelData
    --
    --  Filters applied INDEPENDENTLY from LIS (no cross-table bridge):
    --    • DosFrom / DosTo      → DateofService range
    --    • BilledFrom / BilledTo → FirstBilledDate range
    --    • Panels               → PanelName
    --    • Clinics              → ClinicName
    --    • Providers            → ReferringProvider
    --    • Reps                 → SalesRepname
    -- ════════════════════════════════════════════════════════════════════
    IF @Debug = 1
    BEGIN
        PRINT '=== PMS/Cash/Avg filters (ClaimLevelData) ===';
        PRINT '  @DosFrom        = ' + ISNULL(CONVERT(VARCHAR(10), @DosFrom,    120), '(null)');
        PRINT '  @DosTo          = ' + ISNULL(CONVERT(VARCHAR(10), @DosTo,      120), '(null)');
        PRINT '  @BilledFrom     = ' + ISNULL(CONVERT(VARCHAR(10), @BilledFrom, 120), '(null)');
        PRINT '  @BilledTo       = ' + ISNULL(CONVERT(VARCHAR(10), @BilledTo,   120), '(null)');
        PRINT '  @HasPanelFilter    = ' + CAST(@HasPanelFilter    AS VARCHAR(1));
        PRINT '  @HasClinicFilter   = ' + CAST(@HasClinicFilter   AS VARCHAR(1));
        PRINT '  @HasProviderFilter = ' + CAST(@HasProviderFilter AS VARCHAR(1));
        PRINT '  @HasRepFilter      = ' + CAST(@HasRepFilter      AS VARCHAR(1));
    END

    PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [PMS-1] Starting ClaimLevelData scan (#Base)...';
    -- Pre-create #Base so SQL Server doesn't see two SELECT…INTO statements
    -- (which causes Msg 2714 at compile time regardless of IF/ELSE branching).
    -- Each branch uses INSERT INTO instead of SELECT INTO.
    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        AccessionNumber      NVARCHAR(100)  COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear               INT            NOT NULL DEFAULT 0,
        ESMonth              INT            NOT NULL DEFAULT 0,
        BillStatus           NVARCHAR(200)  COLLATE DATABASE_DEFAULT NOT NULL DEFAULT '',
        ClaimStatus          NVARCHAR(200)  COLLATE DATABASE_DEFAULT NOT NULL DEFAULT '',
        ChargeAmount         DECIMAL(18,2)  NOT NULL DEFAULT 0,
        InsurancePayment     DECIMAL(18,2)  NOT NULL DEFAULT 0,
        PatientPayment       DECIMAL(18,2)  NOT NULL DEFAULT 0,
        InsuranceAdjustments DECIMAL(18,2)  NOT NULL DEFAULT 0,
        PatientAdjustments   DECIMAL(18,2)  NOT NULL DEFAULT 0,
        InsuranceBalance     DECIMAL(18,2)  NOT NULL DEFAULT 0,
        PatientBalance       DECIMAL(18,2)  NOT NULL DEFAULT 0
    );

    -- DOS mode   : ESYear/ESMonth from DateofService,    filter by @DosFrom/@DosTo.
    -- BilledDate : ESYear/ESMonth from FirstBilledDate,  filter by @BilledFrom/@BilledTo.
    IF @UseBilledDate = 0
    BEGIN
        INSERT INTO #Base (AccessionNumber, ESYear, ESMonth, BillStatus, ClaimStatus,
                           ChargeAmount, InsurancePayment, PatientPayment,
                           InsuranceAdjustments, PatientAdjustments,
                           InsuranceBalance, PatientBalance)
        SELECT
            AccessionNumber,
            ISNULL(YEAR (TRY_CAST(DateofService AS DATE)), 0),
            ISNULL(MONTH(TRY_CAST(DateofService AS DATE)), 0),
            ISNULL(LTRIM(RTRIM(BillStatus)),  ''),
            ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
        FROM dbo.ClaimLevelData WITH (NOLOCK)
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
          AND (@DosFrom    IS NULL OR TRY_CAST(DateofService AS DATE) >= @DosFrom)
          AND (@DosTo      IS NULL OR TRY_CAST(DateofService AS DATE) <= @DosTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(PanelName,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels    + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics   + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps      + ',') COLLATE DATABASE_DEFAULT) > 0);
    END
    ELSE  -- @UseBilledDate = 1 : period + filter on FirstBilledDate
    BEGIN
        INSERT INTO #Base (AccessionNumber, ESYear, ESMonth, BillStatus, ClaimStatus,
                           ChargeAmount, InsurancePayment, PatientPayment,
                           InsuranceAdjustments, PatientAdjustments,
                           InsuranceBalance, PatientBalance)
        SELECT
            AccessionNumber,
            ISNULL(YEAR (TRY_CAST(FirstBilledDate AS DATE)), 0),
            ISNULL(MONTH(TRY_CAST(FirstBilledDate AS DATE)), 0),
            ISNULL(LTRIM(RTRIM(BillStatus)),  ''),
            ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
        FROM dbo.ClaimLevelData WITH (NOLOCK)
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
          AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
          AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(PanelName,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels    + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics   + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps      + ',') COLLATE DATABASE_DEFAULT) > 0)
        OPTION (RECOMPILE);  -- lets optimizer use actual @BilledFrom/@BilledTo values,
                             -- eliminates dead IS-NULL branches, enables parallel scan
                             -- of ClaimLevelData (FirstBilledDate is NVARCHAR → full scan)
    END

    SELECT @DbgCnt = COUNT(*) FROM #Base;
    PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [PMS-2] #Base loaded (' + CAST(@DbgCnt AS VARCHAR(20)) + ' rows). Building CIX...';
    CREATE CLUSTERED INDEX CIX_Base ON #Base(ESYear, ESMonth);
    PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [PMS-3] #Base CIX built.';

    IF @Debug = 1
    BEGIN
        SELECT @DbgCnt = COUNT(*) FROM #Base;
        PRINT '#Base rows loaded from ClaimLevelData: ' + CAST(@DbgCnt AS VARCHAR(20));
    END

    -- ════════════════════════════════════════════════════════════════════
    --  LIS breakdown is built independently above from dbo.LIMSMaster.
    --  PMS/Cash/Avg breakdown is built above from dbo.ClaimLevelData.
    --  No cross-table bridge — each section reflects its own source data.
    -- ════════════════════════════════════════════════════════════════════
    IF @Debug = 1
    BEGIN
        SELECT @DbgCnt = COUNT(*) FROM #Lis;
        PRINT '#Lis rows loaded from LIMSMaster (dimension filters applied): ' + CAST(@DbgCnt AS VARCHAR(20));
    END

    -- #Periods not used — aggregation is done via direct GROUP BY on #Lis / #Base
    -- (avoids OR-join pattern that prevented index use)

    -- #LisRows collects all output rows (LIS A-E and PMS/Cash/Avg F-X).
    -- Created here — before the IF — so both branches (filtered and aggregate) can INSERT.
    DROP TABLE IF EXISTS #LisRows;
    CREATE TABLE #LisRows
    (
        ESYear      INT           NOT NULL,
        ESMonth     INT           NOT NULL,
        RowCode     NVARCHAR(420) NOT NULL,
        Description NVARCHAR(420) NOT NULL,
        MetricValue DECIMAL(18,2) NOT NULL
    );

    -- When @HasLisFilter = 0 (SalesRep-only or date-only), skip LIMSMaster;
    -- serve LIS rows from the pre-built aggregate. When @HasLisFilter = 1, build from #Lis.
    IF @HasLisFilter = 1
    BEGIN
    -- ── Dynamic LIS dimension tables ────────────────────────────────────────
    -- #LisPanelTypes: PanelSeq drives D.5.{m} / D.6.{m} sub-row RowCodes.
    -- D.{n} and E.{n} now use inline CROSS JOIN VALUES (fixed list matching 19_LIS_Alt).
    DROP TABLE IF EXISTS #LisPanelTypes;
    SELECT PanelType, ROW_NUMBER() OVER (ORDER BY PanelType) AS PanelSeq
    INTO #LisPanelTypes
    FROM (SELECT DISTINCT PanelType FROM #Lis WHERE NULLIF(PanelType, '') IS NOT NULL) p;

    -- ── Build the LIS rows (matches 19_LIS_Alt numbering) ──────────────────
    --   A  Total Samples
    --   B  Billable Samples           + B.<PanelType> (dynamic, per distinct PanelType)
    --   C  Billed
    --   D  Not Billed                 + D.1–D.20 (fixed SubStatus list)
    --                                 + D.5.{m} / D.6.{m} (dynamic panel subs for exceptions)
    --   E  Other Samples              + E.1–E.7 (fixed NewStatus list)

    PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-4] Building LIS A-E rows...';
    -- ════════════════════════════════════════════════════════════════════
    --  LIS rows A–E  (direct GROUP BY — no OR-join, no #Periods needed)
    --  Two passes: per-month breakdown + (0,0) grand total UNION ALL'd.
    -- ════════════════════════════════════════════════════════════════════
    INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
    SELECT ESYear, ESMonth, v.RowCode, v.Description, v.MetricValue
    FROM (
        -- Per-month
        SELECT l.LISYear AS ESYear, l.LISMonth AS ESMonth,
            COUNT(DISTINCT l.Accession)                                                                           AS cntA,
            COUNT(DISTINCT CASE WHEN l.NewStatus='Billable'                              THEN l.Accession END)    AS cntB,
            COUNT(DISTINCT CASE WHEN l.NewStatus='Billable' AND l.BillCategory='Billed'     THEN l.Accession END) AS cntC,
            COUNT(DISTINCT CASE WHEN l.NewStatus='Billable' AND l.BillCategory='Not Billed' THEN l.Accession END) AS cntD,
            COUNT(DISTINCT CASE WHEN l.NewStatus <> 'Billable'                           THEN l.Accession END)    AS cntE
        FROM #Lis l
        GROUP BY l.LISYear, l.LISMonth
        UNION ALL
        -- Grand total
        SELECT 0, 0,
            COUNT(DISTINCT l.Accession),
            COUNT(DISTINCT CASE WHEN l.NewStatus='Billable'                              THEN l.Accession END),
            COUNT(DISTINCT CASE WHEN l.NewStatus='Billable' AND l.BillCategory='Billed'     THEN l.Accession END),
            COUNT(DISTINCT CASE WHEN l.NewStatus='Billable' AND l.BillCategory='Not Billed' THEN l.Accession END),
            COUNT(DISTINCT CASE WHEN l.NewStatus <> 'Billable'                           THEN l.Accession END)
        FROM #Lis l
    ) agg
    CROSS APPLY (VALUES
        ('A', 'Total Samples',    CAST(agg.cntA AS DECIMAL(18,2))),
        ('B', 'Billable Samples', CAST(agg.cntB AS DECIMAL(18,2))),
        ('C', 'Billed',           CAST(agg.cntC AS DECIMAL(18,2))),
        ('D', 'Not Billed',       CAST(agg.cntD AS DECIMAL(18,2))),
        ('E', 'Other Samples',    CAST(agg.cntE AS DECIMAL(18,2)))
    ) v(RowCode, Description, MetricValue);

    PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-5] Building B.PanelType rows...';
    -- ── B.<PanelType>  per-month + grand total ───────────────────────────────────
    INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
    SELECT LISYear, LISMonth, N'B.' + PanelType, N'  ' + PanelType,
           CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' THEN Accession END) AS DECIMAL(18,2))
    FROM #Lis WHERE NULLIF(PanelType,'') IS NOT NULL
    GROUP BY LISYear, LISMonth, PanelType
    UNION ALL
    SELECT 0, 0, N'B.' + PanelType, N'  ' + PanelType,
           CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' THEN Accession END) AS DECIMAL(18,2))
    FROM #Lis WHERE NULLIF(PanelType,'') IS NOT NULL
    GROUP BY PanelType;

    -- ── D.{n}  Not Billed by SubStatus (pre-aggregated — replaces 200k×20 CROSS JOIN) ──
    -- #LisDNB: distinct accession count per (year, month, substatus) for Billable/Not Billed.
    -- Cross-joining N_months × 20 rows is ~120 rows — vs the old #Lis×20 = 4M+ row plan.
    PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-6] Building D.{n} (pre-agg)...';
    DROP TABLE IF EXISTS #LisDNB;
    SELECT LISYear, LISMonth, SubStatus, COUNT(DISTINCT Accession) AS AccCount
    INTO   #LisDNB
    FROM   #Lis
    WHERE  NewStatus = 'Billable' AND BillCategory = 'Not Billed'
    GROUP BY LISYear, LISMonth, SubStatus;

    INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
    -- Per-month: each (year, month) pair × each of the 20 fixed SubStatus codes
    SELECT p.LISYear, p.LISMonth, v.RowCode, v.Description,
           CAST(ISNULL(d.AccCount, 0) AS DECIMAL(18,2))
    FROM   (SELECT DISTINCT LISYear, LISMonth FROM #Lis) p
    CROSS JOIN (VALUES
        ('D.1',  '  Billed Insurance In Covedx',                  'Billed Insurance In Covedx'),
        ('D.2',  '  Billed In Variantx Lab',                      'Billed In Variantx Lab'),
        ('D.3',  '  Billed In Elixir Dx',                        'Billed In Elixir Dx'),
        ('D.4',  '  Ignored - Duplicate Accession',               'Ignored - Duplicate Accession'),
        ('D.5',  '  Coding exception',                            'Coding exception'),
        ('D.6',  '  CP Exception',                                'CP Exception'),
        ('D.7',  '  In process',                                  'In process'),
        ('D.8',  '  Ignored - Client Response Non Billiable',     'Ignored - Client Response Non Billiable'),
        ('D.9',  '  Ready To Bill',                               'Ready To Bill'),
        ('D.10', '  Ignored - NGS & PGX in Cove',                'Ignored - NGS & PGX in Cove'),
        ('D.11', '  CP Exception -In Review',                     'CP Exception -In Review'),
        ('D.12', '  Medicaid Credentialling In Process',          'Medicaid Credentialling In Process'),
        ('D.13', '  Ignored - Reported in Elixir Truemed',        'Ignored - Reported in Elixir Truemed'),
        ('D.14', '  Ignored - CP Exception',                      'Ignored - CP Exception'),
        ('D.15', '  Client Bill Cases',                           'Client Bill Cases'),
        ('D.16', '  Ignored - Client Response Pure Selfpay',      'Ignored - Client Response Pure Selfpay'),
        ('D.17', '  Selfpay',                                     'Selfpay'),
        ('D.18', '  Ignored - Rejected Accession',                'Ignored - Rejected Accession'),
        ('D.19', '  Hold-Amerihealth Lousiana',                   'Hold-Amerihealth Lousiana'),
        ('D.20', '  Ignored - Test Cases',                        'Ignored - Test Cases')
    ) v(RowCode, Description, SubStatusVal)
    LEFT JOIN #LisDNB d ON d.LISYear  = p.LISYear
                        AND d.LISMonth = p.LISMonth
                        AND d.SubStatus = v.SubStatusVal
    UNION ALL
    -- Grand total (0,0): SUM of per-month counts.
    -- Safe because each accession has exactly one billed/collection month,
    -- so SUM across months equals COUNT DISTINCT across all months.
    SELECT 0, 0, v.RowCode, v.Description,
           CAST(ISNULL(SUM(g.AccCount), 0) AS DECIMAL(18,2))
    FROM   (VALUES
        ('D.1',  '  Billed Insurance In Covedx',                  'Billed Insurance In Covedx'),
        ('D.2',  '  Billed In Variantx Lab',                      'Billed In Variantx Lab'),
        ('D.3',  '  Billed In Elixir Dx',                        'Billed In Elixir Dx'),
        ('D.4',  '  Ignored - Duplicate Accession',               'Ignored - Duplicate Accession'),
        ('D.5',  '  Coding exception',                            'Coding exception'),
        ('D.6',  '  CP Exception',                                'CP Exception'),
        ('D.7',  '  In process',                                  'In process'),
        ('D.8',  '  Ignored - Client Response Non Billiable',     'Ignored - Client Response Non Billiable'),
        ('D.9',  '  Ready To Bill',                               'Ready To Bill'),
        ('D.10', '  Ignored - NGS & PGX in Cove',                'Ignored - NGS & PGX in Cove'),
        ('D.11', '  CP Exception -In Review',                     'CP Exception -In Review'),
        ('D.12', '  Medicaid Credentialling In Process',          'Medicaid Credentialling In Process'),
        ('D.13', '  Ignored - Reported in Elixir Truemed',        'Ignored - Reported in Elixir Truemed'),
        ('D.14', '  Ignored - CP Exception',                      'Ignored - CP Exception'),
        ('D.15', '  Client Bill Cases',                           'Client Bill Cases'),
        ('D.16', '  Ignored - Client Response Pure Selfpay',      'Ignored - Client Response Pure Selfpay'),
        ('D.17', '  Selfpay',                                     'Selfpay'),
        ('D.18', '  Ignored - Rejected Accession',                'Ignored - Rejected Accession'),
        ('D.19', '  Hold-Amerihealth Lousiana',                   'Hold-Amerihealth Lousiana'),
        ('D.20', '  Ignored - Test Cases',                        'Ignored - Test Cases')
    ) v(RowCode, Description, SubStatusVal)
    LEFT JOIN (SELECT SubStatus, SUM(AccCount) AS AccCount FROM #LisDNB GROUP BY SubStatus) g
        ON g.SubStatus = v.SubStatusVal
    GROUP BY v.RowCode, v.Description, v.SubStatusVal;
    PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-7] D.{n} done.';

    -- ── D.{n}.{m}  Exception SubStatus by panel (D.5/D.6 only, matching 19_LIS_Alt) ─────
    -- Skipped when no panel filter is active: a large #Lis (date-only filter) makes the
    -- triple CROSS JOIN (#Lis × 2 exceptions × N PanelTypes) prohibitively expensive.
    -- These sub-rows are only meaningful when drilling into a specific panel anyway.
    IF @HasPanelFilter = 1
    INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
    SELECT l.LISYear, l.LISMonth,
           N'D.' + CAST(ex.SubNum AS NVARCHAR(10)) + N'.' + CAST(pt.PanelSeq AS NVARCHAR(10)),
           N'    ' + pt.PanelType,
           CAST(COUNT(DISTINCT CASE WHEN l.SubStatus = ex.SubStatusVal AND l.PanelType = pt.PanelType THEN l.Accession END) AS DECIMAL(18,2))
    FROM #Lis l
    CROSS JOIN (VALUES (5, 'Coding exception'), (6, 'CP Exception')) ex(SubNum, SubStatusVal)
    CROSS JOIN #LisPanelTypes pt
    WHERE l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed'
    GROUP BY l.LISYear, l.LISMonth, ex.SubNum, ex.SubStatusVal, pt.PanelSeq, pt.PanelType
    UNION ALL
    SELECT 0, 0,
           N'D.' + CAST(ex.SubNum AS NVARCHAR(10)) + N'.' + CAST(pt.PanelSeq AS NVARCHAR(10)),
           N'    ' + pt.PanelType,
           CAST(COUNT(DISTINCT CASE WHEN l.SubStatus = ex.SubStatusVal AND l.PanelType = pt.PanelType THEN l.Accession END) AS DECIMAL(18,2))
    FROM #Lis l
    CROSS JOIN (VALUES (5, 'Coding exception'), (6, 'CP Exception')) ex(SubNum, SubStatusVal)
    CROSS JOIN #LisPanelTypes pt
    WHERE l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed'
    GROUP BY ex.SubNum, ex.SubStatusVal, pt.PanelSeq, pt.PanelType;

    -- ── E.{n}  Other Samples by NewStatus (pre-aggregated) ─────────────────────
    PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-8] Building E.{n} (pre-agg)...';
    DROP TABLE IF EXISTS #LisEOther;
    SELECT LISYear, LISMonth, NewStatus, COUNT(DISTINCT Accession) AS AccCount
    INTO   #LisEOther
    FROM   #Lis
    WHERE  NewStatus <> 'Billable'
    GROUP BY LISYear, LISMonth, NewStatus;

    INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
    SELECT p.LISYear, p.LISMonth, v.RowCode, v.Description,
           CAST(ISNULL(e.AccCount, 0) AS DECIMAL(18,2))
    FROM   (SELECT DISTINCT LISYear, LISMonth FROM #Lis) p
    CROSS JOIN (VALUES
        ('E.1', '  Self Pay',               'Self Pay'),
        ('E.2', '  Client Bill',            'Client Bill'),
        ('E.3', '  Deleted / Rejected',     'Deleted / Rejected'),
        ('E.4', '  System Test',            'System Test'),
        ('E.5', '  Ref Lab - Bill Patient', 'Ref Lab - Bill Patient'),
        ('E.6', '  Missing Accession',      'Missing Accession'),
        ('E.7', '  Yet To Be Validated',    'Yet To Be Validated')
    ) v(RowCode, Description, NewStatusVal)
    LEFT JOIN #LisEOther e ON e.LISYear  = p.LISYear
                           AND e.LISMonth = p.LISMonth
                           AND e.NewStatus = v.NewStatusVal
    UNION ALL
    SELECT 0, 0, v.RowCode, v.Description,
           CAST(ISNULL(SUM(g.AccCount), 0) AS DECIMAL(18,2))
    FROM   (VALUES
        ('E.1', '  Self Pay',               'Self Pay'),
        ('E.2', '  Client Bill',            'Client Bill'),
        ('E.3', '  Deleted / Rejected',     'Deleted / Rejected'),
        ('E.4', '  System Test',            'System Test'),
        ('E.5', '  Ref Lab - Bill Patient', 'Ref Lab - Bill Patient'),
        ('E.6', '  Missing Accession',      'Missing Accession'),
        ('E.7', '  Yet To Be Validated',    'Yet To Be Validated')
    ) v(RowCode, Description, NewStatusVal)
    LEFT JOIN (SELECT NewStatus, SUM(AccCount) AS AccCount FROM #LisEOther GROUP BY NewStatus) g
        ON g.NewStatus = v.NewStatusVal
    GROUP BY v.RowCode, v.Description, v.NewStatusVal;
    PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-9] E.{n} done.';
    END  -- IF @HasLisFilter = 1
    ELSE
    BEGIN
        -- No dimension filter active — no LIMSMaster scan.
        -- Serve LIS from the pre-built aggregate.
        -- When DOS dates are set, filter per-month rows by ESYear/ESMonth and
        -- recompute the (0,0) grand total from the matching months (fast, no live scan).
        IF @DosFrom IS NULL AND @DosTo IS NULL
        BEGIN
            -- No date filter: full aggregate including its own (0,0) grand total
            INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
            SELECT ESYear, ESMonth, RoleID, Description, CAST(ESMonthClaimCount AS DECIMAL(18,2))
            FROM dbo.Cove_ES_LIS;
        END
        ELSE
        BEGIN
            -- DOS filter: convert to integer YYYYMM for simple range comparison
            DECLARE @FromYM INT = ISNULL(YEAR(@DosFrom) * 100 + MONTH(@DosFrom), 0);
            DECLARE @ToYM   INT = ISNULL(YEAR(@DosTo)   * 100 + MONTH(@DosTo),   999999);

            -- Per-month rows within the DOS period
            INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
            SELECT ESYear, ESMonth, RoleID, Description, CAST(ESMonthClaimCount AS DECIMAL(18,2))
            FROM dbo.Cove_ES_LIS
            WHERE ESYear > 0
              AND ESYear * 100 + ESMonth >= @FromYM
              AND ESYear * 100 + ESMonth <= @ToYM;

            -- Grand total (0,0): SUM of selected months
            -- (Each accession has exactly one DateOfCollection → summing is safe)
            INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
            SELECT 0, 0, RoleID, Description, SUM(CAST(ESMonthClaimCount AS DECIMAL(18,2)))
            FROM dbo.Cove_ES_LIS
            WHERE ESYear > 0
              AND ESYear * 100 + ESMonth >= @FromYM
              AND ESYear * 100 + ESMonth <= @ToYM
            GROUP BY RoleID, Description;
        END
    END

    -- ════════════════════════════════════════════════════════════════════
    --  PMS / Cash / Avg  (direct GROUP BY — single scan per pass)
    --  Per-month + (0,0) grand total via UNION ALL + CROSS APPLY VALUES.
    -- ════════════════════════════════════════════════════════════════════
    INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
    SELECT agg.ESYear, agg.ESMonth, v.RowCode, v.Description, v.MetricValue
    FROM (
        -- Per-month breakdown
        SELECT b.ESYear, b.ESMonth,
            COUNT(DISTINCT CASE WHEN b.BillStatus IN ('Billed','Billed-Client','Billed - Client') THEN b.AccessionNumber END)                                              AS cntF,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client')                             THEN b.AccessionNumber END)                                              AS cntH,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Patient Responsibility'                                  THEN b.AccessionNumber END)                                              AS cntI,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Adjusted'                                         THEN b.AccessionNumber END)                                              AS cntJ,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Adjusted'                                      THEN b.AccessionNumber END)                                              AS cntK,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Paid'                                         THEN b.AccessionNumber END)                                              AS cntL,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Patient Payment'                                        THEN b.AccessionNumber END)                                              AS cntM,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response','No Response-Client') THEN b.AccessionNumber END)                               AS cntN,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Denied'                                           THEN b.AccessionNumber END)                                              AS cntN1,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Denied'                                       THEN b.AccessionNumber END)                                              AS cntN2,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('No Response','No Response-Client')                    THEN b.AccessionNumber END)                                              AS cntN3,
            SUM(CASE WHEN b.BillStatus  IN ('Billed','Billed-Client','Billed - Client')                                       THEN b.ChargeAmount            ELSE 0 END)               AS amtO,
            SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client')                                                       THEN b.InsurancePayment         ELSE 0 END)               AS amtP,
            SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB','No Response','No Response-Client')                THEN b.PatientBalance           ELSE 0 END)               AS amtQ,
            SUM(CASE WHEN b.PatientPayment > 0                                                                                  THEN b.PatientPayment           ELSE 0 END)               AS amtR,
            SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB')                                                     THEN b.InsuranceAdjustments + b.PatientAdjustments  ELSE 0 END)  AS amtS,
            SUM(CASE WHEN b.ClaimStatus = 'Partially Paid'                                                                    THEN b.InsurancePayment         ELSE 0 END)               AS amtT,
            SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB')                                                   THEN b.InsuranceBalance         ELSE 0 END)               AS amtU,
            SUM(CASE WHEN b.ClaimStatus = 'Fully Denied'                                                                      THEN b.InsuranceBalance         ELSE 0 END)               AS amtU1,
            SUM(CASE WHEN b.ClaimStatus IN ('Partially Denied','Partially Adjusted','Partially Paid','Patient Payment','Patient Responsibility') THEN b.InsuranceBalance ELSE 0 END)    AS amtU2,
            SUM(CASE WHEN b.ClaimStatus IN ('No Response','No Response-Client')                                               THEN b.InsuranceBalance         ELSE 0 END)               AS amtU3,
            COUNT(DISTINCT CASE WHEN b.BillStatus  IN ('Billed','Billed-Client','Billed - Client')            THEN b.AccessionNumber END)                                              AS cntV,
            SUM(CASE WHEN b.BillStatus  IN ('Billed','Billed-Client','Billed - Client') THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)                                         AS sumV,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client')                            THEN b.AccessionNumber END)                                              AS cntW,
            SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client')                 THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)                                         AS sumW,
            COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB')                        THEN b.AccessionNumber END)                                              AS cntX,
            SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB')             THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)                                         AS sumX
        FROM #Base b
        GROUP BY b.ESYear, b.ESMonth
        UNION ALL
        -- Grand total (0,0) — same aggregates, no GROUP BY column
        SELECT 0, 0,
            COUNT(DISTINCT CASE WHEN b.BillStatus IN ('Billed','Billed-Client','Billed - Client') THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client')                             THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Patient Responsibility'                                  THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Adjusted'                                         THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Adjusted'                                      THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Paid'                                         THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Patient Payment'                                        THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response','No Response-Client') THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Denied'                                           THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Denied'                                       THEN b.AccessionNumber END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('No Response','No Response-Client')                    THEN b.AccessionNumber END),
            SUM(CASE WHEN b.BillStatus  IN ('Billed','Billed-Client','Billed - Client')                                       THEN b.ChargeAmount            ELSE 0 END),
            SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client')                                                       THEN b.InsurancePayment         ELSE 0 END),
            SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB','No Response','No Response-Client')                THEN b.PatientBalance           ELSE 0 END),
            SUM(CASE WHEN b.PatientPayment > 0                                                                                  THEN b.PatientPayment           ELSE 0 END),
            SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB')                                                     THEN b.InsuranceAdjustments + b.PatientAdjustments  ELSE 0 END),
            SUM(CASE WHEN b.ClaimStatus = 'Partially Paid'                                                                    THEN b.InsurancePayment         ELSE 0 END),
            SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB')                                                   THEN b.InsuranceBalance         ELSE 0 END),
            SUM(CASE WHEN b.ClaimStatus = 'Fully Denied'                                                                      THEN b.InsuranceBalance         ELSE 0 END),
            SUM(CASE WHEN b.ClaimStatus IN ('Partially Denied','Partially Adjusted','Partially Paid','Patient Payment','Patient Responsibility') THEN b.InsuranceBalance ELSE 0 END),
            SUM(CASE WHEN b.ClaimStatus IN ('No Response','No Response-Client')                                               THEN b.InsuranceBalance         ELSE 0 END),
            COUNT(DISTINCT CASE WHEN b.BillStatus  IN ('Billed','Billed-Client','Billed - Client')            THEN b.AccessionNumber END),
            SUM(CASE WHEN b.BillStatus  IN ('Billed','Billed-Client','Billed - Client') THEN b.InsurancePayment + b.PatientPayment ELSE 0 END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client')                            THEN b.AccessionNumber END),
            SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client')                 THEN b.InsurancePayment + b.PatientPayment ELSE 0 END),
            COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB')                        THEN b.AccessionNumber END),
            SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB')             THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Base b
    ) agg
    CROSS APPLY (VALUES
        ('F',   'No. of Billed Claims',                               CAST(agg.cntF  AS DECIMAL(18,2))),
        ('H',   'No. of Fully Paid Claims',                           CAST(agg.cntH  AS DECIMAL(18,2))),
        ('I',   'No. of Patient Responsibility Claims',               CAST(agg.cntI  AS DECIMAL(18,2))),
        ('J',   'No. of Adjusted/Written Off Claims',                 CAST(agg.cntJ  AS DECIMAL(18,2))),
        ('K',   'No. of Partially Adjusted/Written Off Claims',       CAST(agg.cntK  AS DECIMAL(18,2))),
        ('L',   'No. of Partially Paid Claims',                       CAST(agg.cntL  AS DECIMAL(18,2))),
        ('M',   'No. of Patient Paid Claims',                         CAST(agg.cntM  AS DECIMAL(18,2))),
        ('N',   'No. of Insurance Balance Claims',                    CAST(agg.cntN  AS DECIMAL(18,2))),
        ('N.1', '  No. of Fully Denied Claims',                       CAST(agg.cntN1 AS DECIMAL(18,2))),
        ('N.2', '  No. of Partially Denied Claims',                   CAST(agg.cntN2 AS DECIMAL(18,2))),
        ('N.3', '  No. of No Response from Payor Claims',             CAST(agg.cntN3 AS DECIMAL(18,2))),
        ('O',   'Total Billed ($)',                                   CAST(agg.amtO  AS DECIMAL(18,2))),
        ('P',   'Insurance Payment ($)',                              CAST(agg.amtP  AS DECIMAL(18,2))),
        ('Q',   'Patient Responsibility ($)',                         CAST(agg.amtQ  AS DECIMAL(18,2))),
        ('R',   'Patient Payment ($)',                                CAST(agg.amtR  AS DECIMAL(18,2))),
        ('S',   'Adjustments / Write Off ($)',                        CAST(agg.amtS  AS DECIMAL(18,2))),
        ('T',   'Partially Paid ($)',                                 CAST(agg.amtT  AS DECIMAL(18,2))),
        ('U',   'Insurance Balance ($)',                              CAST(agg.amtU  AS DECIMAL(18,2))),
        ('U.1', '  Denials',                                          CAST(agg.amtU1 AS DECIMAL(18,2))),
        ('U.2', '  Partially Denied',                                 CAST(agg.amtU2 AS DECIMAL(18,2))),
        ('U.3', '  No Response from Payor',                           CAST(agg.amtU3 AS DECIMAL(18,2))),
        ('V',   'Average Payment ($) - Total Pay/Billed Claims',      CAST(CASE WHEN agg.cntV > 0 THEN agg.sumV / agg.cntV ELSE 0 END AS DECIMAL(18,2))),
        ('W',   'Average Payment ($) - Total Pay/Paid Claims',        CAST(CASE WHEN agg.cntW > 0 THEN agg.sumW / agg.cntW ELSE 0 END AS DECIMAL(18,2))),
        ('X',   'Average Payment ($) - Total Pay/Adjudicated Claims', CAST(CASE WHEN agg.cntX > 0 THEN agg.sumX / agg.cntX ELSE 0 END AS DECIMAL(18,2)))
    ) v(RowCode, Description, MetricValue);

    -- ── G  Billed Mismatches (needs both #Base and #Lis) ─────────────────────
    -- Only computed when LIMSMaster was scanned (#Lis has live data).
    -- When @HasLisFilter = 0, #Lis is empty → G would be meaningless, so skip it.
    --
    -- PRE-AGGREGATED (same fix as D/E): the previous version JOINed #Base directly
    -- to #Lis on (year,month) and ran COUNT(DISTINCT ...) over the join result.
    -- Because many accessions share a month, that produced a per-month cross product
    -- (#Base_m × #Lis_m ≈ millions of rows) and the grand-total FULL JOIN multiplied
    -- the entire sets — which is what hung / terminated the query right after [LIS-9].
    -- Here each side is collapsed to ONE distinct-count per (year,month) first, then
    -- the two tiny results are joined 1:1. Result is identical; cost is negligible.
    IF @HasLisFilter = 1
    BEGIN
        PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-10] Building G (pre-agg)...';

        DROP TABLE IF EXISTS #GBase;
        SELECT ESYear, ESMonth,
               COUNT(DISTINCT CASE WHEN BillStatus IN ('Billed','Billed-Client','Billed - Client') THEN AccessionNumber END) AS BilledBase
        INTO   #GBase
        FROM   #Base
        GROUP BY ESYear, ESMonth;

        DROP TABLE IF EXISTS #GLis;
        SELECT LISYear AS ESYear, LISMonth AS ESMonth,
               COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Billed' THEN Accession END) AS BilledLis
        INTO   #GLis
        FROM   #Lis
        GROUP BY LISYear, LISMonth;

        -- Per-month: driven by #Base months (matches the old LEFT JOIN #Base→#Lis).
        INSERT INTO #LisRows (ESYear, ESMonth, RowCode, Description, MetricValue)
        SELECT b.ESYear, b.ESMonth, 'G', '  Billed Mismatches - Accessions NA / Other Sample',
               CAST(CASE WHEN b.BilledBase - ISNULL(l.BilledLis, 0) > 0
                         THEN b.BilledBase - ISNULL(l.BilledLis, 0) ELSE 0 END AS DECIMAL(18,2))
        FROM   #GBase b
        LEFT JOIN #GLis l ON l.ESYear = b.ESYear AND l.ESMonth = b.ESMonth
        UNION ALL
        -- Grand total (0,0): totals over ALL accessions — equivalent to the old
        -- FULL JOIN with no GROUP BY (total distinct billed base − total distinct billed LIS).
        SELECT 0, 0, 'G', '  Billed Mismatches - Accessions NA / Other Sample',
               CAST(CASE WHEN tb.TotBase - tl.TotLis > 0
                         THEN tb.TotBase - tl.TotLis ELSE 0 END AS DECIMAL(18,2))
        FROM   (SELECT COUNT(DISTINCT CASE WHEN BillStatus IN ('Billed','Billed-Client','Billed - Client') THEN AccessionNumber END) AS TotBase FROM #Base) tb
        CROSS JOIN (SELECT COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Billed' THEN Accession END) AS TotLis FROM #Lis) tl;

        DROP TABLE IF EXISTS #GBase;
        DROP TABLE IF EXISTS #GLis;
        PRINT CONVERT(VARCHAR(8), GETDATE(), 108) + ' [LIS-11] G done.';
    END

    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM
    (
        SELECT RowCode, 'LIS'  AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth, MetricValue, 1 AS CatOrder FROM #LisRows WHERE RowCode IN ('A','B','C','D','E') OR RowCode LIKE 'B.%' OR RowCode LIKE 'D.%' OR RowCode LIKE 'E.%'
        UNION ALL
        SELECT RowCode, 'PMS',  Description, ESYear, ESMonth, MetricValue, 2 FROM #LisRows WHERE RowCode IN ('F','G','H','I','J','K','L','M','N','N.1','N.2','N.3')
        UNION ALL
        SELECT RowCode, 'Cash', Description, ESYear, ESMonth, MetricValue, 3 FROM #LisRows WHERE RowCode IN ('O','P','Q','R','S','T','U','U.1','U.2','U.3')
        UNION ALL
        SELECT RowCode, 'Avg',  Description, ESYear, ESMonth, MetricValue, 4 FROM #LisRows WHERE RowCode IN ('V','W','X')
    ) result
    ORDER BY BillYear, BillMonth, CatOrder, RowCode;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #LisRows;
    DROP TABLE IF EXISTS #LisPanelTypes;
    DROP TABLE IF EXISTS #FilterPanels;
    DROP TABLE IF EXISTS #FilterClinics;
    DROP TABLE IF EXISTS #FilterProviders;
    DROP TABLE IF EXISTS #FilterReps;
END;
GO

PRINT '17_Cove_ExecutiveSummary_Read.sql completed.';
GO
