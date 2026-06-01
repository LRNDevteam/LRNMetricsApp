-- ============================================================
-- 06_PredictionReadSPs.sql
-- Read-only stored procedures consumed by LabMetricsDashboard and
-- PredictionAnalysisApp so that no caller embeds inline SQL.
--
-- The dashboard never passes a RunId — every read SP auto-resolves
-- the latest snapshot in its source PV_* table by RefreshedAt.
-- Only @FilterPayerName flows from the UI (Payer dropdown).
--
-- Run once against every lab database that holds PayerValidationReport,
-- AFTER 04_PredictionAggregateTables.sql and 05_PredictionAggregateRefreshSPs.sql.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================
-- SP : usp_PV_GetLatestRunId
-- Returns the most recent RunId in dbo.PayerValidationReport, or NULL
-- when the table is empty. Kept for diagnostics / ingestion only —
-- the read SPs below no longer require it.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_GetLatestRunId
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1 RunId
    FROM   dbo.PayerValidationReport
    WHERE  RunId IS NOT NULL
    ORDER  BY InsertedDateTime DESC;
END
GO

-- ============================================================
-- SP : usp_PV_IsFileLogged
-- Returns 1 when @SourceFullPath already has an entry in
-- dbo.PayerValidationFileLog (so the ingestion app can skip re-insert).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_IsFileLogged
(
    @SourceFullPath NVARCHAR(1000)
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CAST(
        CASE WHEN EXISTS (
            SELECT 1
            FROM   dbo.PayerValidationFileLog
            WHERE  SourceFullPath = @SourceFullPath
        ) THEN 1 ELSE 0 END AS BIT) AS IsLogged;
END
GO

-- ============================================================
-- SP : usp_PV_ReadSummaryBuckets   (snapshot read for SP 6 fast path)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadSummaryBuckets
(
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId
    FROM   dbo.PV_SummaryBuckets
    ORDER  BY RefreshedAt DESC;

    IF @RunId IS NULL RETURN;

    SELECT
        BucketName,
        SortOrder,
        LineItemCount,
        PredictedAllowed,
        PredictedInsurance,
        ActualAllowed,
        ActualInsurance
    FROM   dbo.PV_SummaryBuckets
    WHERE  RunId = @RunId
      AND  (@WeekStartDate IS NULL OR WeekStartDate = @WeekStartDate)
    ORDER  BY SortOrder;
END
GO

-- ============================================================
-- SP : usp_PV_ReadValidationByPayer   (snapshot read for SP 7)
-- Optional @FilterPayerName — only filter that flows from the UI.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadValidationByPayer
(
    @WeekStartDate   DATE          = NULL,
    @FilterPayerName NVARCHAR(255) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId
    FROM   dbo.PV_ValidationByPayer
    ORDER  BY RefreshedAt DESC;

    IF @RunId IS NULL RETURN;

    SELECT
        PayerName, PayerType, TotalLineItems,
        PaidCount, DeniedCount, NoResponseCount, AdjustedCount, UnpaidCount,
        PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance
    FROM   dbo.PV_ValidationByPayer
    WHERE  RunId = @RunId
      AND  (@WeekStartDate   IS NULL OR WeekStartDate = @WeekStartDate)
      AND  (@FilterPayerName IS NULL OR PayerName     = @FilterPayerName)
    ORDER  BY TotalLineItems DESC;
END
GO

-- ============================================================
-- SP : usp_PV_ReadValidationByPanel   (snapshot read for SP 8)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadValidationByPanel
(
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId
    FROM   dbo.PV_ValidationByPanel
    ORDER  BY RefreshedAt DESC;

    IF @RunId IS NULL RETURN;

    SELECT
        PanelName, TotalLineItems,
        PaidCount, DeniedCount, NoResponseCount, AdjustedCount, UnpaidCount,
        PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance
    FROM   dbo.PV_ValidationByPanel
    WHERE  RunId = @RunId
      AND  (@WeekStartDate IS NULL OR WeekStartDate = @WeekStartDate)
    ORDER  BY TotalLineItems DESC;
END
GO

-- ============================================================
-- SP : usp_PV_ReadValidationByCPT   (snapshot read for SP 9)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadValidationByCPT
(
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId
    FROM   dbo.PV_ValidationByCPT
    ORDER  BY RefreshedAt DESC;

    IF @RunId IS NULL RETURN;

    SELECT
        CPTCode, LineItemCount,
        BilledAmount, PredictedAllowed, PredictedInsurance
    FROM   dbo.PV_ValidationByCPT
    WHERE  RunId = @RunId
      AND  (@WeekStartDate IS NULL OR WeekStartDate = @WeekStartDate)
    ORDER  BY PredictedInsurance DESC;
END
GO

-- ============================================================
-- SP : usp_PV_ReadDenialBreakdown   (snapshot read for SP 10)
-- Optional @FilterPayerName.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadDenialBreakdown
(
    @WeekStartDate   DATE          = NULL,
    @FilterPayerName NVARCHAR(255) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId
    FROM   dbo.PV_DenialBreakdown
    ORDER  BY RefreshedAt DESC;

    IF @RunId IS NULL RETURN;

    SELECT
        PayerName, DenialCode, DenialDescription, ExpectedPaymentMonth,
        LineItemCount, PredictedAllowed, PredictedInsurance
    FROM   dbo.PV_DenialBreakdown
    WHERE  RunId = @RunId
      AND  (@WeekStartDate   IS NULL OR WeekStartDate = @WeekStartDate)
      AND  (@FilterPayerName IS NULL OR PayerName     = @FilterPayerName)
    ORDER  BY PayerName, DenialCode, ExpectedPaymentMonth;
END
GO

-- ============================================================
-- SP : usp_PV_ReadNoResponseBreakdown   (snapshot read for SP 11)
-- Optional @FilterPayerName.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadNoResponseBreakdown
(
    @WeekStartDate   DATE          = NULL,
    @FilterPayerName NVARCHAR(255) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId
    FROM   dbo.PV_NoResponseBreakdown
    ORDER  BY RefreshedAt DESC;

    IF @RunId IS NULL RETURN;

    SELECT
        PayerName, AgeBucket, LineItemCount,
        PredictedAllowed, PredictedInsurance
    FROM   dbo.PV_NoResponseBreakdown
    WHERE  RunId = @RunId
      AND  (@WeekStartDate   IS NULL OR WeekStartDate = @WeekStartDate)
      AND  (@FilterPayerName IS NULL OR PayerName     = @FilterPayerName)
    ORDER  BY PayerName;
END
GO

-- ============================================================
-- SP : usp_PV_ReadSummaryMetrics   (snapshot read for SP 12)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadSummaryMetrics
(
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId
    FROM   dbo.PV_SummaryMetrics
    ORDER  BY RefreshedAt DESC;

    IF @RunId IS NULL RETURN;

    SELECT TOP 1
        ToPay_LineItems, ToPay_ModeAllowed, ToPay_ModeIns,
        Paid_LineItems,  Paid_ModeAllowed,  Paid_ModeIns,  Paid_ActAllowed, Paid_ActIns,
        Unpaid_LineItems, Unpaid_ModeAllowed, Unpaid_ModeIns,
        Denied_LineItems, Denied_ModeAllowed, Denied_ModeIns,
        NoResp_LineItems, NoResp_ModeAllowed, NoResp_ModeIns,
        Adj_LineItems,    Adj_ModeAllowed,    Adj_ModeIns,
        PaymentRatio_Claim,       PaymentRatio_Allowed,       PaymentRatio_Insurance,
        NonPaymentRate_Claim,     NonPaymentRate_Allowed,     NonPaymentRate_Insurance,
        DeniedPct_Claim,          DeniedPct_Allowed,          DeniedPct_Insurance,
        NoResponsePct_Claim,      NoResponsePct_Allowed,      NoResponsePct_Insurance,
        AdjustedPct_Claim,        AdjustedPct_Allowed,        AdjustedPct_Insurance,
        PredAccuracy_Claim,       PredAccuracy_AllowedAmount, PredAccuracy_InsurancePayment
    FROM   dbo.PV_SummaryMetrics
    WHERE  RunId = @RunId
      AND  (@WeekStartDate IS NULL OR WeekStartDate = @WeekStartDate)
    ORDER  BY RefreshedAt DESC;
END
GO
