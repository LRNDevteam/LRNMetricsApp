-- ============================================================
-- Cove Collection — Avg Payments (Correct Logic) v3.1
-- Date: 2026-09-16
-- Fixes vs v3:
--   - UNION ALL ORDER BY (SortGroup in subquery, not outer SELECT)
--   - @PayerList/@PanelList key length (NVARCHAR(450), no 1000-byte PK warning)
--   - Sanity checks use real columns
--
-- Panel total row: PayerName = '' (PayerRank 0 in snapshot)
-- Date: calendar 1st of month N months before MAX(CheckDate)
-- Counts: COUNT(*)
-- ============================================================
SET NOCOUNT ON;
GO

PRINT 'Creating usp_RefreshCove_CS_AvgPayments_ClientLogic v3.1...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_AvgPayments_ClientLogic
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MaxCheck DATE =
        (SELECT MAX(TRY_CAST(CheckDate AS DATE))
         FROM dbo.ClaimLevelData
         WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL);

    DECLARE @Cutoff DATE = DATEFROMPARTS(
        YEAR(DATEADD(MONTH, -6, @MaxCheck)),
        MONTH(DATEADD(MONTH, -6, @MaxCheck)),
        1);

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))        AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            NULLIF(LTRIM(RTRIM(FullyPaidCount)), '')       AS FullyPaidFlag,
            NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '')    AS AdjFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))  AS AdjAmt,
            NULLIF(LTRIM(RTRIM(Bucket30Count)), '')        AS Bucket30Flag,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))      AS Bucket30Amt,
            NULLIF(LTRIM(RTRIM(Bucket60Count)), '')        AS Bucket60Flag,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))      AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND TRY_CAST(CheckDate AS DATE) <= @MaxCheck
          AND NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
    ),
    panel_tot AS
    (
        SELECT
            PanelName,
            CAST(N'' AS NVARCHAR(450)) AS PayerName,
            CAST(0 AS INT) AS PayerRank,
            COUNT(*) AS ClaimCount,
            ISNULL(SUM(Chg), 0) AS TotalCharges,
            ISNULL(SUM(InsPay), 0) AS InsurancePayment,
            COUNT(CASE WHEN FullyPaidFlag IS NOT NULL THEN 1 END) AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FullyPaidFlag IS NOT NULL THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
            COUNT(CASE WHEN AdjFlag IS NOT NULL THEN 1 END) AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN AdjFlag IS NOT NULL THEN AdjAmt ELSE 0 END), 0) AS AdjudicatedAmount,
            COUNT(CASE WHEN Bucket30Flag IS NOT NULL THEN 1 END) AS Over30Count,
            ISNULL(SUM(CASE WHEN Bucket30Flag IS NOT NULL THEN Bucket30Amt ELSE 0 END), 0) AS Over30Amount,
            COUNT(CASE WHEN Bucket60Flag IS NOT NULL THEN 1 END) AS Over60Count,
            ISNULL(SUM(CASE WHEN Bucket60Flag IS NOT NULL THEN Bucket60Amt ELSE 0 END), 0) AS Over60Amount
        FROM src
        GROUP BY PanelName
    ),
    payer_agg AS
    (
        SELECT
            PanelName,
            PayerName,
            COUNT(*) AS ClaimCount,
            ISNULL(SUM(Chg), 0) AS TotalCharges,
            ISNULL(SUM(InsPay), 0) AS InsurancePayment,
            COUNT(CASE WHEN FullyPaidFlag IS NOT NULL THEN 1 END) AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FullyPaidFlag IS NOT NULL THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
            COUNT(CASE WHEN AdjFlag IS NOT NULL THEN 1 END) AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN AdjFlag IS NOT NULL THEN AdjAmt ELSE 0 END), 0) AS AdjudicatedAmount,
            COUNT(CASE WHEN Bucket30Flag IS NOT NULL THEN 1 END) AS Over30Count,
            ISNULL(SUM(CASE WHEN Bucket30Flag IS NOT NULL THEN Bucket30Amt ELSE 0 END), 0) AS Over30Amount,
            COUNT(CASE WHEN Bucket60Flag IS NOT NULL THEN 1 END) AS Over60Count,
            ISNULL(SUM(CASE WHEN Bucket60Flag IS NOT NULL THEN Bucket60Amt ELSE 0 END), 0) AS Over60Amount
        FROM src
        GROUP BY PanelName, PayerName
    ),
    payer_ranked AS
    (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY PanelName ORDER BY ClaimCount DESC, PayerName) AS PayerRank
        FROM payer_agg
    )
    SELECT * INTO #out FROM panel_tot
    UNION ALL
    SELECT PanelName, PayerName, CAST(PayerRank AS INT),
           ClaimCount, TotalCharges, InsurancePayment,
           FullyPaidCount, FullyPaidAmount,
           AdjudicatedCount, AdjudicatedAmount,
           Over30Count, Over30Amount, Over60Count, Over60Amount
    FROM payer_ranked;

    TRUNCATE TABLE dbo.Cove_CS_AvgPayments;

    INSERT INTO dbo.Cove_CS_AvgPayments
    (
        PanelName, PayerName, PayerRank,
        ClaimCount, TotalCharges, AvgCharges,
        InsurancePayment, AvgInsurancePayment,
        FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
        AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
        Over30Count, Over30Amount, AvgOver30,
        Over60Count, Over60Amount, AvgOver60,
        RefreshedAt
    )
    SELECT
        PanelName,
        PayerName,
        CAST(CASE WHEN PayerRank > 255 THEN 255 ELSE PayerRank END AS TINYINT),
        ClaimCount, TotalCharges,
        CASE WHEN ClaimCount > 0 THEN TotalCharges / ClaimCount ELSE 0 END,
        InsurancePayment,
        CASE WHEN ClaimCount > 0 THEN InsurancePayment / ClaimCount ELSE 0 END,
        FullyPaidCount, FullyPaidAmount,
        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Over30Count, Over30Amount,
        CASE WHEN Over30Count > 0 THEN Over30Amount / Over30Count ELSE 0 END,
        Over60Count, Over60Amount,
        CASE WHEN Over60Count > 0 THEN Over60Amount / Over60Count ELSE 0 END,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank;

    DROP TABLE IF EXISTS #out;

    PRINT 'usp_RefreshCove_CS_AvgPayments_ClientLogic v3.1 — '
        + CONVERT(VARCHAR(10), @Cutoff, 120) + ' .. '
        + CONVERT(VARCHAR(10), @MaxCheck, 120);
