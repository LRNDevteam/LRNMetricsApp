-- =====================================================================
-- Cove Average Payments: DateOfService rows, anchored to week-range end
-- Date: 2026-09-29
--
-- Same window as Elixir (FIX_Elixir_CS_AvgPayments_DateOfService.sql):
--   Six months:   DateOfService > DATEADD(MONTH, -6, latest week-range end)
--   Three months: DateOfService > DATEADD(MONTH, -3, latest week-range end)
--   Start date is inclusive; week-range end date is exclusive.
--   Week-range end = LineClaimFileLogs.WeekFolder, else MAX(DateOfService).
--
-- Cove output shape is unchanged (v3.1): panel total row (PayerName = '')
-- over ALL payers + every payer row; counts = COUNT(*).
-- SQL-ONLY variant: works with the currently deployed dashboard DLL.
-- That DLL always sends a computed CheckDate window in @CheckDateFrom / @CheckDateTo,
-- so this Get SP ignores both parameters (the Check Date filter has no effect on
-- the Average Payments tabs). Once the DLL routing Cove through
-- LabCollectionPrefix.UsesDateOfServiceAvgPayments is live, run
-- FIX_Cove_CS_AvgPayments_DateOfService.sql to restore Check Date as a user filter.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT 'Updating dbo.usp_RefreshCove_CS_AvgPayments (DateOfService)...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_AvgPayments
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @WindowEnd DATE;

    IF OBJECT_ID(N'dbo.LineClaimFileLogs', N'U') IS NOT NULL
        SELECT @WindowEnd = MAX(TRY_CONVERT(DATE,
            REPLACE(LTRIM(RTRIM(SUBSTRING(WeekFolder, CHARINDEX(' - ', WeekFolder) + 3, 50))), '.', '/'),
            101))
        FROM dbo.LineClaimFileLogs
        WHERE NULLIF(LTRIM(RTRIM(RunId)), '') IS NOT NULL
          AND CHARINDEX(' - ', WeekFolder) > 0;

    IF @WindowEnd IS NULL
        SELECT @WindowEnd = MAX(TRY_CAST(DateOfService AS DATE))
        FROM dbo.ClaimLevelData;

    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, @WindowEnd);
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, @Cutoff);

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
        WHERE TRY_CAST(DateOfService AS DATE) >= @WindowFrom
          AND TRY_CAST(DateOfService AS DATE) < @WindowEnd
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

    PRINT 'usp_RefreshCove_CS_AvgPayments completed: DateOfService '
        + COALESCE(CONVERT(VARCHAR(10), @WindowFrom, 120), 'NULL')
        + ' .. < ' + COALESCE(CONVERT(VARCHAR(10), @WindowEnd, 120), 'NULL')
        + ' (week-range end, exclusive)';
END
GO

PRINT 'Updating dbo.usp_GetCove_CS_AvgPayments (DateOfService, SQL-only: CheckDate params ignored)...';
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

    IF ISNULL(@LastMonths, 0) NOT IN (3, 6)
        SET @LastMonths = 6;

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

    DECLARE @WindowEnd DATE;

    IF OBJECT_ID(N'dbo.LineClaimFileLogs', N'U') IS NOT NULL
        SELECT @WindowEnd = MAX(TRY_CONVERT(DATE,
            REPLACE(LTRIM(RTRIM(SUBSTRING(WeekFolder, CHARINDEX(' - ', WeekFolder) + 3, 50))), '.', '/'),
            101))
        FROM dbo.LineClaimFileLogs
        WHERE NULLIF(LTRIM(RTRIM(RunId)), '') IS NOT NULL
          AND CHARINDEX(' - ', WeekFolder) > 0;

    IF @WindowEnd IS NULL
        SELECT @WindowEnd = MAX(TRY_CAST(DateOfService AS DATE))
        FROM dbo.ClaimLevelData;

    DECLARE @Cutoff DATE = DATEADD(MONTH, -@LastMonths, @WindowEnd);
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, @Cutoff);

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
        WHERE TRY_CAST(DateOfService AS DATE) >= @WindowFrom
          AND TRY_CAST(DateOfService AS DATE) < @WindowEnd
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

PRINT 'Refreshing Cove Avg Payments snapshot...';
EXEC dbo.usp_RefreshCove_CS_AvgPayments;
GO

-- Verify: window used by both 6- and 3-month views
DECLARE @WindowEnd DATE;

SELECT @WindowEnd = MAX(TRY_CONVERT(DATE,
    REPLACE(LTRIM(RTRIM(SUBSTRING(WeekFolder, CHARINDEX(' - ', WeekFolder) + 3, 50))), '.', '/'),
    101))
FROM dbo.LineClaimFileLogs
WHERE NULLIF(LTRIM(RTRIM(RunId)), '') IS NOT NULL
  AND CHARINDEX(' - ', WeekFolder) > 0;

SELECT
    @WindowEnd AS WeekRangeEndDate,
    DATEADD(DAY, 1, DATEADD(MONTH, -6, @WindowEnd)) AS SixMonthFrom,
    @WindowEnd AS SixMonthToExclusive,
    DATEADD(DAY, 1, DATEADD(MONTH, -3, @WindowEnd)) AS ThreeMonthFrom,
    @WindowEnd AS ThreeMonthToExclusive;

SELECT COUNT(*) AS SnapshotRows,
       SUM(CASE WHEN PayerRank = 0 THEN ClaimCount ELSE 0 END) AS PanelTotalClaims,
       MAX(RefreshedAt) AS RefreshedAt
FROM dbo.Cove_CS_AvgPayments;
GO

PRINT 'Cove Average Payments DateOfService fix (SQL-only) completed.';
GO
