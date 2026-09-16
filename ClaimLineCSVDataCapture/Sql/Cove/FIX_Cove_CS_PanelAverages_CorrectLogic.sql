-- ============================================================
-- Cove Collection — Panel Averages (Correct Logic) v3.1
-- Date: 2026-09-16
-- Run on CoveLRN. Safe to re-run.
--
-- Matches client Excel "Last 6 Months | Based On Deposit Date":
--   Filter : CheckDate calendar window
--            from 1st of month 6 months before MAX(CheckDate)
--            through MAX(CheckDate)
--            CheckDate = Deposit / Posted Date for Cove
--   Panel totals : ALL payers (row with PayerName = '')
--   Drill-down   : all payers stored; UI/Excel show Top 3 only
--   Counts       : COUNT(*) — NOT DISTINCT
--   Fully Paid / Adjudicated / Bucket30 / Bucket60:
--            flag column Not blank; COUNT(*);
--            FullyPaidAmount = Sum(InsurancePayment)
--            AdjudicatedAmount = Sum(AdjucticatedAmount)
--            Bucket amounts = Sum(Bucket*Amount)
--
-- Root cause vs client (UTI ~7007 vs ~10180):
--   1) Snapshot previously kept only Top 3 payers, so panel totals under-counted
--   2) Rolling DATEADD(MONTH,-6) missed partial calendar months vs Excel
-- ============================================================
SET NOCOUNT ON;
GO

PRINT 'Creating usp_RefreshCove_CS_PanelAverages_ClientLogic v3.1...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_PanelAverages_ClientLogic
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
            PanelName,
            PayerName,
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
    )
    SELECT * INTO #out FROM panel_tot
    UNION ALL
    SELECT PanelName, PayerName,
           ClaimCount, TotalCharges, CarrierPayment,
           FullyPaidCount, FullyPaidAmount,
           AdjudicatedCount, AdjudicatedAmount,
           Days30Count, Days30Amount, Days60Count, Days60Amount
    FROM payer_agg;

    TRUNCATE TABLE dbo.Cove_CS_PanelAverages;

    INSERT INTO dbo.Cove_CS_PanelAverages
    (
        PanelName, PayerName,
        ClaimCount, TotalCharges, CarrierPayment, AvgCarrierPayment,
        FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
        AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
        Days30Count, Days30Amount, AvgDays30,
        Days60Count, Days60Amount, AvgDays60,
        RefreshedAt
    )
    SELECT
        PanelName, PayerName,
        ClaimCount, TotalCharges, CarrierPayment,
        CASE WHEN ClaimCount > 0 THEN CarrierPayment / ClaimCount ELSE 0 END,
        FullyPaidCount, FullyPaidAmount,
        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Days30Count, Days30Amount,
        CASE WHEN Days30Count > 0 THEN Days30Amount / Days30Count ELSE 0 END,
        Days60Count, Days60Amount,
        CASE WHEN Days60Count > 0 THEN Days60Amount / Days60Count ELSE 0 END,
        GETDATE()
    FROM #out
    ORDER BY PanelName,
             CASE WHEN PayerName = N'' THEN 0 ELSE 1 END,
             ClaimCount DESC,
             PayerName;

    DROP TABLE IF EXISTS #out;

    PRINT 'usp_RefreshCove_CS_PanelAverages_ClientLogic v3.1 — '
        + CONVERT(VARCHAR(10), @Cutoff, 120) + ' .. '
        + CONVERT(VARCHAR(10), @MaxCheck, 120);
END
GO

