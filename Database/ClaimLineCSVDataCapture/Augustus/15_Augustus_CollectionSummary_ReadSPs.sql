-- =====================================================================
-- Augustus - Collection Summary READ Stored Procedures
-- Used by LabMetricsDashboard Collection Summary page (Monthly + Weekly
-- Claim Volume tabs) and the related Excel export.
--
-- Pattern mirrors dbo.usp_GetNW_CS_MonthlyClaimVolume / WeeklyClaimVolume:
--   1) No filters  -> read pre-aggregated dbo.Aug_CS_* snapshot tables.
--   2) Any filters -> aggregate live from dbo.ClaimLevelData.
--
-- List parameters use '|' delimiter.
-- =====================================================================

SET NOCOUNT ON;
GO

-- =====================================================================
-- Monthly Claim Volume - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_MonthlyClaimVolume
-- Filter: InsurancePayment > 0, valid CheckDate
-- Rows: PanelNew, PayerName_Raw with PayerRank
-- Columns: Year/Month from CheckDate
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_MonthlyClaimVolume
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment,
               CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM dbo.Aug_CS_MonthlyClaimVolume
        ORDER BY PanelName, PayerRank, BillYear, BillMonth;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            YEAR (TRY_CAST(CheckDate AS DATE))             AS BillYear,
            MONTH(TRY_CAST(CheckDate AS DATE))             AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            YEAR (TRY_CAST(CheckDate AS DATE)),
            MONTH(TRY_CAST(CheckDate AS DATE))
    ),
    Ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM Agg
        GROUP BY PanelName, PayerName
    )
    SELECT  a.PanelName,
            a.PayerName,
            CAST(r.PayerRank AS INT) AS PayerRank,
            a.BillYear,
            CAST(a.BillMonth AS TINYINT) AS BillMonth,
            a.NoOfClaims,
            a.InsurancePayment,
            CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM Agg a
    JOIN Ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.BillYear, a.BillMonth;
END
GO

-- =====================================================================
-- Weekly Claim Volume - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_WeeklyClaimVolume
-- Filter: InsurancePayment > 0, valid CheckDate
-- No-filter path reads aggregate values.
-- Filter path calculates last 4 weeks from latest CheckDate in filtered data.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_WeeklyClaimVolume
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
               NoOfClaims, InsurancePayment,
               CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM dbo.Aug_CS_WeeklyClaimVolume
        ORDER BY PanelName, PayerRank, WeekKey;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @LatestCheckDate DATE;

    SELECT @LatestCheckDate = MAX(TRY_CAST(CheckDate AS DATE))
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo);

    IF @LatestCheckDate IS NULL
    BEGIN
        SELECT  CAST(NULL AS NVARCHAR(500)) AS PanelName,
                CAST(NULL AS NVARCHAR(500)) AS PayerName,
                CAST(NULL AS INT) AS PayerRank,
                CAST(NULL AS TINYINT)       AS WeekKey,
                CAST(NULL AS DATE)          AS WeekStart,
                CAST(NULL AS DATE)          AS WeekEnd,
                CAST(NULL AS INT)           AS NoOfClaims,
                CAST(NULL AS DECIMAL(18,2)) AS InsurancePayment,
                CAST(NULL AS DECIMAL(18,2)) AS AveragePaidAmount
        WHERE 1 = 0;
        RETURN;
    END;

    -- Sunday-ending weeks, with Week 4 ending on the latest data point's week end.
    DECLARE @DaysSinceSun INT = ((DATEDIFF(DAY, '1900-01-07', @LatestCheckDate) % 7) + 7) % 7;
    DECLARE @W4End DATE = DATEADD(DAY, 6 - @DaysSinceSun, @LatestCheckDate);
    DECLARE @W4Start DATE = DATEADD(DAY, -6, @W4End);
    DECLARE @W3End DATE = DATEADD(DAY, -7, @W4End),  @W3Start DATE = DATEADD(DAY, -13, @W4End);
    DECLARE @W2End DATE = DATEADD(DAY,-14, @W4End),  @W2Start DATE = DATEADD(DAY, -20, @W4End);
    DECLARE @W1End DATE = DATEADD(DAY,-21, @W4End),  @W1Start DATE = DATEADD(DAY, -27, @W4End);

    ;WITH Src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CASE
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W4End
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    Agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
               ISNULL(SUM(InsurancePayment), 0) AS InsurancePayment
        FROM Src
        WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    Ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM Agg
        GROUP BY PanelName, PayerName
    )
    SELECT  a.PanelName,
            a.PayerName,
            CAST(r.PayerRank AS INT) AS PayerRank,
            CAST(a.WeekKey AS TINYINT) AS WeekKey,
            CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start WHEN 3 THEN @W3Start WHEN 4 THEN @W4Start END AS WeekStart,
            CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End   WHEN 3 THEN @W3End   WHEN 4 THEN @W4End   END AS WeekEnd,
            a.NoOfClaims,
            a.InsurancePayment,
            CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM Agg a
    JOIN Ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.WeekKey;
