-- =====================================================================

-- InHealthDTR — Collection Summary Refresh SPs

-- Panel dimension: Panelname  ->  PanelNameBasedOnCPT
--

-- Deploy on: InHealthDTRLRN

-- Source of truth for original logic: 12_InHealthDTR_CollectionSummary.sql

-- This file is a SEPARATE deployable patch (does not replace 12 in place).
--

-- Column change (ClaimLevelData only):

--   FROM: Panelname

--   TO:   PanelNameBasedOnCPT

-- Aggregate table column names remain PanelName (output dimension unchanged).
--

-- SPs updated in this script:

--   dbo.usp_RefreshIHD_CS_MonthlyClaimVolume

--   dbo.usp_RefreshIHD_CS_WeeklyClaimVolume

--   dbo.usp_RefreshIHD_CS_PanelAverages

--   dbo.usp_RefreshIHD_CS_AvgPayments

--   dbo.usp_RefreshIHD_CS_PanelVsPayment

--   dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct
--

-- SPs intentionally NOT changed (and why):

--   usp_RefreshIHD_CS_Top5ReimbursementPct / Pay

--     - no Panel dimension (payer-only)

--   usp_RefreshIHD_CS_InsuranceVsAging

--     - no Panel dimension (payer x aging)

--   usp_RefreshIHD_CS_RepVsPayment

--     - SalesRep dimension, not Panel

--   usp_RefreshIHD_CS_CptVsPaymentPct

--     - CPT dimension, not Panel

--   usp_RefreshIHD_CS_ProviderSummary

--     - ReferringProvider dimension, not Panel

--   usp_RefreshIHD_CS_StatusSummary

--     - sources LineLevelData, which has Panelname only

--       (no PanelNameBasedOnCPT on LineLevel per field mappings)
--

-- After deploy: re-run the six SPs below (or the full Collection Summary

-- refresh job) so IHD_CS_* snapshots rebuild with CPT-based panel names.
--

-- Null hardening (Msg 515): InsuranceVsPaymentPct + PanelVsPayment now use

-- ISNULL(..., 'Unknown') for PayerName_Raw / PanelNameBasedOnCPT, matching

-- Monthly/Weekly/PanelAverages/AvgPayments. Standalone hotfix: 19b_*.sql.
--

-- NOTE: Live-filter paths in 13_InHealthDTR_CollectionSummary_ReadSPs.sql

-- still reference ClaimLevelData.Panelname. Update those separately if

-- panel filters must match the new CPT-based dimension.

-- =====================================================================

SET NOCOUNT ON;

GO

-- 3. Monthly Claim Volume

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')))                 AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                 AS PayerName,
        YEAR (TRY_CAST(CheckDate AS DATE))                             AS BillYear,
        MONTH(TRY_CAST(CheckDate AS DATE))                             AS BillMonth,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                       AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)    AS InsurancePayment
    INTO #raw
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
      AND LTRIM(RTRIM(CheckDate)) <> ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));
    SELECT
        PanelName, PayerName,
        DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
    INTO #ranks
    FROM #raw
    GROUP BY PanelName, PayerName;
    TRUNCATE TABLE dbo.IHD_CS_MonthlyClaimVolume;
    INSERT INTO dbo.IHD_CS_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT r.PanelName, r.PayerName, CAST(k.PayerRank AS TINYINT),
           r.BillYear, CAST(r.BillMonth AS TINYINT), r.NoOfClaims, r.InsurancePayment, GETDATE()
    FROM #raw r
    JOIN #ranks k ON k.PanelName = r.PanelName AND k.PayerName = r.PayerName
    ORDER BY r.PanelName, k.PayerRank, r.BillYear, r.BillMonth;
    DROP TABLE IF EXISTS #raw;
    DROP TABLE IF EXISTS #ranks;
    PRINT 'usp_RefreshIHD_CS_MonthlyClaimVolume completed.';

END

GO