PRINT 'Creating usp_GetCove_CS_PanelAverages_ClientLogic v3.1...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_PanelAverages_ClientLogic
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
            WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, PayerName,
               ClaimCount,
               TotalCharges, CarrierPayment,
               FullyPaidCount, FullyPaidAmount,
               AdjudicatedCount, AdjudicatedAmount,
               Days30Count, Days30Amount,
               Days60Count, Days60Amount
        FROM dbo.Cove_CS_PanelAverages
        ORDER BY PanelName,
                 CASE WHEN PayerName = N'' THEN 0 ELSE 1 END,
                 ClaimCount DESC,
                 PayerName;
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
        YEAR(DATEADD(MONTH, -6, @MaxCheck)),
        MONTH(DATEADD(MONTH, -6, @MaxCheck)),
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
               ClaimCount, TotalCharges, CarrierPayment,
               FullyPaidCount, FullyPaidAmount,
               AdjudicatedCount, AdjudicatedAmount,
               Days30Count, Days30Amount,
               Days60Count, Days60Amount,
               CAST(0 AS INT) AS SortGroup
        FROM panel_tot
        UNION ALL
        SELECT PanelName, PayerName,
               ClaimCount, TotalCharges, CarrierPayment,
               FullyPaidCount, FullyPaidAmount,
               AdjudicatedCount, AdjudicatedAmount,
               Days30Count, Days30Amount,
               Days60Count, Days60Amount,
               CAST(1 AS INT) AS SortGroup
        FROM payer_agg
    )
    SELECT PanelName, PayerName,
           ClaimCount,
           TotalCharges, CarrierPayment,
           FullyPaidCount, FullyPaidAmount,
           AdjudicatedCount, AdjudicatedAmount,
           Days30Count, Days30Amount,
           Days60Count, Days60Amount
    FROM united
    ORDER BY PanelName, SortGroup, ClaimCount DESC, PayerName;
END
GO

PRINT 'Aligning legacy usp_RefreshCove_CS_PanelAverages / Get to Correct Logic...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RefreshCove_CS_PanelAverages_ClientLogic;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_PanelAverages
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
    EXEC dbo.usp_GetCove_CS_PanelAverages_ClientLogic
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @CheckDateFrom=@CheckDateFrom, @CheckDateTo=@CheckDateTo;
END
GO

PRINT 'Refreshing Panel Averages snapshot (v3.1)...';
EXEC dbo.usp_RefreshCove_CS_PanelAverages_ClientLogic;
GO

DECLARE @MaxCheck DATE =
    (SELECT MAX(TRY_CAST(CheckDate AS DATE)) FROM dbo.ClaimLevelData WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL);
DECLARE @Cutoff DATE = DATEFROMPARTS(
    YEAR(DATEADD(MONTH, -6, @MaxCheck)),
    MONTH(DATEADD(MONTH, -6, @MaxCheck)),
    1);

SELECT @Cutoff AS CheckFrom, @MaxCheck AS CheckTo;

-- Live UTI (calendar CheckDate) vs snapshot panel total vs Top 3
SELECT 'LIVE UTI calendar' AS Src, COUNT(*) AS Claims
FROM dbo.ClaimLevelData
WHERE TRY_CAST(CheckDate AS DATE) BETWEEN @Cutoff AND @MaxCheck
  AND UPPER(LTRIM(RTRIM(Panelname))) = 'UTI';

SELECT PanelName,
       SUM(CASE WHEN PayerName = N'' THEN ClaimCount ELSE 0 END) AS PanelTotalClaims,
       SUM(CASE WHEN PayerName <> N'' THEN ClaimCount ELSE 0 END) AS SumPayerRows,
       SUM(CASE WHEN PayerName <> N'' THEN ClaimCount ELSE 0 END)
         - SUM(CASE WHEN PayerName = N'' THEN ClaimCount ELSE 0 END) AS DiffShouldBe0,
       COUNT(*) AS SnapshotRows
FROM dbo.Cove_CS_PanelAverages
WHERE UPPER(PanelName) = 'UTI'
GROUP BY PanelName;

;WITH ranked AS (
    SELECT PayerName, ClaimCount,
           ROW_NUMBER() OVER (ORDER BY ClaimCount DESC, PayerName) AS rn
    FROM dbo.Cove_CS_PanelAverages
    WHERE UPPER(PanelName) = 'UTI' AND PayerName <> N''
)
SELECT 'Top3 UTI' AS Src, SUM(CASE WHEN rn <= 3 THEN ClaimCount ELSE 0 END) AS Top3Claims
FROM ranked;

SELECT TOP 5 PanelName, PayerName, ClaimCount, TotalCharges, FullyPaidCount, FullyPaidAmount
FROM dbo.Cove_CS_PanelAverages
WHERE UPPER(PanelName) = 'UTI'
ORDER BY CASE WHEN PayerName = N'' THEN 0 ELSE 1 END, ClaimCount DESC;
GO

PRINT 'FIX_Cove_CS_PanelAverages_CorrectLogic v3.1 complete.';
GO
