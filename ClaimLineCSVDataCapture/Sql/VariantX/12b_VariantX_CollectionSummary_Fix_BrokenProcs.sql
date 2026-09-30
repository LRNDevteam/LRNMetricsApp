/* =============================================================================
   VariantX — re-run fix for failed Collection Summary refresh procs
   (does NOT alter ClaimLevelData / LineLevelData — safe when skipping scripts 02-05)

   Fixes:
   - Invalid GO; / go; batch separators (caused #out collisions)
   - Missing SalesRepname / ReferringProvider (dynamic column resolve + skip)
   - Missing script-02 columns (FullyPaid*, AgingDOS, PaymentPercent, etc.)

   Run this against VariantX_LRN, then optionally EXEC the refresh procs at the end.
   ============================================================================= */
SET NOCOUNT ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;
    DROP TABLE IF EXISTS #out;

    -- Bucket / paid columns come from script 02; VariantX may skip that alter.
    DECLARE @HasFullyPaid BIT = CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'FullyPaidCount') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasAdj BIT = CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'AdjucticatedCount') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @Has30 BIT = CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'Bucket30Count') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @Has60 BIT = CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'Bucket60Count') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     ''Unknown'')))          AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, ''Unknown'')))          AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''''),
                     LTRIM(RTRIM(ClaimID)))                         AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))             AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))             AS InsPay,
            ' + CASE WHEN @HasFullyPaid = 1 THEN N'FullyPaidCount' ELSE N'CAST(NULL AS NVARCHAR(100))' END + N' AS FullyPaidCount,
            ' + CASE WHEN @HasFullyPaid = 1 THEN N'TRY_CAST(FullyPaidAmount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END + N' AS FullyPaidAmount,
            ' + CASE WHEN @HasAdj = 1 THEN N'AdjucticatedCount' ELSE N'CAST(NULL AS NVARCHAR(100))' END + N' AS AdjucticatedCount,
            ' + CASE WHEN @HasAdj = 1 THEN N'TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END + N' AS AdjucticatedAmount,
            ' + CASE WHEN @Has30 = 1 THEN N'Bucket30Count' ELSE N'CAST(NULL AS NVARCHAR(100))' END + N' AS Bucket30Count,
            ' + CASE WHEN @Has30 = 1 THEN N'TRY_CAST(Bucket30Amount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END + N' AS Bucket30Amount,
            ' + CASE WHEN @Has60 = 1 THEN N'Bucket60Count' ELSE N'CAST(NULL AS NVARCHAR(100))' END + N' AS Bucket60Count,
            ' + CASE WHEN @Has60 = 1 THEN N'TRY_CAST(Bucket60Amount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END + N' AS Bucket60Amount
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND TRY_CAST(DateofService AS DATE) <= CAST(GETDATE() AS DATE)
          AND TRY_CAST(DateofService AS DATE) >=
              DATEADD(DAY, 1,
                  EOMONTH(
                      (SELECT MAX(TRY_CAST(DateofService AS DATE))
                       FROM dbo.ClaimLevelData
                       WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
                         AND TRY_CAST(DateofService AS DATE) <= CAST(GETDATE() AS DATE)),
                  -6))
    )
    SELECT
        PanelName,
        PayerName,
        COUNT(VisitKey)          AS ClaimCount,
        ISNULL(SUM(Chg), 0)     AS TotalCharges,
        ISNULL(SUM(InsPay), 0)     AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN FullyPaidCount = ''Fully Paid'' THEN VisitKey END) AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FullyPaidCount = ''Fully Paid'' THEN FullyPaidAmount ELSE 0 END), 0) AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN AdjucticatedCount = ''Adjucticated'' THEN VisitKey END) AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjucticatedCount = ''Adjucticated'' THEN AdjucticatedAmount ELSE 0 END), 0) AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN Bucket30Count = ''30 Bucket'' THEN VisitKey END) AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30Count = ''30 Bucket'' THEN Bucket30Amount ELSE 0 END), 0) AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Bucket60Count = ''60 Bucket'' THEN VisitKey END) AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60Count = ''60 Bucket'' THEN Bucket60Amount ELSE 0 END), 0) AS Days60Amount
    INTO #out
    FROM src
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.VarX_CS_PanelAverages;

    INSERT INTO dbo.VarX_CS_PanelAverages
        (PanelName, PayerName,
         NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,
         FullyPaidCount,   FullyPaidAmount,   AvgFullyPaid,
         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Days30Count,      Days30Amount,      AvgDays30,
         Days60Count,      Days60Amount,      AvgDays60,
         RefreshedAt)
    SELECT
        PanelName, PayerName,
        ClaimCount, TotalCharges, CarrierPayment,
        CASE WHEN ClaimCount       > 0 THEN CarrierPayment    / ClaimCount       ELSE 0 END,
        FullyPaidCount,   FullyPaidAmount,
        CASE WHEN FullyPaidCount   > 0 THEN FullyPaidAmount   / FullyPaidCount   ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Days30Count,      Days30Amount,
        CASE WHEN Days30Count      > 0 THEN Days30Amount      / Days30Count      ELSE 0 END,
        Days60Count,      Days60Amount,
        CASE WHEN Days60Count      > 0 THEN Days60Amount      / Days60Count      ELSE 0 END,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerName;

    DROP TABLE IF EXISTS #out;';

    EXEC sys.sp_executesql @sql;
    PRINT 'usp_RefreshVarX_CS_PanelAverages completed.';
END;
GO


-- 6. AvgPayments (DateOfService rows; rolling 6 months from latest week-range end)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_AvgPayments
AS
BEGIN
    SET NOCOUNT ON;
    DROP TABLE IF EXISTS #out;

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

    DECLARE @HasFullyPaid BIT = CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'FullyPaidCount') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasAdj BIT = CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'AdjucticatedCount') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @Has30 BIT = CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'Bucket30Count') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @Has60 BIT = CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'Bucket60Count') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,        ''Unknown'')))            AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, ''Unknown'')))            AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))               AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))               AS InsPay,
            ' + CASE WHEN @HasFullyPaid = 1 THEN N'NULLIF(LTRIM(RTRIM(FullyPaidCount)), '''')' ELSE N'CAST(NULL AS NVARCHAR(100))' END + N' AS FullyPaidFlag,
            ' + CASE WHEN @HasAdj = 1 THEN N'NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '''')' ELSE N'CAST(NULL AS NVARCHAR(100))' END + N' AS AdjudicatedFlag,
            ' + CASE WHEN @HasAdj = 1 THEN N'TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END + N' AS AdjudicatedAmt,
            ' + CASE WHEN @Has30 = 1 THEN N'NULLIF(LTRIM(RTRIM(Bucket30Count)), '''')' ELSE N'CAST(NULL AS NVARCHAR(100))' END + N' AS Bucket30Flag,
            ' + CASE WHEN @Has30 = 1 THEN N'TRY_CAST(Bucket30Amount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END + N' AS Bucket30Amt,
            ' + CASE WHEN @Has60 = 1 THEN N'NULLIF(LTRIM(RTRIM(Bucket60Count)), '''')' ELSE N'CAST(NULL AS NVARCHAR(100))' END + N' AS Bucket60Flag,
            ' + CASE WHEN @Has60 = 1 THEN N'TRY_CAST(Bucket60Amount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END + N' AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateOfService AS DATE) >= @WindowFrom
          AND TRY_CAST(DateOfService AS DATE) < @WindowEnd
          AND Panelname IS NOT NULL AND LTRIM(RTRIM(Panelname)) <> ''''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''''
    ),
    agg AS (
        SELECT PanelName, PayerName,
               COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '''')) AS ClaimCount,
               ISNULL(SUM(Chg),    0) AS TotalCharges,
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
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY ClaimCount DESC) AS PayerRank
        FROM agg
    )
    SELECT a.*, CAST(r.PayerRank AS TINYINT) AS PayerRank
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.VarX_CS_AvgPayments;
    INSERT INTO dbo.VarX_CS_AvgPayments
        (PanelName, PayerName, PayerRank,
         ClaimCount, TotalCharges, AvgCharges,
         InsurancePayment, AvgInsurancePayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Over30Count, Over30Amount, AvgOver30,
         Over60Count, Over60Amount, AvgOver60,
         RefreshedAt)
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

    DROP TABLE IF EXISTS #out;';

    EXEC sys.sp_executesql @sql,
        N'@WindowFrom DATE, @WindowEnd DATE',
        @WindowFrom = @WindowFrom,
        @WindowEnd = @WindowEnd;

    PRINT 'usp_RefreshVarX_CS_AvgPayments completed: DateOfService '
        + COALESCE(CONVERT(VARCHAR(10), DATEADD(DAY, 1, @Cutoff), 120), 'NULL')
        + ' .. < ' + COALESCE(CONVERT(VARCHAR(10), @WindowEnd, 120), 'NULL')
        + ' (week-range end, exclusive)';