-- 4. Weekly Claim Volume

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MaxCheckDate DATE;
    DECLARE @WeekContainingMaxStart DATE;
    DECLARE @WeekContainingMaxEnd   DATE;
    DECLARE @LatestCompletedWeekStart DATE;
    DECLARE @LatestCompletedWeekEnd   DATE;
    SELECT @MaxCheckDate = MAX(TRY_CAST(CheckDate AS DATE))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND TRY_CAST(CheckDate AS DATE) <= @Today
      AND LTRIM(RTRIM(CheckDate)) <> '';
    IF @MaxCheckDate IS NULL
    BEGIN
        RAISERROR('No valid CheckDate <= today found in ClaimLevelData.', 16, 1);
        RETURN;
    END;
    -- Thu-Wed week; 1900-01-04 is Thursday
    SET @WeekContainingMaxStart =
        DATEADD(DAY, -(DATEDIFF(DAY, '19000104', @MaxCheckDate) % 7), @MaxCheckDate);
    SET @WeekContainingMaxEnd = DATEADD(DAY, 6, @WeekContainingMaxStart);
    IF @WeekContainingMaxEnd <= @Today
    BEGIN
        SET @LatestCompletedWeekStart = @WeekContainingMaxStart;
        SET @LatestCompletedWeekEnd   = @WeekContainingMaxEnd;
    END
    ELSE
    BEGIN
        SET @LatestCompletedWeekStart = DATEADD(DAY, -7, @WeekContainingMaxStart);
        SET @LatestCompletedWeekEnd   = DATEADD(DAY,  6, @LatestCompletedWeekStart);
    END;
    DECLARE @W4Start DATE = @LatestCompletedWeekStart;
    DECLARE @W4End   DATE = @LatestCompletedWeekEnd;
    DECLARE @W3Start DATE = DATEADD(DAY, -7, @W4Start);  DECLARE @W3End DATE = DATEADD(DAY, 6, @W3Start);
    DECLARE @W2Start DATE = DATEADD(DAY, -7, @W3Start);  DECLARE @W2End DATE = DATEADD(DAY, 6, @W2Start);
    DECLARE @W1Start DATE = DATEADD(DAY, -7, @W2Start);  DECLARE @W1End DATE = DATEADD(DAY, 6, @W1Start);
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CASE
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(CheckDate)) <> ''
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W4End
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))  AS NoOfClaims,
               ISNULL(SUM(InsPay), 0)                    AS InsurancePayment
        FROM src WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM agg GROUP BY PanelName, PayerName
    )
    SELECT
        a.PanelName, a.PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
        CAST(a.WeekKey AS TINYINT) AS WeekKey,
        CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start WHEN 3 THEN @W3Start WHEN 4 THEN @W4Start END AS WeekStart,
        CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End   WHEN 3 THEN @W3End   WHEN 4 THEN @W4End   END AS WeekEnd,
        a.NoOfClaims, a.InsurancePayment
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName;
    TRUNCATE TABLE dbo.IHD_CS_WeeklyClaimVolume;
    INSERT INTO dbo.IHD_CS_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank, WeekKey;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_WeeklyClaimVolume completed.';
    print @W1Start 
    print @W4End

END

GO

