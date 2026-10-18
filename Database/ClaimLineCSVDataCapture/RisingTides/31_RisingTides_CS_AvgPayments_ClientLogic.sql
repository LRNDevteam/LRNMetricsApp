-- =====================================================================
-- RisingTides - Collection Summary "Average Payments" (client logic)
-- Two tabs / sheets while the client confirms which one to keep:
--   @DateBasis = 'DOS'       -> window on DateofService
--   @DateBasis = 'CheckDate' -> window on CheckDate
--
-- Window (both): 6 calendar months back from the latest date in that
-- column on or before the billed week-range end
-- (latest dbo.LineClaimFileLogs.WeekFolder, e.g. '09.18.2026 - 09.24.2026').
--   From = DATEADD(MONTH, -6, End) + 1 day   (09.27.2026 -> 03.28 .. 09.27)
--
-- Rows    : Panelname, PayerName_Raw (C# drill-down shows Top 3 payers)
-- Values  : No. of Claims       = Count(ClaimID)
--           Total Billed Amount = Sum(ChargeAmount)
--           InsurancePayment    = Sum(InsurancePayment)
--           Fully Paid          = FullyPaidCount    not blank: Count(ClaimID), Sum(FullyPaidAmount)
--           Adjudicated         = AdjucticatedCount not blank: Count(ClaimID), Sum(AdjucticatedAmount)
--           > 30                = Bucket30Count     not blank: Count(ClaimID), Sum(Bucket30Amount)
--           > 60                = Bucket60Count     not blank: Count(ClaimID), Sum(Bucket60Amount)
--           Averages are computed in C# as Sum / Count.
-- Optional Collection Summary filters apply on top of the window.
-- =====================================================================

SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRT_CS_AvgPayments_ClientLogic
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL,
    @DateBasis       VARCHAR(10)   = 'DOS',
    @LastMonths      INT           = 6
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UseCheckDate BIT = CASE WHEN @DateBasis = 'CheckDate' THEN 1 ELSE 0 END;
    IF @LastMonths IS NULL OR @LastMonths < 1 SET @LastMonths = 6;

    DECLARE @WeekFolder NVARCHAR(200), @WeekEnd DATE;
    IF OBJECT_ID(N'dbo.LineClaimFileLogs', N'U') IS NOT NULL
        SELECT TOP 1 @WeekFolder = LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200))))
        FROM dbo.LineClaimFileLogs
        WHERE NULLIF(LTRIM(RTRIM(CAST(RunId AS NVARCHAR(50)))), '') IS NOT NULL
        ORDER BY FileLogId DESC;

    IF CHARINDEX('-', ISNULL(@WeekFolder, '')) > 0
        SET @WeekEnd = TRY_CONVERT(DATE,
            REPLACE(LTRIM(RTRIM(RIGHT(@WeekFolder, CHARINDEX('-', REVERSE(@WeekFolder)) - 1))), '.', '/'), 101);

    DECLARE @WindowTo DATE =
        CASE WHEN @UseCheckDate = 1
            THEN (SELECT MAX(TRY_CAST(CheckDate AS DATE)) FROM dbo.ClaimLevelData
                  WHERE @WeekEnd IS NULL OR TRY_CAST(CheckDate AS DATE) <= @WeekEnd)
            ELSE (SELECT MAX(TRY_CAST(DateofService AS DATE)) FROM dbo.ClaimLevelData
                  WHERE @WeekEnd IS NULL OR TRY_CAST(DateofService AS DATE) <= @WeekEnd)
        END;
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, DATEADD(MONTH, -@LastMonths, @WindowTo));

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH src AS (
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(Panelname)),     ''), '(blank)') AS PanelName,
            ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), '(blank)') AS PayerName,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                           AS ClaimID,
            TRY_CAST(ChargeAmount       AS DECIMAL(18,2))               AS Chg,
            TRY_CAST(InsurancePayment   AS DECIMAL(18,2))               AS InsPay,
            NULLIF(LTRIM(RTRIM(FullyPaidCount)),    '')                 AS FpFlag,
            TRY_CAST(FullyPaidAmount    AS DECIMAL(18,2))               AS FpAmt,
            NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '')                 AS AdjFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))               AS AdjAmt,
            NULLIF(LTRIM(RTRIM(Bucket30Count)),     '')                 AS B30Flag,
            TRY_CAST(Bucket30Amount     AS DECIMAL(18,2))               AS B30Amt,
            NULLIF(LTRIM(RTRIM(Bucket60Count)),     '')                 AS B60Flag,
            TRY_CAST(Bucket60Amount     AS DECIMAL(18,2))               AS B60Amt
        FROM dbo.ClaimLevelData
        WHERE CASE WHEN @UseCheckDate = 1 THEN TRY_CAST(CheckDate AS DATE)
                   ELSE TRY_CAST(DateofService AS DATE) END BETWEEN @WindowFrom AND @WindowTo
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PanelName,
        PayerName,
        CAST(COUNT(ClaimID) AS INT)                                              AS NoOfClaims,
        ISNULL(SUM(Chg), 0)                                                      AS TotalCharges,
        ISNULL(SUM(InsPay), 0)                                                   AS CarrierPayment,
        CAST(COUNT(CASE WHEN FpFlag  IS NOT NULL THEN ClaimID END) AS INT)       AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FpFlag  IS NOT NULL THEN FpAmt  END), 0)            AS FullyPaidAmount,
        CAST(COUNT(CASE WHEN AdjFlag IS NOT NULL THEN ClaimID END) AS INT)       AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjFlag IS NOT NULL THEN AdjAmt END), 0)            AS AdjudicatedAmount,
        CAST(COUNT(CASE WHEN B30Flag IS NOT NULL THEN ClaimID END) AS INT)       AS Days30Count,
        ISNULL(SUM(CASE WHEN B30Flag IS NOT NULL THEN B30Amt END), 0)            AS Days30Amount,
        CAST(COUNT(CASE WHEN B60Flag IS NOT NULL THEN ClaimID END) AS INT)       AS Days60Count,
        ISNULL(SUM(CASE WHEN B60Flag IS NOT NULL THEN B60Amt END), 0)            AS Days60Amount,
        @WindowFrom                                                              AS WindowFrom,
        @WindowTo                                                                AS WindowTo
    FROM src
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, PayerName;
END
GO

-- Verify
-- EXEC dbo.usp_GetRT_CS_AvgPayments_ClientLogic @DateBasis = 'DOS';        -- expect 03/23..09/22 (week 09.18-09.24)
-- EXEC dbo.usp_GetRT_CS_AvgPayments_ClientLogic @DateBasis = 'CheckDate';  -- expect 03/25..09/24
