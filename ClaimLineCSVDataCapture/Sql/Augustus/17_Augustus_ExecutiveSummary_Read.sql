-- ============================================================
-- Augustus – Executive Summary Read SP
-- File : 17_Augustus_ExecutiveSummary_Read.sql
-- DB   : Augustus_LRN
--
-- Mirrors Cove\17_Cove_ExecutiveSummary_Read.sql.
--
-- usp_GetAug_ExecutiveSummary(@YearFrom,@YearTo,@MonthFrom,@MonthTo, ...)
--   @YearFrom/@YearTo/@MonthFrom/@MonthTo : INT = 0 (0 = unbounded)
--   @HasFilter = 1 if any parameter is non-zero / non-null.
--
-- No-filter path (fast read): UNION ALL of the 4 aggregate tables
-- (Augustus_ES_LIS, Augustus_ES_PMS, Augustus_ES_Cash, Augustus_ES_Avg),
-- each row already bucketed by (ESYear, ESMonth) with a (0,0) grand-total
-- sentinel, returned as (RowCode, Category, Description, BillYear, BillMonth,
-- MetricValue).
--
-- Filtered path (live re-aggregation): re-derives ALL RowCodes from
-- dbo.LIMSMaster (LIS, date-filtered on ReqCollectDate) and
-- dbo.ClaimLevelData (PMS/Cash/Avg, date-filtered on DateofService).
-- BillYear/BillMonth are now derived from the source date so month-wise
-- columns are preserved exactly as in the no-filter path.
--
-- Augustus LIS uses:
--   BillTo        -> maps to BillCategory column in LIMSMaster
--   BillingStatus -> maps to NewStatus column
--   FinalStatus   -> maps to SubStatus column
--   ClientStatus1 -> maps to a secondary SubStatus flag
--   ReqCollectDate -> the date column
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAug_ExecutiveSummary
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
            FROM dbo.Augustus_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
                   2, Id
            FROM dbo.Augustus_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   3, Id
            FROM dbo.Augustus_ES_Cash

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   4, Id
            FROM dbo.Augustus_ES_Avg
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

    -- @HasLisFilter: 1 only when a filter that applies to LIMSMaster is active.
    -- SalesRep is not tracked in LIMSMaster for Augustus, so a Rep-only filter
    -- must NOT trigger a full LIMSMaster scan; the aggregate table is used instead.
    DECLARE @HasLisFilter BIT = CASE WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 THEN 1 ELSE 0 END;

    -- ── LIS: build #Lis from dbo.LIMSMaster, date-filtered on ReqCollectDate ──
    -- BillYear/BillMonth added so the filtered path produces month-wise rows.
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession     NVARCHAR(100) NOT NULL,
        BillTo        NVARCHAR(200) NOT NULL,
        BillingStatus NVARCHAR(200) NOT NULL,
        FinalStatus   NVARCHAR(200) NOT NULL,
        ClientStatus1 NVARCHAR(200) NOT NULL,
        PanelType     NVARCHAR(200) NOT NULL,
        BillYear      INT           NOT NULL,
        BillMonth     INT           NOT NULL
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
              AND name IN ('ReqCollectDate','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'ReqCollectDate' THEN 0 WHEN 'RequestCollectDate' THEN 1
                WHEN 'DateOfCollection' THEN 2 WHEN 'DateofService' THEN 3
                WHEN 'CollectionDate' THEN 4 WHEN 'ServiceDate' THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

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

        DECLARE @ClientStatus1Col SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClientStatus1','ClientStatus','ClientStatus2','ClientFlag')
            ORDER BY CASE name WHEN 'ClientStatus1' THEN 0 WHEN 'ClientStatus' THEN 1 WHEN 'ClientStatus2' THEN 2 WHEN 'ClientFlag' THEN 3 ELSE 4 END);

        -- LIS dimension filter columns — Augustus-specific mappings:
        --   Panels  -> PanelType (priority 0), then PanelName, PanelCategory ...
        --   Clinics -> ClinicName
        --   SalesRep  -> not available on LIMSMaster for Augustus
        --   Providers -> not applied to LIS
        DECLARE @LisPanelTypeCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelType','PanelName','PanelCategory','Panelname','TestPanel','Panel')
            ORDER BY CASE name
                WHEN 'PanelType'     THEN 0
                WHEN 'PanelName'     THEN 1
                WHEN 'PanelCategory' THEN 2
                WHEN 'Panelname'     THEN 3
                ELSE 4 END);

        DECLARE @LisClinicNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClinicName','Clinic','FacilityName','Facility')
            ORDER BY CASE name
                WHEN 'ClinicName' THEN 0 WHEN 'Clinic' THEN 1 WHEN 'FacilityName' THEN 2 ELSE 3 END);

        IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @BillToCol IS NOT NULL AND @BillingStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        BEGIN
            DECLARE @CS1Expr NVARCHAR(400) = CASE WHEN @ClientStatus1Col IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientStatus1Col + N']), '''')))'
                ELSE N'''''' END;

            DECLARE @PanelTypeExpr NVARCHAR(400) = CASE WHEN @LisPanelTypeCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @LisPanelTypeCol + N']), '''')))'
                ELSE N'''''' END;

            -- Date parameters are intentionally NOT applied to LIMSMaster for Augustus.
            -- BillYear/BillMonth are still captured from the date column for period display.
            -- Dimension filters applied: Panels→PanelType, Clinics→ClinicName.
            -- SalesRep and Providers filters are not applied to LIS.
            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (Accession, BillTo, BillingStatus, FinalStatus, ClientStatus1, PanelType, BillYear, BillMonth)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
                    ' + @CS1Expr + N',
                    ' + @PanelTypeExpr + N',
                    ISNULL(YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)), 0),
                    ISNULL(MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)), 0)
                FROM dbo.LIMSMaster
                WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL';

            -- Panel filter: Panels → PanelType
            IF @LisPanelTypeCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasPanelFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisPanelTypeCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iPanels + '','') > 0)';

            -- Clinic filter: Clinics → ClinicName
            IF @LisClinicNameCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasClinicFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisClinicNameCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iClinics + '','') > 0)';

            SET @LisSql = @LisSql + N';';

            EXEC sp_executesql @LisSql,
                N'@iHasPanelFilter  BIT,           @iPanels  NVARCHAR(MAX),
                  @iHasClinicFilter BIT,           @iClinics NVARCHAR(MAX)',
                @iHasPanelFilter  = @HasPanelFilter,  @iPanels  = @Panels,
                @iHasClinicFilter = @HasClinicFilter, @iClinics = @Clinics;
        END
    END

    -- ── PMS/Cash/Avg: build #Base from dbo.ClaimLevelData, date-filtered ────
    -- BillYear/BillMonth added so the filtered path produces month-wise rows.
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        ISNULL(YEAR (TRY_CAST(DateofService AS DATE)), 0)        AS BillYear,
        ISNULL(MONTH(TRY_CAST(DateofService AS DATE)), 0)        AS BillMonth,
        ISNULL(LTRIM(RTRIM(BillingStatus)),  '')                 AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)),    '')                 AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Source)),         '')                 AS Source,
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
      AND (ISNULL(@YearFrom,0)=0  OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
      AND (ISNULL(@YearTo,0)=0    OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
      AND (ISNULL(@MonthFrom,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
      AND (ISNULL(@MonthTo,0)=0   OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
      AND (@DosFrom    IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
      AND (@DosTo      IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
      AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
      AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
      AND (@HasPanelFilter    = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(Panelname,         ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Panels + ',') > 0)
      AND (@HasClinicFilter   = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Clinics + ',') > 0)
      AND (@HasProviderFilter = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Providers + ',') > 0)
      AND (@HasRepFilter      = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Reps + ',') > 0);

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
        FROM dbo.Augustus_ES_LIS;
    END
    ELSE
    BEGIN
        -- LIS-applicable filter(s) active — build from #Lis (live LIMSMaster data)
        -- new RoleID scheme: A=Total Samples, B=Billable, B1.x=panel sub-rows,
        -- B2.1/B2.2=billed/unbilled, C-F=other bill categories.
        ;WITH Lis AS
        (
            -- A  Total Samples (all accessions)
            SELECT 'A' AS RowCode, 'Total Samples' AS Description, BillYear, BillMonth,
               CAST(COUNT(DISTINCT Accession) AS DECIMAL(18,2)) AS MetricValue
        FROM #Lis GROUP BY BillYear, BillMonth
        -- B  Billable Samples (Insurance)
        UNION ALL
        SELECT 'B', 'Billable Samples', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo LIKE '%Insurance%' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- B2.1  Billed
        UNION ALL
        SELECT 'B2.1', '  Billed (First Billed Date = Date AND Billed Amount <> 0)', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.1.1', '    Claim Submitted in IRCM (First Billed Date = Date AND Billed Amount <> 0 AND Source = IRCM)', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Billed' AND FinalStatus='Claim Submitted in IRCM' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.1.2', '    Claim Submitted in Daqbilling (First Billed Date = Date AND Billed Amount <> 0 AND Source = Daq)', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Billed' AND FinalStatus='Claim Submitted in Daqbilling' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- B2.2  Unbilled
        UNION ALL
        SELECT 'B2.2', '  Unbilled (First Billed Date = Blank AND Billed Amount <> 0)', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Unbilled' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.2.1', '    Resulted yet to be billed', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Unbilled' AND FinalStatus='Resulted yet to be billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.2.1*', '      Ready to bill', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Unbilled' AND FinalStatus='Resulted yet to be billed' AND ClientStatus1='Ready to bill' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.2.2', '    Insurance name not listed', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Unbilled' AND FinalStatus='Insurance Name Not Listed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- C  Yet to be Validated
        UNION ALL
        SELECT 'C', 'Yet to be Validated', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Yet to be Validated' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C.1', '  Billed', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Yet to be Validated' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- D  Client Bills
        UNION ALL
        SELECT 'D', 'Client Bills', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Client Bills' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'D.1', '  Billed', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Client Bills' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- E  System Test
        UNION ALL
        SELECT 'E', 'System Test', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo='System Test' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'E.1', '  Billed', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo='System Test' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- F  Self pay
        UNION ALL
        SELECT 'F', 'Self pay', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Self pay' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'F.1', '  Billed', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Self pay' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        )
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT RowCode, Description, BillYear, BillMonth, MetricValue FROM Lis;

        -- B1.x  Panel sub-rows under B (Billable Samples / Insurance)
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT 'B1.' + LTRIM(RTRIM(PanelType)), '  ' + LTRIM(RTRIM(PanelType)),
               BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillTo LIKE '%Insurance%' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis
        WHERE BillTo LIKE '%Insurance%' AND LTRIM(RTRIM(PanelType)) <> ''
        GROUP BY LTRIM(RTRIM(PanelType)), BillYear, BillMonth;
    END

    -- ────────────────────────────────────────────────────────────────────
    --  PMS  -  F, F.1, F.2, G, H, I, J, K, L, M, N, O, O.1, O.2, O.3
    -- ────────────────────────────────────────────────────────────────────
    ;WITH PMS AS
    (
        SELECT 'F' AS RowCode, 'No. of Billed Claims' AS Description, BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2)) AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'F.1', '  No. of Claims Billed in IRCM', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='IRCM' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'F.2', '  No. of Claims Billed in Daq Billing', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='Daq' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'G', 'No. of Unbilled Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN (BillStatus='' OR BillStatus IS NULL) AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'H', 'Client bill claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'I', 'No. of Fully Paid Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'J', 'No. of Patient Paid Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Patient paid' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'K', 'No. of Patient Responsibility Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Pat Responsibility' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'L', 'No. of Partially Paid Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Partial Paid' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'M', 'No. of Adjusted/Written Off Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'N', 'No. of Partially Adjusted/Written Off Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O', 'No. of Insurance Balance Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied','No Response') THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O.1', '  No. of Fully Denied Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Denied' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O.2', '  No. of Partially Denied Claims', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Denied' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O.3', '  No. of No Response from Payor', BillYear, BillMonth,
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='No Response' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Cash  -  P, P.1, P.2, Q, R, S, T, U, U.1, U.2, V, W, X, X.1, X.2, X.3
    -- ────────────────────────────────────────────────────────────────────
    Cash AS
    (
        SELECT 'P' AS RowCode, 'Total Billed ($)' AS Description, BillYear, BillMonth,
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN ChargeAmount ELSE 0 END) AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'P.1', '  Total Charge of Claims Billed (IRCM)', BillYear, BillMonth,
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='IRCM' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'P.2', '  Total Charge of Claims Billed (Daq)', BillYear, BillMonth,
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='Daq' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'Q', 'Total Unbilled ($)', BillYear, BillMonth,
               SUM(CASE WHEN (BillStatus='' OR BillStatus IS NULL) AND ClaimStatus<>'Billed amount 0' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'R', 'Insurance Payment ($)', BillYear, BillMonth,
               SUM(CASE WHEN InsurancePayment > 0 AND ClaimStatus='Fully Paid' THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'S', 'Partially Paid ($)', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus='Partial Paid' THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'T', 'Patient Paid ($)', BillYear, BillMonth,
               SUM(CASE WHEN PatientPayment > 0 THEN PatientPayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U', 'Patient Responsibility ($)', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U.1', '  Daqbilling', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND Source='Daq' THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U.2', '  IRCM', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND Source='IRCM' THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'V', 'Adjustment amount ($)', BillYear, BillMonth,
               SUM(InsuranceAdjustments + PatientAdjustments)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'W', 'Total Payments ($) - Insurance', BillYear, BillMonth,
               SUM(CASE WHEN InsurancePayment > 0 THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X', 'Insurance Balance ($)', BillYear, BillMonth,
               SUM(InsuranceBalance)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X.1', '  Fully Denied', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus='Fully Denied' THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X.2', '  Partially Denied', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus='Partially Denied' THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X.3', '  No Response from Payor', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus='No Response' THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Avg  -  Y, Z, AA
    -- ────────────────────────────────────────────────────────────────────
    AvgRows AS
    (
        SELECT 'Y' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description, BillYear, BillMonth,
               CASE WHEN COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END)
                    ELSE 0 END AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth

        UNION ALL
        SELECT 'Z', 'Average Payment ($) - Total Pay/Paid Claims', BillYear, BillMonth,
               CASE WHEN COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN ClaimStatus='Fully Paid' THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END)
                    ELSE 0 END
        FROM #Base GROUP BY BillYear, BillMonth

        UNION ALL
        SELECT 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims', BillYear, BillMonth,
               CASE WHEN COUNT(DISTINCT CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END)
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

PRINT '17_Augustus_ExecutiveSummary_Read.sql completed.';
GO
