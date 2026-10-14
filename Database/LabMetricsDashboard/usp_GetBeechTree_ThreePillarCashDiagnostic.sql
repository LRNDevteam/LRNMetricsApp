/* =====================================================================
   dbo.usp_GetBeechTree_ThreePillarCashDiagnostic
   ---------------------------------------------------------------------
   Beech_Tree Three-Pillar — Pillar 3 Cash / Leakage & Risk ($).

   Comparable window matches LIS + PMS diagnostics:
     @AsOfDate   = Billed WeekRange END date
     @DayWindow  = DAY(@AsOfDate)
     Monthly $ metrics use DOS day BETWEEN 1 AND @DayWindow

   Result sets
     1  Monthly Cash series (Total Billed, Collection Rate, Partially Paid,
        Insurance Balance % + composition $, Patient WO vs Balance,
        Fully Adjusted $)
     2  Fully Adjusted write-off reason Pareto (counts from BTWOSummary)

   Formulas (Cash pillar brief):
     Collection Rate     = Fully Paid Ins $ ÷ Total Billed $ × 100
     % Partially Paid $  = Partially Paid $ ÷ Total Billed $ × 100
     % Insurance Balance = IB $ ÷ Total Billed $ × 100
     No Response share   = No Response IB $ ÷ (FD+NR+PD IB $) × 100
     Write-off ratio     = Patient WO $ ÷ (Patient WO $ + Patient Balance $) × 100
     Patient Coll. Rate  = Patient Payment $ ÷ (Patient Payment $ + Patient Balance $) × 100
     % Fully Adjusted $  = Fully Adjusted $ ÷ Total Billed $ × 100
   ===================================================================== */
