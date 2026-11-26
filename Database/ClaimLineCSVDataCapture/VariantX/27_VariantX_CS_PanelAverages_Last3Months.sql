-- =====================================================================
-- VariantX – Panel Averages Last 3 Months (fix)
-- File : 27_VariantX_CS_PanelAverages_Last3Months.sql
-- DB   : VariantX_LRN
--
-- @LastMonths = 3 → last 3 calendar months ending at the month of max DOS
--   (include MaxDos month). Example: MaxDos 2026-03-31 → 2026-01-01..2026-03-31.
--   Sheet example "Feb..Apr excluding May" = those 3 months when MaxDos is in Apr.
-- @LastMonths = 6 → rolling window ending at max DOS (unchanged).
--
-- Metrics (client Excel pivot / Panel Averages sheet):
--   Billed     = Count(ClaimID), Sum/Avg(ChargeAmount)
--   Fully Paid = Count(FullyPaidCount='Fully Paid'), Sum/Avg(FullyPaidAmount)
--   Adjudicated= Count(AdjucticatedCount non-blank), Sum(AdjucticatedAmount),
--                Avg = Sum/Count(flag)  — includes $0 flagged rows (client pivot)
--   30 / 60    = Count(Bucket30/60Count non-blank), Sum(Bucket30/60Amount),
--                Avg = Sum/Count(flag)
-- Returns WindowFrom / WindowTo for UI and Excel.
-- =====================================================================
SET NOCOUNT ON;
GO

IF DB_NAME() NOT LIKE N'VariantX%'
BEGIN
    RAISERROR(N'27_VariantX_CS_PanelAverages_Last3Months.sql must run on a VariantX database.', 16, 1);
    RETURN;
END
GO

PRINT 'Updating dbo.usp_GetVarX_CS_AvgPayments (Panel Averages Last 3 Months fix)...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_CS_AvgPayments
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL,
    @LastMonths      INT           = 6
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@LastMonths, 0) NOT IN (3, 6)
        SET @LastMonths = 6;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @MaxDos DATE =
        (SELECT MAX(TRY_CAST(DateOfService AS DATE))
         FROM dbo.ClaimLevelData
         WHERE TRY_CAST(DateOfService AS DATE) IS NOT NULL
           AND TRY_CAST(DateOfService AS DATE) <= CAST(GETDATE() AS DATE));

    DECLARE @WindowFrom DATE;
    DECLARE @WindowEnd  DATE; -- exclusive
    DECLARE @WindowTo   DATE; -- inclusive

    IF @LastMonths = 3
    BEGIN
        -- Last 3 calendar months ending with the MaxDos month (inclusive).
        -- MaxDos in Mar → Jan 1 .. Mar 31. MaxDos in Apr → Feb 1 .. Apr 30.
        SET @WindowEnd  = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@MaxDos), MONTH(@MaxDos), 1));
        SET @WindowFrom = DATEADD(MONTH, -3, @WindowEnd);
        SET @WindowTo   = DATEADD(DAY, -1, @WindowEnd);
    END
    ELSE
    BEGIN
        SET @WindowEnd  = DATEADD(DAY, 1, @MaxDos);
        SET @WindowFrom = DATEADD(DAY, 1, DATEADD(MONTH, -@LastMonths, @MaxDos));
        SET @WindowTo   = @MaxDos;
    END

    ;WITH base AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))        AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            CASE WHEN LTRIM(RTRIM(FullyPaidCount)) = N'Fully Paid' THEN 1 ELSE 0 END AS IsFullyPaid,
            COALESCE(
                TRY_CAST(FullyPaidAmount AS DECIMAL(18,2)),
                TRY_CAST(InsurancePayment AS DECIMAL(18,2)),
                0) AS FullyPaidAmt,
            -- Counts follow Excel "Count of <FlagColumn>" (non-blank), not amount > 0.
            CASE WHEN NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '') IS NOT NULL THEN 1 ELSE 0 END AS IsAdjudicated,
            ISNULL(TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2)), 0) AS AdjudicatedAmt,
            CASE WHEN NULLIF(LTRIM(RTRIM(Bucket30Count)), '') IS NOT NULL THEN 1 ELSE 0 END AS IsBucket30,
            ISNULL(TRY_CAST(Bucket30Amount AS DECIMAL(18,2)), 0) AS Bucket30Amt,
            CASE WHEN NULLIF(LTRIM(RTRIM(Bucket60Count)), '') IS NOT NULL THEN 1 ELSE 0 END AS IsBucket60,
            ISNULL(TRY_CAST(Bucket60Amount AS DECIMAL(18,2)), 0) AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateOfService AS DATE) >= @WindowFrom
          AND TRY_CAST(DateOfService AS DATE) < @WindowEnd
          AND NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo IS NULL OR TRY_CAST(CheckDate AS DATE) <= @CheckDateTo)
    )
    SELECT
        @WindowFrom AS WindowFrom,
        @WindowTo   AS WindowTo,
        PanelName,
        PayerName,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
        ISNULL(SUM(Chg), 0) AS TotalCharges,
        ISNULL(SUM(InsPay), 0) AS CarrierPayment,
        COUNT(CASE WHEN IsFullyPaid = 1 THEN ClaimID END) AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN IsFullyPaid = 1 THEN FullyPaidAmt ELSE 0 END), 0) AS FullyPaidAmount,
        COUNT(CASE WHEN IsAdjudicated = 1 THEN ClaimID END) AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN IsAdjudicated = 1 THEN AdjudicatedAmt ELSE 0 END), 0) AS AdjudicatedAmount,
        COUNT(CASE WHEN IsBucket30 = 1 THEN ClaimID END) AS Days30Count,
        ISNULL(SUM(CASE WHEN IsBucket30 = 1 THEN Bucket30Amt ELSE 0 END), 0) AS Days30Amount,
        COUNT(CASE WHEN IsBucket60 = 1 THEN ClaimID END) AS Days60Count,
        ISNULL(SUM(CASE WHEN IsBucket60 = 1 THEN Bucket60Amt ELSE 0 END), 0) AS Days60Amount
    FROM base
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, NoOfClaims DESC, PayerName;
END
GO

