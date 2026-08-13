-- ============================================================
-- NorthWest – Executive Summary Read SP
-- File : 31_NW_ExecutiveSummary_Read.sql
-- DB   : NWL_LRN
--
-- usp_GetNW_ExecutiveSummary(@YearFrom,@YearTo,@MonthFrom,@MonthTo,...)
--   @HasFilter = 0                      → fast read from 4 NW_ES_ aggregate tables.
--   Date / Rep filter only              → PMS+Cash+Avg live from ClaimLevelData;
--                                         LIS from NW_ES_LIS (period-filtered).
--   Panel / Clinic / Provider filter    → additionally re-aggregates LIS live from
--                                         LIMSMaster via #LisBase (dimension- AND
--                                         DateofService-filtered). Columns: PanelType,
--                                         ClinicName, ReferringProvider. SalesRep skipped.
--
-- Lisbreakdown (LIMSMaster) field mapping — confirmed in
-- LabMetricsDashboard\Sql\LIMSScript\LAB_Filter_Reference_Script.sql (NWL_LRN block):
--   Panel                -> PanelType
--   DateofService         -> RequestCollectDate
--   ClinicName            -> ClinicName
--   ReferringProviderName -> ReferringProvider
--   FirstBilledDate       -> N/A. LIMSMaster has no FirstBilledDate column, so
--                            @BilledFrom/@BilledTo are NEVER applied to the LIS/
--                            LIMSMaster path (#LisBase below). FirstBilledDate
--                            (and DateofService range re-filtering beyond the
--                            period bucket) only affect the PMS/Cash/Avg section
--                            (#Base, built from ClaimLevelData) further down.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_ExecutiveSummary
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
    --  NO FILTER  –  fast read from the 4 aggregate tables
    -- ════════════════════════════════════════════════════════════════════
    IF @HasFilter = 0
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
        FROM
        (
            SELECT RoleID AS RowCode, 'LIS'  AS Category, Description,
                   ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue,
                   1 AS CatOrder, Id AS SortId
            FROM dbo.NW_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   -- Aria % rows store the ratio in ESMonthChargeAmount (ClaimCount is INT → would truncate to 0)
                   CASE WHEN RoleID IN ('S.1.AP','S.3.AP')
                        THEN ESMonthChargeAmount
                        ELSE CAST(ESMonthClaimCount AS DECIMAL(18,2)) END,
                   2, Id
            FROM dbo.NW_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount, 3, Id
            FROM dbo.NW_ES_Cash

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount, 4, Id
            FROM dbo.NW_ES_Avg
        ) x
        ORDER BY BillYear, BillMonth, CatOrder, SortId;
        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  FILTERED  –  live re-aggregate for date-range slice
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

    -- ── LIS dimension filter via LIMSMaster ──────────────────────────────
    --    When Panel / Clinic / Provider filter is active, re-aggregate LIS
    --    live from dbo.LIMSMaster (filtered) instead of the pre-built
    --    aggregate table.  The DateofService range (@DosFrom/@DosTo) IS applied
    --    to LIMSMaster's resolved date column below.  SalesRep is not available
    --    for NW LIS — skipped.
    --    Column logic mirrors usp_RefreshNW_ExecutiveSummary_LIS_Alt (file 33).
    -- ─────────────────────────────────────────────────────────────────────
    DECLARE @HasLisFilter BIT = CASE
        WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
        THEN 1 ELSE 0 END;

    -- #LisBase: mirrors #LisBase in the refresh SP (file 33).
    -- Populated from LIMSMaster when @HasLisFilter = 1; empty otherwise.
    DROP TABLE IF EXISTS #LisBase;
    CREATE TABLE #LisBase
    (
        OrderID                 NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear                  INT           NOT NULL,
        ESMonth                 INT           NOT NULL,
        IncorrectDOS            NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
        BilledTo                NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        BillStatus              NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        FinalStatus             NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        Source                  NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ChargesNotEnteredStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PanelName               NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL
    );

    DECLARE @LisMasterFiltered BIT = 0;

    IF @HasLisFilter = 1 AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        -- ── Column detection (same priority order as file 33) ──────────────
        DECLARE @LisOrderIDCol  SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('OrderID','OrderId','AccessionNumber','Accession')
            ORDER BY CASE name WHEN 'OrderID' THEN 0 WHEN 'OrderId' THEN 1 WHEN 'AccessionNumber' THEN 2 ELSE 3 END);
        -- DateofService for NW maps to LIMSMaster.RequestCollectDate (confirmed in
        -- LabMetricsDashboard\Sql\LIMSScript\LAB_Filter_Reference_Script.sql, NWL_LRN block).
        -- RequestCollectDate is given top priority so an unrelated column (e.g. a
        -- generic record-creation timestamp) can never silently outrank it.
        DECLARE @LisDateCol     SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('RequestCollectDate','ReqCollectDate','Entry_DateCreated','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name WHEN 'RequestCollectDate' THEN 0 WHEN 'ReqCollectDate' THEN 1 WHEN 'Entry_DateCreated' THEN 2
                WHEN 'DateOfCollection' THEN 3 WHEN 'DateofService' THEN 4 WHEN 'CollectionDate' THEN 5
                WHEN 'ServiceDate' THEN 6 WHEN 'AccessionDate' THEN 7 ELSE 8 END);
        DECLARE @LisIncorrectDOSCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('IncorrectDOS','IncorrectDos','Incorrect_DOS','BadDOS')
            ORDER BY CASE name WHEN 'IncorrectDOS' THEN 0 WHEN 'IncorrectDos' THEN 1 WHEN 'Incorrect_DOS' THEN 2 ELSE 3 END);
        DECLARE @LisBilledToCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('BilledTo','BillTo','Billed_To')
            ORDER BY CASE name WHEN 'BilledTo' THEN 0 WHEN 'BillTo' THEN 1 ELSE 2 END);
        DECLARE @LisBillStatusCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('BillStatus','BillingStatus','Bill_Status')
            ORDER BY CASE name WHEN 'BillStatus' THEN 0 WHEN 'BillingStatus' THEN 1 ELSE 2 END);
        DECLARE @LisFinalStatusCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('FinalStatus','Final_Status','SubStatus','Status')
            ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'Final_Status' THEN 1 WHEN 'SubStatus' THEN 2 ELSE 3 END);
        DECLARE @LisSourceCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('Source','ClaimSource','System_Source')
            ORDER BY CASE name WHEN 'Source' THEN 0 WHEN 'ClaimSource' THEN 1 ELSE 2 END);
        DECLARE @LisChargesNotCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('ChargesNotEnteredStatus','ChargesNotEntered','NotEnteredStatus')
            ORDER BY CASE name WHEN 'ChargesNotEnteredStatus' THEN 0 WHEN 'ChargesNotEntered' THEN 1 ELSE 2 END);
        -- Panel display/grouping column for NW mirrors the Panel filter column
        -- (PanelType — confirmed in LAB_Filter_Reference_Script.sql, NWL_LRN block:
        -- "PanelType [Panel Name]"), so the B.{PanelName} breakdown rows line up
        -- with whatever the user selects in the Panel filter.
        DECLARE @LisPanelNameCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('PanelType','LRNPanelName','PanelName','Panelname','Panel','TestPanel')
            ORDER BY CASE name WHEN 'PanelType' THEN 0 WHEN 'LRNPanelName' THEN 1 WHEN 'PanelName' THEN 2
                WHEN 'Panelname' THEN 3 WHEN 'Panel' THEN 4 ELSE 5 END);

        -- Dimension filter columns (separate from the sub-row label column above).
        -- Panel filter uses PanelType per spec; Clinic uses ClinicName; Provider uses ReferringProvider.
        DECLARE @LisPanelFilterCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('PanelType','PanelCategory','PanelName','Panelname','Panel','TestPanel')
            ORDER BY CASE name WHEN 'PanelType' THEN 0 WHEN 'PanelCategory' THEN 1 WHEN 'PanelName' THEN 2
                WHEN 'Panelname' THEN 3 WHEN 'Panel' THEN 4 ELSE 5 END);
        DECLARE @LisFacilityCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('ClinicName','Facility','FacilityName','Clinic','FacilityID')
            ORDER BY CASE name WHEN 'ClinicName' THEN 0 WHEN 'Facility' THEN 1 WHEN 'FacilityName' THEN 2
                WHEN 'Clinic' THEN 3 WHEN 'FacilityID' THEN 4 ELSE 5 END);
        DECLARE @LisProviderCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
            AND name IN ('ReferringProvider','Provider','PhysicianName','ProviderName','ReferringPhysician')
            ORDER BY CASE name WHEN 'ReferringProvider' THEN 0 WHEN 'Provider' THEN 1 WHEN 'PhysicianName' THEN 2
                WHEN 'ProviderName' THEN 3 WHEN 'ReferringPhysician' THEN 4 ELSE 5 END);

        -- Required base columns must be present; each active filter must have its column.
        IF @LisOrderIDCol IS NOT NULL AND @LisDateCol IS NOT NULL
           AND @LisIncorrectDOSCol IS NOT NULL AND @LisBilledToCol IS NOT NULL
           AND (@HasPanelFilter    = 0 OR @LisPanelFilterCol IS NOT NULL)
           AND (@HasClinicFilter   = 0 OR @LisFacilityCol    IS NOT NULL)
           AND (@HasProviderFilter = 0 OR @LisProviderCol    IS NOT NULL)
        BEGIN
            DECLARE @LisBsExpr  NVARCHAR(300) = CASE WHEN @LisBillStatusCol  IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @LisBillStatusCol  + N'])),'''')' ELSE N'''''' END;
            DECLARE @LisFsExpr  NVARCHAR(300) = CASE WHEN @LisFinalStatusCol IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @LisFinalStatusCol + N'])),'''')' ELSE N'''''' END;
            DECLARE @LisSrcExpr NVARCHAR(300) = CASE WHEN @LisSourceCol      IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @LisSourceCol      + N'])),'''')' ELSE N'''''' END;
            DECLARE @LisCnsExpr NVARCHAR(300) = CASE WHEN @LisChargesNotCol  IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @LisChargesNotCol  + N'])),'''')' ELSE N'''''' END;
            DECLARE @LisPnExpr  NVARCHAR(300) = CASE WHEN @LisPanelNameCol   IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @LisPanelNameCol   + N'])),'''')' ELSE N'''''' END;

            DECLARE @LisBaseSql NVARCHAR(MAX) = N'
            INSERT INTO #LisBase
            SELECT
                LTRIM(RTRIM(ISNULL([' + @LisOrderIDCol + N'],''''))),
                YEAR (TRY_CAST([' + @LisDateCol + N'] AS DATE)),
                MONTH(TRY_CAST([' + @LisDateCol + N'] AS DATE)),
                ISNULL(LTRIM(RTRIM([' + @LisIncorrectDOSCol + N'])),''''),
                ISNULL(LTRIM(RTRIM([' + @LisBilledToCol + N'])),''''),
                ' + @LisBsExpr + N',
                ' + @LisFsExpr + N',
                ' + @LisSrcExpr + N',
                ' + @LisCnsExpr + N',
                ' + @LisPnExpr + N'
            FROM dbo.LIMSMaster
            WHERE TRY_CAST([' + @LisDateCol + N'] AS DATE) IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(ISNULL([' + @LisOrderIDCol + N'],''''))),'''') IS NOT NULL';

            -- DOS date predicates applied to LIMSMaster via resolved date column.
            SET @LisBaseSql += N'
              AND (@iDosFrom IS NULL OR TRY_CAST([' + @LisDateCol + N'] AS DATE) >= @iDosFrom)
              AND (@iDosTo   IS NULL OR TRY_CAST([' + @LisDateCol + N'] AS DATE) <= @iDosTo)';

            -- Dimension predicates (COLLATE DATABASE_DEFAULT prevents collation conflicts).
            -- COLLATE DATABASE_DEFAULT prevents collation conflicts in CHARINDEX.
            IF @HasPanelFilter = 1 AND @LisPanelFilterCol IS NOT NULL
                SET @LisBaseSql += N'
              AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300),[' + @LisPanelFilterCol + N']),''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iPanels + '','') COLLATE DATABASE_DEFAULT) > 0';

            IF @HasClinicFilter = 1 AND @LisFacilityCol IS NOT NULL
                SET @LisBaseSql += N'
              AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300),[' + @LisFacilityCol + N']),''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iClinics + '','') COLLATE DATABASE_DEFAULT) > 0';

            IF @HasProviderFilter = 1 AND @LisProviderCol IS NOT NULL
                SET @LisBaseSql += N'
              AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300),[' + @LisProviderCol + N']),''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iProviders + '','') COLLATE DATABASE_DEFAULT) > 0';

            SET @LisBaseSql += N';';

            EXEC sp_executesql @LisBaseSql,
                N'@iPanels NVARCHAR(MAX), @iClinics NVARCHAR(MAX), @iProviders NVARCHAR(MAX), @iDosFrom DATE, @iDosTo DATE',
                @iPanels = @Panels, @iClinics = @Clinics, @iProviders = @Providers, @iDosFrom = @DosFrom, @iDosTo = @DosTo;

            SET @LisMasterFiltered = 1;
        END
    END

    -- #LisPeriods: distinct periods from filtered LIMSMaster.
    -- NOTE: No (0,0) grand-total sentinel — NW filtered path does not produce grand totals.
    DROP TABLE IF EXISTS #LisPeriods;
    CREATE TABLE #LisPeriods (ESYear INT NOT NULL, ESMonth INT NOT NULL);

    -- #LisPanels: distinct panel names for B.{PanelName} sub-rows.
    DROP TABLE IF EXISTS #LisPanels;
    CREATE TABLE #LisPanels (PanelName NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);

    IF @LisMasterFiltered = 1
    BEGIN
        INSERT INTO #LisPeriods (ESYear, ESMonth)
        SELECT DISTINCT ESYear, ESMonth FROM #LisBase;

        INSERT INTO #LisPanels (PanelName)
        SELECT DISTINCT PanelName FROM #LisBase WHERE IncorrectDOS = '' AND BilledTo = 'Insurance Bill' AND PanelName <> '';
    END

    -- #LisOut: final LIS rows served to the UNION ALL below.
    -- Widened RowCode/Description to accommodate B.{PanelName} sub-row codes.
    DROP TABLE IF EXISTS #LisOut;
    CREATE TABLE #LisOut
    (
        RowCode     NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
        Description NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear      INT           NOT NULL,
        ESMonth     INT           NOT NULL,
        MetricValue DECIMAL(18,2) NOT NULL
    );

    IF @LisMasterFiltered = 1
    BEGIN
        -- Live aggregation from #LisBase — row logic mirrors usp_RefreshNW_ExecutiveSummary_LIS_Alt (file 33).
        INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
        SELECT RowCode, Description, ESYear, ESMonth, CAST(SampleCount AS DECIMAL(18,2))
        FROM
        (
            -- A  Total No. of Samples (all rows, no IncorrectDOS filter)
            SELECT p.ESYear, p.ESMonth, 'A' AS RowCode, 'Total No. of Samples' AS Description,
                   COUNT(DISTINCT l.OrderID) AS SampleCount
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- B  Billable Samples
            SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- C  No. of Billed Claims
            SELECT p.ESYear, p.ESMonth, 'C', 'No. of Billed Claims',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Billed' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- C.1
            SELECT p.ESYear, p.ESMonth, 'C.1', '  Claim Submitted in Webpm',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Billed' AND l.FinalStatus='Claim Submitted in Webpm' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- C.2
            SELECT p.ESYear, p.ESMonth, 'C.2', '  Claim Submitted in Daqbilling',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Billed' AND l.FinalStatus='Claim Submitted in Daqbilling' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- C.3
            SELECT p.ESYear, p.ESMonth, 'C.3', '  Claim Submitted in Daq & Webpm',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Billed' AND l.FinalStatus='Claim Submitted in Daq & Webpm' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- C.4
            SELECT p.ESYear, p.ESMonth, 'C.4', '  Non Billable - Excluded Organizations',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Billed' AND l.FinalStatus='Non Billable - Excluded Organizations' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- C.5
            SELECT p.ESYear, p.ESMonth, 'C.5', '  Manually Pushed in Emedix',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Billed' AND l.FinalStatus='Manually Pushed in Emedix' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D  No. of Unbilled Claims
            SELECT p.ESYear, p.ESMonth, 'D', 'No. of Unbilled Claims',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.1
            SELECT p.ESYear, p.ESMonth, 'D.1', '  Unbilled - Charge Not Created',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Charge Not Created' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.1.W
            SELECT p.ESYear, p.ESMonth, 'D.1.W', '    Charge Not Created - Webpm',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Charge Not Created' AND l.Source='Webpm' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.1.NC
            SELECT p.ESYear, p.ESMonth, 'D.1.NC', '    Charge Not Created - No Charges found in Webpm',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Charge Not Created' AND l.ChargesNotEnteredStatus='No Charges found in Webpm' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.1.UP
            SELECT p.ESYear, p.ESMonth, 'D.1.UP', '    Charge Not Created - Unposted Charges in Webpm',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Charge Not Created' AND l.ChargesNotEnteredStatus='Unposted Charges in Webpm' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.1.DQ
            SELECT p.ESYear, p.ESMonth, 'D.1.DQ', '    Charge Not Created - Daqbilling',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Charge Not Created' AND l.Source='Daqbilling' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.2
            SELECT p.ESYear, p.ESMonth, 'D.2', '  Unbilled - Non Billable (Excluded PAP Codes)',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Non Billable - Excluded PAP Codes' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.3
            SELECT p.ESYear, p.ESMonth, 'D.3', '  Unbilled - Non Billable (Excluded Validity Codes)',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Non Billable - Excluded Validity Codes' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.4
            SELECT p.ESYear, p.ESMonth, 'D.4', '  Unbilled - Non Billable (Excluded Organizations)',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Non Billable - Excluded Organizations' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.5
            SELECT p.ESYear, p.ESMonth, 'D.5', '  Unbilled - Charges Created and Not Submitted',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Charges Created and Not Submitted' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.5.W
            SELECT p.ESYear, p.ESMonth, 'D.5.W', '    Charges Not Submitted - Webpm',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Charges Created and Not Submitted' AND l.Source='Webpm' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- D.5.DQ
            SELECT p.ESYear, p.ESMonth, 'D.5.DQ', '    Charges Not Submitted - Daqbilling',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Insurance Bill' AND l.BillStatus='Unbilled' AND l.FinalStatus='Charges Created and Not Submitted' AND l.Source='Daqbilling' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- E  No. of ADCS Claims
            SELECT p.ESYear, p.ESMonth, 'E', 'No. of ADCS Claims',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='ADCS Claims' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- F  No. of Other Claims
            SELECT p.ESYear, p.ESMonth, 'F', 'No. of Other Claims',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo NOT IN ('Insurance Bill','ADCS Claims') THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- F.1
            SELECT p.ESYear, p.ESMonth, 'F.1', '  Other - Yet to be validate',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Yet to be validate' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- F.2
            SELECT p.ESYear, p.ESMonth, 'F.2', '  Other - Self pay',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Self pay' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- F.3
            SELECT p.ESYear, p.ESMonth, 'F.3', '  Other - Client Bills',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Client Bills' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- F.4
            SELECT p.ESYear, p.ESMonth, 'F.4', '  Other - System Test',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='System Test' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth

            UNION ALL
            -- F.5
            SELECT p.ESYear, p.ESMonth, 'F.5', '  Other - Rejections',
                   COUNT(DISTINCT CASE WHEN l.IncorrectDOS='' AND l.BilledTo='Rejections' THEN l.OrderID END)
            FROM #LisPeriods p LEFT JOIN #LisBase l ON (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)
            GROUP BY p.ESYear, p.ESMonth
        ) lis_rows;

        -- B.{PanelName} panel sub-rows (collapses under Row B in the dashboard).
        INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
        SELECT 'B.' + pn.PanelName, '  ' + pn.PanelName,
               p.ESYear, p.ESMonth, CAST(COUNT(DISTINCT l.OrderID) AS DECIMAL(18,2))
        FROM #LisPanels pn
        CROSS JOIN #LisPeriods p
        LEFT JOIN #LisBase l
               ON l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth
              AND l.IncorrectDOS = '' AND l.BilledTo = 'Insurance Bill'
              AND l.PanelName COLLATE DATABASE_DEFAULT = pn.PanelName COLLATE DATABASE_DEFAULT
        GROUP BY pn.PanelName, p.ESYear, p.ESMonth;
    END
    ELSE
    BEGIN
        -- No LIS dimension filter: serve from pre-built aggregate table with period filter.
        -- (ESYear<>0 excludes grand-total rows.)
        --
        -- NULL-safe year/month predicates: the UI sends @YearFrom/@YearTo/@MonthFrom/@MonthTo
        -- as NULL (not 0) whenever the user filters by a DateofService range instead of
        -- Year/Month.  Without ISNULL, "@YearFrom = 0" is UNKNOWN and "ESYear >= @YearFrom"
        -- is UNKNOWN, so every LIS row was silently dropped (no LIS breakdown rows).
        --
        -- DateofService range is also mapped onto the (ESYear,ESMonth) period key so a
        -- DOS-only filter correctly restricts LIS to the selected months and lines its
        -- columns up with the PMS/Cash/Avg path.  ESYear/ESMonth derive from the LIMSMaster
        -- collection date in usp_RefreshNW_ExecutiveSummary_LIS_Alt (file 33).
        INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
        SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
        FROM dbo.NW_ES_LIS
        WHERE (ISNULL(@YearFrom, 0)=0  OR ESYear  >= @YearFrom)
          AND (ISNULL(@YearTo,   0)=0  OR ESYear  <= @YearTo)
          AND (ISNULL(@MonthFrom,0)=0  OR ESMonth >= @MonthFrom)
          AND (ISNULL(@MonthTo,  0)=0  OR ESMonth <= @MonthTo)
          AND (@DosFrom IS NULL OR (ESYear*100 + ESMonth) >= (YEAR(@DosFrom)*100 + MONTH(@DosFrom)))
          AND (@DosTo   IS NULL OR (ESYear*100 + ESMonth) <= (YEAR(@DosTo)*100   + MONTH(@DosTo)))
          AND ESYear<>0;
    END

    -- ── ClaimLevelData column detection ──────────────────────────────────
    DECLARE @BilledCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('Billed','BillStatus','BillingStatus','BilledStatus')
        ORDER BY CASE name WHEN 'Billed' THEN 0 WHEN 'BillStatus' THEN 1 WHEN 'BillingStatus' THEN 2 ELSE 3 END);

    -- Fallback date columns used to derive Billed status when @BilledCol IS NULL
    -- (mirrors usp_RefreshNW_ExecutiveSummary / file 30)
    DECLARE @FirstBillDateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('FirstBillDate','FirstBilledDate','First_Bill_Date','FirstBilled')
        ORDER BY CASE name WHEN 'FirstBillDate' THEN 0 WHEN 'FirstBilledDate' THEN 1
                           WHEN 'First_Bill_Date' THEN 2 ELSE 3 END);

    -- ARIA age uses Last Billed Date when present; else FirstBilledDate (mirrors file 30).
    DECLARE @LastBillDateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('LastBillDate','LastBilledDate','Last_Bill_Date','LastBilled','LastBill')
        ORDER BY CASE name
            WHEN 'LastBillDate' THEN 0 WHEN 'LastBilledDate' THEN 1
            WHEN 'Last_Bill_Date' THEN 2 WHEN 'LastBilled' THEN 3 ELSE 4 END);

    DECLARE @EmedixSubDateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('EmedixSubmissionDate','EmedixSubmitDate','Emedix_Submission_Date','EmedixDate')
        ORDER BY CASE name WHEN 'EmedixSubmissionDate' THEN 0 WHEN 'EmedixSubmitDate' THEN 1
                           WHEN 'Emedix_Submission_Date' THEN 2 ELSE 3 END);

    -- Build the Billed expression — MUST match usp_RefreshNW_ExecutiveSummary production logic:
    --   BilledStatus column exists but is NOT populated for NW.
    --   Derive 'Billed'/'Unbilled' from FirstBilledDate / EmedixSubmissionDate (date columns).
    --   BilledStatus / BillStatus column is used only as a last resort when no date columns exist.
    --   Output: always 'Billed' or 'Unbilled' — same values the aggregate table was built from.
    DECLARE @BilledExpr NVARCHAR(MAX) =
        CASE
            -- Priority 1: derive from date columns (matches production aggregate SP)
            WHEN @FirstBillDateCol IS NOT NULL OR @EmedixSubDateCol IS NOT NULL
                THEN
                    N'CASE'
                    + CASE WHEN @FirstBillDateCol IS NOT NULL
                           THEN N' WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50),[' + @FirstBillDateCol + N']),''''))),'''') IS NOT NULL THEN ''Billed'''
                           ELSE N'' END
                    + CASE WHEN @EmedixSubDateCol IS NOT NULL
                           THEN N' WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50),[' + @EmedixSubDateCol + N']),''''))),'''') IS NOT NULL THEN ''Billed'''
                           ELSE N'' END
                    + N' ELSE ''Unbilled'' END'
            -- Priority 2: BilledStatus / Billed column (only if no date columns found)
            WHEN @BilledCol IS NOT NULL
                THEN N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')'
            ELSE NULL
        END;

    DECLARE @ClaimTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('ClaimType','ClaimCategory')
        ORDER BY CASE name WHEN 'ClaimType' THEN 0 ELSE 1 END);

    DECLARE @ActualPayCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('ActualPayment','ActualPay')
        ORDER BY CASE name WHEN 'ActualPayment' THEN 0 ELSE 1 END);

    DECLARE @DupPayCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('DuplicatePayment','DuplicatePay')
        ORDER BY CASE name WHEN 'DuplicatePayment' THEN 0 ELSE 1 END);

    -- Build #Base for filtered path
    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        AccessionNumber  NVARCHAR(100) NOT NULL,
        ESYear           INT NOT NULL, ESMonth INT NOT NULL,
        Billed           NVARCHAR(50)  NOT NULL,
        ClaimType        NVARCHAR(200) NOT NULL,
        ClaimStatus      NVARCHAR(200) NOT NULL,
        FirstBilledDate  DATE          NULL,
        LastBilledDate   DATE          NULL,
        ChargeAmount     DECIMAL(18,2) NOT NULL,
        InsurancePayment DECIMAL(18,2) NOT NULL,
        ActualPayment    DECIMAL(18,2) NOT NULL,
        DuplicatePayment DECIMAL(18,2) NOT NULL,
        PatientPayment   DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceBalance DECIMAL(18,2) NOT NULL,
        PatientBalance   DECIMAL(18,2) NOT NULL
    );

    IF @BilledExpr IS NOT NULL AND @ClaimTypeCol IS NOT NULL
    BEGIN
        DECLARE @ActExpr NVARCHAR(300) = CASE WHEN @ActualPayCol IS NOT NULL
            THEN N'ISNULL(TRY_CAST([' + @ActualPayCol + N'] AS DECIMAL(18,2)),0)' ELSE N'0' END;
        DECLARE @DupExpr NVARCHAR(300) = CASE WHEN @DupPayCol IS NOT NULL
            THEN N'ISNULL(TRY_CAST([' + @DupPayCol + N'] AS DECIMAL(18,2)),0)' ELSE N'0' END;

        -- BilledDate predicate: use the dynamically-detected column so the query
        -- does not fail when FirstBilledDate does not exist in ClaimLevelData.
        DECLARE @BfPred NVARCHAR(300) =
            CASE WHEN @FirstBillDateCol IS NOT NULL
                 THEN N'(@bf IS NULL OR TRY_CAST([' + @FirstBillDateCol + N'] AS DATE) >= @bf)'
                 ELSE N'(1=1)' END;
        DECLARE @BtPred NVARCHAR(300) =
            CASE WHEN @FirstBillDateCol IS NOT NULL
                 THEN N'(@bt IS NULL OR TRY_CAST([' + @FirstBillDateCol + N'] AS DATE) <= @bt)'
                 ELSE N'(1=1)' END;

        -- FirstBilledDate captured for ARIA age (anchor day + 30-day lookback).
        -- LastBilledDate kept for parity with aggregate #Base shape.
        DECLARE @FBDExpr NVARCHAR(300) = CASE WHEN @FirstBillDateCol IS NOT NULL
            THEN N'TRY_CAST([' + @FirstBillDateCol + N'] AS DATE)'
            ELSE N'CAST(NULL AS DATE)' END;
        DECLARE @LBDExpr NVARCHAR(300) = CASE
            WHEN @LastBillDateCol IS NOT NULL
                THEN N'TRY_CAST([' + @LastBillDateCol + N'] AS DATE)'
            WHEN @FirstBillDateCol IS NOT NULL
                THEN N'TRY_CAST([' + @FirstBillDateCol + N'] AS DATE)'
            ELSE N'CAST(NULL AS DATE)' END;

        DECLARE @BaseSql NVARCHAR(MAX) = N'
            INSERT INTO #Base SELECT
                LTRIM(RTRIM(ISNULL(AccessionNumber,''''))),
                YEAR(TRY_CAST(DateofService AS DATE)), MONTH(TRY_CAST(DateofService AS DATE)),
                ' + @BilledExpr + N',
                ISNULL(LTRIM(RTRIM([' + @ClaimTypeCol + N'])),''''),
                ISNULL(LTRIM(RTRIM(ClaimStatus)),''''),
                ' + @FBDExpr + N',
                ' + @LBDExpr + N',
                ISNULL(TRY_CAST(ChargeAmount AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0),
                ' + @ActExpr + N', ' + @DupExpr + N',
                ISNULL(TRY_CAST(PatientPayment AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(PatientAdjustments AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(PatientBalance AS DECIMAL(18,2)),0)
            FROM dbo.ClaimLevelData
            WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(ISNULL(AccessionNumber,''''))),'''') IS NOT NULL
              AND (ISNULL(@yf,0)=0 OR YEAR(TRY_CAST(DateofService AS DATE))>=@yf)
              AND (ISNULL(@yt,0)=0 OR YEAR(TRY_CAST(DateofService AS DATE))<=@yt)
              AND (ISNULL(@mf,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE))>=@mf)
              AND (ISNULL(@mt,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE))<=@mt)
              AND (@df IS NULL OR TRY_CAST(DateofService AS DATE) >= @df)
              AND (@dt IS NULL OR TRY_CAST(DateofService AS DATE) <= @dt)
              AND ' + @BfPred + N'
              AND ' + @BtPred + N'
              AND (@hpf=0 OR CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(PanelType,        ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @ipnl + '','') COLLATE DATABASE_DEFAULT) > 0)
              AND (@hcf=0 OR CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(ClinicName,       ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @icln + '','') COLLATE DATABASE_DEFAULT) > 0)
              AND (@hpvf=0 OR CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(ReferringProvider,''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iprv + '','') COLLATE DATABASE_DEFAULT) > 0)
              AND (@hrf=0 OR CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(SalesRepname,     ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @irep + '','') COLLATE DATABASE_DEFAULT) > 0);';
        EXEC sp_executesql @BaseSql,
             N'@yf INT,@yt INT,@mf INT,@mt INT,@df DATE,@dt DATE,@bf DATE,@bt DATE,@hpf BIT,@hcf BIT,@hpvf BIT,@hrf BIT,@ipnl NVARCHAR(MAX),@icln NVARCHAR(MAX),@iprv NVARCHAR(MAX),@irep NVARCHAR(MAX)',
             @yf=@YearFrom, @yt=@YearTo, @mf=@MonthFrom, @mt=@MonthTo,
             @df=@DosFrom, @dt=@DosTo,
             @bf=@BilledFrom, @bt=@BilledTo,
             @hpf=@HasPanelFilter, @hcf=@HasClinicFilter, @hpvf=@HasProviderFilter, @hrf=@HasRepFilter, @ipnl=@Panels, @icln=@Clinics, @iprv=@Providers, @irep=@Reps;
    END

    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base;

    -- ── ARIA — per DOS period (same simple rule as file 30) ──
    -- Anchor = MAX(FirstBilledDate) < today; every month AsOf = same day; lookback 30.
    DECLARE @AriaAnchor DATE = (
        SELECT MAX(FirstBilledDate) FROM #Base
        WHERE FirstBilledDate IS NOT NULL AND FirstBilledDate < CAST(GETDATE() AS DATE));
    IF @AriaAnchor IS NULL SET @AriaAnchor = DATEADD(DAY, -1, CAST(GETDATE() AS DATE));
    DECLARE @AriaDay INT = DAY(@AriaAnchor);

    IF OBJECT_ID('tempdb..#PeriodWindow') IS NOT NULL DROP TABLE #PeriodWindow;
    SELECT
        p.ESYear, p.ESMonth,
        AsOfDate = CASE
            WHEN (
                CASE WHEN @AriaDay > DAY(EOMONTH(DATEFROMPARTS(p.ESYear, p.ESMonth, 1)))
                     THEN EOMONTH(DATEFROMPARTS(p.ESYear, p.ESMonth, 1))
                     ELSE DATEFROMPARTS(p.ESYear, p.ESMonth, @AriaDay) END
            ) > @AriaAnchor THEN @AriaAnchor
            ELSE
                CASE WHEN @AriaDay > DAY(EOMONTH(DATEFROMPARTS(p.ESYear, p.ESMonth, 1)))
                     THEN EOMONTH(DATEFROMPARTS(p.ESYear, p.ESMonth, 1))
                     ELSE DATEFROMPARTS(p.ESYear, p.ESMonth, @AriaDay) END
        END
    INTO #PeriodWindow
    FROM #Periods p;

    -- Combine LIS (#LisOut) + PMS/Cash/Avg (live from ClaimLevelData)
    SELECT RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth, MetricValue FROM #LisOut

    UNION ALL
    -- PMS: G, H, M-S
    -- G: Billed='Billed' matches production aggregate SP logic (derived from FirstBilledDate/EmedixSubmissionDate)
    SELECT 'G','PMS','No. of Billed Claims',b.ESYear,b.ESMonth,
           COUNT(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'H','PMS','No. of Unbilled Claims',b.ESYear,b.ESMonth,
           COUNT(CASE WHEN (b.Billed='Unbilled' OR b.Billed='' OR b.Billed IS NULL) AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'J','PMS','Test Patient Entries',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN b.ClaimType='Test Patient Entries' THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'K','PMS','ADCS Claims',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN b.ClaimType='ADCS - Invoice' THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'M','PMS','No. of Fully Paid Claims',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus='Fully Paid' THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'S','PMS','No. of Insurance Balance Claims',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response') THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth

    UNION ALL
    -- Cash: T, U, X, AA, AC
    SELECT 'T','Cash','Total Billed ($)',b.ESYear,b.ESMonth,
           SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'U','Cash','Total Unbilled ($)',b.ESYear,b.ESMonth,
           SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') THEN b.ChargeAmount ELSE 0 END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'X','Cash','Insurance Payment ($)',b.ESYear,b.ESMonth,
           SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus='Fully Paid' THEN b.InsurancePayment ELSE 0 END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'AC','Cash','Insurance Balance ($)',b.ESYear,b.ESMonth,
           SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') THEN b.InsuranceBalance ELSE 0 END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth

    UNION ALL
    -- Avg: AD, AE, AF (computed inline)
    SELECT 'AD','Avg','Average Payment ($) - Total Pay/Billed Claims',b.ESYear,b.ESMonth,
           CASE WHEN COUNT(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)>0
                THEN SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.InsurancePayment+b.PatientPayment ELSE 0 END)
                   / COUNT(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
                ELSE 0 END
    FROM #Base b GROUP BY b.ESYear, b.ESMonth

    UNION ALL
    -- AE  Average Payment Per Claim (Total Pay / Paid Claims)
    SELECT 'AE','Avg','Average Payment Per Claim',b.ESYear,b.ESMonth,
           CASE WHEN COUNT(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Patient Paid') THEN b.AccessionNumber END)>0
                THEN SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Patient Paid') THEN b.InsurancePayment+b.PatientPayment ELSE 0 END)
                   / COUNT(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Patient Paid') THEN b.AccessionNumber END)
                ELSE 0 END
    FROM #Base b GROUP BY b.ESYear, b.ESMonth

    UNION ALL
    -- AF  Average Payment ($) - Total Pay/Adjudicated Claims
    --     = (Fully Paid Ins $ + Partially Paid $)
    --       / (ADCS + Fully Paid + Adj/WO + Fully Denied + Partially Denied
    --          + Partially Paid + Partially Adjusted + Patient Paid + Pat Resp)
    SELECT 'AF','Avg','Average Payment ($) - Total Pay/Adjudicated Claims',b.ESYear,b.ESMonth,
           CASE WHEN COUNT(CASE
                    WHEN b.ClaimType = 'ADCS - Invoice' THEN b.AccessionNumber
                    WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                     AND b.ClaimStatus IN (
                         'Fully Paid','Fully Adjusted','Fully Denied','Partially Denied',
                         'Partially Paid','Partial Paid','Partially Adjusted',
                         'Patient Paid','Pat Responsibility')
                    THEN b.AccessionNumber END) > 0
                THEN SUM(CASE
                        WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Partial Paid')
                        THEN b.InsurancePayment ELSE 0 END)
                   / COUNT(CASE
                        WHEN b.ClaimType = 'ADCS - Invoice' THEN b.AccessionNumber
                        WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus IN (
                             'Fully Paid','Fully Adjusted','Fully Denied','Partially Denied',
                             'Partially Paid','Partial Paid','Partially Adjusted',
                             'Patient Paid','Pat Responsibility')
                        THEN b.AccessionNumber END)
                ELSE 0 END
    FROM #Base b GROUP BY b.ESYear, b.ESMonth

    UNION ALL
    -- S.1 / S.3 ARIA (PMS) — FirstBilledDate window per month AsOf (not DOS-filtered)
    SELECT 'S.1.A1','PMS','    Aria Submitted in the last 30 Days',w.ESYear,w.ESMonth,
           COUNT(b.AccessionNumber)
    FROM #PeriodWindow w
    LEFT JOIN #Base b
      ON b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
     AND b.ClaimStatus = 'Fully Denied'
     AND b.FirstBilledDate IS NOT NULL
     AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30
    GROUP BY w.ESYear, w.ESMonth
    UNION ALL
    SELECT 'S.1.A2','PMS','    Aria not submitted in the last 30 Days',w.ESYear,w.ESMonth,
           COUNT(b.AccessionNumber)
    FROM #PeriodWindow w
    LEFT JOIN #Base b
      ON b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
     AND b.ClaimStatus = 'Fully Denied'
     AND (b.FirstBilledDate IS NULL
          OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30)
    GROUP BY w.ESYear, w.ESMonth
    UNION ALL
    SELECT 'S.1.AP','PMS','    % of the claim submitted in the last 30 Days',a1.ESYear,a1.ESMonth,
           CASE WHEN ISNULL(a2.MetricValue,0) > 0 THEN CAST(a1.MetricValue AS DECIMAL(18,4)) / a2.MetricValue ELSE 0 END
    FROM (
        SELECT w.ESYear, w.ESMonth, COUNT(b.AccessionNumber) AS MetricValue
        FROM #PeriodWindow w
        LEFT JOIN #Base b
          ON b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
         AND b.ClaimStatus = 'Fully Denied'
         AND b.FirstBilledDate IS NOT NULL
         AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30
        GROUP BY w.ESYear, w.ESMonth
    ) a1
    JOIN (
        SELECT w.ESYear, w.ESMonth, COUNT(b.AccessionNumber) AS MetricValue
        FROM #PeriodWindow w
        LEFT JOIN #Base b
          ON b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
         AND b.ClaimStatus = 'Fully Denied'
         AND (b.FirstBilledDate IS NULL
              OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30)
        GROUP BY w.ESYear, w.ESMonth
    ) a2 ON a2.ESYear = a1.ESYear AND a2.ESMonth = a1.ESMonth
    UNION ALL
    SELECT 'S.3.A1','PMS','    Claim filed by ARIA in the last 30 days',w.ESYear,w.ESMonth,
           COUNT(b.AccessionNumber)
    FROM #PeriodWindow w
    LEFT JOIN #Base b
      ON b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
     AND b.ClaimStatus = 'No Response'
     AND b.FirstBilledDate IS NOT NULL
     AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30
    GROUP BY w.ESYear, w.ESMonth
    UNION ALL
    SELECT 'S.3.A2','PMS','    Claims not filed in the last 30 days',w.ESYear,w.ESMonth,
           COUNT(b.AccessionNumber)
    FROM #PeriodWindow w
    LEFT JOIN #Base b
      ON b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
     AND b.ClaimStatus = 'No Response'
     AND (b.FirstBilledDate IS NULL
          OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30)
    GROUP BY w.ESYear, w.ESMonth
    UNION ALL
    SELECT 'S.3.AP','PMS','    % of the claim submitted in the last 30 Days',a1.ESYear,a1.ESMonth,
           CASE WHEN ISNULL(a2.MetricValue,0) > 0 THEN CAST(a1.MetricValue AS DECIMAL(18,4)) / a2.MetricValue ELSE 0 END
    FROM (
        SELECT w.ESYear, w.ESMonth, COUNT(b.AccessionNumber) AS MetricValue
        FROM #PeriodWindow w
        LEFT JOIN #Base b
          ON b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
         AND b.ClaimStatus = 'No Response'
         AND b.FirstBilledDate IS NOT NULL
         AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30
        GROUP BY w.ESYear, w.ESMonth
    ) a1
    JOIN (
        SELECT w.ESYear, w.ESMonth, COUNT(b.AccessionNumber) AS MetricValue
        FROM #PeriodWindow w
        LEFT JOIN #Base b
          ON b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
         AND b.ClaimStatus = 'No Response'
         AND (b.FirstBilledDate IS NULL
              OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30)
        GROUP BY w.ESYear, w.ESMonth
    ) a2 ON a2.ESYear = a1.ESYear AND a2.ESMonth = a1.ESMonth
    UNION ALL
    -- AC.1 / AC.3 ARIA (Cash $) — FirstBilledDate window (not DOS-filtered)
    SELECT 'AC.1.A1','Cash','    Aria Submitted in the last 30 Days',w.ESYear,w.ESMonth,
           ISNULL(SUM(b.InsuranceBalance),0)
    FROM #PeriodWindow w
    LEFT JOIN #Base b
      ON b.Billed IN ('Billed','Billed - Client')
     AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
     AND b.ClaimStatus = 'Fully Denied'
     AND b.FirstBilledDate IS NOT NULL
     AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30
    GROUP BY w.ESYear, w.ESMonth
    UNION ALL
    SELECT 'AC.1.A2','Cash','    Aria not submitted in the last 30 Days',w.ESYear,w.ESMonth,
           ISNULL(SUM(b.InsuranceBalance),0)
    FROM #PeriodWindow w
    LEFT JOIN #Base b
      ON b.Billed IN ('Billed','Billed - Client')
     AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
     AND b.ClaimStatus = 'Fully Denied'
     AND (b.FirstBilledDate IS NULL
          OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30)
    GROUP BY w.ESYear, w.ESMonth
    UNION ALL
    SELECT 'AC.1.AP','Cash','    % of the claim submitted in the last 30 Days',a1.ESYear,a1.ESMonth,
           CASE WHEN ISNULL(a2.MetricValue,0) > 0 THEN a1.MetricValue / a2.MetricValue ELSE 0 END
    FROM (
        SELECT w.ESYear, w.ESMonth, ISNULL(SUM(b.InsuranceBalance),0) AS MetricValue
        FROM #PeriodWindow w
        LEFT JOIN #Base b
          ON b.Billed IN ('Billed','Billed - Client')
         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
         AND b.ClaimStatus = 'Fully Denied'
         AND b.FirstBilledDate IS NOT NULL
         AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30
        GROUP BY w.ESYear, w.ESMonth
    ) a1
    JOIN (
        SELECT w.ESYear, w.ESMonth, ISNULL(SUM(b.InsuranceBalance),0) AS MetricValue
        FROM #PeriodWindow w
        LEFT JOIN #Base b
          ON b.Billed IN ('Billed','Billed - Client')
         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
         AND b.ClaimStatus = 'Fully Denied'
         AND (b.FirstBilledDate IS NULL
              OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30)
        GROUP BY w.ESYear, w.ESMonth
    ) a2 ON a2.ESYear = a1.ESYear AND a2.ESMonth = a1.ESMonth
    UNION ALL
    SELECT 'AC.3.A1','Cash','    Aria Submitted in the last 30 Days',w.ESYear,w.ESMonth,
           ISNULL(SUM(b.InsuranceBalance),0)
    FROM #PeriodWindow w
    LEFT JOIN #Base b
      ON b.Billed IN ('Billed','Billed - Client')
     AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
     AND b.ClaimStatus = 'No Response'
     AND b.FirstBilledDate IS NOT NULL
     AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30
    GROUP BY w.ESYear, w.ESMonth
    UNION ALL
    SELECT 'AC.3.A2','Cash','    Aria not submitted in the last 30 Days',w.ESYear,w.ESMonth,
           ISNULL(SUM(b.InsuranceBalance),0)
    FROM #PeriodWindow w
    LEFT JOIN #Base b
      ON b.Billed IN ('Billed','Billed - Client')
     AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
     AND b.ClaimStatus = 'No Response'
     AND (b.FirstBilledDate IS NULL
          OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30)
    GROUP BY w.ESYear, w.ESMonth
    UNION ALL
    SELECT 'AC.3.AP','Cash','    % of the claim submitted in the last 30 Days',a1.ESYear,a1.ESMonth,
           CASE WHEN ISNULL(a2.MetricValue,0) > 0 THEN a1.MetricValue / a2.MetricValue ELSE 0 END
    FROM (
        SELECT w.ESYear, w.ESMonth, ISNULL(SUM(b.InsuranceBalance),0) AS MetricValue
        FROM #PeriodWindow w
        LEFT JOIN #Base b
          ON b.Billed IN ('Billed','Billed - Client')
         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
         AND b.ClaimStatus = 'No Response'
         AND b.FirstBilledDate IS NOT NULL
         AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30
        GROUP BY w.ESYear, w.ESMonth
    ) a1
    JOIN (
        SELECT w.ESYear, w.ESMonth, ISNULL(SUM(b.InsuranceBalance),0) AS MetricValue
        FROM #PeriodWindow w
        LEFT JOIN #Base b
          ON b.Billed IN ('Billed','Billed - Client')
         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
         AND b.ClaimStatus = 'No Response'
         AND (b.FirstBilledDate IS NULL
              OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30)
        GROUP BY w.ESYear, w.ESMonth
    ) a2 ON a2.ESYear = a1.ESYear AND a2.ESMonth = a1.ESMonth

    ORDER BY BillYear, BillMonth, Category, RowCode;

    DROP TABLE IF EXISTS #LisBase;
    DROP TABLE IF EXISTS #LisPeriods;
    DROP TABLE IF EXISTS #LisPanels;
    DROP TABLE IF EXISTS #LisOut;
    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #PeriodWindow;
END;
GO

PRINT '31_NW_ExecutiveSummary_Read.sql completed.';
GO
