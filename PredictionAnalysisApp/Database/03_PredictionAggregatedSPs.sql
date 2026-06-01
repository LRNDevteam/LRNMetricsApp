-- ============================================================
-- 03_PredictionAggregatedSPs.sql
-- Aggregated stored procedures for the Prediction Analysis page.
-- Run this against every lab database that holds dbo.PayerValidationReport.
--
-- SPs created:
--   SP 6:  usp_GetPredictionSummaryBuckets
--   SP 7:  usp_GetPredictionValidationByPayer
--   SP 8:  usp_GetPredictionValidationByPanel
--   SP 9:  usp_GetPredictionValidationByCPT
--   SP 10: usp_GetPredictionDenialBreakdown
--   SP 11: usp_GetPredictionNoResponseBreakdown
--   SP 12: usp_GetPredictionSummaryMetrics  ? Ratios + Prediction Accuracy
--
-- Common design rules (all SPs):
--   ForecastingPayability filter: 'Payable' | 'Potentially Payable' | 'Payable%Need%Action'
--   PayStatus grouping: UPPER(LTRIM(RTRIM(...))) compared case-insensitively
--   Date parsing:  ExpectedPaymentDate / FirstBilledDate stored as NVARCHAR(MAX).
--                  May be an Excel OA-date serial (e.g. "46200") or text ("05/15/2026").
--                  OA date base: 1899-12-30  (matches .NET DateTime.FromOADate)
--   RunId: if @RunId IS NULL, the SP resolves to the most-recent InsertedDateTime.
-- ============================================================

-- ============================================================
-- SP 6 : usp_GetPredictionSummaryBuckets
-- Returns exactly 6 rows (one per bucket), ordered by SortOrder.
-- Columns: BucketName, LineItemCount, PredictedAllowed, PredictedInsurance,
--          ActualAllowed (NULL for Predicted-To-Pay), ActualInsurance (NULL for Predicted-To-Pay)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionSummaryBuckets
(
    @WeekStartDate             DATE          = NULL,
    @RunId                     NVARCHAR(100) = NULL,
    @FilterPayerName           NVARCHAR(255) = NULL,
    @FilterPayerType           NVARCHAR(100) = NULL,
    @FilterPanelName           NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus NVARCHAR(100) = NULL,
    @FilterPayability          NVARCHAR(100) = NULL,
    @FilterCPTCode             NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve latest RunId when not supplied
    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER  BY InsertedDateTime DESC;

    ;WITH base AS
    (
        SELECT
            UPPER(LTRIM(RTRIM(ISNULL(PayStatus, '')))) AS NormPayStatus,
            NULLIF(LTRIM(RTRIM(VisitNumber)), '')      AS VisitNumber,
            ISNULL(TRY_CAST(ModeAllowedAmountSameLab  AS DECIMAL(18,4)), 0) AS ModeAllowed,
            ISNULL(TRY_CAST(ModeInsurancePaidSameLab  AS DECIMAL(18,4)), 0) AS ModeIns,
            ISNULL(TRY_CAST(AllowedAmount             AS DECIMAL(18,4)), 0) AS ActAllowed,
            ISNULL(TRY_CAST(InsurancePayment          AS DECIMAL(18,4)), 0) AS ActIns
        FROM dbo.PayerValidationReport
        WHERE
            (@RunId IS NULL OR RunId = @RunId)
            -- ForecastingPayability: Payable | Potentially Payable | Payable - Need Action
            AND (
                LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Potentially Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS LIKE 'Payable%Need%Action'
            )
            -- ExpectedPaymentDate < @WeekStartDate (OA serial or text date)
            AND (@WeekStartDate IS NULL OR
                CASE
                    WHEN TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) IS NOT NULL
                         AND TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) BETWEEN 2 AND 2958466
                    THEN CAST(DATEADD(DAY, CAST(TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) AS INT), '1899-12-30') AS DATE)
                    ELSE TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS DATE)
                END < @WeekStartDate)
            -- Optional dimension filters
            AND (@FilterPayerName           IS NULL OR LTRIM(RTRIM(PayerNameNormalized)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerName)
            AND (@FilterPayerType           IS NULL OR LTRIM(RTRIM(PayerType))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerType)
            AND (@FilterPanelName           IS NULL OR LTRIM(RTRIM(PanelName))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPanelName)
            AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterFinalCoverageStatus)
            AND (@FilterPayability          IS NULL OR LTRIM(RTRIM(Payability))          COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayability)
            AND (@FilterCPTCode             IS NULL OR LTRIM(RTRIM(CPTCode))             COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterCPTCode)
    )
    SELECT BucketName, SortOrder, LineItemCount,
           PredictedAllowed, PredictedInsurance,
           ActualAllowed, ActualInsurance
    FROM (
        -- 1. Predicted To Pay – all ForecastPayable rows
        SELECT N'Predicted To Pay'   AS BucketName, 1 AS SortOrder,
               COUNT(DISTINCT VisitNumber) AS LineItemCount,
               ISNULL(SUM(ModeAllowed), 0) AS PredictedAllowed,
               ISNULL(SUM(ModeIns),    0)  AS PredictedInsurance,
               CAST(NULL AS DECIMAL(18,4)) AS ActualAllowed,
               CAST(NULL AS DECIMAL(18,4)) AS ActualInsurance
        FROM base

        UNION ALL

        -- 2. Predicted - Paid
        SELECT N'Predicted - Paid', 2,
               COUNT(DISTINCT VisitNumber),
               ISNULL(SUM(ModeAllowed), 0), ISNULL(SUM(ModeIns), 0),
               ISNULL(SUM(ActAllowed), 0),  ISNULL(SUM(ActIns),  0)
        FROM base WHERE NormPayStatus = 'PAID'

        UNION ALL

        -- 3. Predicted - Unpaid  (Denied + No Response + Adjusted)
        SELECT N'Predicted - Unpaid', 3,
               COUNT(DISTINCT VisitNumber),
               ISNULL(SUM(ModeAllowed), 0), ISNULL(SUM(ModeIns), 0),
               ISNULL(SUM(ActAllowed), 0),  ISNULL(SUM(ActIns),  0)
        FROM base WHERE NormPayStatus IN ('DENIED', 'NO RESPONSE', 'ADJUSTED')

        UNION ALL

        -- 4. Unpaid - Denied
        SELECT N'Unpaid - Denied', 4,
               COUNT(DISTINCT VisitNumber),
               ISNULL(SUM(ModeAllowed), 0), ISNULL(SUM(ModeIns), 0),
               ISNULL(SUM(ActAllowed), 0),  ISNULL(SUM(ActIns),  0)
        FROM base WHERE NormPayStatus = 'DENIED'

        UNION ALL

        -- 5. Unpaid - No Response
        SELECT N'Unpaid - No Response', 5,
               COUNT(DISTINCT VisitNumber),
               ISNULL(SUM(ModeAllowed), 0), ISNULL(SUM(ModeIns), 0),
               ISNULL(SUM(ActAllowed), 0),  ISNULL(SUM(ActIns),  0)
        FROM base WHERE NormPayStatus = 'NO RESPONSE'

        UNION ALL

        -- 6. Unpaid - Adjusted
        SELECT N'Unpaid - Adjusted', 6,
               COUNT(DISTINCT VisitNumber),
               ISNULL(SUM(ModeAllowed), 0), ISNULL(SUM(ModeIns), 0),
               ISNULL(SUM(ActAllowed), 0),  ISNULL(SUM(ActIns),  0)
        FROM base WHERE NormPayStatus = 'ADJUSTED'
    ) x
    ORDER BY SortOrder;