END
GO

-- =====================================================================
-- Panel Averages - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_PanelAverages
-- No-filter path: reads Aug_CS_PanelAverages snapshot.
-- Filter path:    aggregates live from dbo.ClaimLevelData.
-- Columns: PanelName, PayerName,
--   NoOfClaims, TotalCharges, CarrierPayment,
--   FullyPaidCount, FullyPaidAmount,
--   AdjudicatedCount (0 — not in Aug snapshot), AdjudicatedAmount (0),
--   Days30Count, Days30Amount, Days60Count, Days60Amount
-- Augustus: PanelNew (not PanelType), Bucket30/'30 Bucket', Bucket60/'60 Bucket'
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_PanelAverages
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, PayerName, NoOfClaims, TotalCharges, CarrierPayment,
               FullyPaidCount, FullyPaidAmount,
               0 AS AdjudicatedCount, CAST(0 AS DECIMAL(18,2)) AS AdjudicatedAmount,
               Days30Count, Days30Amount, Days60Count, Days60Amount
        FROM dbo.Aug_CS_PanelAverages
        ORDER BY PanelName, PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID))) AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))    AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                      AS ClaimStatus,
            LTRIM(RTRIM(Bucket30))                         AS Bucket30,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))      AS Bucket30Amt,
            LTRIM(RTRIM(Bucket60))                         AS Bucket60,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))      AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE PanelNew IS NOT NULL AND LTRIM(RTRIM(PanelNew)) <> ''
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PanelName, PayerName,
        COUNT(DISTINCT CASE WHEN ClaimStatus <> 'No Response' THEN VisitKey END)       AS NoOfClaims,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN Chg    ELSE 0 END), 0)  AS TotalCharges,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN InsPay ELSE 0 END), 0)  AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Paid' THEN VisitKey END)         AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN ClaimStatus = 'Fully Paid' THEN InsPay ELSE 0 END), 0)    AS FullyPaidAmount,
        0                                                                               AS AdjudicatedCount,
        CAST(0 AS DECIMAL(18,2))                                                        AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN Bucket30 = '30 Bucket' THEN VisitKey END)             AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30 = '30 Bucket' THEN Bucket30Amt ELSE 0 END), 0)   AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Bucket60 = '60 Bucket' THEN VisitKey END)             AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60 = '60 Bucket' THEN Bucket60Amt ELSE 0 END), 0)   AS Days60Amount
    FROM src
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, PayerName;
END
GO

-- =====================================================================
-- Average Payments - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_AvgPayments
-- No-filter path: reads Aug_CS_AvgPayments snapshot.
-- Filter path:    aggregates live from dbo.ClaimLevelData.
-- Augustus: PanelNew, Adjudicated/'Adjudicated', Bucket30/'30 Bucket', Bucket60/'60 Bucket'
-- Columns (C# alias map): ClaimCount->NoOfClaims, InsurancePayment->CarrierPayment,
--   Over30Count->Days30Count, Over60Count->Days60Count
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_AvgPayments
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, PayerName,
               ClaimCount AS NoOfClaims, TotalCharges, InsurancePayment AS CarrierPayment,
               FullyPaidCount, FullyPaidAmount, AdjudicatedCount, AdjudicatedAmount,
               Over30Count AS Days30Count, Over30Amount AS Days30Amount,
               Over60Count AS Days60Count, Over60Amount AS Days60Amount
        FROM dbo.Aug_CS_AvgPayments
        ORDER BY PanelName, PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))    AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                      AS Status,
            LTRIM(RTRIM(Adjudicated))                      AS Adjudicated,
            TRY_CAST(AdjudicatedAmount AS DECIMAL(18,2))   AS AdjAmt,
            LTRIM(RTRIM(Bucket30))                         AS Bucket30,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))      AS Bucket30Amt,
            LTRIM(RTRIM(Bucket60))                         AS Bucket60,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))      AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND PanelNew      IS NOT NULL AND LTRIM(RTRIM(PanelNew))      <> ''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PanelName, PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                   AS NoOfClaims,
        ISNULL(SUM(Chg),    0)                                              AS TotalCharges,
        ISNULL(SUM(InsPay), 0)                                              AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN Status = 'Fully Paid' THEN ClaimID END)    AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN Status = 'Fully Paid' THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN Adjudicated = 'Adjudicated' THEN ClaimID END)  AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN Adjudicated = 'Adjudicated' THEN AdjAmt ELSE 0 END), 0) AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN Bucket30 = '30 Bucket' THEN ClaimID END)  AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30 = '30 Bucket' THEN Bucket30Amt ELSE 0 END), 0) AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Bucket60 = '60 Bucket' THEN ClaimID END)  AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60 = '60 Bucket' THEN Bucket60Amt ELSE 0 END), 0) AS Days60Amount
    FROM base
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, PayerName;
END
GO