END
GO

PRINT 'Creating usp_GetCove_CS_AvgPayments v3.1...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_AvgPayments
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

    IF @LastMonths NOT IN (3, 6)
        SET @LastMonths = 6;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0 AND @LastMonths = 6
    BEGIN
        SELECT  PanelName, PayerName,
                ClaimCount       AS NoOfClaims,
                TotalCharges,
                InsurancePayment AS CarrierPayment,
                FullyPaidCount,   FullyPaidAmount,
                AdjudicatedCount, AdjudicatedAmount,
                Over30Count      AS Days30Count, Over30Amount AS Days30Amount,
                Over60Count      AS Days60Count, Over60Amount AS Days60Amount
        FROM    dbo.Cove_CS_AvgPayments
        ORDER BY PanelName, PayerRank, PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @MaxCheck DATE =
        (SELECT MAX(TRY_CAST(CheckDate AS DATE))
         FROM dbo.ClaimLevelData
         WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL);

    DECLARE @Cutoff DATE = DATEFROMPARTS(
        YEAR(DATEADD(MONTH, -@LastMonths, @MaxCheck)),
        MONTH(DATEADD(MONTH, -@LastMonths, @MaxCheck)),
        1);

    IF @CheckDateFrom IS NOT NULL AND @CheckDateFrom > @Cutoff SET @Cutoff = @CheckDateFrom;
    IF @CheckDateTo   IS NOT NULL AND @CheckDateTo   < @MaxCheck SET @MaxCheck = @CheckDateTo;

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))        AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            NULLIF(LTRIM(RTRIM(FullyPaidCount)), '')       AS FullyPaidFlag,
            NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '')    AS AdjFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))  AS AdjAmt,
            NULLIF(LTRIM(RTRIM(Bucket30Count)), '')        AS Bucket30Flag,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))      AS Bucket30Amt,
            NULLIF(LTRIM(RTRIM(Bucket60Count)), '')        AS Bucket60Flag,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))      AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND TRY_CAST(CheckDate AS DATE) <= @MaxCheck
          AND NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
    ),
    panel_tot AS
    (
        SELECT
            PanelName,
            CAST(N'' AS NVARCHAR(450)) AS PayerName,
            COUNT(*) AS ClaimCount,
            ISNULL(SUM(Chg), 0) AS TotalCharges,
            ISNULL(SUM(InsPay), 0) AS CarrierPayment,
            COUNT(CASE WHEN FullyPaidFlag IS NOT NULL THEN 1 END) AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FullyPaidFlag IS NOT NULL THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
            COUNT(CASE WHEN AdjFlag IS NOT NULL THEN 1 END) AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN AdjFlag IS NOT NULL THEN AdjAmt ELSE 0 END), 0) AS AdjudicatedAmount,
            COUNT(CASE WHEN Bucket30Flag IS NOT NULL THEN 1 END) AS Days30Count,
            ISNULL(SUM(CASE WHEN Bucket30Flag IS NOT NULL THEN Bucket30Amt ELSE 0 END), 0) AS Days30Amount,
            COUNT(CASE WHEN Bucket60Flag IS NOT NULL THEN 1 END) AS Days60Count,
            ISNULL(SUM(CASE WHEN Bucket60Flag IS NOT NULL THEN Bucket60Amt ELSE 0 END), 0) AS Days60Amount
        FROM src
        GROUP BY PanelName
    ),
    payer_agg AS
    (
        SELECT
            PanelName, PayerName,
            COUNT(*) AS ClaimCount,
            ISNULL(SUM(Chg), 0) AS TotalCharges,
            ISNULL(SUM(InsPay), 0) AS CarrierPayment,
            COUNT(CASE WHEN FullyPaidFlag IS NOT NULL THEN 1 END) AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FullyPaidFlag IS NOT NULL THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
            COUNT(CASE WHEN AdjFlag IS NOT NULL THEN 1 END) AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN AdjFlag IS NOT NULL THEN AdjAmt ELSE 0 END), 0) AS AdjudicatedAmount,
            COUNT(CASE WHEN Bucket30Flag IS NOT NULL THEN 1 END) AS Days30Count,
            ISNULL(SUM(CASE WHEN Bucket30Flag IS NOT NULL THEN Bucket30Amt ELSE 0 END), 0) AS Days30Amount,
            COUNT(CASE WHEN Bucket60Flag IS NOT NULL THEN 1 END) AS Days60Count,
            ISNULL(SUM(CASE WHEN Bucket60Flag IS NOT NULL THEN Bucket60Amt ELSE 0 END), 0) AS Days60Amount
        FROM src
        GROUP BY PanelName, PayerName
    ),
    united AS
    (
        SELECT PanelName, PayerName,
               ClaimCount AS NoOfClaims,
               TotalCharges, CarrierPayment,
               FullyPaidCount, FullyPaidAmount,
               AdjudicatedCount, AdjudicatedAmount,
               Days30Count, Days30Amount,
               Days60Count, Days60Amount,
               CAST(0 AS INT) AS SortGroup
        FROM panel_tot
        UNION ALL
        SELECT PanelName, PayerName,
               ClaimCount AS NoOfClaims,
               TotalCharges, CarrierPayment,
               FullyPaidCount, FullyPaidAmount,
               AdjudicatedCount, AdjudicatedAmount,
               Days30Count, Days30Amount,
               Days60Count, Days60Amount,
               CAST(1 AS INT) AS SortGroup
        FROM payer_agg
    )
    SELECT PanelName, PayerName,
           NoOfClaims,
           TotalCharges, CarrierPayment,
           FullyPaidCount, FullyPaidAmount,
           AdjudicatedCount, AdjudicatedAmount,
           Days30Count, Days30Amount,
           Days60Count, Days60Amount
    FROM united
    ORDER BY PanelName, SortGroup, NoOfClaims DESC, PayerName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_AvgPayments
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RefreshCove_CS_AvgPayments_ClientLogic;
END
GO