END
GO

-- ============================================================
-- SP 7 : usp_GetPredictionValidationByPayer
-- Prediction Validation & Breakdown Analysis – Payers tab.
-- Columns: PayerName, PayerType, TotalLineItems, PaidCount, DeniedCount,
--          NoResponseCount, AdjustedCount, UnpaidCount,
--          PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance
-- Sorted by TotalLineItems DESC.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionValidationByPayer
(
    @WeekStartDate             DATE          = NULL,
    @RunId                     NVARCHAR(100) = NULL,
    @FilterPayerName           NVARCHAR(255) = NULL,
    @FilterPayerType           NVARCHAR(100) = NULL,
    @FilterPanelName           NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus NVARCHAR(100) = NULL,
    @FilterPayability          NVARCHAR(100) = NULL,
    @FilterCPTCode             NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER  BY InsertedDateTime DESC;

    ;WITH base AS
    (
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), ''), LTRIM(RTRIM(ISNULL(PayerName, 'Unknown')))) AS PayerNameKey,
            LTRIM(RTRIM(ISNULL(PayerType, '')))                                                               AS PayerTypeKey,
            UPPER(LTRIM(RTRIM(ISNULL(PayStatus, ''))))                                                        AS NormPayStatus,
            ISNULL(TRY_CAST(ModeAllowedAmountSameLab AS DECIMAL(18,4)), 0) AS ModeAllowed,
            ISNULL(TRY_CAST(ModeInsurancePaidSameLab AS DECIMAL(18,4)), 0) AS ModeIns,
            ISNULL(TRY_CAST(AllowedAmount            AS DECIMAL(18,4)), 0) AS ActAllowed,
            ISNULL(TRY_CAST(InsurancePayment         AS DECIMAL(18,4)), 0) AS ActIns
        FROM dbo.PayerValidationReport
        WHERE
            (@RunId IS NULL OR RunId = @RunId)
            AND (
                LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Potentially Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS LIKE 'Payable%Need%Action'
            )
            AND (@WeekStartDate IS NULL OR
                CASE
                    WHEN TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) IS NOT NULL
                         AND TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) BETWEEN 2 AND 2958466
                    THEN CAST(DATEADD(DAY, CAST(TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) AS INT), '1899-12-30') AS DATE)
                    ELSE TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS DATE)
                END < @WeekStartDate)
            AND (@FilterPayerName           IS NULL OR LTRIM(RTRIM(PayerNameNormalized)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerName)
            AND (@FilterPayerType           IS NULL OR LTRIM(RTRIM(PayerType))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerType)
            AND (@FilterPanelName           IS NULL OR LTRIM(RTRIM(PanelName))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPanelName)
            AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterFinalCoverageStatus)
            AND (@FilterPayability          IS NULL OR LTRIM(RTRIM(Payability))          COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayability)
            AND (@FilterCPTCode             IS NULL OR LTRIM(RTRIM(CPTCode))             COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterCPTCode)
    )
    SELECT
        PayerNameKey                                                   AS PayerName,
        PayerTypeKey                                                   AS PayerType,
        COUNT(*)                                                       AS TotalLineItems,
        SUM(CASE WHEN NormPayStatus = 'PAID'        THEN 1 ELSE 0 END) AS PaidCount,
        SUM(CASE WHEN NormPayStatus = 'DENIED'      THEN 1 ELSE 0 END) AS DeniedCount,
        SUM(CASE WHEN NormPayStatus = 'NO RESPONSE' THEN 1 ELSE 0 END) AS NoResponseCount,
        SUM(CASE WHEN NormPayStatus = 'ADJUSTED'    THEN 1 ELSE 0 END) AS AdjustedCount,
        SUM(CASE WHEN NormPayStatus IN ('DENIED','NO RESPONSE','ADJUSTED') THEN 1 ELSE 0 END) AS UnpaidCount,
        ISNULL(SUM(ModeAllowed), 0) AS PredictedAllowed,
        ISNULL(SUM(ModeIns),    0)  AS PredictedInsurance,
        ISNULL(SUM(ActAllowed), 0)  AS ActualAllowed,
        ISNULL(SUM(ActIns),     0)  AS ActualInsurance
    FROM base
    GROUP BY PayerNameKey, PayerTypeKey
    ORDER BY COUNT(*) DESC;