IF OBJECT_ID('dbo.usp_GetBeechTree_ThreePillarCashDiagnostic', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_GetBeechTree_ThreePillarCashDiagnostic;
GO
CREATE PROCEDURE dbo.usp_GetBeechTree_ThreePillarCashDiagnostic
    @TrailingMonths INT  = 12,
    @DayWindow      INT  = 0,
    @AsOfDate       DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @t0 DATETIME2 = SYSDATETIME();
    DECLARE @msg NVARCHAR(400);

    IF @AsOfDate IS NULL SET @AsOfDate = CAST(GETDATE() AS date);
    IF @TrailingMonths NOT BETWEEN 1 AND 36 SET @TrailingMonths = 12;
    IF @DayWindow NOT BETWEEN 1 AND 31
        SET @DayWindow = CASE WHEN DAY(@AsOfDate) BETWEEN 1 AND 31 THEN DAY(@AsOfDate) ELSE 9 END;

    DECLARE @AsOfStr VARCHAR(10) = CONVERT(varchar(10), @AsOfDate, 23);
    RAISERROR(N'[Start] ThreePillarCash months=%d dayWindow=%d asOf=%s', 0, 1,
              @TrailingMonths, @DayWindow, @AsOfStr) WITH NOWAIT;

    IF OBJECT_ID('dbo.ClaimLevelData', 'U') IS NULL
    BEGIN
        RAISERROR(N'ClaimLevelData not found — Cash diagnostic cannot run.', 16, 1);
        RETURN;
    END

    DECLARE @HasWO BIT = CASE WHEN OBJECT_ID('dbo.BTWOSummary','U') IS NOT NULL THEN 1 ELSE 0 END;

    -- ES PMS/Cash BillStatus (16_/17_/21_):
    --   ISNULL(LTRIM(RTRIM(BilledUnbilled)), '') AS BillStatus
    -- Must be DYNAMIC SQL: static BilledUnbilled fails CREATE PROC (Msg 207)
    -- when the column is not on ClaimLevelData — IF/ELSE does NOT help (both
    -- branches are bound at create time). Do NOT ALTER / add columns.
    -- Prefer BilledUnbilled (ES); fall back to same-name aliases if present.
    DECLARE @BilledCol SYSNAME = (
        SELECT TOP (1) name
        FROM sys.columns
        WHERE object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND name IN (N'BilledUnbilled', N'BillStatus', N'BilledStatus', N'BilledorNot', N'BillOrNot', N'Billed')
        ORDER BY CASE name
            WHEN N'BilledUnbilled' THEN 0
            WHEN N'BillStatus'     THEN 1
            WHEN N'BilledStatus'   THEN 2
            WHEN N'BilledorNot'    THEN 3
            WHEN N'BillOrNot'      THEN 4
            ELSE 5 END);

    IF @BilledCol IS NULL
    BEGIN
        RAISERROR(N'ClaimLevelData has no billed-flag column (ES expects BilledUnbilled). No ALTER — check live column names.', 16, 1);
        RETURN;
    END

    SET @msg = CONCAT(N'[BillStatus] ES-style: ISNULL(LTRIM(RTRIM(', @BilledCol, N')), '''')');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    DECLARE @LatestY INT = YEAR(@AsOfDate);
    DECLARE @LatestM INT = MONTH(@AsOfDate);

    DECLARE @StartDate DATE = DATEFROMPARTS(
        YEAR(DATEADD(MONTH, -(@TrailingMonths - 1), @AsOfDate)),
        MONTH(DATEADD(MONTH, -(@TrailingMonths - 1), @AsOfDate)),
        1);
    DECLARE @EndDate DATE = @AsOfDate;

    SET @msg = CONCAT(N'[Window] ', CONVERT(varchar(10), @StartDate, 23), N' .. ',
                      CONVERT(varchar(10), @EndDate, 23), N' dayWindow=1..', @DayWindow);
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    /* ── #Base ── */
    IF OBJECT_ID('tempdb..#Base') IS NOT NULL DROP TABLE #Base;
    CREATE TABLE #Base (
        ClaimIDKey           NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear               INT NOT NULL,
        ESMonth              INT NOT NULL,
        DosDay               INT NOT NULL,
        BillStatus           NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus          NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ChargeAmount         DECIMAL(18,2) NOT NULL,
        InsurancePayment     DECIMAL(18,2) NOT NULL,
        PatientPayment       DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL
    );

    -- Same expression as ES #Base BillStatus; column name injected (no static BilledUnbilled).
    DECLARE @BaseSql NVARCHAR(MAX) = N'
        INSERT INTO #Base (
            ClaimIDKey, ESYear, ESMonth, DosDay, BillStatus, ClaimStatus,
            ChargeAmount, InsurancePayment, PatientPayment,
            InsuranceBalance, PatientBalance, PatientAdjustments, InsuranceAdjustments)
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ClaimID))), N''''), N''?'') COLLATE DATABASE_DEFAULT,
            YEAR(d.DOS), MONTH(d.DOS), DAY(d.DOS),
            ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])), N'''') COLLATE DATABASE_DEFAULT,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), N'''') COLLATE DATABASE_DEFAULT,
            ISNULL(TRY_CAST(ChargeAmount AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientPayment AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientBalance AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientAdjustments AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0)
        FROM dbo.ClaimLevelData WITH (NOLOCK)
        CROSS APPLY (SELECT TRY_CAST(DateofService AS DATE) AS DOS) d
        WHERE d.DOS IS NOT NULL
          AND d.DOS >= @pStart
          AND d.DOS <  DATEADD(DAY, 1, @pEnd);';

    EXEC sp_executesql @BaseSql,
        N'@pStart DATE, @pEnd DATE',
        @pStart = @StartDate, @pEnd = @EndDate;

    IF EXISTS (SELECT 1 FROM #Base)
        CREATE CLUSTERED INDEX IX_CashBase_YM ON #Base (ESYear, ESMonth, DosDay);

    SET @msg = CONCAT(N'[#Base] rows=', (SELECT COUNT(*) FROM #Base),
                      N' ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    IF OBJECT_ID('tempdb..#Cmp') IS NOT NULL DROP TABLE #Cmp;
    SELECT * INTO #Cmp FROM #Base WHERE DosDay BETWEEN 1 AND @DayWindow;
    IF EXISTS (SELECT 1 FROM #Cmp)
        CREATE CLUSTERED INDEX IX_CashCmp_YM ON #Cmp (ESYear, ESMonth);

    IF OBJECT_ID('tempdb..#Months') IS NOT NULL DROP TABLE #Months;
    ;WITH n AS (
        SELECT TOP (36) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS rn
        FROM sys.all_objects
    )
    SELECT
        MY        = DATEADD(MONTH, rn, DATEFROMPARTS(YEAR(@StartDate), MONTH(@StartDate), 1)),
        CollYear  = YEAR(DATEADD(MONTH, rn, DATEFROMPARTS(YEAR(@StartDate), MONTH(@StartDate), 1))),
        CollMonth = MONTH(DATEADD(MONTH, rn, DATEFROMPARTS(YEAR(@StartDate), MONTH(@StartDate), 1)))
    INTO #Months
    FROM n
    WHERE DATEADD(MONTH, rn, DATEFROMPARTS(YEAR(@StartDate), MONTH(@StartDate), 1))
          <= DATEFROMPARTS(@LatestY, @LatestM, 1);
    CREATE CLUSTERED INDEX IX_CashMonths ON #Months (CollYear, CollMonth);

    /* ===================================================================
       1) Monthly Cash series
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),

        TotalBilledAmt = SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END),

        InsurancePaymentFullyPaid = SUM(CASE
            WHEN b.BillStatus = N'Billed' AND b.ClaimStatus = N'Fully Paid'
            THEN b.InsurancePayment ELSE 0 END),

        CollectionRatePct = CASE
            WHEN SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END) = 0 THEN NULL
            ELSE CAST(SUM(CASE WHEN b.BillStatus = N'Billed' AND b.ClaimStatus = N'Fully Paid'
                               THEN b.InsurancePayment ELSE 0 END) * 100.0
                 / NULLIF(SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END), 0)
                 AS decimal(18,4)) END,

        PartiallyPaidAmt = SUM(CASE
            WHEN b.BillStatus = N'Billed'
             AND b.ClaimStatus IN (N'Partially Paid', N'Partial Paid')
            THEN b.InsurancePayment ELSE 0 END),

        PctPartiallyPaidOfBilled = CASE
            WHEN SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END) = 0 THEN NULL
            ELSE CAST(SUM(CASE WHEN b.BillStatus = N'Billed'
                                AND b.ClaimStatus IN (N'Partially Paid', N'Partial Paid')
                               THEN b.InsurancePayment ELSE 0 END) * 100.0
                 / NULLIF(SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END), 0)
                 AS decimal(18,4)) END,

        PatientWOAmt = SUM(CASE WHEN b.PatientAdjustments > 0 THEN b.PatientAdjustments ELSE 0 END),
        PatientBalanceAmt = SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.PatientBalance ELSE 0 END),
        PatientPaymentAmt = SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.PatientPayment ELSE 0 END),

        WriteOffRatioPct = CASE
            WHEN SUM(CASE WHEN b.PatientAdjustments > 0 THEN b.PatientAdjustments ELSE 0 END)
               + SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.PatientBalance ELSE 0 END) = 0 THEN NULL
            ELSE CAST(
                SUM(CASE WHEN b.PatientAdjustments > 0 THEN b.PatientAdjustments ELSE 0 END) * 100.0
              / NULLIF(
                    SUM(CASE WHEN b.PatientAdjustments > 0 THEN b.PatientAdjustments ELSE 0 END)
                  + SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.PatientBalance ELSE 0 END), 0)
              AS decimal(18,4)) END,

        PatientCollectionRatePct = CASE
            WHEN SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.PatientPayment ELSE 0 END)
               + SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.PatientBalance ELSE 0 END) = 0 THEN NULL
            ELSE CAST(
                SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.PatientPayment ELSE 0 END) * 100.0
              / NULLIF(
                    SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.PatientPayment ELSE 0 END)
                  + SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.PatientBalance ELSE 0 END), 0)
              AS decimal(18,4)) END,

        FullyAdjustedAmt = SUM(CASE
            WHEN b.BillStatus = N'Billed'
             AND b.ClaimStatus IN (N'Complete W/O', N'Fully Adjusted')
            THEN b.InsuranceAdjustments + b.PatientAdjustments ELSE 0 END),

        PctFullyAdjustedOfBilled = CASE
            WHEN SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END) = 0 THEN NULL
            ELSE CAST(SUM(CASE WHEN b.BillStatus = N'Billed'
                                AND b.ClaimStatus IN (N'Complete W/O', N'Fully Adjusted')
                               THEN b.InsuranceAdjustments + b.PatientAdjustments ELSE 0 END) * 100.0
                 / NULLIF(SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END), 0)
                 AS decimal(18,4)) END,

        InsuranceBalanceAmt = SUM(CASE
            WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied')
            THEN b.InsuranceBalance ELSE 0 END),

        PctInsuranceBalanceOfBilled = CASE
            WHEN SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END) = 0 THEN NULL
            ELSE CAST(SUM(CASE WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied')
                               THEN b.InsuranceBalance ELSE 0 END) * 100.0
                 / NULLIF(SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END), 0)
                 AS decimal(18,4)) END,

        FullyDeniedIBAmt = SUM(CASE WHEN b.ClaimStatus = N'Fully Denied' THEN b.InsuranceBalance ELSE 0 END),
        NoResponseIBAmt = SUM(CASE WHEN b.ClaimStatus = N'No Response' THEN b.InsuranceBalance ELSE 0 END),
        PartiallyDeniedIBAmt = SUM(CASE WHEN b.ClaimStatus = N'Partially Denied' THEN b.InsuranceBalance ELSE 0 END),

        NoResponseSharePct = CASE
            WHEN SUM(CASE WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied')
                          THEN b.InsuranceBalance ELSE 0 END) = 0 THEN NULL
            ELSE CAST(SUM(CASE WHEN b.ClaimStatus = N'No Response' THEN b.InsuranceBalance ELSE 0 END) * 100.0
                 / NULLIF(SUM(CASE WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied')
                                   THEN b.InsuranceBalance ELSE 0 END), 0)
                 AS decimal(18,4)) END
    FROM #Months m
    LEFT JOIN #Cmp b ON b.ESYear = m.CollYear AND b.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS1 monthly] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       2) Fully Adjusted write-off reason Pareto (counts)
       =================================================================== */
    IF @HasWO = 1
    BEGIN
        IF OBJECT_ID('tempdb..#WO') IS NOT NULL DROP TABLE #WO;
        SELECT
            ClaimIDKey = ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ClaimID))), N''), N'?') COLLATE DATABASE_DEFAULT,
            TransactionCodeCombined = LTRIM(RTRIM(CONVERT(NVARCHAR(200), TransactionCodeCombined))) COLLATE DATABASE_DEFAULT,
            MatchingCount = ISNULL(MatchingCount, 0)
        INTO #WO
        FROM dbo.BTWOSummary WITH (NOLOCK)
        WHERE TransactionCodeCombined IS NOT NULL
          AND TRY_CAST(DateofService AS DATE) >= @StartDate
          AND TRY_CAST(DateofService AS DATE) <  DATEADD(DAY, 1, @EndDate);

        SELECT TOP (15)
            ws.TransactionCodeCombined,
            MatchingCount = SUM(ws.MatchingCount)
        FROM #WO ws
        INNER JOIN #Cmp b ON b.ClaimIDKey = ws.ClaimIDKey
         AND b.BillStatus = N'Billed'
         AND b.ClaimStatus IN (N'Complete W/O', N'Fully Adjusted')
        GROUP BY ws.TransactionCodeCombined
        ORDER BY SUM(ws.MatchingCount) DESC;

        IF OBJECT_ID('tempdb..#WO') IS NOT NULL DROP TABLE #WO;
    END
    ELSE
        SELECT TransactionCodeCombined = CAST(N'' AS NVARCHAR(200)), MatchingCount = CAST(0 AS int) WHERE 1 = 0;

    SET @msg = CONCAT(N'[RS2 reasons] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    DROP TABLE IF EXISTS #Cmp;
    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Months;

    PRINT 'usp_GetBeechTree_ThreePillarCashDiagnostic completed.';
END
GO

PRINT 'usp_GetBeechTree_ThreePillarCashDiagnostic created.';
GO