-- =====================================================================
-- Insurance vs Aging - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_InsuranceVsAging
-- No-filter path: reads Aug_CS_InsuranceVsAging snapshot.
-- Filter path:    aggregates live; aging bucket from DaystoDOS.
-- Columns: PayerName, AgingBucket, VisitCount, InsuranceBalance
-- Note: snapshot column is ClaimCount; aliased as VisitCount to match C# reader.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerName, AgingBucket, ClaimCount AS VisitCount, InsuranceBalance
        FROM dbo.Aug_CS_InsuranceVsAging
        ORDER BY PayerName, AgingBucket;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
        CASE
          WHEN ISNULL(TRY_CAST(DaystoDOS AS INT), -1) < 0  THEN '(blank)'
          WHEN TRY_CAST(DaystoDOS AS INT) < 30             THEN 'Current'
          WHEN TRY_CAST(DaystoDOS AS INT) < 60             THEN '30 Days'
          WHEN TRY_CAST(DaystoDOS AS INT) < 90             THEN '60 Days'
          WHEN TRY_CAST(DaystoDOS AS INT) < 120            THEN '90 Days'
          ELSE '120+ Days'
        END                                                  AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))             AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance
    FROM dbo.ClaimLevelData
    WHERE PayerName_Raw IS NOT NULL
      AND LTRIM(RTRIM(ClaimStatus)) <> 'No Response'
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        CASE
          WHEN ISNULL(TRY_CAST(DaystoDOS AS INT), -1) < 0  THEN '(blank)'
          WHEN TRY_CAST(DaystoDOS AS INT) < 30             THEN 'Current'
          WHEN TRY_CAST(DaystoDOS AS INT) < 60             THEN '30 Days'
          WHEN TRY_CAST(DaystoDOS AS INT) < 90             THEN '60 Days'
          WHEN TRY_CAST(DaystoDOS AS INT) < 120            THEN '90 Days'
          ELSE '120+ Days'
        END
    ORDER BY PayerName, AgingBucket;
END
GO

-- =====================================================================
-- Panel vs Payment - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_PanelVsPayment
-- No-filter path: reads Aug_CS_PanelVsPayment (sums monthly grain to panel total).
-- Filter path:    aggregates live from dbo.ClaimLevelData.
-- Columns: PanelName, NoOfClaims, InsurancePayments
-- Augustus: PanelNew (not PanelType)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_PanelVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName,
               SUM(NoOfClaims)        AS NoOfClaims,
               SUM(InsurancePayment)  AS InsurancePayments
        FROM dbo.Aug_CS_PanelVsPayment
        GROUP BY PanelName
        ORDER BY SUM(InsurancePayment) DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(PanelNew, 'Unknown')))                        AS PanelName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                 AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)      AS InsurancePayments
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
      AND CheckDate <> ''
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(ISNULL(PanelNew, 'Unknown')))
    ORDER BY SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))) DESC;
END
GO