END
GO

-- ============================================================
-- SP 8 : usp_GetPredictionValidationByPanel
-- Prediction Validation & Breakdown Analysis – Panels tab.
-- Columns: PanelName, TotalLineItems, PaidCount, DeniedCount,
--          NoResponseCount, AdjustedCount, UnpaidCount,
--          PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance
-- Sorted by TotalLineItems DESC.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionValidationByPanel
(
    @WeekStartDate             DATE          = NULL,
    @RunId                     NVARCHAR(100) = NULL,
    @FilterPayerName           NVARCHAR(255) = NULL,
    @FilterPayerType           NVARCHAR(100) = NULL,
    @FilterPanelName           NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus NVARCHAR(100) = NULL,
    @FilterPayability          NVARCHAR(100) = NULL,
    @FilterCPTCode             NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER  BY InsertedDateTime DESC;

    ;WITH base AS
    (
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(PanelName)), ''), 'Unknown')    AS PanelNameKey,
            UPPER(LTRIM(RTRIM(ISNULL(PayStatus, ''))))                 AS NormPayStatus,
            ISNULL(TRY_CAST(ModeAllowedAmountSameLab AS DECIMAL(18,4)), 0) AS ModeAllowed,
            ISNULL(TRY_CAST(ModeInsurancePaidSameLab AS DECIMAL(18,4)), 0) AS ModeIns,
            ISNULL(TRY_CAST(AllowedAmount            AS DECIMAL(18,4)), 0) AS ActAllowed,
            ISNULL(TRY_CAST(InsurancePayment         AS DECIMAL(18,4)), 0) AS ActIns
        FROM dbo.PayerValidationReport
        WHERE
            (@RunId IS NULL OR RunId = @RunId)
            AND (
                LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Potentially Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS LIKE 'Payable%Need%Action'
            )
            AND (@WeekStartDate IS NULL OR
                CASE
                    WHEN TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) IS NOT NULL
                         AND TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) BETWEEN 2 AND 2958466
                    THEN CAST(DATEADD(DAY, CAST(TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) AS INT), '1899-12-30') AS DATE)
                    ELSE TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS DATE)
                END < @WeekStartDate)
            AND (@FilterPayerName           IS NULL OR LTRIM(RTRIM(PayerNameNormalized)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerName)
            AND (@FilterPayerType           IS NULL OR LTRIM(RTRIM(PayerType))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerType)
            AND (@FilterPanelName           IS NULL OR LTRIM(RTRIM(PanelName))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPanelName)
            AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterFinalCoverageStatus)
            AND (@FilterPayability          IS NULL OR LTRIM(RTRIM(Payability))          COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayability)
            AND (@FilterCPTCode             IS NULL OR LTRIM(RTRIM(CPTCode))             COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterCPTCode)
    )
    SELECT
        PanelNameKey                                                    AS PanelName,
        COUNT(*)                                                        AS TotalLineItems,
        SUM(CASE WHEN NormPayStatus = 'PAID'        THEN 1 ELSE 0 END)  AS PaidCount,
        SUM(CASE WHEN NormPayStatus = 'DENIED'      THEN 1 ELSE 0 END)  AS DeniedCount,
        SUM(CASE WHEN NormPayStatus = 'NO RESPONSE' THEN 1 ELSE 0 END)  AS NoResponseCount,
        SUM(CASE WHEN NormPayStatus = 'ADJUSTED'    THEN 1 ELSE 0 END)  AS AdjustedCount,
        SUM(CASE WHEN NormPayStatus IN ('DENIED','NO RESPONSE','ADJUSTED') THEN 1 ELSE 0 END) AS UnpaidCount,
        ISNULL(SUM(ModeAllowed), 0) AS PredictedAllowed,
        ISNULL(SUM(ModeIns),    0)  AS PredictedInsurance,
        ISNULL(SUM(ActAllowed), 0)  AS ActualAllowed,
        ISNULL(SUM(ActIns),     0)  AS ActualInsurance
    FROM base
    GROUP BY PanelNameKey
    ORDER BY COUNT(*) DESC;