END
GO


-- 7. Insurance vs Aging
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.VarX_CS_InsuranceVsAging;

    IF COL_LENGTH(N'dbo.ClaimLevelData', N'AgingDOS') IS NULL
    BEGIN
        PRINT 'usp_RefreshVarX_CS_InsuranceVsAging skipped: AgingDOS column missing on dbo.ClaimLevelData (script 02 not applied).';
        RETURN;
    END;

    INSERT INTO dbo.VarX_CS_InsuranceVsAging
        (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                  AS PayerName,
        CASE LTRIM(RTRIM(AgingDOS))
            WHEN 'Current' THEN 'Current'
            WHEN '30+'     THEN '30+'
            WHEN '60+'     THEN '60+'
            WHEN '90+'     THEN '90+'
            WHEN '120+'    THEN '120+'
            ELSE '(blank)'
        END                                                          AS AgingBucket,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))    AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
        GETDATE()                                                    AS RefreshedAt
    FROM dbo.ClaimLevelData
    WHERE
       LTRIM(RTRIM(PayerName_Raw))                    <> ''
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
      AND LTRIM(RTRIM(ClaimStatus))                       = 'No Response'
      AND LTRIM(RTRIM(AgingDOS))                         IN ('Current','30+','60+','90+','120+')
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        CASE LTRIM(RTRIM(AgingDOS))
            WHEN 'Current' THEN 'Current'
            WHEN '30+'     THEN '30+'
            WHEN '60+'     THEN '60+'
            WHEN '90+'     THEN '90+'
            WHEN '120+'    THEN '120+'
            ELSE '(blank)'
        END;

    PRINT 'usp_RefreshVarX_CS_InsuranceVsAging completed.';
