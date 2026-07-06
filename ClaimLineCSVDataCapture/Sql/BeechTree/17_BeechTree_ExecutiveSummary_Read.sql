-- ============================================================
-- BeechTree – Executive Summary Read SP
-- File : 17_BeechTree_ExecutiveSummary_Read.sql
-- DB   : BeechTree_LRN
--
-- Mirrors Augustus\17_Augustus_ExecutiveSummary_Read.sql.
--
-- usp_GetBT_ExecutiveSummary(@YearFrom,@YearTo,@MonthFrom,@MonthTo, ...)
--   @YearFrom/@YearTo/@MonthFrom/@MonthTo : INT = 0 (0 = unbounded)
--   @HasFilter = 1 if any parameter is non-zero / non-null.
--
-- No-filter path (fast read): UNION ALL of the 4 aggregate tables
-- (BeechTree_ES_LIS, BeechTree_ES_PMS, BeechTree_ES_Cash, BeechTree_ES_Avg).
--
-- Filtered path (live re-aggregation): re-derives ALL RowCodes from
-- dbo.LIMSMaster (LIS) and dbo.ClaimLevelData (PMS/Cash/Avg).
-- BillYear/BillMonth are now derived from the source date so month-wise
-- columns are preserved exactly as in the no-filter path.
--
-- Date mode (mirrors RisingTides, see @UseBilledDate): DOS and FirstBilledDate
-- are mutually exclusive filters that switch the period-basis column:
--   DOS mode (default)   : LIS -> LIMSMaster.RequestCollectDate
--                           PMS/Cash/Avg -> ClaimLevelData.DateofService
--   FirstBilledDate mode  : LIS -> LIMSMaster.AMDLBD
--                           PMS/Cash/Avg -> ClaimLevelData.FirstBilledDate
-- AMDLBD/FirstBilledDate have mixed content (real dates, text such as
-- 'Not Entered in AMD', and blanks) - TRY_CAST(... AS DATE) returns NULL for
-- the non-date content, so those rows are naturally excluded from billed-date
-- filtering/period bucketing automatically; no special-casing is needed.
--
-- BeechTree LIS column mapping (passed to dbo.LIMSMaster):
--   Accession   : AccessionNumber / VisitNumber / OrderID / Accession
--   DateofService (DOS)   : RequestCollectDate (priority 0)
--   FirstBilledDate       : AMDLBD (mixed date/text/blank — see above)
--   ClinicName            : Facility
--   Referring ProviderName: Provider
--   Resulted    : RessultedStatus / ResultedStatus / ...
--   ClaimStatus : ClaimStatus
--   BilledorNot : BilledorNot / BilledStatus / BilledUnbilled
--   ClientStatus: ClientStatus
--   SampleStatus: SampleStatus
--   PaymentMethod: PaymentMethod
--   PanelName   : PanelName / PanelName / Panelname / ...
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetBT_ExecutiveSummary
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
            FROM dbo.BeechTree_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
                   2, Id
            FROM dbo.BeechTree_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   3, Id
            FROM dbo.BeechTree_ES_Cash

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   4, Id
            FROM dbo.BeechTree_ES_Avg
        ) x
        ORDER BY BillYear, BillMonth, CatOrder, SortId;

        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  FILTERED  -  live re-aggregation with month-wise breakdown
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

    -- Date mode: DOS vs FirstBilledDate are mutually exclusive (same convention as
    -- RisingTides). @UseBilledDate = 1 -> FirstBilledDate filter is active
    -- (@BilledFrom/@BilledTo set, @DosFrom/@DosTo NULL) - LIS period basis switches
    -- from RequestCollectDate to AMDLBD, and the PMS/Cash/Avg period basis switches
    -- from DateofService to FirstBilledDate. @UseBilledDate = 0 -> DOS mode (or no
    -- date filter) - period basis stays RequestCollectDate / DateofService.
    DECLARE @UseBilledDate BIT = CASE
        WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
         AND  @DosFrom IS NULL AND @DosTo IS NULL
        THEN 1 ELSE 0 END;

    -- @HasLisFilter: 1 when any filter that applies to LIMSMaster is active.
    -- DOS date range (@DosFrom/@DosTo) is applied to LIMSMaster via RequestCollectDate;
    -- FirstBilledDate range (@UseBilledDate=1) is applied via AMDLBD.
    -- SalesRep is not tracked in LIMSMaster for BeechTree, so a Rep-only filter
    -- must NOT trigger a full LIMSMaster scan; the aggregate table is used instead.
    DECLARE @HasLisFilter BIT = CASE WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
                                       OR @DosFrom IS NOT NULL OR @DosTo IS NOT NULL
                                       OR @UseBilledDate = 1
                                       OR ISNULL(@YearFrom,0)  <> 0 OR ISNULL(@YearTo,0)    <> 0
                                       OR ISNULL(@MonthFrom,0) <> 0 OR ISNULL(@MonthTo,0)   <> 0
                                  THEN 1 ELSE 0 END;

    -- ── LIS: build #Lis from dbo.LIMSMaster, date-filtered on RequestCollectDate ──
    -- BillYear/BillMonth added so the filtered path produces month-wise rows.
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession      NVARCHAR(100) NOT NULL,
        Resulted       NVARCHAR(200) NOT NULL,
        ClaimStatus    NVARCHAR(200) NOT NULL,
        BilledorNot    NVARCHAR(200) NOT NULL,
        ClientStatus   NVARCHAR(200) NOT NULL,
        SampleStatus   NVARCHAR(200) NOT NULL,
        PaymentMethod  NVARCHAR(200) NOT NULL,
        PanelName      NVARCHAR(200) NOT NULL,
        BillYear       INT           NOT NULL,
        BillMonth      INT           NOT NULL
    );

    IF @HasLisFilter = 1 AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        DECLARE @AccCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('AccessionNumber','VisitNumber','OrderID','Accession','AccessionNo')
            ORDER BY CASE name
                WHEN 'AccessionNumber' THEN 0 WHEN 'VisitNumber' THEN 1
                WHEN 'OrderID' THEN 2 WHEN 'Accession' THEN 3 WHEN 'AccessionNo' THEN 4 ELSE 5 END);

        DECLARE @DateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('RequestCollectDate','ReqCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'RequestCollectDate' THEN 0 WHEN 'ReqCollectDate' THEN 1
                WHEN 'DateOfCollection'   THEN 2 WHEN 'DateofService'  THEN 3
                WHEN 'CollectionDate'     THEN 4 WHEN 'ServiceDate'    THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

        DECLARE @ResultedCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('RessultedStatus','ResultedStatus','ResultedNot','Resulted_Not','IsResulted','Resulted')
            ORDER BY CASE name
                WHEN 'RessultedStatus' THEN 0 WHEN 'ResultedStatus' THEN 1
                WHEN 'ResultedNot'     THEN 2 WHEN 'Resulted_Not'   THEN 3
                WHEN 'IsResulted'      THEN 4 WHEN 'Resulted'       THEN 5 ELSE 6 END);

        DECLARE @ClaimStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClaimStatus','ClaimStatusCode')
            ORDER BY CASE name WHEN 'ClaimStatus' THEN 0 ELSE 1 END);

        DECLARE @BilledorNotCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BilledorNot','BilledStatus','BilledUnbilled','BillOrNot')
            ORDER BY CASE name WHEN 'BilledorNot' THEN 0 WHEN 'BilledStatus' THEN 1 WHEN 'BilledUnbilled' THEN 2 ELSE 3 END);

        DECLARE @ClientStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClientStatus','ClientStatus1','ClientStatusCode')
            ORDER BY CASE name WHEN 'ClientStatus' THEN 0 ELSE 1 END);

        DECLARE @SampleStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('SampleStatus','Sample_Status','SampleStatusCode')
            ORDER BY CASE name WHEN 'SampleStatus' THEN 0 ELSE 1 END);

        DECLARE @PaymentMethodCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PaymentMethod','Payment_Method','PayMethod')
            ORDER BY CASE name WHEN 'PaymentMethod' THEN 0 ELSE 1 END);

        -- PanelCategory is the BeechTree-specific column for panel (priority 0)
        DECLARE @PanelNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','TestName','Test_Panel')
            ORDER BY CASE name
                WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1
                WHEN 'Panelname'     THEN 2 WHEN 'TestPanel'  THEN 3 ELSE 4 END);

        -- LIS dimension filter columns — BeechTree-specific mappings:
        --   Panels   -> PanelCategory   (reuses @PanelNameCol resolved above)
        --   Clinics  -> Facility
        --   Providers-> Provider
        --   SalesRep -> not available on LIMSMaster for BeechTree
        DECLARE @LisFacilityCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('Facility','FacilityName','ClinicName','Clinic')
            ORDER BY CASE name
                WHEN 'Facility' THEN 0 WHEN 'FacilityName' THEN 1 WHEN 'ClinicName' THEN 2 ELSE 3 END);

        DECLARE @LisProviderCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('Provider','ReferringProvider','ProviderName','PhysicianName')
            ORDER BY CASE name
                WHEN 'Provider' THEN 0 WHEN 'ReferringProvider' THEN 1 WHEN 'ProviderName' THEN 2 ELSE 3 END);

        -- FirstBilledDate -> AMDLBD (BeechTree LIMSMaster's billed-date column).
        -- PLEASE NOTE: this column has mixed content - real dates, the literal text
        -- 'Not Entered in AMD', and blanks. TRY_CAST(... AS DATE) returns NULL for the
        -- latter two, so those rows are naturally excluded from billed-date filtering/
        -- period bucketing below - no special-casing of the text value is needed.
        DECLARE @LisBilledDateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'AMDLBD');

        IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @ResultedCol IS NOT NULL
        BEGIN
            DECLARE @CSExpr  NVARCHAR(400) = CASE WHEN @ClaimStatusCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @ClaimStatusCol + N']),'''')))'   ELSE N'''''' END;
            DECLARE @BONExpr NVARCHAR(400) = CASE WHEN @BilledorNotCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @BilledorNotCol + N']),'''')))'   ELSE N'''''' END;
            DECLARE @CLExpr  NVARCHAR(400) = CASE WHEN @ClientStatusCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @ClientStatusCol + N']),'''')))'  ELSE N'''''' END;
            DECLARE @SSExpr  NVARCHAR(400) = CASE WHEN @SampleStatusCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @SampleStatusCol + N']),'''')))'  ELSE N'''''' END;
            DECLARE @PMExpr  NVARCHAR(400) = CASE WHEN @PaymentMethodCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @PaymentMethodCol + N']),'''')))'  ELSE N'''''' END;
            DECLARE @PTExpr  NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @PanelNameCol + N']),'''')))'      ELSE N'''''' END;

            -- LIS period basis:
            --   DOS mode (default)   -> TRY_CAST([@DateCol] AS DATE)   (RequestCollectDate)
            --   FirstBilledDate mode -> TRY_CAST([AMDLBD] AS DATE) — TRY_CAST returns NULL
            --     for the non-date content ('Not Entered in AMD' text, blanks), and the
            --     WHERE clause below requires the period expression to be NOT NULL, so
            --     those rows are naturally excluded rather than mis-parsed.
            DECLARE @LisPeriodExpr NVARCHAR(200) =
                CASE WHEN @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
                     THEN N'TRY_CAST([' + @LisBilledDateCol + N'] AS DATE)'
                     ELSE N'[' + @DateCol + N']' END;

            -- DOS date filter applies to LIMSMaster via @DateCol (RequestCollectDate);
            -- FirstBilledDate filter applies via AMDLBD. The two modes are mutually
            -- exclusive (see @UseBilledDate above), matching RisingTides.
            -- Dimension filters applied: Panels→PanelCategory, Clinics→Facility, Providers→Provider.
            -- SalesRep filter is skipped — column not present on LIMSMaster.
            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (Accession, Resulted, ClaimStatus, BilledorNot, ClientStatus, SampleStatus, PaymentMethod, PanelName, BillYear, BillMonth)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100),[' + @AccCol + N']))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @ResultedCol + N']),''''))),
                    ' + @CSExpr + N',
                    ' + @BONExpr + N',
                    ' + @CLExpr + N',
                    ' + @SSExpr + N',
                    ' + @PMExpr + N',
                    ' + @PTExpr + N',
                    ISNULL(YEAR (' + @LisPeriodExpr + N'), 0),
                    ISNULL(MONTH(' + @LisPeriodExpr + N'), 0)
                FROM dbo.LIMSMaster
                WHERE ' + @LisPeriodExpr + N' IS NOT NULL';

            -- Date predicate: DOS mode filters on RequestCollectDate (@DateCol);
            -- FirstBilledDate mode filters on AMDLBD (TRY_CAST — invalid/blank values
            -- already excluded by the period-basis bucketing above).
            IF @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iBilledFrom IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) >= @iBilledFrom)
                  AND (@iBilledTo   IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) <= @iBilledTo)';
            ELSE
                SET @LisSql = @LisSql + N'
                  AND (@iDosFrom IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) >= @iDosFrom)
                  AND (@iDosTo   IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) <= @iDosTo)';

            -- Year/month on RequestCollectDate (DOS mode) or AMDLBD (billed mode).
            SET @LisSql = @LisSql + N'
                  AND (ISNULL(@iYearFrom,0)=0  OR YEAR (' + @LisPeriodExpr + N') >= @iYearFrom)
                  AND (ISNULL(@iYearTo,0)=0    OR YEAR (' + @LisPeriodExpr + N') <= @iYearTo)
                  AND (ISNULL(@iMonthFrom,0)=0 OR MONTH(' + @LisPeriodExpr + N') >= @iMonthFrom)
                  AND (ISNULL(@iMonthTo,0)=0   OR MONTH(' + @LisPeriodExpr + N') <= @iMonthTo)';

            -- Panel filter: Panels → PanelCategory
            IF @PanelNameCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasPanelFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @PanelNameCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iPanels + '','') > 0)';

            -- Clinic filter: Clinics → Facility
            IF @LisFacilityCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasClinicFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisFacilityCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iClinics + '','') > 0)';

            -- Provider filter: Providers → Provider
            IF @LisProviderCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasProviderFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisProviderCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iProviders + '','') > 0)';

            SET @LisSql = @LisSql + N';';

            EXEC sp_executesql @LisSql,
                N'@iHasPanelFilter    BIT,           @iPanels    NVARCHAR(MAX),
                  @iHasClinicFilter   BIT,           @iClinics   NVARCHAR(MAX),
                  @iHasProviderFilter BIT,           @iProviders NVARCHAR(MAX),
                  @iDosFrom DATE, @iDosTo DATE,
                  @iBilledFrom DATE, @iBilledTo DATE,
                  @iYearFrom INT, @iYearTo INT, @iMonthFrom INT, @iMonthTo INT',
                @iHasPanelFilter    = @HasPanelFilter,    @iPanels    = @Panels,
                @iHasClinicFilter   = @HasClinicFilter,   @iClinics   = @Clinics,
                @iHasProviderFilter = @HasProviderFilter, @iProviders = @Providers,
                @iDosFrom = @DosFrom, @iDosTo = @DosTo,
                @iBilledFrom = @BilledFrom, @iBilledTo = @BilledTo,
                @iYearFrom = @YearFrom, @iYearTo = @YearTo,
                @iMonthFrom = @MonthFrom, @iMonthTo = @MonthTo;
        END
    END

    -- ── PMS/Cash/Avg: build #Base from dbo.ClaimLevelData, date-filtered ────
    -- BillYear/BillMonth added so the filtered path produces month-wise rows.
    -- Period basis now follows the same DOS vs FirstBilledDate mode as LIS
    -- (@UseBilledDate, declared above). Previously BillYear/BillMonth were ALWAYS
    -- derived from DateofService even when filtering by FirstBilledDate — rows that
    -- matched the FirstBilledDate WHERE bound still got bucketed under their
    -- (unrelated) DOS year/month, so a Billed-mode filter could show prior-period
    -- columns under a "DATA BASED ON BILLED DATE" header. Fixed by branching the
    -- period expression (and the date WHERE bound) on @UseBilledDate, mirroring
    -- RisingTides' #Base construction. Only the date-related logic changes here —
    -- Panel/Clinic/Provider/Rep filters are unchanged in both branches.
    --
    -- NOTE: #Base is pre-declared via CREATE TABLE (not SELECT...INTO) because SQL
    -- Server does not allow SELECT...INTO to target the same temp table name from
    -- two different branches of the same procedure, even when the branches are
    -- mutually exclusive at runtime ("There is already an object named '#Base'...").
    -- Both branches below use INSERT INTO instead, matching RisingTides' pattern.
    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        ClaimID              NVARCHAR(500) NOT NULL,
        BillYear             INT           NOT NULL,
        BillMonth            INT           NOT NULL,
        BillStatus           NVARCHAR(500) NOT NULL,
        ClaimStatus          NVARCHAR(500) NOT NULL,
        ChargeAmount         DECIMAL(18,2) NOT NULL,
        InsurancePayment     DECIMAL(18,2) NOT NULL,
        PatientPayment       DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL
    );

    IF @UseBilledDate = 0
    BEGIN
        INSERT INTO #Base (ClaimID, BillYear, BillMonth, BillStatus, ClaimStatus,
                            ChargeAmount, InsurancePayment, PatientPayment,
                            InsuranceAdjustments, PatientAdjustments,
                            InsuranceBalance, PatientBalance)
        SELECT
            ClaimID,
            ISNULL(YEAR (TRY_CAST(DateofService AS DATE)), 0)        AS BillYear,
            ISNULL(MONTH(TRY_CAST(DateofService AS DATE)), 0)        AS BillMonth,
            ISNULL(LTRIM(RTRIM(BilledUnbilled)), '')                 AS BillStatus,
            ISNULL(LTRIM(RTRIM(ClaimStatus)),    '')                 AS ClaimStatus,
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND (ISNULL(@YearFrom,0)=0  OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
          AND (ISNULL(@YearTo,0)=0    OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
          AND (ISNULL(@MonthFrom,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
          AND (ISNULL(@MonthTo,0)=0   OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
          AND (@DosFrom    IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo      IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(PanelName,         ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Panels + ',') > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Clinics + ',') > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Providers + ',') > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Reps + ',') > 0);
    END
    ELSE  -- @UseBilledDate = 1 : period + filter on FirstBilledDate (mixed date/text/blank — TRY_CAST excludes non-date rows)
    BEGIN
        INSERT INTO #Base (ClaimID, BillYear, BillMonth, BillStatus, ClaimStatus,
                            ChargeAmount, InsurancePayment, PatientPayment,
                            InsuranceAdjustments, PatientAdjustments,
                            InsuranceBalance, PatientBalance)
        SELECT
            ClaimID,
            ISNULL(YEAR (TRY_CAST(FirstBilledDate AS DATE)), 0)      AS BillYear,
            ISNULL(MONTH(TRY_CAST(FirstBilledDate AS DATE)), 0)      AS BillMonth,
            ISNULL(LTRIM(RTRIM(BilledUnbilled)), '')                 AS BillStatus,
            ISNULL(LTRIM(RTRIM(ClaimStatus)),    '')                 AS ClaimStatus,
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
          AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(PanelName,         ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Panels + ',') > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Clinics + ',') > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Providers + ',') > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Reps + ',') > 0)
        OPTION (RECOMPILE);
    END

    -- ── Populate #LisOut: aggregate (fast path) or live from #Lis (filtered path) ──
    -- When @HasLisFilter = 0 (SalesRep-only filter), LIMSMaster was not scanned
    -- above; LIS rows are served from the pre-built aggregate to stay responsive.
    DROP TABLE IF EXISTS #LisOut;
    CREATE TABLE #LisOut
    (
        RowCode     NVARCHAR(420) NOT NULL,
        Description NVARCHAR(420) NOT NULL,
        BillYear    INT           NOT NULL,
        BillMonth   INT           NOT NULL,
        MetricValue DECIMAL(18,2) NOT NULL
    );

    IF @HasLisFilter = 0
    BEGIN
        -- No LIS-applicable filter — serve directly from aggregate (fast)
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
        FROM dbo.BeechTree_ES_LIS
        WHERE (ESYear = 0 AND ESMonth = 0)
           OR ( (ISNULL(@YearFrom,0)=0  OR ESYear  >= @YearFrom)
            AND (ISNULL(@YearTo,0)=0    OR ESYear  <= @YearTo)
            AND (ISNULL(@MonthFrom,0)=0 OR ESMonth >= @MonthFrom)
            AND (ISNULL(@MonthTo,0)=0   OR ESMonth <= @MonthTo));
    END
    ELSE
    BEGIN
        -- LIS-applicable filter(s) active — build from #Lis (live LIMSMaster data)
        ;WITH Lis AS
        (
            SELECT 'A' AS RowCode, 'Total Samples' AS Description, BillYear, BillMonth,
               CAST(COUNT(*) AS DECIMAL(18,2)) AS MetricValue
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B', 'Billable Samples - Resulted', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2', '  Billed to Insurance', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClaimStatus='Billed' AND BilledorNot='Billed' AND ClientStatus='' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.1', '    Billed In AMD', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClaimStatus='Billed' AND BilledorNot='Billed' AND ClientStatus='' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B3', '  Not Entered in AMD', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B3.1', '    Received', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') AND SampleStatus='Received' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B3.2', '    Billing Review Required', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND SampleStatus='Received' AND ClientStatus='Billing Review Required' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B3.3', '    In Transit', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') AND SampleStatus='In Transit' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B3.4', '    Transferred', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') AND SampleStatus='Transferred' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B3.5', '    Collected', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') AND SampleStatus='Collected' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B4', '  Unbilled', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClaimStatus='Entered' AND BilledorNot='UnBilled' AND ClientStatus='' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B5', '  Client Bill', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Client Bill' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B5.1', '    Not Entered in AMD', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Client Bill' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B5.2', '    Billed', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Client Bill' AND BilledorNot='Billed' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B6', '  Self Pay', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Self Pay' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B6.1', '    Not Entered in AMD', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Self Pay' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B6.2', '    Billed', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Self Pay' AND BilledorNot='Billed' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B6.3', '    Entered', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Self Pay' AND ClaimStatus='Entered' AND BilledorNot='UnBilled' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B7', '  Test Entries', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Test Entries' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B7.1', '    Not Entered in AMD', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Test Entries' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B7.2', '    Billed', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Test Entries' AND BilledorNot='Billed' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B8', '  Rejected Sample', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Rejected Sample' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B8.1', '    Not Entered in AMD', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Rejected Sample' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B8.2', '    Billed', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND ClientStatus='Rejected Sample' AND BilledorNot='Billed' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B9', '  Payment Method No Bill', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Resulted' AND PaymentMethod='No Bill' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C', 'Not Resulted', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C1', '  No Result date on LIS but Billed', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Billed' AND BilledorNot='Billed' AND ClientStatus='' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C2', '  Not Entered in AMD', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C2.1', '    Received', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' AND SampleStatus='Received' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C2.2', '    In Transit', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' AND SampleStatus='In Transit' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C2.3', '    Collected', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' AND SampleStatus='Collected' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C2.4', '    Transferred', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' AND SampleStatus='Transferred' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C3', '  Client Bill', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClientStatus='Client Bill' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C4', '  Self Pay', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClientStatus='Self Pay' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C4.1', '    Not Entered in AMD', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClientStatus='Self Pay' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C4.2', '    Billed', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClientStatus='Self Pay' AND BilledorNot='Billed' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'D', 'Test Entries', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClientStatus='Test Entries' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'E', 'Rejected Sample', BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted='Not Resulted' AND ClientStatus='Rejected Sample' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        )
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT RowCode, Description, BillYear, BillMonth, MetricValue FROM Lis;

        -- B1.x  Panel sub-rows under B (Billable Samples / Resulted), one row per PanelName per period.
        -- PanelName in #Lis holds PanelCategory value (the column chosen during dynamic detection).
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT 'B1.' + LTRIM(RTRIM(PanelName)), '  ' + LTRIM(RTRIM(PanelName)),
               BillYear, BillMonth,
               CAST(SUM(CASE WHEN Resulted = 'Resulted' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Lis
        WHERE Resulted = 'Resulted' AND LTRIM(RTRIM(PanelName)) <> ''
        GROUP BY LTRIM(RTRIM(PanelName)), BillYear, BillMonth;
    END

    -- ────────────────────────────────────────────────────────────────────
    --  PMS  -  R, S, T, U, V, V.1..Vn (BTWOSummary), W, X, Y, Z, Z.1, Z.2, Z.3
    -- ────────────────────────────────────────────────────────────────────
    ;WITH PMS AS
    (
        SELECT 'R' AS RowCode, 'Billed - Includes all Claims Billed in AMD' AS Description, BillYear, BillMonth,
               CAST(SUM(CASE WHEN BillStatus='Billed' THEN 1 ELSE 0 END) AS DECIMAL(18,2)) AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'S', 'Billed Mismatches - Non Diagnose LIS Samples', BillYear, BillMonth,
               CAST(SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus='Billed amount 0' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'T', 'Unbilled - Entered to AMD - Yet to be released to Payer', BillYear, BillMonth,
               CAST(SUM(CASE WHEN BillStatus='UnBilled' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U', 'Fully Paid - Insurance Pay', BillYear, BillMonth,
               CAST(SUM(CASE WHEN ClaimStatus='Fully Paid' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        -- V  Fully Adjusted – SUM(MatchingCount) from BTWOSummary so the parent
        --    total equals the sum of its V.n sub-rows. Bucketed by
        --    BTWOSummary.DateofService to avoid double-counting.
        SELECT 'V', 'Fully Adjusted', p.BillYear, p.BillMonth,
               CAST(ISNULL(SUM(ws.MatchingCount), 0) AS DECIMAL(18,2))
        FROM (SELECT DISTINCT BillYear, BillMonth FROM #Base) p
        LEFT JOIN (
            SELECT
                ws2.MatchingCount,
                ISNULL(YEAR (TRY_CAST(ws2.DateofService AS DATE)), 0) AS WOYear,
                ISNULL(MONTH(TRY_CAST(ws2.DateofService AS DATE)), 0) AS WOMonth
            FROM dbo.BTWOSummary ws2
            JOIN (SELECT DISTINCT LTRIM(RTRIM(CAST(ClaimID AS NVARCHAR(50)))) AS ClaimID FROM #Base) b
                ON LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50)))) = b.ClaimID
            WHERE TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
        ) ws ON p.BillYear = ws.WOYear AND p.BillMonth = ws.WOMonth
        GROUP BY p.BillYear, p.BillMonth
        UNION ALL
        -- V.n  Fully Adjusted sub-rows – one per TransactionCodeCombined (A-Z order),
        --      period bucketed from BTWOSummary.DateofService.
        SELECT
            'V.' + CAST(ROW_NUMBER() OVER (PARTITION BY sub.BillYear, sub.BillMonth
                                           ORDER BY     sub.TransactionCodeCombined) AS NVARCHAR(10)),
            '  ' + sub.TransactionCodeCombined,
            sub.BillYear,
            sub.BillMonth,
            CAST(sub.MatchingCount AS DECIMAL(18,2))
        FROM (
            SELECT
                p.BillYear,
                p.BillMonth,
                ws.TransactionCodeCombined,
                SUM(ws.MatchingCount) AS MatchingCount
            FROM (SELECT DISTINCT BillYear, BillMonth FROM #Base) p
            JOIN (
                SELECT
                    ws2.ClaimID,
                    ws2.TransactionCodeCombined,
                    ws2.MatchingCount,
                    ISNULL(YEAR (TRY_CAST(ws2.DateofService AS DATE)), 0) AS WOYear,
                    ISNULL(MONTH(TRY_CAST(ws2.DateofService AS DATE)), 0) AS WOMonth
                FROM dbo.BTWOSummary ws2
                JOIN (SELECT DISTINCT LTRIM(RTRIM(CAST(ClaimID AS NVARCHAR(50)))) AS ClaimID FROM #Base) b
                    ON LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50)))) = b.ClaimID
                WHERE ws2.TransactionCodeCombined IS NOT NULL
                  AND TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
            ) ws ON p.BillYear = ws.WOYear AND p.BillMonth = ws.WOMonth
            GROUP BY p.BillYear, p.BillMonth, ws.TransactionCodeCombined
        ) sub
        UNION ALL
        SELECT 'W', 'Patient Responsibility', BillYear, BillMonth,
               CAST(SUM(CASE WHEN ClaimStatus='Pat Responsibility' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X', 'Partially Paid', BillYear, BillMonth,
               CAST(SUM(CASE WHEN ClaimStatus='Partial Paid' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'Y', 'Patient Payment', BillYear, BillMonth,
               CAST(SUM(CASE WHEN PatientPayment > 0 THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'Z', 'Insurance Balance', BillYear, BillMonth,
               CAST(SUM(CASE WHEN ClaimStatus IN ('Fully Denied','No Response','Partially Denied') THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'Z.1', '  Fully Denied', BillYear, BillMonth,
               CAST(SUM(CASE WHEN ClaimStatus='Fully Denied' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'Z.2', '  No Response', BillYear, BillMonth,
               CAST(SUM(CASE WHEN ClaimStatus='No Response' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'Z.3', '  Partially Denied', BillYear, BillMonth,
               CAST(SUM(CASE WHEN ClaimStatus='Partially Denied' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Cash  -  AA through AJ
    -- ────────────────────────────────────────────────────────────────────
    Cash AS
    (
        SELECT 'AA' AS RowCode, 'Total Billed ($)' AS Description, BillYear, BillMonth,
               SUM(CASE WHEN BillStatus='Billed' THEN ChargeAmount ELSE 0 END) AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'AB', 'Unbilled ($)', BillYear, BillMonth,
               SUM(CASE WHEN BillStatus='UnBilled' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'AC', 'Insurance Payment (fully paid) ($)', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus='Fully Paid' AND InsurancePayment>0 THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'AD', 'Partially Paid ($)', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus='Partial Paid' THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'AE', 'Patient Payment ($)', BillYear, BillMonth,
               SUM(CASE WHEN PatientPayment>0 THEN PatientPayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'AF', 'Fully Adjusted (Complete W/O)', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus='Fully Adjusted' THEN InsuranceAdjustments+PatientAdjustments ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'AG', 'Contractual Obligation W/O', BillYear, BillMonth,
               SUM(CASE WHEN InsuranceAdjustments>0 THEN InsuranceAdjustments ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'AH', 'Patient Balance ($)', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'AI', 'Patient WO', BillYear, BillMonth,
               SUM(CASE WHEN PatientAdjustments>0 THEN PatientAdjustments ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'AJ', 'Insurance Balance ($)', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus IN ('Fully Denied','No Response','Partially Denied') THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Avg  -  AK, AL, AM
    -- ────────────────────────────────────────────────────────────────────
    AvgRows AS
    (
        SELECT 'AK' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description, BillYear, BillMonth,
               CASE WHEN SUM(CASE WHEN BillStatus='Billed' THEN 1 ELSE 0 END) > 0
                    THEN SUM(CASE WHEN BillStatus='Billed' THEN InsurancePayment+PatientPayment ELSE 0 END)
                         / SUM(CASE WHEN BillStatus='Billed' THEN 1 ELSE 0 END)
                    ELSE 0 END AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth

        UNION ALL
        SELECT 'AL', 'Average Payment ($) - Total Pay/Paid Claims', BillYear, BillMonth,
               CASE WHEN SUM(CASE WHEN ClaimStatus='Fully Paid' THEN 1 ELSE 0 END) > 0
                    THEN SUM(CASE WHEN ClaimStatus='Fully Paid' THEN InsurancePayment+PatientPayment ELSE 0 END)
                         / SUM(CASE WHEN ClaimStatus='Fully Paid' THEN 1 ELSE 0 END)
                    ELSE 0 END
        FROM #Base GROUP BY BillYear, BillMonth

        UNION ALL
        SELECT 'AM', 'Average Payment ($) - Total Pay/Adjudicated Claims', BillYear, BillMonth,
               CASE WHEN SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN 1 ELSE 0 END) > 0
                    THEN SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN InsurancePayment+PatientPayment ELSE 0 END)
                         / SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN 1 ELSE 0 END)
                    ELSE 0 END
        FROM #Base GROUP BY BillYear, BillMonth
    )
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM
    (
        SELECT RowCode, 'LIS'  AS Category, Description, BillYear, BillMonth, MetricValue, 1 AS CatOrder FROM #LisOut
        UNION ALL
        SELECT RowCode, 'PMS',  Description, BillYear, BillMonth, MetricValue, 2 FROM PMS
        UNION ALL
        SELECT RowCode, 'Cash', Description, BillYear, BillMonth, MetricValue, 3 FROM Cash
        UNION ALL
        SELECT RowCode, 'Avg',  Description, BillYear, BillMonth, MetricValue, 4 FROM AvgRows
    ) result
    ORDER BY BillYear, BillMonth, CatOrder, RowCode;

    DROP TABLE IF EXISTS #LisOut;
    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '17_BeechTree_ExecutiveSummary_Read.sql completed.';
GO