END
GO

-- ============================================================
-- SP 9 : usp_GetPredictionValidationByCPT
-- Prediction Validation & Breakdown Analysis – CPT Codes tab.
-- Columns: CPTCode, LineItemCount, BilledAmount,
--          PredictedAllowed, PredictedInsurance
-- Sorted by PredictedInsurance DESC, top 50 rows.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionValidationByCPT
(
    @WeekStartDate             DATE          = NULL,
    @RunId                     NVARCHAR(100) = NULL,
    @FilterPayerName           NVARCHAR(255) = NULL,
    @FilterPayerType           NVARCHAR(100) = NULL,
    @FilterPanelName           NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus NVARCHAR(100) = NULL,
    @FilterPayability          NVARCHAR(100) = NULL,
    @FilterCPTCode             NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER  BY InsertedDateTime DESC;

    ;WITH base AS
    (
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(CPTCode)), ''), 'Unknown')      AS CPTCodeKey,
            ISNULL(TRY_CAST(BilledAmount             AS DECIMAL(18,4)), 0) AS Billed,
            ISNULL(TRY_CAST(ModeAllowedAmountSameLab AS DECIMAL(18,4)), 0) AS ModeAllowed,
            ISNULL(TRY_CAST(ModeInsurancePaidSameLab AS DECIMAL(18,4)), 0) AS ModeIns
        FROM dbo.PayerValidationReport
        WHERE
            (@RunId IS NULL OR RunId = @RunId)
            AND (
                LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Potentially Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS LIKE 'Payable%Need%Action'
            )
            AND (@WeekStartDate IS NULL OR
                CASE
                    WHEN TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) IS NOT NULL
                         AND TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) BETWEEN 2 AND 2958466
                    THEN CAST(DATEADD(DAY, CAST(TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) AS INT), '1899-12-30') AS DATE)
                    ELSE TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS DATE)
                END < @WeekStartDate)
            AND (@FilterPayerName           IS NULL OR LTRIM(RTRIM(PayerNameNormalized)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerName)
            AND (@FilterPayerType           IS NULL OR LTRIM(RTRIM(PayerType))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerType)
            AND (@FilterPanelName           IS NULL OR LTRIM(RTRIM(PanelName))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPanelName)
            AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterFinalCoverageStatus)
            AND (@FilterPayability          IS NULL OR LTRIM(RTRIM(Payability))          COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayability)
            AND (@FilterCPTCode             IS NULL OR LTRIM(RTRIM(CPTCode))             COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterCPTCode)
    )
    SELECT TOP 50
        CPTCodeKey                  AS CPTCode,
        COUNT(*)                    AS LineItemCount,
        ISNULL(SUM(Billed), 0)      AS BilledAmount,
        ISNULL(SUM(ModeAllowed), 0) AS PredictedAllowed,
        ISNULL(SUM(ModeIns),    0)  AS PredictedInsurance
    FROM base
    GROUP BY CPTCodeKey
    ORDER BY SUM(ModeIns) DESC;
END
GO