END;
GO

-- 8. Panel vs Payment
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.VarX_CS_PanelVsPayment;

    INSERT INTO dbo.VarX_CS_PanelVsPayment
        (PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(Panelname))                                         AS PanelName,
        YEAR (TRY_CAST(CheckDate AS DATE))                              AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)             AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))               AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)     AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
     
    GROUP BY
        LTRIM(RTRIM(Panelname)),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

    PRINT 'usp_RefreshVarX_CS_PanelVsPayment completed.';
END
GO


-- 9. Rep vs Payment
-- Resolves SalesRep column dynamically (VariantX ClaimLevelData may use a different name
-- and scripts 02-05 that add/align columns were intentionally skipped).
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_RepVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.VarX_CS_RepVsPayment;

    DECLARE @RepCol SYSNAME =
    (
        SELECT TOP (1) c.name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND c.name IN (N'SalesRepname', N'SalesRepName', N'SalesRep', N'Sales Representative', N'SalesRep_Name')
        ORDER BY CASE c.name
            WHEN N'SalesRepname' THEN 1
            WHEN N'SalesRepName' THEN 2
            WHEN N'SalesRep' THEN 3
            ELSE 4
        END
    );

    IF @RepCol IS NULL
    BEGIN
        PRINT 'usp_RefreshVarX_CS_RepVsPayment skipped: no SalesRep* column on dbo.ClaimLevelData.';
        RETURN;
    END;

    DECLARE @sql NVARCHAR(MAX) = N'
    INSERT INTO dbo.VarX_CS_RepVsPayment
        (SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N'))                                   AS SalesRepName,
        YEAR (TRY_CAST(CheckDate AS DATE))                           AS CheckYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)          AS CheckMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''''))            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND ' + QUOTENAME(@RepCol) + N' IS NOT NULL AND LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N')) <> ''''
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N')),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));';

    EXEC sys.sp_executesql @sql;
    PRINT 'usp_RefreshVarX_CS_RepVsPayment completed using column ' + @RepCol + N'.';
END
GO


