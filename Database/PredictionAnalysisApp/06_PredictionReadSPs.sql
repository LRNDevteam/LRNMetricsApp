-- ============================================================
-- 06_PredictionReadSPs.sql
-- Read stored procedures for PV_* snapshot tables.
-- Run AFTER 04_PredictionAggregateTables.sql and 05_PredictionAggregateRefreshSPs.sql.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadSummaryBuckets
(
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId FROM dbo.PV_SummaryBuckets ORDER BY RefreshedAt DESC;
    SELECT GroupName, BucketName, PayStatus, IsGroupTotal, SortOrder, LineItemCount,
           PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance,
           VarianceAllowed, VariancePaid
    FROM dbo.PV_SummaryBuckets
    WHERE RunId = @RunId
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadValidationByPayer
(
    @WeekStartDate    DATE          = NULL,
    @FilterPayerName  NVARCHAR(255) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId FROM dbo.PV_ValidationByPayer ORDER BY RefreshedAt DESC;

    -- Slim table has no pay-status count columns; legacy table does.
    IF COL_LENGTH('dbo.PV_ValidationByPayer', 'PaidCount') IS NOT NULL
    BEGIN
        SELECT PayerName, PayerType, TotalLineItems,
               ISNULL(PaidCount, 0) AS PaidCount,
               ISNULL(DeniedCount, 0) AS DeniedCount,
               ISNULL(NoResponseCount, 0) AS NoResponseCount,
               ISNULL(AdjustedCount, 0) AS AdjustedCount,
               ISNULL(UnpaidCount, 0) AS UnpaidCount,
               PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance,
               VarianceAllowed, VariancePaid
        FROM dbo.PV_ValidationByPayer
        WHERE RunId = @RunId
          AND (@FilterPayerName IS NULL OR PayerName = @FilterPayerName)
        ORDER BY VarianceAllowed DESC;
    END
    ELSE
    BEGIN
        SELECT PayerName, PayerType, TotalLineItems,
               CAST(0 AS INT) AS PaidCount,
               CAST(0 AS INT) AS DeniedCount,
               CAST(0 AS INT) AS NoResponseCount,
               CAST(0 AS INT) AS AdjustedCount,
               CAST(0 AS INT) AS UnpaidCount,
               PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance,
               VarianceAllowed, VariancePaid
        FROM dbo.PV_ValidationByPayer
        WHERE RunId = @RunId
          AND (@FilterPayerName IS NULL OR PayerName = @FilterPayerName)
        ORDER BY VarianceAllowed DESC;
    END
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadPayerPayStatusBreakdown
(
    @WeekStartDate    DATE          = NULL,
    @FilterPayerName  NVARCHAR(255) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId FROM dbo.PV_PayerPayStatusBreakdown ORDER BY RefreshedAt DESC;
    SELECT PayerName, PayStatus, LineItemCount,
           PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance,
           VarianceAllowed, VariancePaid
    FROM dbo.PV_PayerPayStatusBreakdown
    WHERE RunId = @RunId
      AND (@FilterPayerName IS NULL OR PayerName = @FilterPayerName)
    ORDER BY PayerName, PayStatus;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadDenialBreakdown
(
    @WeekStartDate    DATE          = NULL,
    @FilterPayerName  NVARCHAR(255) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId FROM dbo.PV_DenialBreakdown ORDER BY RefreshedAt DESC;
    SELECT PayerName, DenialCode, DenialDescription, N'' AS ExpectedPaymentMonth,
           LineItemCount, PredictedAllowed, PredictedInsurance,
           ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
    FROM dbo.PV_DenialBreakdown
    WHERE RunId = @RunId
      AND (@FilterPayerName IS NULL OR PayerName = @FilterPayerName)
    ORDER BY PayerName, VarianceAllowed DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadNoResponseBreakdown
(
    @WeekStartDate    DATE          = NULL,
    @FilterPayerName  NVARCHAR(255) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId FROM dbo.PV_NoResponseBreakdown ORDER BY RefreshedAt DESC;
    SELECT PayerName, AgeBucket, LineItemCount, VarianceAllowed, VariancePaid,
           PctVarianceAllowed, PctVariancePaid,
           SUM(VarianceAllowed) OVER (PARTITION BY PayerName) AS TotalVarianceAllowed,
           SUM(VariancePaid)    OVER (PARTITION BY PayerName) AS TotalVariancePaid
    FROM dbo.PV_NoResponseBreakdown
    WHERE RunId = @RunId
      AND (@FilterPayerName IS NULL OR PayerName = @FilterPayerName)
    ORDER BY PayerName, AgeBucket;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadAdjustedByPayer
(
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId FROM dbo.PV_AdjustedByPayer ORDER BY RefreshedAt DESC;
    SELECT PayerName, LineItemCount, PredictedAllowed, PredictedInsurance,
           ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
    FROM dbo.PV_AdjustedByPayer
    WHERE RunId = @RunId
    ORDER BY VarianceAllowed DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadSummaryMetrics
(
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId FROM dbo.PV_SummaryMetrics ORDER BY RefreshedAt DESC;
    SELECT ToPay_LineItems, ToPay_ModeAllowed, ToPay_ModeIns,
           Paid_LineItems, Paid_ModeAllowed, Paid_ModeIns, Paid_ActAllowed, Paid_ActIns,
           Unpaid_LineItems, Unpaid_ModeAllowed, Unpaid_ModeIns,
           Denied_LineItems, Denied_ModeAllowed, Denied_ModeIns,
           NoResp_LineItems, NoResp_ModeAllowed, NoResp_ModeIns,
           Adj_LineItems, Adj_ModeAllowed, Adj_ModeIns,
           PaymentRatio_Claim, PaymentRatio_Allowed, PaymentRatio_Insurance,
           NonPaymentRate_Claim, NonPaymentRate_Allowed, NonPaymentRate_Insurance,
           DeniedPct_Claim, DeniedPct_Allowed, DeniedPct_Insurance,
           NoResponsePct_Claim, NoResponsePct_Allowed, NoResponsePct_Insurance,
           AdjustedPct_Claim, AdjustedPct_Allowed, AdjustedPct_Insurance,
           PredAccuracy_Claim, PredAccuracy_AllowedAmount, PredAccuracy_InsurancePayment
    FROM dbo.PV_SummaryMetrics
    WHERE RunId = @RunId;
END
GO

-- Legacy read stubs for panels/CPT (return empty when tables absent)
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadValidationByPanel
(
    @WeekStartDate DATE = NULL
)
AS
BEGIN SET NOCOUNT ON;
    SELECT CAST(NULL AS NVARCHAR(255)) AS PanelName WHERE 1=0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadValidationByCPT
(
    @WeekStartDate DATE = NULL
)
AS
BEGIN SET NOCOUNT ON;
    SELECT CAST(NULL AS NVARCHAR(50)) AS CPTCode WHERE 1=0;
END
GO