-- ============================================================
-- SP 10 : usp_GetPredictionDenialBreakdown
-- Denial Breakdown analysis.
-- Returns flat detail rows; C# pivots by ExpectedPaymentMonth.
-- Columns: PayerName, DenialCode, DenialDescription,
--          ExpectedPaymentMonth, LineItemCount,
--          PredictedAllowed, PredictedInsurance
-- Only rows where PayStatus = Denied and ForecastPayable.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionDenialBreakdown
(
    @WeekStartDate             DATE          = NULL,
    @RunId                     NVARCHAR(100) = NULL,
    @FilterPayerName           NVARCHAR(255) = NULL,
    @FilterPayerType           NVARCHAR(100) = NULL,
    @FilterPanelName           NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus NVARCHAR(100) = NULL,
    @FilterPayability          NVARCHAR(100) = NULL,
    @FilterCPTCode             NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER  BY InsertedDateTime DESC;

    SELECT
        ISNULL(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), ''),
               LTRIM(RTRIM(ISNULL(PayerName, 'Unknown'))))          AS PayerName,
        ISNULL(NULLIF(LTRIM(RTRIM(DenialCode)), ''), '(No Code)')   AS DenialCode,
        ISNULL(LTRIM(RTRIM(DenialDescription)), '')                  AS DenialDescription,
        ISNULL(LTRIM(RTRIM(ExpectedPaymentMonth)), '')               AS ExpectedPaymentMonth,
        COUNT(*)                                                      AS LineItemCount,
        SUM(ISNULL(TRY_CAST(ModeAllowedAmountSameLab AS DECIMAL(18,4)), 0)) AS PredictedAllowed,
        SUM(ISNULL(TRY_CAST(ModeInsurancePaidSameLab AS DECIMAL(18,4)), 0)) AS PredictedInsurance
    FROM dbo.PayerValidationReport
    WHERE
        (@RunId IS NULL OR RunId = @RunId)
        AND UPPER(LTRIM(RTRIM(ISNULL(PayStatus, '')))) = 'DENIED'
        AND (
            LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Payable'
            OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Potentially Payable'
            OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS LIKE 'Payable%Need%Action'
        )
        AND (@WeekStartDate IS NULL OR
            CASE
                WHEN TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) IS NOT NULL
                     AND TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) BETWEEN 2 AND 2958466
                THEN CAST(DATEADD(DAY, CAST(TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) AS INT), '1899-12-30') AS DATE)
                ELSE TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS DATE)
            END < @WeekStartDate)
        AND (@FilterPayerName           IS NULL OR LTRIM(RTRIM(PayerNameNormalized)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerName)
        AND (@FilterPayerType           IS NULL OR LTRIM(RTRIM(PayerType))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerType)
        AND (@FilterPanelName           IS NULL OR LTRIM(RTRIM(PanelName))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPanelName)
        AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterFinalCoverageStatus)
        AND (@FilterPayability          IS NULL OR LTRIM(RTRIM(Payability))          COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayability)
        AND (@FilterCPTCode             IS NULL OR LTRIM(RTRIM(CPTCode))             COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterCPTCode)
    GROUP BY
        ISNULL(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), ''), LTRIM(RTRIM(ISNULL(PayerName, 'Unknown')))),
        ISNULL(NULLIF(LTRIM(RTRIM(DenialCode)), ''), '(No Code)'),
        ISNULL(LTRIM(RTRIM(DenialDescription)), ''),
        ISNULL(LTRIM(RTRIM(ExpectedPaymentMonth)), '')
    ORDER BY
        ISNULL(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), ''), LTRIM(RTRIM(ISNULL(PayerName, 'Unknown')))),
        ISNULL(NULLIF(LTRIM(RTRIM(DenialCode)), ''), '(No Code)'),
        ISNULL(LTRIM(RTRIM(ExpectedPaymentMonth)), '');
END
GO