-- Smoke
DECLARE @MaxDos DATE =
    (SELECT MAX(TRY_CAST(DateOfService AS DATE))
     FROM dbo.ClaimLevelData
     WHERE TRY_CAST(DateOfService AS DATE) IS NOT NULL
       AND TRY_CAST(DateOfService AS DATE) <= CAST(GETDATE() AS DATE));

DECLARE @WinEnd  DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@MaxDos), MONTH(@MaxDos), 1));
DECLARE @WinFrom DATE = DATEADD(MONTH, -3, @WinEnd);
DECLARE @WinTo   DATE = DATEADD(DAY, -1, @WinEnd);

SELECT @MaxDos AS MaxDos, @WinFrom AS ThreeMonthFrom, @WinTo AS ThreeMonthToInclusive;

CREATE TABLE #g (
    WindowFrom        DATE,
    WindowTo          DATE,
    PanelName         NVARCHAR(500),
    PayerName         NVARCHAR(500),
    NoOfClaims        INT,
    TotalCharges      DECIMAL(18,2),
    CarrierPayment    DECIMAL(18,2),
    FullyPaidCount    INT,
    FullyPaidAmount   DECIMAL(18,2),
    AdjudicatedCount  INT,
    AdjudicatedAmount DECIMAL(18,2),
    Days30Count       INT,
    Days30Amount      DECIMAL(18,2),
    Days60Count       INT,
    Days60Amount      DECIMAL(18,2)
);

INSERT #g EXEC dbo.usp_GetVarX_CS_AvgPayments @LastMonths = 3;

SELECT
    'Last3' AS K,
    MIN(WindowFrom) AS WindowFrom,
    MAX(WindowTo) AS WindowTo,
    COUNT(DISTINCT PanelName) AS Panels,
    SUM(NoOfClaims) AS Claims,
    SUM(TotalCharges) AS Charges
FROM #g;

SELECT TOP 12
    PanelName,
    SUM(NoOfClaims) AS Claims,
    SUM(TotalCharges) AS Charges,
    CASE WHEN SUM(NoOfClaims) > 0 THEN SUM(TotalCharges) * 1.0 / SUM(NoOfClaims) ELSE 0 END AS AvgBilled,
    SUM(FullyPaidCount) AS FpCnt,
    SUM(FullyPaidAmount) AS FpAmt,
    SUM(AdjudicatedCount) AS AdjCnt,
    SUM(AdjudicatedAmount) AS AdjAmt,
    SUM(Days30Count) AS D30Cnt,
    SUM(Days60Count) AS D60Cnt
FROM #g
GROUP BY PanelName
ORDER BY Claims DESC;

DROP TABLE #g;
GO

PRINT '27_VariantX_CS_PanelAverages_Last3Months.sql completed.';
GO
