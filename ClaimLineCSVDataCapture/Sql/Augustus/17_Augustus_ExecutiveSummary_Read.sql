-- ============================================================
-- Augustus – Executive Summary Read SP
-- File : 17_Augustus_ExecutiveSummary_Read.sql
-- DB   : Augustus_LRN
--
-- Mirrors Cove\17_Cove_ExecutiveSummary_Read.sql.
--
-- usp_GetAugustus_ExecutiveSummary(@YearFrom,@YearTo,@MonthFrom,@MonthTo)
--   @YearFrom/@YearTo/@MonthFrom/@MonthTo : INT = 0 (0 = unbounded)
--   @HasFilter = 1 if any of the four parameters is non-zero.
--
-- No-filter path (fast read): UNION ALL of the 4 aggregate tables
-- (Augustus_ES_LIS, Augustus_ES_PMS, Augustus_ES_Cash, Augustus_ES_Avg),
-- each row already bucketed by (ESYear, ESMonth) with a (0,0) grand-total
-- sentinel, returned as (RowCode, Category, Description, BillYear, BillMonth,
-- MetricValue).
--
-- Filtered path (live re-aggregation): re-derives ALL RowCodes from
-- dbo.LIMSMaster (LIS, date-filtered on ReqCollectDate) and
-- dbo.ClaimLevelData (PMS/Cash/Avg, date-filtered on DateofService),
-- collapsed into a single "filtered total" bucket (BillYear=0, BillMonth=0).
--
-- Augustus LIS uses:
--   BillTo       -> maps to BillCategory column in LIMSMaster
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
    @ReceivedFrom DATE          = NULL,
    @ReceivedTo   DATE          = NULL,
    @BilledFrom   DATE          = NULL,
    @BilledTo     DATE          = NULL,
    @PostedFrom   DATE          = NULL,
    @PostedTo     DATE          = NULL,
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
        WHEN @ReceivedFrom IS NOT NULL THEN 1
        WHEN @ReceivedTo   IS NOT NULL THEN 1
        WHEN @BilledFrom   IS NOT NULL THEN 1
        WHEN @BilledTo     IS NOT NULL THEN 1
        WHEN @PostedFrom   IS NOT NULL THEN 1
        WHEN @PostedTo     IS NOT NULL THEN 1
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
    --  FILTERED  -  live re-aggregation
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

    -- ── LIS: build #Lis from dbo.LIMSMaster, date-filtered on ReqCollectDate ──
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession     NVARCHAR(100) NOT NULL,
        BillTo        NVARCHAR(200) NOT NULL,
        BillingStatus NVARCHAR(200) NOT NULL,
        FinalStatus   NVARCHAR(200) NOT NULL,
        ClientStatus1 NVARCHAR(200) NOT NULL
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

        IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @BillToCol IS NOT NULL AND @BillingStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        BEGIN
            DECLARE @CS1Expr NVARCHAR(400) = CASE WHEN @ClientStatus1Col IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientStatus1Col + N']), '''')))'
                ELSE N'''''' END;

            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (Accession, BillTo, BillingStatus, FinalStatus, ClientStatus1)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
                    ' + @CS1Expr + N'
                FROM dbo.LIMSMaster
                WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
                  AND (ISNULL(@iYearFrom,0)=0  OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iYearFrom)
                  AND (ISNULL(@iYearTo,0)=0    OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iYearTo)
                  AND (ISNULL(@iMonthFrom,0)=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iMonthFrom)
                  AND (ISNULL(@iMonthTo,0)=0   OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iMonthTo)
                  AND (@iReceivedFrom IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) >= @iReceivedFrom)
                  AND (@iReceivedTo   IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) <= @iReceivedTo);';

            EXEC sp_executesql @LisSql,
                N'@iYearFrom INT, @iYearTo INT, @iMonthFrom INT, @iMonthTo INT, @iReceivedFrom DATE, @iReceivedTo DATE',
                @iYearFrom=@YearFrom, @iYearTo=@YearTo, @iMonthFrom=@MonthFrom, @iMonthTo=@MonthTo,
                @iReceivedFrom=@ReceivedFrom, @iReceivedTo=@ReceivedTo;
        END
    END

    -- ── PMS/Cash/Avg: build #Base from dbo.ClaimLevelData, date-filtered ────
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        ISNULL(LTRIM(RTRIM(BillingStatus)),  '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Source)), '')        AS Source,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance
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
      AND (@PostedFrom IS NULL OR TRY_CAST(PostedDate      AS DATE) >= @PostedFrom)
      AND (@PostedTo   IS NULL OR TRY_CAST(PostedDate      AS DATE) <= @PostedTo)
      AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(PanelType,         ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterPanels))
      AND (@HasClinicFilter   = 0 OR LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterClinics))
      AND (@HasProviderFilter = 0 OR LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterProviders))
      AND (@HasRepFilter      = 0 OR LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterReps));

    -- ────────────────────────────────────────────────────────────────────
    --  LIS  -  A, A.1, A.1.1, A.1.2, A.2, A.2.1, A.2.1*, A.2.2,
    --          B, B.1, C, C.1, D, D.1, E, E.1
    -- ────────────────────────────────────────────────────────────────────
    ;WITH Lis AS
    (
        -- A  Insurance Bills
        SELECT 'A'       AS RowCode, 'Insurance Bills'                                     AS Description,
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Insurance Bills' THEN Accession END) AS DECIMAL(18,2)) AS MetricValue FROM #Lis
        UNION ALL SELECT 'A.1',   '  Billed',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Insurance Bills' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'A.1.1', '    Claim Submitted in IRCM',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Insurance Bills' AND BillingStatus='Billed' AND FinalStatus='Claim Submitted in IRCM' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'A.1.2', '    Claim Submitted in Daqbilling',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Insurance Bills' AND BillingStatus='Billed' AND FinalStatus='Claim Submitted in Daqbilling' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'A.2',   '  Unbilled',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Insurance Bills' AND BillingStatus='Unbilled' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'A.2.1', '    Resulted yet to be billed',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Insurance Bills' AND BillingStatus='Unbilled' AND FinalStatus='Resulted yet to be billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'A.2.1*','      Ready to bill',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Insurance Bills' AND BillingStatus='Unbilled' AND FinalStatus='Resulted yet to be billed' AND ClientStatus1='Ready to bill' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'A.2.2', '    Insurance name not listed',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Insurance Bills' AND BillingStatus='Unbilled' AND FinalStatus='Insurance Name Not Listed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        -- B  Yet to be Validated
        UNION ALL SELECT 'B',     'Yet to be Validated',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Yet to be Validated' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B.1',   '  Billed',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Yet to be Validated' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        -- C  Client Bills
        UNION ALL SELECT 'C',     'Client Bills',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Client Bills' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C.1',   '  Billed',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Client Bills' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        -- D  System Test
        UNION ALL SELECT 'D',     'System Test',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='System Test' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D.1',   '  Billed',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='System Test' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        -- E  Self pay
        UNION ALL SELECT 'E',     'Self pay',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Self pay' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E.1',   '  Billed',
               CAST(COUNT(DISTINCT CASE WHEN BillTo='Self pay' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  PMS  -  F, F.1, F.2, G, H, I, J, K, L, M, N, O, O.1, O.2, O.3
    -- ────────────────────────────────────────────────────────────────────
    PMS AS
    (
        SELECT 'F'   AS RowCode, 'No. of Billed Claims'                                AS Description,
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2)) AS MetricValue FROM #Base
        UNION ALL SELECT 'F.1',  '  No. of Claims Billed in IRCM',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='IRCM' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'F.2',  '  No. of Claims Billed in Daq Billing',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='Daq' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'G',    'No. of Unbilled Claims',
               CAST(COUNT(DISTINCT CASE WHEN (BillStatus='' OR BillStatus IS NULL) AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'H',    'Client bill claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'I',    'No. of Fully Paid Claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'J',    'No. of Patient Paid Claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Patient paid' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'K',    'No. of Patient Responsibility Claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Pat Responsibility' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'L',    'No. of Partially Paid Claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Partial Paid' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'M',    'No. of Adjusted/Written Off Claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'N',    'No. of Partially Adjusted/Written Off Claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'O',    'No. of Insurance Balance Claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied','No Response') THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'O.1',  '  No. of Fully Denied Claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Denied' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'O.2',  '  No. of Partially Denied Claims',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Denied' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'O.3',  '  No. of No Response from Payor',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='No Response' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Cash  -  P, P.1, P.2, Q, R, S, T, U, U.1, U.2, V, W, X, X.1, X.2, X.3
    -- ────────────────────────────────────────────────────────────────────
    Cash AS
    (
        SELECT 'P'   AS RowCode, 'Total Billed ($)'              AS Description,
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN ChargeAmount ELSE 0 END) AS MetricValue FROM #Base
        UNION ALL SELECT 'P.1',  '  Total Charge of Claims Billed (IRCM)',
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='IRCM' THEN ChargeAmount ELSE 0 END) FROM #Base
        UNION ALL SELECT 'P.2',  '  Total Charge of Claims Billed (Daq)',
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='Daq' THEN ChargeAmount ELSE 0 END) FROM #Base
        UNION ALL SELECT 'Q',    'Total Unbilled ($)',
               SUM(CASE WHEN (BillStatus='' OR BillStatus IS NULL) AND ClaimStatus<>'Billed amount 0' THEN ChargeAmount ELSE 0 END) FROM #Base
        UNION ALL SELECT 'R',    'Insurance Payment ($)',
               SUM(CASE WHEN InsurancePayment > 0 AND ClaimStatus='Fully Paid' THEN InsurancePayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'S',    'Partially Paid ($)',
               SUM(CASE WHEN ClaimStatus='Partial Paid' THEN InsurancePayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'T',    'Patient Paid ($)',
               SUM(CASE WHEN PatientPayment > 0 THEN PatientPayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'U',    'Patient Responsibility ($)',
               SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN PatientBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'U.1',  '  Daqbilling',
               SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND Source='Daq' THEN PatientBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'U.2',  '  IRCM',
               SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND Source='IRCM' THEN PatientBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'V',    'Adjustment amount ($)',
               SUM(InsuranceAdjustments + PatientAdjustments) FROM #Base
        UNION ALL SELECT 'W',    'Total Payments ($) - Insurance',
               SUM(CASE WHEN InsurancePayment > 0 THEN InsurancePayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'X',    'Insurance Balance ($)',
               SUM(InsuranceBalance) FROM #Base
        UNION ALL SELECT 'X.1',  '  Fully Denied',
               SUM(CASE WHEN ClaimStatus='Fully Denied' THEN InsuranceBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'X.2',  '  Partially Denied',
               SUM(CASE WHEN ClaimStatus='Partially Denied' THEN InsuranceBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'X.3',  '  No Response from Payor',
               SUM(CASE WHEN ClaimStatus='No Response' THEN InsuranceBalance ELSE 0 END) FROM #Base
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Avg  -  Y, Z, AA
    -- ────────────────────────────────────────────────────────────────────
    AvgRows AS
    (
        SELECT 'Y' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               CASE WHEN COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END)
                    ELSE 0 END AS MetricValue
        FROM #Base

        UNION ALL
        SELECT 'Z', 'Average Payment ($) - Total Pay/Paid Claims',
               CASE WHEN COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN ClaimStatus='Fully Paid' THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END)
                    ELSE 0 END
        FROM #Base

        UNION ALL
        SELECT 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
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
        SELECT RowCode, 'PMS',  Description, 0, 0, MetricValue, 2 FROM PMS
        UNION ALL
        SELECT RowCode, 'Cash', Description, 0, 0, MetricValue, 3 FROM Cash
        UNION ALL
        SELECT RowCode, 'Avg',  Description, 0, 0, MetricValue, 4 FROM AvgRows
    ) result
    ORDER BY CatOrder, RowCode;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '17_Augustus_ExecutiveSummary_Read.sql completed.';
GO