-- ============================================================
-- SP 11 : usp_GetPredictionNoResponseBreakdown
-- No Response Breakdown analysis.
-- Age bucket derived from FirstBilledDate vs today (GETDATE()).
-- Returns flat detail rows; C# assembles the final breakdown.
-- Columns: PayerName, AgeBucket, LineItemCount,
--          PredictedAllowed, PredictedInsurance
-- Only rows where PayStatus = No Response and ForecastPayable.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionNoResponseBreakdown
(
    @WeekStartDate             DATE          = NULL,
    @RunId                     NVARCHAR(100) = NULL,
    @FilterPayerName           NVARCHAR(255) = NULL,
    @FilterPayerType           NVARCHAR(100) = NULL,
    @FilterPanelName           NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus NVARCHAR(100) = NULL,
    @FilterPayability          NVARCHAR(100) = NULL,
    @FilterCPTCode             NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER  BY InsertedDateTime DESC;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    ;WITH base AS
    (
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), ''),
                   LTRIM(RTRIM(ISNULL(PayerName, 'Unknown'))))                  AS PayerNameKey,
            ISNULL(TRY_CAST(ModeAllowedAmountSameLab AS DECIMAL(18,4)), 0)       AS ModeAllowed,
            ISNULL(TRY_CAST(ModeInsurancePaidSameLab AS DECIMAL(18,4)), 0)       AS ModeIns,
            -- Age in days from FirstBilledDate to today
            CASE
                WHEN TRY_CAST(LTRIM(RTRIM(FirstBilledDate)) AS FLOAT) IS NOT NULL
                     AND TRY_CAST(LTRIM(RTRIM(FirstBilledDate)) AS FLOAT) BETWEEN 2 AND 2958466
                THEN DATEDIFF(DAY,
                        CAST(DATEADD(DAY, CAST(TRY_CAST(LTRIM(RTRIM(FirstBilledDate)) AS FLOAT) AS INT), '1899-12-30') AS DATE),
                        @Today)
                ELSE DATEDIFF(DAY, TRY_CAST(LTRIM(RTRIM(FirstBilledDate)) AS DATE), @Today)
            END AS AgeDays
        FROM dbo.PayerValidationReport
        WHERE
            (@RunId IS NULL OR RunId = @RunId)
            AND UPPER(LTRIM(RTRIM(ISNULL(PayStatus, '')))) = 'NO RESPONSE'
            AND (
                LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Potentially Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS LIKE 'Payable%Need%Action'
            )
            AND (@WeekStartDate IS NULL OR
                CASE
                    WHEN TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) IS NOT NULL
                         AND TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) BETWEEN 2 AND 2958466
                    THEN CAST(DATEADD(DAY, CAST(TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) AS INT), '1899-12-30') AS DATE)
                    ELSE TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS DATE)
                END < @WeekStartDate)
            AND (@FilterPayerName           IS NULL OR LTRIM(RTRIM(PayerNameNormalized)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerName)
            AND (@FilterPayerType           IS NULL OR LTRIM(RTRIM(PayerType))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerType)
            AND (@FilterPanelName           IS NULL OR LTRIM(RTRIM(PanelName))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPanelName)
            AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterFinalCoverageStatus)
            AND (@FilterPayability          IS NULL OR LTRIM(RTRIM(Payability))          COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayability)
            AND (@FilterCPTCode             IS NULL OR LTRIM(RTRIM(CPTCode))             COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterCPTCode)
    ),
    bucketed AS
    (
        SELECT
            PayerNameKey,
            ModeAllowed,
            ModeIns,
            -- Assign age bucket (matches AgeBuckets.Classify in C#)
            CASE
                WHEN AgeDays IS NULL OR AgeDays < 0 THEN '0-30'
                WHEN AgeDays <= 30  THEN '0-30'
                WHEN AgeDays <= 60  THEN '31-60'
                WHEN AgeDays <= 90  THEN '61-90'
                WHEN AgeDays <= 120 THEN '91-120'
                ELSE '>120'
            END AS AgeBucket
        FROM base
    )
    SELECT
        PayerNameKey                AS PayerName,
        AgeBucket,
        COUNT(*)                    AS LineItemCount,
        ISNULL(SUM(ModeAllowed), 0) AS PredictedAllowed,
        ISNULL(SUM(ModeIns),    0)  AS PredictedInsurance
    FROM bucketed
    GROUP BY PayerNameKey, AgeBucket
    ORDER BY SUM(ModeIns) DESC, PayerNameKey, AgeBucket;
END
GO

-- ============================================================
-- SP 12 : usp_GetPredictionSummaryMetrics
-- Returns a SINGLE ROW containing:
--   Section 1 – Non-Payment Summary counts & amounts (6 buckets)
--   Section 2 – All 5 Ratio metrics (Claim / Allowed / Insurance % each)
--   Section 3 – All 3 Prediction Accuracy metrics
--
-- Bucket definitions (same as SP 6):
--   ToPay   = ForecastPayable rows, all PayStatus
--   Paid    = ForecastPayable AND PayStatus = PAID
--   Unpaid  = ForecastPayable AND PayStatus IN (DENIED, NO RESPONSE, ADJUSTED)
--   Denied  = ForecastPayable AND PayStatus = DENIED
--   NoResp  = ForecastPayable AND PayStatus = NO RESPONSE
--   Adj     = ForecastPayable AND PayStatus = ADJUSTED
--
-- Ratio formulas:
--   Payment Ratio    = Paid  / ToPay  * 100
--   Non-Payment Rate = Unpaid / ToPay * 100
--   Denied %         = Denied / Unpaid * 100
--   No Response %    = NoResp / Unpaid * 100
--   Adjusted %       = Adj    / Unpaid * 100
--
-- Prediction Accuracy formulas:
--   Claim %               = PaidLineItems   / ToPayLineItems   * 100      (counts use COUNT(DISTINCT VisitNumber))
--   Allowed Amount %      = Paid ActualAllowed     / ToPay PredictedAllowed     * 100
--   Insurance Payment %   = Paid ActualInsurance   / ToPay PredictedInsurance   * 100
--
-- Claim Count (#) rule (SP 6 & SP 12):
--   Every bucket's line-item count is COUNT(DISTINCT VisitNumber) within the bucket.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionSummaryMetrics
(
    @WeekStartDate             DATE          = NULL,
    @RunId                     NVARCHAR(100) = NULL,
    @FilterPayerName           NVARCHAR(255) = NULL,
    @FilterPayerType           NVARCHAR(100) = NULL,
    @FilterPanelName           NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus NVARCHAR(100) = NULL,
    @FilterPayability          NVARCHAR(100) = NULL,
    @FilterCPTCode             NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve latest RunId when not supplied
    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER  BY InsertedDateTime DESC;

    -- ?? Base CTE: one row per line item, ForecastPayable only ??????????????
    ;WITH base AS
    (
        SELECT
            UPPER(LTRIM(RTRIM(ISNULL(PayStatus, ''))))                         AS NormPayStatus,
            NULLIF(LTRIM(RTRIM(VisitNumber)), '')                              AS VisitNumber,
            ISNULL(TRY_CAST(ModeAllowedAmountSameLab  AS DECIMAL(18,4)), 0)    AS ModeAllowed,
            ISNULL(TRY_CAST(ModeInsurancePaidSameLab  AS DECIMAL(18,4)), 0)    AS ModeIns,
            ISNULL(TRY_CAST(AllowedAmount             AS DECIMAL(18,4)), 0)    AS ActAllowed,
            ISNULL(TRY_CAST(InsurancePayment          AS DECIMAL(18,4)), 0)    AS ActIns
        FROM dbo.PayerValidationReport
        WHERE
            (@RunId IS NULL OR RunId = @RunId)
            AND (
                LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Potentially Payable'
                OR LTRIM(RTRIM(ForecastingPayability)) COLLATE SQL_Latin1_General_CP1_CI_AS LIKE 'Payable%Need%Action'
            )
            AND (@WeekStartDate IS NULL OR
                CASE
                    WHEN TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) IS NOT NULL
                         AND TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) BETWEEN 2 AND 2958466
                    THEN CAST(DATEADD(DAY, CAST(TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS FLOAT) AS INT), '1899-12-30') AS DATE)
                    ELSE TRY_CAST(LTRIM(RTRIM(ExpectedPaymentDate)) AS DATE)
                END < @WeekStartDate)
            AND (@FilterPayerName           IS NULL OR LTRIM(RTRIM(PayerNameNormalized)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerName)
            AND (@FilterPayerType           IS NULL OR LTRIM(RTRIM(PayerType))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayerType)
            AND (@FilterPanelName           IS NULL OR LTRIM(RTRIM(PanelName))           COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPanelName)
            AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterFinalCoverageStatus)
            AND (@FilterPayability          IS NULL OR LTRIM(RTRIM(Payability))          COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterPayability)
            AND (@FilterCPTCode             IS NULL OR LTRIM(RTRIM(CPTCode))             COLLATE SQL_Latin1_General_CP1_CI_AS = @FilterCPTCode)
    ),
    -- ?? Bucket aggregates ??????????????????????????????????????????????????
    buckets AS
    (
        SELECT
            -- Predicted To Pay  (all ForecastPayable rows)
            COUNT(DISTINCT VisitNumber)                                                     AS ToPay_LineItems,
            ISNULL(SUM(ModeAllowed), 0)                                                     AS ToPay_ModeAllowed,
            ISNULL(SUM(ModeIns),    0)                                                      AS ToPay_ModeIns,

            -- Predicted - Paid
            COUNT(DISTINCT CASE WHEN NormPayStatus = 'PAID' THEN VisitNumber END)           AS Paid_LineItems,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'PAID' THEN ModeAllowed ELSE 0 END), 0)   AS Paid_ModeAllowed,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'PAID' THEN ModeIns     ELSE 0 END), 0)   AS Paid_ModeIns,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'PAID' THEN ActAllowed  ELSE 0 END), 0)   AS Paid_ActAllowed,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'PAID' THEN ActIns      ELSE 0 END), 0)   AS Paid_ActIns,

            -- Predicted - Unpaid  (Denied + No Response + Adjusted)
            COUNT(DISTINCT CASE WHEN NormPayStatus IN ('DENIED','NO RESPONSE','ADJUSTED') THEN VisitNumber END) AS Unpaid_LineItems,
            ISNULL(SUM(CASE WHEN NormPayStatus IN ('DENIED','NO RESPONSE','ADJUSTED') THEN ModeAllowed ELSE 0 END), 0) AS Unpaid_ModeAllowed,
            ISNULL(SUM(CASE WHEN NormPayStatus IN ('DENIED','NO RESPONSE','ADJUSTED') THEN ModeIns     ELSE 0 END), 0) AS Unpaid_ModeIns,

            -- Unpaid - Denied
            COUNT(DISTINCT CASE WHEN NormPayStatus = 'DENIED'      THEN VisitNumber END)    AS Denied_LineItems,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'DENIED'      THEN ModeAllowed ELSE 0 END), 0) AS Denied_ModeAllowed,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'DENIED'      THEN ModeIns     ELSE 0 END), 0) AS Denied_ModeIns,

            -- Unpaid - No Response
            COUNT(DISTINCT CASE WHEN NormPayStatus = 'NO RESPONSE' THEN VisitNumber END)    AS NoResp_LineItems,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'NO RESPONSE' THEN ModeAllowed ELSE 0 END), 0) AS NoResp_ModeAllowed,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'NO RESPONSE' THEN ModeIns     ELSE 0 END), 0) AS NoResp_ModeIns,

            -- Unpaid - Adjusted
            COUNT(DISTINCT CASE WHEN NormPayStatus = 'ADJUSTED'    THEN VisitNumber END)    AS Adj_LineItems,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'ADJUSTED'    THEN ModeAllowed ELSE 0 END), 0) AS Adj_ModeAllowed,
            ISNULL(SUM(CASE WHEN NormPayStatus = 'ADJUSTED'    THEN ModeIns     ELSE 0 END), 0) AS Adj_ModeIns
        FROM base
    )
    -- ?? Final SELECT: buckets + all ratios + all prediction accuracy values ?
    SELECT
        -- ?? Section 1: Non-Payment Summary raw counts & amounts ??????????????
        ToPay_LineItems,   ToPay_ModeAllowed,   ToPay_ModeIns,
        Paid_LineItems,    Paid_ModeAllowed,    Paid_ModeIns,    Paid_ActAllowed,  Paid_ActIns,
        Unpaid_LineItems,  Unpaid_ModeAllowed,  Unpaid_ModeIns,
        Denied_LineItems,  Denied_ModeAllowed,  Denied_ModeIns,
        NoResp_LineItems,  NoResp_ModeAllowed,  NoResp_ModeIns,
        Adj_LineItems,     Adj_ModeAllowed,     Adj_ModeIns,

        -- ?? Section 2: Ratios ?????????????????????????????????????????????????
        -- Payment Ratio %  = Paid / ToPay * 100
        CASE WHEN ToPay_LineItems  > 0 THEN CAST(Paid_LineItems   * 100.0 / ToPay_LineItems   AS DECIMAL(10,2)) END AS PaymentRatio_Claim,
        CASE WHEN ToPay_ModeAllowed > 0 THEN CAST(Paid_ModeAllowed * 100.0 / ToPay_ModeAllowed AS DECIMAL(10,2)) END AS PaymentRatio_Allowed,
        CASE WHEN ToPay_ModeIns    > 0 THEN CAST(Paid_ModeIns     * 100.0 / ToPay_ModeIns     AS DECIMAL(10,2)) END AS PaymentRatio_Insurance,

        -- Non-Payment Rate % = Unpaid / ToPay * 100
        CASE WHEN ToPay_LineItems  > 0 THEN CAST(Unpaid_LineItems   * 100.0 / ToPay_LineItems   AS DECIMAL(10,2)) END AS NonPaymentRate_Claim,
        CASE WHEN ToPay_ModeAllowed > 0 THEN CAST(Unpaid_ModeAllowed * 100.0 / ToPay_ModeAllowed AS DECIMAL(10,2)) END AS NonPaymentRate_Allowed,
        CASE WHEN ToPay_ModeIns    > 0 THEN CAST(Unpaid_ModeIns     * 100.0 / ToPay_ModeIns     AS DECIMAL(10,2)) END AS NonPaymentRate_Insurance,

        -- Denied % = Denied / Unpaid * 100
        CASE WHEN Unpaid_LineItems  > 0 THEN CAST(Denied_LineItems   * 100.0 / Unpaid_LineItems   AS DECIMAL(10,2)) END AS DeniedPct_Claim,
        CASE WHEN Unpaid_ModeAllowed > 0 THEN CAST(Denied_ModeAllowed * 100.0 / Unpaid_ModeAllowed AS DECIMAL(10,2)) END AS DeniedPct_Allowed,
        CASE WHEN Unpaid_ModeIns    > 0 THEN CAST(Denied_ModeIns     * 100.0 / Unpaid_ModeIns     AS DECIMAL(10,2)) END AS DeniedPct_Insurance,

        -- No Response % = NoResp / Unpaid * 100
        CASE WHEN Unpaid_LineItems  > 0 THEN CAST(NoResp_LineItems   * 100.0 / Unpaid_LineItems   AS DECIMAL(10,2)) END AS NoResponsePct_Claim,
        CASE WHEN Unpaid_ModeAllowed > 0 THEN CAST(NoResp_ModeAllowed * 100.0 / Unpaid_ModeAllowed AS DECIMAL(10,2)) END AS NoResponsePct_Allowed,
        CASE WHEN Unpaid_ModeIns    > 0 THEN CAST(NoResp_ModeIns     * 100.0 / Unpaid_ModeIns     AS DECIMAL(10,2)) END AS NoResponsePct_Insurance,

        -- Adjusted % = Adj / Unpaid * 100
        CASE WHEN Unpaid_LineItems  > 0 THEN CAST(Adj_LineItems   * 100.0 / Unpaid_LineItems   AS DECIMAL(10,2)) END AS AdjustedPct_Claim,
        CASE WHEN Unpaid_ModeAllowed > 0 THEN CAST(Adj_ModeAllowed * 100.0 / Unpaid_ModeAllowed AS DECIMAL(10,2)) END AS AdjustedPct_Allowed,
        CASE WHEN Unpaid_ModeIns    > 0 THEN CAST(Adj_ModeIns     * 100.0 / Unpaid_ModeIns     AS DECIMAL(10,2)) END AS AdjustedPct_Insurance,

        -- ?? Section 3: Prediction Accuracy ????????????????????????????????????
        -- Claim %             = Predicted Paid Claim Count / Predicted To Pay Claim Count * 100
        --                       (both line-item counts are COUNT(DISTINCT VisitNumber))
        CASE WHEN ToPay_LineItems > 0 THEN CAST(Paid_LineItems  * 100.0 / ToPay_LineItems   AS DECIMAL(10,2)) END AS PredAccuracy_Claim,

        -- Allowed Amount %    = SUM(Actual Allowed on Paid rows) / SUM(Predicted Allowed on Predicted-To-Pay rows) * 100
        --                       (numerator: Paid bucket actuals; denominator: full Predicted-To-Pay predicted amount)
        CASE WHEN ToPay_ModeAllowed > 0 THEN CAST(Paid_ActAllowed * 100.0 / ToPay_ModeAllowed AS DECIMAL(10,2)) END AS PredAccuracy_AllowedAmount,

        -- Insurance Payment % = SUM(Actual Insurance on Paid rows) / SUM(Predicted Insurance on Predicted-To-Pay rows) * 100
        CASE WHEN ToPay_ModeIns > 0 THEN CAST(Paid_ActIns * 100.0 / ToPay_ModeIns AS DECIMAL(10,2)) END AS PredAccuracy_InsurancePayment
    FROM buckets;
END
GO
