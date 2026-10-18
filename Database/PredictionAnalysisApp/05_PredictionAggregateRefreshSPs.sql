-- ============================================================
-- 05_PredictionAggregateRefreshSPs.sql  (reworked)
-- Refresh PV_* snapshot tables after field update + aggregate SPs.
-- Run AFTER 03_PredictionAggregatedSPs.sql and 04_PredictionAggregateTables.sql.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_SummaryBuckets
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows TABLE (
        GroupName NVARCHAR(100), BucketName NVARCHAR(100), PayStatus NVARCHAR(100),
        IsGroupTotal BIT, SortOrder INT, LineItemCount INT,
        PredictedAllowed DECIMAL(18,4), PredictedInsurance DECIMAL(18,4),
        ActualAllowed DECIMAL(18,4) NULL, ActualInsurance DECIMAL(18,4) NULL,
        VarianceAllowed DECIMAL(18,4) NULL, VariancePaid DECIMAL(18,4) NULL);
    INSERT INTO @Rows EXEC dbo.usp_GetPredictionSummaryBuckets @WeekStartDate = @WeekStartDate, @RunId = @RunId;
    DELETE FROM dbo.PV_SummaryBuckets WHERE RunId = @RunId
      AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);
    INSERT INTO dbo.PV_SummaryBuckets (RunId, WeekStartDate, GroupName, BucketName, PayStatus, IsGroupTotal, SortOrder,
        LineItemCount, PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
    SELECT @RunId, @WeekStartDate, GroupName, BucketName, PayStatus, IsGroupTotal, SortOrder,
        LineItemCount, PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
    FROM @Rows;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_ValidationByPayer
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows TABLE (
        PayerName NVARCHAR(255), PayerType NVARCHAR(100), TotalLineItems INT,
        PaidCount INT, DeniedCount INT, NoResponseCount INT, AdjustedCount INT, UnpaidCount INT,
        PredictedAllowed DECIMAL(18,4), PredictedInsurance DECIMAL(18,4),
        ActualAllowed DECIMAL(18,4), ActualInsurance DECIMAL(18,4),
        VarianceAllowed DECIMAL(18,4), VariancePaid DECIMAL(18,4));
    INSERT INTO @Rows EXEC dbo.usp_GetPredictionValidationByPayer @WeekStartDate = @WeekStartDate, @RunId = @RunId;
    DELETE FROM dbo.PV_ValidationByPayer WHERE RunId = @RunId
      AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

    -- Legacy tables include PaidCount/DeniedCount/etc.; new slim tables do not.
    IF COL_LENGTH('dbo.PV_ValidationByPayer', 'PaidCount') IS NOT NULL
    BEGIN
        INSERT INTO dbo.PV_ValidationByPayer (RunId, WeekStartDate, PayerName, PayerType, TotalLineItems,
            PaidCount, DeniedCount, NoResponseCount, AdjustedCount, UnpaidCount,
            PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
        SELECT @RunId, @WeekStartDate, PayerName, PayerType, TotalLineItems,
            ISNULL(PaidCount, 0), ISNULL(DeniedCount, 0), ISNULL(NoResponseCount, 0),
            ISNULL(AdjustedCount, 0), ISNULL(UnpaidCount, 0),
            PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
        FROM @Rows;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.PV_ValidationByPayer (RunId, WeekStartDate, PayerName, PayerType, TotalLineItems,
            PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
        SELECT @RunId, @WeekStartDate, PayerName, PayerType, TotalLineItems,
            PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
        FROM @Rows;
    END
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_PayerPayStatusBreakdown
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows TABLE (
        PayerName NVARCHAR(255), PayStatus NVARCHAR(100), LineItemCount INT,
        PredictedAllowed DECIMAL(18,4), PredictedInsurance DECIMAL(18,4),
        ActualAllowed DECIMAL(18,4), ActualInsurance DECIMAL(18,4),
        VarianceAllowed DECIMAL(18,4), VariancePaid DECIMAL(18,4));
    INSERT INTO @Rows EXEC dbo.usp_GetPredictionPayerPayStatusBreakdown @WeekStartDate = @WeekStartDate, @RunId = @RunId;
    DELETE FROM dbo.PV_PayerPayStatusBreakdown WHERE RunId = @RunId
      AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);
    INSERT INTO dbo.PV_PayerPayStatusBreakdown (RunId, WeekStartDate, PayerName, PayStatus, LineItemCount,
        PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
    SELECT @RunId, @WeekStartDate, PayerName, PayStatus, LineItemCount,
        PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
    FROM @Rows;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_DenialBreakdown
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows TABLE (
        PayerName NVARCHAR(255), DenialCode NVARCHAR(100), DenialDescription NVARCHAR(1000),
        ExpectedPaymentMonth NVARCHAR(100), LineItemCount INT,
        PredictedAllowed DECIMAL(18,4), PredictedInsurance DECIMAL(18,4),
        ActualAllowed DECIMAL(18,4), ActualInsurance DECIMAL(18,4),
        VarianceAllowed DECIMAL(18,4), VariancePaid DECIMAL(18,4));
    INSERT INTO @Rows EXEC dbo.usp_GetPredictionDenialBreakdown @WeekStartDate = @WeekStartDate, @RunId = @RunId;
    DELETE FROM dbo.PV_DenialBreakdown WHERE RunId = @RunId
      AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);
    INSERT INTO dbo.PV_DenialBreakdown (RunId, WeekStartDate, PayerName, DenialCode, DenialDescription,
        LineItemCount, PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
    SELECT @RunId, @WeekStartDate, PayerName, DenialCode, DenialDescription,
        LineItemCount, PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
    FROM @Rows;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_NoResponseBreakdown
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows TABLE (
        PayerName NVARCHAR(255), AgeBucket NVARCHAR(50), LineItemCount INT,
        VarianceAllowed DECIMAL(18,4), VariancePaid DECIMAL(18,4),
        PctVarianceAllowed DECIMAL(10,2) NULL, PctVariancePaid DECIMAL(10,2) NULL,
        TotalVarianceAllowed DECIMAL(18,4), TotalVariancePaid DECIMAL(18,4));
    INSERT INTO @Rows EXEC dbo.usp_GetPredictionNoResponseBreakdown @WeekStartDate = @WeekStartDate, @RunId = @RunId;
    DELETE FROM dbo.PV_NoResponseBreakdown WHERE RunId = @RunId
      AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

    -- Build INSERT dynamically: NWL legacy has PredictedAllowed/PredictedInsurance NOT NULL,
    -- but may not have ActualAllowed/ActualInsurance. Static IF COL_LENGTH still fails CREATE
    -- when the column is missing — so use dynamic SQL.
    IF OBJECT_ID('tempdb..#NrRows') IS NOT NULL DROP TABLE #NrRows;
    SELECT * INTO #NrRows FROM @Rows;

    DECLARE @sql NVARCHAR(MAX);
    IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'PredictedAllowed') IS NOT NULL
       AND COL_LENGTH('dbo.PV_NoResponseBreakdown', 'ActualAllowed') IS NOT NULL
    BEGIN
        SET @sql = N'
            INSERT INTO dbo.PV_NoResponseBreakdown (RunId, WeekStartDate, PayerName, AgeBucket, LineItemCount,
                PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance,
                VarianceAllowed, VariancePaid, PctVarianceAllowed, PctVariancePaid)
            SELECT @RunId, @WeekStartDate, PayerName, AgeBucket, LineItemCount,
                0, 0, 0, 0,
                VarianceAllowed, VariancePaid, PctVarianceAllowed, PctVariancePaid
            FROM #NrRows;';
    END
    ELSE IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'PredictedAllowed') IS NOT NULL
    BEGIN
        SET @sql = N'
            INSERT INTO dbo.PV_NoResponseBreakdown (RunId, WeekStartDate, PayerName, AgeBucket, LineItemCount,
                PredictedAllowed, PredictedInsurance,
                VarianceAllowed, VariancePaid, PctVarianceAllowed, PctVariancePaid)
            SELECT @RunId, @WeekStartDate, PayerName, AgeBucket, LineItemCount,
                0, 0,
                VarianceAllowed, VariancePaid, PctVarianceAllowed, PctVariancePaid
            FROM #NrRows;';
    END
    ELSE
    BEGIN
        SET @sql = N'
            INSERT INTO dbo.PV_NoResponseBreakdown (RunId, WeekStartDate, PayerName, AgeBucket, LineItemCount,
                VarianceAllowed, VariancePaid, PctVarianceAllowed, PctVariancePaid)
            SELECT @RunId, @WeekStartDate, PayerName, AgeBucket, LineItemCount,
                VarianceAllowed, VariancePaid, PctVarianceAllowed, PctVariancePaid
            FROM #NrRows;';
    END

    EXEC sp_executesql @sql,
        N'@RunId NVARCHAR(100), @WeekStartDate DATE',
        @RunId = @RunId, @WeekStartDate = @WeekStartDate;

    DROP TABLE #NrRows;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_AdjustedByPayer
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows TABLE (
        PayerName NVARCHAR(255), LineItemCount INT,
        PredictedAllowed DECIMAL(18,4), PredictedInsurance DECIMAL(18,4),
        ActualAllowed DECIMAL(18,4), ActualInsurance DECIMAL(18,4),
        VarianceAllowed DECIMAL(18,4), VariancePaid DECIMAL(18,4));
    INSERT INTO @Rows EXEC dbo.usp_GetPredictionAdjustedByPayer @WeekStartDate = @WeekStartDate, @RunId = @RunId;
    DELETE FROM dbo.PV_AdjustedByPayer WHERE RunId = @RunId
      AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);
    INSERT INTO dbo.PV_AdjustedByPayer (RunId, WeekStartDate, PayerName, LineItemCount,
        PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
    SELECT @RunId, @WeekStartDate, PayerName, LineItemCount,
        PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
    FROM @Rows;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_SummaryMetrics
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows TABLE (
        ToPay_LineItems INT, ToPay_ModeAllowed DECIMAL(18,4), ToPay_ModeIns DECIMAL(18,4),
        Paid_LineItems INT, Paid_ModeAllowed DECIMAL(18,4), Paid_ModeIns DECIMAL(18,4),
        Paid_ActAllowed DECIMAL(18,4), Paid_ActIns DECIMAL(18,4),
        Unpaid_LineItems INT, Unpaid_ModeAllowed DECIMAL(18,4), Unpaid_ModeIns DECIMAL(18,4),
        Denied_LineItems INT, Denied_ModeAllowed DECIMAL(18,4), Denied_ModeIns DECIMAL(18,4),
        NoResp_LineItems INT, NoResp_ModeAllowed DECIMAL(18,4), NoResp_ModeIns DECIMAL(18,4),
        Adj_LineItems INT, Adj_ModeAllowed DECIMAL(18,4), Adj_ModeIns DECIMAL(18,4),
        PaymentRatio_Claim DECIMAL(10,2) NULL, PaymentRatio_Allowed DECIMAL(10,2) NULL, PaymentRatio_Insurance DECIMAL(10,2) NULL,
        NonPaymentRate_Claim DECIMAL(10,2) NULL, NonPaymentRate_Allowed DECIMAL(10,2) NULL, NonPaymentRate_Insurance DECIMAL(10,2) NULL,
        DeniedPct_Claim DECIMAL(10,2) NULL, DeniedPct_Allowed DECIMAL(10,2) NULL, DeniedPct_Insurance DECIMAL(10,2) NULL,
        NoResponsePct_Claim DECIMAL(10,2) NULL, NoResponsePct_Allowed DECIMAL(10,2) NULL, NoResponsePct_Insurance DECIMAL(10,2) NULL,
        AdjustedPct_Claim DECIMAL(10,2) NULL, AdjustedPct_Allowed DECIMAL(10,2) NULL, AdjustedPct_Insurance DECIMAL(10,2) NULL,
        PredAccuracy_Claim DECIMAL(10,2) NULL, PredAccuracy_AllowedAmount DECIMAL(10,2) NULL, PredAccuracy_InsurancePayment DECIMAL(10,2) NULL);
    INSERT INTO @Rows EXEC dbo.usp_GetPredictionSummaryMetrics @WeekStartDate = @WeekStartDate, @RunId = @RunId;
    DELETE FROM dbo.PV_SummaryMetrics WHERE RunId = @RunId
      AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);
    INSERT INTO dbo.PV_SummaryMetrics (RunId, WeekStartDate,
        ToPay_LineItems, ToPay_ModeAllowed, ToPay_ModeIns,
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
        PredAccuracy_Claim, PredAccuracy_AllowedAmount, PredAccuracy_InsurancePayment)
    SELECT @RunId, @WeekStartDate,
        ToPay_LineItems, ToPay_ModeAllowed, ToPay_ModeIns,
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
    FROM @Rows;
