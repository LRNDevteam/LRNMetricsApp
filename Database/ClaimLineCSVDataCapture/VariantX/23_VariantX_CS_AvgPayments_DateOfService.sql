-- =====================================================================
-- VariantX Average Payments: DateOfService rows, anchored to week-range end
-- Date: 2026-09-24
--
-- Six months: DateOfService > DATEADD(MONTH, -6, latest week-range end)
-- Three months: DateOfService > DATEADD(MONTH, -3, latest week-range end)
-- Start date is inclusive; week-range end date is exclusive.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT 'Updating dbo.usp_RefreshVarX_CS_AvgPayments...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_AvgPayments
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

    ;WITH base AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))        AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            NULLIF(LTRIM(RTRIM(FullyPaidCount)), '')       AS FullyPaidFlag,
            NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '')    AS AdjudicatedFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))  AS AdjudicatedAmt,
            NULLIF(LTRIM(RTRIM(Bucket30Count)), '')        AS Bucket30Flag,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))      AS Bucket30Amt,
            NULLIF(LTRIM(RTRIM(Bucket60Count)), '')        AS Bucket60Flag,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))      AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateOfService AS DATE) >= @WindowFrom
          AND TRY_CAST(DateOfService AS DATE) < @WindowEnd
          AND NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    ),
    agg AS
    (
        SELECT
            PanelName,
            PayerName,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
            ISNULL(SUM(Chg), 0) AS TotalCharges,
            ISNULL(SUM(InsPay), 0) AS InsurancePayment,
            COUNT(CASE WHEN FullyPaidFlag IS NOT NULL THEN ClaimID END) AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FullyPaidFlag IS NOT NULL THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
            COUNT(CASE WHEN AdjudicatedFlag IS NOT NULL THEN ClaimID END) AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN AdjudicatedFlag IS NOT NULL THEN AdjudicatedAmt ELSE 0 END), 0) AS AdjudicatedAmount,
            COUNT(CASE WHEN Bucket30Flag IS NOT NULL THEN ClaimID END) AS Over30Count,
            ISNULL(SUM(CASE WHEN Bucket30Flag IS NOT NULL THEN Bucket30Amt ELSE 0 END), 0) AS Over30Amount,
            COUNT(CASE WHEN Bucket60Flag IS NOT NULL THEN ClaimID END) AS Over60Count,
            ISNULL(SUM(CASE WHEN Bucket60Flag IS NOT NULL THEN Bucket60Amt ELSE 0 END), 0) AS Over60Amount
        FROM base
        GROUP BY PanelName, PayerName
    ),
    ranks AS
    (
        SELECT
            PanelName,
            PayerName,
            DENSE_RANK() OVER
                (PARTITION BY PanelName ORDER BY ClaimCount DESC) AS PayerRank
        FROM agg
    )
    SELECT a.*, CAST(r.PayerRank AS TINYINT) AS PayerRank
    INTO #out
    FROM agg a
    INNER JOIN ranks r
        ON r.PanelName = a.PanelName
       AND r.PayerName = a.PayerName
    WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.VarX_CS_AvgPayments;

    INSERT INTO dbo.VarX_CS_AvgPayments
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
        PanelName, PayerName, PayerRank,
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

    PRINT 'usp_RefreshVarX_CS_AvgPayments completed: DateOfService '
        + COALESCE(CONVERT(VARCHAR(10), DATEADD(DAY, 1, @Cutoff), 120), 'NULL')
        + ' .. < ' + COALESCE(CONVERT(VARCHAR(10), @WindowEnd, 120), 'NULL')
        + ' (week-range end, exclusive)';
END
GO

PRINT 'Updating dbo.usp_GetVarX_CS_AvgPayments...';
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

    ;WITH base AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))        AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            NULLIF(LTRIM(RTRIM(FullyPaidCount)), '')       AS FullyPaidFlag,
            NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '')    AS AdjudicatedFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))  AS AdjudicatedAmt,
            NULLIF(LTRIM(RTRIM(Bucket30Count)), '')        AS Bucket30Flag,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))      AS Bucket30Amt,
            NULLIF(LTRIM(RTRIM(Bucket60Count)), '')        AS Bucket60Flag,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))      AS Bucket60Amt
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
        PanelName,
        PayerName,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
        ISNULL(SUM(Chg), 0) AS TotalCharges,
        ISNULL(SUM(InsPay), 0) AS CarrierPayment,
        COUNT(CASE WHEN FullyPaidFlag IS NOT NULL THEN ClaimID END) AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FullyPaidFlag IS NOT NULL THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
        COUNT(CASE WHEN AdjudicatedFlag IS NOT NULL THEN ClaimID END) AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjudicatedFlag IS NOT NULL THEN AdjudicatedAmt ELSE 0 END), 0) AS AdjudicatedAmount,
        COUNT(CASE WHEN Bucket30Flag IS NOT NULL THEN ClaimID END) AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30Flag IS NOT NULL THEN Bucket30Amt ELSE 0 END), 0) AS Days30Amount,
        COUNT(CASE WHEN Bucket60Flag IS NOT NULL THEN ClaimID END) AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60Flag IS NOT NULL THEN Bucket60Amt ELSE 0 END), 0) AS Days60Amount
    FROM base
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, NoOfClaims DESC, PayerName;
END
GO

EXEC dbo.usp_RefreshVarX_CS_AvgPayments;
GO

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
GO

PRINT 'VariantX Average Payments DateOfService fix completed.';
GO