PRINT 'Refreshing Avg Payments snapshot (v3.1)...';
EXEC dbo.usp_RefreshCove_CS_AvgPayments_ClientLogic;
GO

DECLARE @MaxCheck DATE =
    (SELECT MAX(TRY_CAST(CheckDate AS DATE)) FROM dbo.ClaimLevelData WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL);
DECLARE @C3 DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH,-3,@MaxCheck)), MONTH(DATEADD(MONTH,-3,@MaxCheck)), 1);

SELECT 'Cutoff3' AS Label, @C3 AS Cutoff3, @MaxCheck AS MaxCheck;

-- Live UTI claim count for Last 3 calendar months
SELECT LTRIM(RTRIM(Panelname)) AS Panel, COUNT(*) AS Claims
FROM dbo.ClaimLevelData
WHERE TRY_CAST(CheckDate AS DATE) BETWEEN @C3 AND @MaxCheck
  AND UPPER(LTRIM(RTRIM(Panelname))) = 'UTI'
GROUP BY LTRIM(RTRIM(Panelname));

-- Snapshot: panel total (PayerRank 0) vs Top 3
SELECT PanelName,
       SUM(CASE WHEN PayerRank = 0 OR PayerName = N'' THEN ClaimCount ELSE 0 END) AS PanelTotalClaims,
       SUM(CASE WHEN PayerRank BETWEEN 1 AND 3 THEN ClaimCount ELSE 0 END) AS Top3Claims,
       COUNT(*) AS SnapshotRows
