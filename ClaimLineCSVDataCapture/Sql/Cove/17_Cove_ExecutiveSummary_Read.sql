-- ============================================================
-- Cove – Executive Summary Read SP
-- File : 17_Cove_ExecutiveSummary_Read.sql
-- DB   : Cove_LRN
--
-- usp_GetCove_ExecutiveSummary
--
-- Parameters (all optional / default to "no filter"):
--   @YearFrom      INT  = 0        Year-of-DOS lower bound (0 = unbounded)
--   @YearTo        INT  = 0        Year-of-DOS upper bound
--   @MonthFrom     INT  = 0        Month-of-DOS lower bound (1-12, 0 = unbounded)
--   @MonthTo       INT  = 0        Month-of-DOS upper bound
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
    -- Legacy year/month filters (kept for backward compat)
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
    @Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Any non-default value forces the live re-aggregation path.
    -- ISNULL guards against C# sending DBNull for int params — NULL <> 0 is
    -- UNKNOWN in SQL, which would leave @HasFilter at 0 accidentally.
    DECLARE @HasFilter BIT = CASE
        WHEN ISNULL(@YearFrom,  0) <> 0 THEN 1
        WHEN ISNULL(@YearTo,    0) <> 0 THEN 1
        WHEN ISNULL(@MonthFrom, 0) <> 0 THEN 1
        WHEN ISNULL(@MonthTo,   0) <> 0 THEN 1
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

    -- ── LIS: build #Lis from dbo.LIMSMaster ─────────────────────────────────
    -- Uses dynamic column name resolution (same as Aggregate SP) to stay
    -- resilient to schema differences across environments.
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession    NVARCHAR(100) NOT NULL,
        NewStatus    NVARCHAR(200) NOT NULL,
        PanelName    NVARCHAR(200) NOT NULL,
        BillCategory NVARCHAR(200) NOT NULL,
        SubStatus    NVARCHAR(200) NOT NULL
    );

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
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

        DECLARE @PanelNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelName','PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
            ORDER BY CASE name
                WHEN 'PanelName'        THEN 0 WHEN 'PanelCategory'   THEN 1 WHEN 'PanelName'      THEN 2
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

        IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @NewStatusCol IS NOT NULL
           AND @PanelNameCol IS NOT NULL AND @BillCategoryCol IS NOT NULL AND @SubStatusCol IS NOT NULL
        BEGIN
            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (Accession, NewStatus, PanelName, BillCategory, SubStatus)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol       + N']))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @NewStatusCol    + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol    + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol    + N']), '''')))
                FROM dbo.LIMSMaster
                WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
                  -- Year/month filters (ISNULL so NULL is treated as 0 = no filter)
                  AND (ISNULL(@iYearFrom,  0) = 0 OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iYearFrom)
                  AND (ISNULL(@iYearTo,    0) = 0 OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iYearTo)
                  AND (ISNULL(@iMonthFrom, 0) = 0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iMonthFrom)
                  AND (ISNULL(@iMonthTo,   0) = 0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iMonthTo)
                  -- Panel dimension filter on LIMSMaster
                  AND (@iHasPanelFilter = 0 OR
                       LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @PanelNameCol + N']),'''')))
                       IN (SELECT Val FROM #FilterPanels));';

            EXEC sp_executesql @LisSql,
                N'@iYearFrom INT, @iYearTo INT, @iMonthFrom INT, @iMonthTo INT, @iHasPanelFilter BIT',
                @iYearFrom=@YearFrom, @iYearTo=@YearTo, @iMonthFrom=@MonthFrom, @iMonthTo=@MonthTo,
                @iHasPanelFilter=@HasPanelFilter;
        END
    END

    -- ── PMS/Cash/Avg: build #Base from dbo.ClaimLevelData ───────────────────
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        ISNULL(LTRIM(RTRIM(BillStatus)),  '')                                AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')                                AS ClaimStatus,
        ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0)           AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0)           AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0)           AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0)           AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0)           AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0)           AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)           AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
      -- Year/month filters on DOS (ISNULL so NULL from C# = 0 = no filter)
      AND (ISNULL(@YearFrom,  0) = 0 OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
      AND (ISNULL(@YearTo,    0) = 0 OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
      AND (ISNULL(@MonthFrom, 0) = 0 OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
      AND (ISNULL(@MonthTo,   0) = 0 OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
      -- Exact date-range filters
      AND (@DosFrom    IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
      AND (@DosTo      IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
      AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
      AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
      -- guarded by checking OBJECT_ID inline at the WHERE level via CASE.
      -- If the column does not exist the filter is silently skipped at ingestion
      -- time because the SP would fail to compile — kept as a no-op placeholder.
      -- Dimension filters
      AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(PanelName,         ''))) IN (SELECT Val FROM #FilterPanels))
      AND (@HasClinicFilter   = 0 OR LTRIM(RTRIM(ISNULL(ClinicName,        ''))) IN (SELECT Val FROM #FilterClinics))
      AND (@HasProviderFilter = 0 OR LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) IN (SELECT Val FROM #FilterProviders))
      AND (@HasRepFilter      = 0 OR LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) IN (SELECT Val FROM #FilterReps));

    -- ────────────────────────────────────────────────────────────────────
    --  LIS  (same logic as v1, sourced from filtered #Lis)
    -- ────────────────────────────────────────────────────────────────────
    ;WITH Lis AS
    (
        SELECT 'A'    AS RowCode, 'Total Samples'                                                               AS Description, CAST(COUNT(DISTINCT Accession) AS DECIMAL(18,2)) AS MetricValue FROM #Lis
        UNION ALL SELECT 'B',    'Billable Samples',                                                            CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C',    'Billed',                                                                      CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D',    'Not Billed',                                                                  CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.1',  '  Billed Insurance In Covedx',                                               CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Billed Insurance In Covedx' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.2',  '  Billed In Variantx Lab',                                                   CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Billed In Variantx Lab' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.3',  '  Billed In Elixir Dx',                                                      CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Billed In Elixir Dx' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.4',  '  Ignored - Duplicate Accession',                                            CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Ignored - Duplicate Accession' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.5',  '  Coding exception',                                                         CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Coding exception' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.6',  '  CP Exception',                                                             CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='CP Exception' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.7',  '  In process',                                                               CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='In process' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.8',  '  Ignored - Client Response Non Billiable',                                  CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Ignored - Client Response Non Billiable' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.9',  '  Ready To Bill',                                                            CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Ready To Bill' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.10', '  Ignored - NGS & PGX in Cove',                                             CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Ignored - NGS & PGX in Cove' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.11', '  CP Exception -In Review',                                                  CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='CP Exception -In Review' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.12', '  Medicaid Credentialling In Process',                                       CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Medicaid Credentialling In Process' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.13', '  Ignored - Reported in Elixir Truemed',                                     CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Ignored - Reported in Elixir Truemed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.14', '  Ignored - CP Exception',                                                   CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Ignored - CP Exception' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.15', '  Client Bill Cases',                                                        CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Client Bill Cases' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.16', '  Ignored - Client Response Pure Selfpay',                                   CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Ignored - Client Response Pure Selfpay' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.17', '  Selfpay',                                                                  CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Selfpay' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.18', '  Ignored - Rejected Accession',                                             CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Ignored - Rejected Accession' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.19', '  Hold-Amerihealth Lousiana',                                                CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Hold-Amerihealth Lousiana' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.20', '  Ignored - Test Cases',                                                     CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Ignored - Test Cases' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E',    'Other Samples',                                                               CAST(COUNT(DISTINCT CASE WHEN NewStatus<>'Billable' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E.1',  '  Self Pay',                                                                  CAST(COUNT(DISTINCT CASE WHEN NewStatus='Self Pay' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E.2',  '  Client Bill',                                                               CAST(COUNT(DISTINCT CASE WHEN NewStatus='Client Bill' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E.3',  '  Deleted / Rejected',                                                        CAST(COUNT(DISTINCT CASE WHEN NewStatus='Deleted / Rejected' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E.4',  '  System Test',                                                               CAST(COUNT(DISTINCT CASE WHEN NewStatus='System Test' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E.5',  '  Ref Lab - Bill Patient',                                                    CAST(COUNT(DISTINCT CASE WHEN NewStatus='Ref Lab - Bill Patient' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E.6',  '  Missing Accession',                                                         CAST(COUNT(DISTINCT CASE WHEN NewStatus='Missing Accession' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E.7',  '  Yet To Be Validated',                                                       CAST(COUNT(DISTINCT CASE WHEN NewStatus='Yet To Be Validated' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
    ),
    LisPanels AS
    (
        SELECT N'B.'   + PanelName AS RowCode, N'  '   + PanelName AS Description,
               CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' THEN Accession END) AS DECIMAL(18,2)) AS MetricValue
        FROM #Lis WHERE NULLIF(PanelName, '') IS NOT NULL GROUP BY PanelName

        UNION ALL
        SELECT N'D.5.' + PanelName, N'    ' + PanelName,
               CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Coding exception' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis WHERE NULLIF(PanelName, '') IS NOT NULL GROUP BY PanelName

        UNION ALL
        SELECT N'D.6.' + PanelName, N'    ' + PanelName,
               CAST(COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='CP Exception' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis WHERE NULLIF(PanelName, '') IS NOT NULL GROUP BY PanelName
    ),
    -- ── PMS ─────────────────────────────────────────────────────────────
    PMS AS
    (
        SELECT 'F'   AS RowCode, 'No. of Billed Claims'                                AS Description, CAST(COUNT(DISTINCT CASE WHEN BillStatus IN ('Billed','Billed-Client') THEN AccessionNumber END) AS DECIMAL(18,2)) AS MetricValue FROM #Base
        UNION ALL SELECT 'G',   '  Billed Mismatches - Accessions NA / Other Sample',
            CAST(CASE WHEN
                (SELECT COUNT(DISTINCT CASE WHEN BillStatus IN ('Billed','Billed-Client') THEN AccessionNumber END) FROM #Base)
              - (SELECT COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Billed' THEN Accession END) FROM #Lis) > 0
              THEN
                (SELECT COUNT(DISTINCT CASE WHEN BillStatus IN ('Billed','Billed-Client') THEN AccessionNumber END) FROM #Base)
              - (SELECT COUNT(DISTINCT CASE WHEN NewStatus='Billable' AND BillCategory='Billed' THEN Accession END) FROM #Lis)
              ELSE 0 END AS DECIMAL(18,2))
        UNION ALL SELECT 'H',   'No. of Fully Paid Claims',                            CAST(COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Fully Paid','Paid-Client') THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'I',   'No. of Patient Responsibility Claims',                CAST(COUNT(DISTINCT CASE WHEN ClaimStatus = 'Patient Responsibility' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'J',   'No. of Adjusted/Written Off Claims',                  CAST(COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'K',   'No. of Partially Adjusted/Written Off Claims',        CAST(COUNT(DISTINCT CASE WHEN ClaimStatus = 'Partially Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'L',   'No. of Partially Paid Claims',                        CAST(COUNT(DISTINCT CASE WHEN ClaimStatus = 'Partially Paid' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'M',   'No. of Patient Paid Claims',                          CAST(COUNT(DISTINCT CASE WHEN ClaimStatus = 'Patient Payment' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'N',   'No. of Insurance Balance Claims',                     CAST(COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied','No Response','No Response-Client') THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'N.1', '  No. of Fully Denied Claims',                        CAST(COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Denied' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'N.2', '  No. of Partially Denied Claims',                    CAST(COUNT(DISTINCT CASE WHEN ClaimStatus = 'Partially Denied' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'N.3', '  No. of No Response from Payor Claims',              CAST(COUNT(DISTINCT CASE WHEN ClaimStatus IN ('No Response','No Response-Client') THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
    ),
    -- ── Cash ─────────────────────────────────────────────────────────────
    Cash AS
    (
        SELECT 'O'   AS RowCode, 'Total Billed ($)'           AS Description, SUM(CASE WHEN BillStatus IN ('Billed','Billed-Client') THEN ChargeAmount ELSE 0 END)                                    AS MetricValue FROM #Base
        UNION ALL SELECT 'P',   'Insurance Payment ($)',       SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Paid-Client') THEN InsurancePayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'Q',   'Patient Responsibility ($)',  SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB','No Response','No Response-Client') THEN PatientBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'R',   'Patient Payment ($)',         SUM(CASE WHEN PatientPayment > 0 THEN PatientPayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'S',   'Adjustments / Write Off ($)', SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN InsuranceAdjustments + PatientAdjustments ELSE 0 END) FROM #Base
        UNION ALL SELECT 'T',   'Partially Paid ($)',          SUM(CASE WHEN ClaimStatus = 'Partially Paid' THEN InsurancePayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'U',   'Insurance Balance ($)',       SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN InsuranceBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'U.1', '  Denials',                   SUM(CASE WHEN ClaimStatus = 'Fully Denied' THEN InsuranceBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'U.2', '  Partially Denied',          SUM(CASE WHEN ClaimStatus IN ('Partially Denied','Partially Adjusted','Partially Paid','Patient Payment','Patient Responsibility') THEN InsuranceBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'U.3', '  No Response from Payor',    SUM(CASE WHEN ClaimStatus IN ('No Response','No Response-Client') THEN InsuranceBalance ELSE 0 END) FROM #Base
    ),
    -- ── Avg ──────────────────────────────────────────────────────────────
    AvgRows AS
    (
        SELECT 'V' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               CASE WHEN COUNT(DISTINCT CASE WHEN BillStatus IN ('Billed','Billed-Client') THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN BillStatus IN ('Billed','Billed-Client') THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN BillStatus IN ('Billed','Billed-Client') THEN AccessionNumber END)
                    ELSE 0 END AS MetricValue
        FROM #Base
        UNION ALL
        SELECT 'W', 'Average Payment ($) - Total Pay/Paid Claims',
               CASE WHEN COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Fully Paid','Paid-Client') THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Paid-Client') THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Fully Paid','Paid-Client') THEN AccessionNumber END)
                    ELSE 0 END
        FROM #Base
        UNION ALL
        SELECT 'X', 'Average Payment ($) - Total Pay/Adjudicated Claims',
               CASE WHEN COUNT(DISTINCT CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END)
                    ELSE 0 END
        FROM #Base
    )
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM
    (
        SELECT RowCode, 'LIS'  AS Category, Description, 0 AS BillYear, 0 AS BillMonth, MetricValue, 1 AS CatOrder FROM Lis
        UNION ALL
        SELECT RowCode, 'LIS',  Description, 0, 0, MetricValue, 1 FROM LisPanels
        UNION ALL
        SELECT RowCode, 'PMS',  Description, 0, 0, MetricValue, 2 FROM PMS
        UNION ALL
        SELECT RowCode, 'Cash', Description, 0, 0, MetricValue, 3 FROM Cash
        UNION ALL
        SELECT RowCode, 'Avg',  Description, 0, 0, MetricValue, 4 FROM AvgRows
    ) result
    ORDER BY CatOrder, RowCode;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #FilterPanels;
    DROP TABLE IF EXISTS #FilterClinics;
    DROP TABLE IF EXISTS #FilterProviders;
    DROP TABLE IF EXISTS #FilterReps;
END;
GO

PRINT '17_Cove_ExecutiveSummary_Read.sql completed.';
GO