-- 10. Insurance vs Payment %
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    DROP TABLE IF EXISTS #out;

    DECLARE @HasPayPct BIT =
        CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'PaymentPercent') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH base AS
    (
        SELECT
            LTRIM(RTRIM(PayerName_Raw)) AS PayerName,
            LTRIM(RTRIM(Panelname)) AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay,
            ' + CASE WHEN @HasPayPct = 1
                     THEN N'TRY_CAST(PaymentPercent AS DECIMAL(9,4))'
                     ELSE N'CAST(NULL AS DECIMAL(9,4))'
                END + N' AS PayPct
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
    ),
    agg AS
    (
        SELECT
            PayerName,
            COUNT(*) AS PanelGroupCount,
            ISNULL(SUM(InsPay), 0) AS InsurancePayment,
            ROUND(ISNULL(AVG(PayPct), 0) * 100, 0) AS PaymentPct
        FROM base
        GROUP BY PayerName
    )
    SELECT
        a.PayerName,
        a.PanelGroupCount,
        a.InsurancePayment,
        a.PaymentPct
    INTO #out
    FROM agg a;

    TRUNCATE TABLE dbo.VarX_CS_InsuranceVsPaymentPct;

    INSERT INTO dbo.VarX_CS_InsuranceVsPaymentPct
    (
        PayerName,
        PanelGroupCount,
        InsurancePayment,
        PaymentPct,
        RefreshedAt
    )
    SELECT
        PayerName,
        PanelGroupCount,
        InsurancePayment,
        PaymentPct,
        GETDATE()
    FROM #out
    ORDER BY InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;';

    EXEC sys.sp_executesql @sql;
    PRINT 'usp_RefreshVarX_CS_InsuranceVsPaymentPct completed.';
END
GO

-- 11. CPT vs Payment %
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    DROP TABLE IF EXISTS #out;

    DECLARE @HasPayPct BIT =
        CASE WHEN COL_LENGTH(N'dbo.LineLevelData', N'PaymentPercent') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH agg AS
    (
        SELECT LTRIM(RTRIM(CPTCode)) AS CPTCode, COUNT(*) AS SumUnits,
            ISNULL(
                SUM(
                    CASE
                        WHEN LTRIM(RTRIM(ClaimStatus)) IN (''Fully Paid'',''Partially Paid'')
                        THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2))
                        ELSE 0
                    END
                ), 0
            ) AS PaidIns,
            ISNULL(
                SUM(
                    CASE
                        WHEN LTRIM(RTRIM(ClaimStatus)) IN (''Fully Paid'',''Partially Paid'')
                        THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2))
                        ELSE 0
                    END
                ), 0
            ) AS PaidChg,
            CAST(
                AVG(
                    ISNULL(
                        ' + CASE WHEN @HasPayPct = 1
                                 THEN N'TRY_CAST(PaymentPercent AS DECIMAL(18,4))'
                                 ELSE N'CAST(0 AS DECIMAL(18,4))'
                            END + N',
                        0
                    )
                ) * 100
            AS DECIMAL(10,2)) AS PaymentPct
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL
          AND LTRIM(RTRIM(CPTCode)) <> ''''
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
        GROUP BY LTRIM(RTRIM(CPTCode))
    )
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct
    INTO #out
    FROM agg;

    TRUNCATE TABLE dbo.VarX_CS_CptVsPaymentPct;

    INSERT INTO dbo.VarX_CS_CptVsPaymentPct
    (
        CPTCode,
        SumUnits,
        PaidInsurancePayment,
        PaidChargeAmount,
        PaymentPct,
        RefreshedAt
    )
    SELECT
        CPTCode,
        SumUnits,
        PaidIns,
        PaidChg,
        PaymentPct,
        GETDATE()
    FROM #out
    ORDER BY SumUnits DESC;

    DROP TABLE IF EXISTS #out;';

    EXEC sys.sp_executesql @sql;
    PRINT 'usp_RefreshVarX_CS_CptVsPaymentPct completed.';
END
GO


-- 12. Status Summary
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_StatusSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.VarX_CS_StatusSummary;

    DECLARE @CptCol SYSNAME =
    (
        SELECT TOP (1) c.name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND c.name IN (N'CPTCodeXUnitsXModifier', N'CPTCodeXUnitsXModifierOrginal', N'CPTCode', N'Panelname')
        ORDER BY CASE c.name
            WHEN N'CPTCodeXUnitsXModifier' THEN 1
            WHEN N'CPTCodeXUnitsXModifierOrginal' THEN 2
            WHEN N'CPTCode' THEN 3
            ELSE 4
        END
    );

    IF @CptCol IS NULL
        SET @CptCol = N'Panelname';

    DECLARE @sql NVARCHAR(MAX) = N'
    INSERT INTO dbo.VarX_CS_StatusSummary
        (ClaimStatus, PanelName, CptCode, PayerName,
         NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT
        ISNULL(LTRIM(RTRIM(ClaimStatus)),              ''(blank)'') AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Panelname)),                   ''(blank)'') AS PanelName,
        ISNULL(LTRIM(RTRIM(' + QUOTENAME(@CptCol) + N')),   ''(blank)'') AS CptCode,
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),            ''(blank)'') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'''')) AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0) AS PatientBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    GROUP BY
        LTRIM(RTRIM(ClaimStatus)),
        LTRIM(RTRIM(Panelname)),
        LTRIM(RTRIM(' + QUOTENAME(@CptCol) + N')),
        LTRIM(RTRIM(PayerName_Raw));';

    EXEC sys.sp_executesql @sql;
    PRINT 'usp_RefreshVarX_CS_StatusSummary completed.';