FROM dbo.Cove_CS_AvgPayments
WHERE UPPER(PanelName) = 'UTI'
GROUP BY PanelName;

-- Smoke: Get LastMonths=3 UTI panel total
IF OBJECT_ID('tempdb..#g') IS NOT NULL DROP TABLE #g;
CREATE TABLE #g (
  PanelName nvarchar(200), PayerName nvarchar(500),
  NoOfClaims int, TotalCharges decimal(18,2), CarrierPayment decimal(18,2),
  FullyPaidCount int, FullyPaidAmount decimal(18,2),
  AdjudicatedCount int, AdjudicatedAmount decimal(18,2),
  Days30Count int, Days30Amount decimal(18,2),
  Days60Count int, Days60Amount decimal(18,2)
);
INSERT #g EXEC dbo.usp_GetCove_CS_AvgPayments @LastMonths = 3;
SELECT PanelName,
       SUM(CASE WHEN PayerName = N'' THEN NoOfClaims ELSE 0 END) AS PanelTotal,
       SUM(CASE WHEN PayerName <> N'' THEN NoOfClaims ELSE 0 END) AS SumPayerRows,
       COUNT(*) AS RowsOut
FROM #g
WHERE UPPER(LTRIM(RTRIM(PanelName))) = 'UTI'
GROUP BY PanelName;
DROP TABLE #g;

PRINT 'FIX_Cove_CS_AvgPayments_CorrectLogic v3.1 complete.';
GO