-- 5. Panel Averages

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @MaxCheckDate DATE;
    DECLARE @StartCheckDate DATE;
    DECLARE @EndCheckDate DATE;
    SELECT
        @MaxCheckDate = MAX(TRY_CAST(CheckDate AS DATE))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND TRY_CAST(CheckDate AS DATE) <= CAST(GETDATE() AS DATE);
    IF @MaxCheckDate IS NULL
    BEGIN
        RAISERROR('No valid CheckDate <= today found in ClaimLevelData.', 16, 1);
        RETURN;
    END;
    SET @StartCheckDate = DATEADD(DAY, -180, @MaxCheckDate);
    SET @EndCheckDate   = @MaxCheckDate;
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')))  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))  AS PayerName,
            LTRIM(RTRIM(ClaimID))                           AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))     AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))     AS InsPay,
            LTRIM(RTRIM(ISNULL(ClaimStatus, '')))           AS ClaimStatus,
            FullyPaidCount,
            TRY_CAST(FullyPaidAmount AS DECIMAL(18,2))      AS FullyPaidAmount,
            [AdjudicatedCount]                               AS AdjudicatedFlag,
            TRY_CAST([AdjudicatedAmount] AS DECIMAL(18,2))  AS AdjudicatedAmount,
            Days30Count                                      AS Bucket30Flag,
            TRY_CAST([Days30Amount] AS DECIMAL(18,2))       AS Bucket30Amt,
            Days60Count                                      AS Bucket60Flag,
            TRY_CAST([Days60Amount] AS DECIMAL(18,2))       AS Bucket60Amt,
            TRY_CAST(CheckDate AS DATE)                     AS CheckDateValue
        FROM dbo.ClaimLevelData
        WHERE NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
    )
    SELECT
        PanelName,
        PayerName,
        COUNT(VisitKey)          AS ClaimCount,
        ISNULL(SUM(Chg), 0)     AS TotalCharges,
        ISNULL(SUM(InsPay), 0)  AS CarrierPayment,
        COUNT(CASE WHEN FullyPaidCount IN ('Fully Paid', 'Fully Paid Count')
                   THEN VisitKey END)                                          AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FullyPaidCount IN ('Fully Paid', 'Fully Paid Count')
                        THEN FullyPaidAmount ELSE 0 END), 0)                  AS FullyPaidAmount,
        COUNT(CASE WHEN AdjudicatedFlag IN ('Adjudicated', 'Adjudicated Count')
                   THEN VisitKey END)                                          AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjudicatedFlag IN ('Adjudicated', 'Adjudicated Count')
                        THEN AdjudicatedAmount ELSE 0 END), 0)                AS AdjudicatedAmount,
        COUNT(CASE WHEN Bucket30Flag IN ('30 Bucket', '30 Days Count')
                   THEN VisitKey END)                                          AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30Flag IN ('30 Bucket', '30 Days Count')
                        THEN Bucket30Amt ELSE 0 END), 0)                      AS Days30Amount,
        COUNT(CASE WHEN Bucket60Flag IN ('60 Bucket', '60 Days Count')
                   THEN VisitKey END)                                          AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60Flag IN ('60 Bucket', '60 Days Count')
                        THEN Bucket60Amt ELSE 0 END), 0)                      AS Days60Amount
    INTO #out
    FROM src
    WHERE CheckDateValue IS NOT NULL
      AND CheckDateValue BETWEEN @StartCheckDate AND @EndCheckDate
    GROUP BY PanelName, PayerName;
    TRUNCATE TABLE dbo.IHD_CS_PanelAverages;
    INSERT INTO dbo.IHD_CS_PanelAverages
    (
        PanelName, PayerName,
        NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,
        FullyPaidCount,   FullyPaidAmount,   AvgFullyPaid,
        AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
        Days30Count,      Days30Amount,      AvgDays30,
        Days60Count,      Days60Amount,      AvgDays60,
        RefreshedAt
    )
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
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_PanelAverages completed.';
    PRINT 'CheckDate Start: ' + CONVERT(VARCHAR(10), @StartCheckDate, 120);
    PRINT 'CheckDate End: '   + CONVERT(VARCHAR(10), @EndCheckDate,   120);

END

GO