END
GO


-- 13. Provider Summary
-- Resolves provider column dynamically (scripts 02-05 skipped; column name may differ).
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_ProviderSummary
AS
BEGIN
    SET NOCOUNT ON;
    DROP TABLE IF EXISTS #out;

    TRUNCATE TABLE dbo.VarX_CS_ProviderSummary;

    DECLARE @ProvCol SYSNAME =
    (
        SELECT TOP (1) c.name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND c.name IN (
                N'ReferringProvider', N'ReferringPhysician', N'Referring Provider',
                N'Provider', N'ProviderName', N'OrderingProvider', N'DoctorFullName', N'BillingProvider')
        ORDER BY CASE c.name
            WHEN N'ReferringProvider' THEN 1
            WHEN N'ReferringPhysician' THEN 2
            WHEN N'Provider' THEN 3
            WHEN N'ProviderName' THEN 4
            WHEN N'OrderingProvider' THEN 5
            WHEN N'DoctorFullName' THEN 6
            WHEN N'BillingProvider' THEN 7
            ELSE 8
        END
    );

    IF @ProvCol IS NULL
    BEGIN
        PRINT 'usp_RefreshVarX_CS_ProviderSummary skipped: no provider column on dbo.ClaimLevelData.';
        RETURN;
    END;

    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(' + QUOTENAME(@ProvCol) + N'))                              AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''''))            AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ' + QUOTENAME(@ProvCol) + N' IS NOT NULL
          AND LTRIM(RTRIM(' + QUOTENAME(@ProvCol) + N')) <> ''''
        GROUP BY LTRIM(RTRIM(' + QUOTENAME(@ProvCol) + N'))
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS ProviderRank,
        ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
    INTO #out
    FROM agg;

    INSERT INTO dbo.VarX_CS_ProviderSummary
        (ProviderRank, ReferringProvider, NoOfClaims,
         InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT ProviderRank, ReferringProvider, NoOfClaims,
           InsurancePayment, InsuranceBalance, PatientBalance, GETDATE()
    FROM #out
    ORDER BY ProviderRank;

    DROP TABLE IF EXISTS #out;';

    EXEC sys.sp_executesql @sql;
    PRINT 'usp_RefreshVarX_CS_ProviderSummary completed using column ' + @ProvCol + N'.';
END
GO

PRINT '12b_VariantX_CollectionSummary_Fix_BrokenProcs.sql completed.';
GO

-- Optional: refresh aggregates now (comment out if you only want CREATE OR ALTER)
EXEC dbo.usp_RefreshVarX_CS_PanelAverages;
EXEC dbo.usp_RefreshVarX_CS_AvgPayments;
EXEC dbo.usp_RefreshVarX_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshVarX_CS_PanelVsPayment;
EXEC dbo.usp_RefreshVarX_CS_RepVsPayment;
EXEC dbo.usp_RefreshVarX_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshVarX_CS_CptVsPaymentPct;
EXEC dbo.usp_RefreshVarX_CS_StatusSummary;
EXEC dbo.usp_RefreshVarX_CS_ProviderSummary;
GO