-- =====================================================================
-- Rep vs Payment - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_RepVsPayment
-- No-filter path: reads Aug_CS_RepVsPayment snapshot.
-- Filter path:    aggregates live from dbo.ClaimLevelData.
-- Columns: SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_RepVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment
        FROM dbo.Aug_CS_RepVsPayment
        ORDER BY SalesRepName, CheckYear, CheckMonth;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(SalesRepname))                                        AS SalesRepName,
        CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT)                   AS CheckYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT)                   AS CheckMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                 AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)      AS InsurancePayment
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND SalesRepname IS NOT NULL AND LTRIM(RTRIM(SalesRepname)) <> ''
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(SalesRepname)),
        CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT),
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT)
    ORDER BY SalesRepName, CheckYear, CheckMonth;
END
GO

-- =====================================================================
-- Insurance vs Payment % - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_InsuranceVsPaymentPct
-- No-filter path: reads Aug_CS_InsuranceVsPaymentPct snapshot.
-- Filter path:    aggregates live from dbo.ClaimLevelData, grouped by PayerName/Month.
-- Columns: PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct
-- Note: Aug snapshot has no BillYear/BillMonth; no-filter path returns NULL for those.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsPaymentPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        -- BillYear/BillMonth intentionally NULL — snapshot is payer-level totals only.
        -- C# reader already guards against DBNull for these columns.
        SELECT PayerName,
               CAST(NULL AS INT) AS BillYear,
               CAST(NULL AS INT) AS BillMonth,
               NoOfPaidClaims, InsurancePayment, PaymentPct
        FROM dbo.Aug_CS_InsuranceVsPaymentPct
        ORDER BY InsurancePayment DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT) AS BillYear,
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT) AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
          AND CheckDate <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT),
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT)
    ),
    grand AS (
        SELECT BillYear, BillMonth,
               NULLIF(SUM(InsurancePayment), 0) AS TotalInsurancePayment
        FROM agg
        GROUP BY BillYear, BillMonth
    )
    SELECT a.PayerName, a.BillYear, a.BillMonth,
           a.NoOfPaidClaims, a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / ISNULL(g.TotalInsurancePayment, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM agg a
    INNER JOIN grand g ON a.BillYear = g.BillYear AND a.BillMonth = g.BillMonth
    ORDER BY a.BillYear DESC, a.BillMonth DESC, a.InsurancePayment DESC;
END
GO

-- =====================================================================
-- CPT vs Payment % - Collection Summary
-- Source: dbo.LineLevelData / dbo.Aug_CS_CptVsPaymentPct
-- No-filter path: reads Aug_CS_CptVsPaymentPct snapshot.
-- Filter path:    aggregates live from dbo.LineLevelData.
-- Columns: CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_CptVsPaymentPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct
        FROM dbo.Aug_CS_CptVsPaymentPct
        ORDER BY SumUnits DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(CPTCode))                                             AS CPTCode,
        ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)                 AS SumUnits,
        ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                        THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidInsurancePayment,
        ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                        THEN TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChargeAmount
    FROM dbo.LineLevelData
    WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelName,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(CPTCode))
    ORDER BY SumUnits DESC;
END
GO

-- =====================================================================
-- Status Summary - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_StatusSummary
-- No-filter path: reads Aug_CS_StatusSummary snapshot.
-- Filter path:    aggregates live from dbo.ClaimLevelData.
-- Columns: ClaimStatus, PanelName, CptCode, PayerName,
--          NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
-- Augustus: PanelNew (not PanelType), CPTCodeXUnitsXModifier -> CptCode
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_StatusSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ClaimStatus, PanelName, CptCode, PayerName,
               NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
        FROM dbo.Aug_CS_StatusSummary;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        ISNULL(LTRIM(RTRIM(ClaimStatus)),            '(blank)') AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(PanelNew)),               '(blank)') AS PanelName,
        ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), '(blank)') AS CptCode,
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),          '(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))         AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0) AS PatientBalance
    FROM dbo.ClaimLevelData
    WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ClaimStatus)),
        LTRIM(RTRIM(PanelNew)),
        LTRIM(RTRIM(CPTCodeXUnitsXModifier)),
        LTRIM(RTRIM(PayerName_Raw));
END
GO