-- 6. Avg Payments

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_AvgPayments
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));
    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')))  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))  AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))     AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))     AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                       AS Status,
            ISNULL(TRY_CAST(DaystoDOS AS INT), 9999)        AS Days
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND PanelNameBasedOnCPT IS NOT NULL AND LTRIM(RTRIM(PanelNameBasedOnCPT)) <> ''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
    ),
    agg AS (
        SELECT PanelName, PayerName,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
               ISNULL(SUM(Chg),    0)  AS TotalCharges,
               ISNULL(SUM(InsPay), 0)  AS CarrierPayment,
               COUNT(DISTINCT CASE WHEN Status = 'Fully Paid' THEN ClaimID END) AS FullyPaidCount,
               ISNULL(SUM(CASE WHEN Status = 'Fully Paid' THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
               COUNT(DISTINCT CASE WHEN Status IN
                   ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted',
                    'Fully Denied','Denied','Partially Denied','Partially Adjusted',
                    'Patient Responsibility')
                 THEN ClaimID END) AS AdjudicatedCount,
               ISNULL(SUM(CASE WHEN Status IN
                   ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted',
                    'Fully Denied','Denied','Partially Denied','Partially Adjusted',
                    'Patient Responsibility')
                 THEN InsPay ELSE 0 END), 0) AS AdjudicatedAmount,
               COUNT(DISTINCT CASE WHEN Days <= 30 THEN ClaimID END) AS Days30Count,
               ISNULL(SUM(CASE WHEN Days <= 30 THEN InsPay ELSE 0 END), 0) AS Days30Amount,
               COUNT(DISTINCT CASE WHEN Days <= 60 THEN ClaimID END) AS Days60Count,
               ISNULL(SUM(CASE WHEN Days <= 60 THEN InsPay ELSE 0 END), 0) AS Days60Amount
        FROM base GROUP BY PanelName, PayerName
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY NoOfClaims DESC) AS PayerRank
        FROM agg
    )
    SELECT a.*, CAST(r.PayerRank AS TINYINT) AS PayerRank
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    WHERE r.PayerRank <= 3;
    TRUNCATE TABLE dbo.IHD_CS_AvgPayments;
    INSERT INTO dbo.IHD_CS_AvgPayments
        (PanelName, PayerName, PayerRank,
         NoOfClaims, TotalCharges, AvgCharges,
         CarrierPayment, AvgCarrierPayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Days30Count, Days30Amount, AvgDays30,
         Days60Count, Days60Amount, AvgDays60,
         RefreshedAt)
    SELECT
        PanelName, PayerName, PayerRank,
        NoOfClaims, TotalCharges,
        CASE WHEN NoOfClaims > 0 THEN TotalCharges / NoOfClaims ELSE 0 END,
        CarrierPayment,
        CASE WHEN NoOfClaims > 0 THEN CarrierPayment / NoOfClaims ELSE 0 END,
        FullyPaidCount, FullyPaidAmount,
        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Days30Count, Days30Amount,
        CASE WHEN Days30Count > 0 THEN Days30Amount / Days30Count ELSE 0 END,
        Days60Count, Days60Amount,
        CASE WHEN Days60Count > 0 THEN Days60Amount / Days60Count ELSE 0 END,
        GETDATE()
    FROM #out ORDER BY PanelName, PayerRank;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_AvgPayments completed.';

END

GO

-- 8. Panel vs Payment

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.IHD_CS_PanelVsPayment;
    INSERT INTO dbo.IHD_CS_PanelVsPayment
        (PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')))                                         AS PanelName,
        YEAR (TRY_CAST(CheckDate AS DATE))                              AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)             AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))               AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)     AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
    GROUP BY
        LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));
    PRINT 'usp_RefreshIHD_CS_PanelVsPayment completed.';

END

GO

-- 10. Insurance vs Payment % (Panel used for PanelGroupCount)

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                          AS PayerName,
            LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')))                              AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))          AS InsPay,
            TRY_CAST(PaymentPercent   AS DECIMAL(9,4))           AS PayPct
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
          AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
    ),
    agg AS (
        SELECT PayerName,
               COUNT(PanelName)                        AS PanelGroupCount,
               ISNULL(SUM(InsPay), 0)                  AS InsurancePayment,
               ROUND(ISNULL(AVG(PayPct), 0) * 100, 0)  AS PaymentPct
        FROM base GROUP BY PayerName
    )
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct
    INTO #out FROM agg;
    TRUNCATE TABLE dbo.IHD_CS_InsuranceVsPaymentPct;
    INSERT INTO dbo.IHD_CS_InsuranceVsPaymentPct
        (PayerName, PanelGroupCount, InsurancePayment, PaymentPct, RefreshedAt)
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct, GETDATE()
    FROM #out ORDER BY InsurancePayment DESC;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_InsuranceVsPaymentPct completed.';

END

GO

PRINT '19_InHealthDTR_CollectionSummary_Refresh_PanelNameBasedOnCPT.sql completed.';

GO

/*

-- Deploy verification (run on InHealthDTRLRN after this script):
EXEC dbo.usp_RefreshIHD_CS_MonthlyClaimVolume;
EXEC dbo.usp_RefreshIHD_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshIHD_CS_PanelAverages;
EXEC dbo.usp_RefreshIHD_CS_AvgPayments;
EXEC dbo.usp_RefreshIHD_CS_PanelVsPayment;
EXEC dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct;

*/