END
GO

-- Legacy stubs kept for backward compatibility
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_ValidationByPanel (@RunId NVARCHAR(100), @WeekStartDate DATE = NULL) AS BEGIN SET NOCOUNT ON; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_ValidationByCPT (@RunId NVARCHAR(100), @WeekStartDate DATE = NULL) AS BEGIN SET NOCOUNT ON; END
GO

-- NOTE: For large labs (NorthWest ~1M+ rows) deploy
--   10_ChunkedAggregateRefresh_LargeLabs.sql AFTER this file.
-- It replaces this procedure with ReportId-chunked materialization into
-- PV_WorkingBase, then one-pass aggregates (identical COUNT/SUM results).
-- @ChunkSize is accepted here so app deploy does not fail before 10 is applied.
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAllPredictionAggregates
(
    @RunId         NVARCHAR(100) = NULL,
    @WeekStartDate DATE          = NULL,
    @LabName       NVARCHAR(255) = NULL,
    @ChunkSize     INT           = 100000  -- unused until 10_* is deployed; kept for signature compat
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @FirstError NVARCHAR(4000) = NULL;
    DECLARE @StepErr NVARCHAR(4000);
    DECLARE @UpdateFieldsErr NVARCHAR(4000);

    -- Silence unused-param warning when 10_* not yet deployed
    SET @ChunkSize = ISNULL(@ChunkSize, 100000);

    IF @RunId IS NULL OR LTRIM(RTRIM(@RunId)) = ''
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL AND (@LabName IS NULL OR LabName = @LabName)
        ORDER BY InsertedDateTime DESC;
    END

    IF @RunId IS NULL
    BEGIN
        RAISERROR('usp_RefreshAllPredictionAggregates: no RunId found.', 16, 1);
        RETURN;
    END

    -- Step 1: update derived prediction fields (post bulk-insert)
    BEGIN TRY
        EXEC dbo.usp_UpdatePayerValidationPredictionFields @RunId = @RunId, @LabName = @LabName;
    END TRY
    BEGIN CATCH
        SET @UpdateFieldsErr = ERROR_MESSAGE();
        RAISERROR('UpdatePredictionFields: %s', 16, 1, @UpdateFieldsErr);
        RETURN;
    END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_SummaryBuckets @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'SummaryBuckets: ' + @StepErr); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_ValidationByPayer @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'ValidationByPayer: ' + @StepErr); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_PayerPayStatusBreakdown @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'PayerPayStatus: ' + @StepErr); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_DenialBreakdown @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'DenialBreakdown: ' + @StepErr); END CATCH

    -- Fill blank DenialDescription from LRNMaster.dbo.DenialMapperSuperMaster (same-server).
    -- Safe to skip when LRNMaster / SP is missing — C# enricher covers cross-server labs.
    BEGIN TRY
        IF OBJECT_ID('dbo.usp_EnrichPV_DenialDescriptionFromMaster', 'P') IS NOT NULL
            EXEC dbo.usp_EnrichPV_DenialDescriptionFromMaster;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'DenialDescEnrich: ' + @StepErr); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_NoResponseBreakdown @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'NoResponseBreakdown: ' + @StepErr); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_AdjustedByPayer @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'AdjustedByPayer: ' + @StepErr); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_SummaryMetrics @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'SummaryMetrics: ' + @StepErr); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_FilterOptions @RunId; END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'FilterOptions: ' + @StepErr); END CATCH

    BEGIN TRY
        DELETE FROM dbo.PV_SummaryBuckets WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_ValidationByPayer WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_PayerPayStatusBreakdown WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_DenialBreakdown WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_NoResponseBreakdown WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_AdjustedByPayer WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_SummaryMetrics WHERE RunId <> @RunId;
        IF OBJECT_ID('dbo.PV_FilterOptions', 'U') IS NOT NULL
            DELETE FROM dbo.PV_FilterOptions WHERE RunId <> @RunId;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'PurgeOldRuns: ' + @StepErr); END CATCH

    IF @FirstError IS NOT NULL
        RAISERROR(@FirstError, 16, 1);
END
GO