-- =====================================================================
-- Provider Summary - Collection Summary
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_ProviderSummary
-- No-filter path: reads Aug_CS_ProviderSummary snapshot.
-- Filter path:    aggregates live from dbo.ClaimLevelData.
-- Columns: ProviderRank, ReferringProvider, NoOfClaims,
--          InsurancePayments (InsurancePayment — Augustus uses this; NW uses ProcTotalPayment),
--          InsuranceBalance, PatientBalance
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_ProviderSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ProviderRank, ReferringProvider, NoOfClaims,
               InsurancePayment AS InsurancePayments, InsuranceBalance, PatientBalance
        FROM dbo.Aug_CS_ProviderSummary
        ORDER BY ProviderRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ReferringProvider))                               AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))             AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayments,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ReferringProvider IS NOT NULL
          AND LTRIM(RTRIM(ReferringProvider)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)

          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(ReferringProvider))
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS ProviderRank,
        ReferringProvider, NoOfClaims, InsurancePayments, InsuranceBalance, PatientBalance
    FROM agg
    ORDER BY ProviderRank;
END
GO

-- =====================================================================
-- 12. Top 5 Reimbursement % (by SumInsurancePayment / UniqueVisitCount)
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_Top5ReimbursementPct
-- No-filter path: reads Aug_CS_Top5ReimbursementPct snapshot.
-- Filter path:    aggregates live from dbo.ClaimLevelData.
-- Panel filter uses PanelNew (Augustus-specific column).
-- Columns: PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_Top5ReimbursementPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount
        FROM dbo.Aug_CS_Top5ReimbursementPct
        ORDER BY PayerRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                                 AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID)))     AS VisitKey,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))                                    AS InsPay,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))                                    AS Chg
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    agg AS (
        SELECT PayerName,
               ISNULL(SUM(InsPay), 0)                          AS SumInsurancePayment,
               ISNULL(SUM(Chg),    0)                          AS SumChargeAmount,
               COUNT(DISTINCT NULLIF(VisitKey, ''))             AS UniqueVisitCount
        FROM base
        GROUP BY PayerName
    )
    SELECT TOP 5
        CAST(ROW_NUMBER() OVER (ORDER BY SumInsurancePayment DESC) AS INT) AS PayerRank,
        PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount
    FROM agg
    ORDER BY PayerRank;
END
GO

-- =====================================================================
-- 13. Top 5 Reimbursement Payments (by TotalPayments / UniqueVisitCount)
-- Source: dbo.ClaimLevelData / dbo.Aug_CS_Top5ReimbursementPay
-- No-filter path: reads Aug_CS_Top5ReimbursementPay snapshot.
-- Filter path:    aggregates live from dbo.ClaimLevelData.
-- Panel filter uses PanelNew (Augustus-specific column).
-- Columns: PayerRank, PayerName, TotalPayments, UniqueVisitCount
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_Top5ReimbursementPay
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerRank, PayerName, TotalPayments, UniqueVisitCount
        FROM dbo.Aug_CS_Top5ReimbursementPay
        ORDER BY PayerRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                                 AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID)))     AS VisitKey,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))                                    AS InsPay
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    agg AS (
        SELECT PayerName,
               ISNULL(SUM(InsPay), 0)                          AS TotalPayments,
               COUNT(DISTINCT NULLIF(VisitKey, ''))             AS UniqueVisitCount
        FROM base
        GROUP BY PayerName
    )
    SELECT TOP 5
        CAST(ROW_NUMBER() OVER (ORDER BY TotalPayments DESC) AS INT) AS PayerRank,
        PayerName, TotalPayments, UniqueVisitCount
    FROM agg
    ORDER BY PayerRank;
END
GO

-- =====================================================================
-- 14. Insurance vs Payment (Payer / Year / Month breakdown)
-- Source: dbo.ClaimLevelData (live-only — no Aug_CS_InsuranceVsPayment table)
-- Augustus panel filter: PanelNew (not PanelName).
-- Columns: PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- This SP has no snapshot path: there is no Aug_CS_InsuranceVsPayment table.
    -- It always aggregates live from ClaimLevelData.

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))             AS PayerName,
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT)            AS BillYear,
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)        AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))           AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL AND CheckDate <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT),
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)
    ),
    grand AS (
        SELECT BillYear, BillMonth,
               NULLIF(SUM(InsurancePayment), 0) AS Total
        FROM agg
        GROUP BY BillYear, BillMonth
    )
    SELECT a.PayerName, a.BillYear, a.BillMonth, a.NoOfPaidClaims,
           a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM agg a
    INNER JOIN grand g ON a.BillYear = g.BillYear AND a.BillMonth = g.BillMonth
    ORDER BY a.BillYear, a.BillMonth, a.InsurancePayment DESC;
END
GO