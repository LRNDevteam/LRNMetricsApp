-- ============================================================
-- 05_PredictionAggregateRefreshSPs.sql
-- Refresh stored procedures that populate the PV_* snapshot tables.
--
-- Each refresh SP runs the matching usp_GetPrediction* aggregate SP
-- with NULL filters (snapshots are the unfiltered totals), deletes
-- existing rows for (RunId, WeekStartDate), then inserts the result
-- set into the snapshot table.
--
-- The dashboard reads the snapshot tables directly when no dimension
-- filters are active, falling back to the live SPs otherwise.
--
-- Run once against every lab database that holds PayerValidationReport,
-- AFTER 03_PredictionAggregatedSPs.sql and 04_PredictionAggregateTables.sql.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================
-- SP : usp_RefreshPV_SummaryBuckets   (snapshot of SP 6)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_SummaryBuckets
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        BucketName         NVARCHAR(100),
        SortOrder          INT,
        LineItemCount      INT,
        PredictedAllowed   DECIMAL(18,4),
        PredictedInsurance DECIMAL(18,4),
        ActualAllowed      DECIMAL(18,4) NULL,
        ActualInsurance    DECIMAL(18,4) NULL
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetPredictionSummaryBuckets
        @WeekStartDate = @WeekStartDate,
        @RunId         = @RunId;

    DELETE FROM dbo.PV_SummaryBuckets
    WHERE  RunId = @RunId
      AND  ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

    INSERT INTO dbo.PV_SummaryBuckets
        (RunId, WeekStartDate, BucketName, SortOrder, LineItemCount,
         PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance)
    SELECT @RunId, @WeekStartDate, BucketName, SortOrder, LineItemCount,
           PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance
    FROM   @Rows;
END
GO

-- ============================================================
-- SP : usp_RefreshPV_ValidationByPayer   (snapshot of SP 7)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_ValidationByPayer
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PayerName          NVARCHAR(255),
        PayerType          NVARCHAR(100),
        TotalLineItems     INT,
        PaidCount          INT,
        DeniedCount        INT,
        NoResponseCount    INT,
        AdjustedCount      INT,
        UnpaidCount        INT,
        PredictedAllowed   DECIMAL(18,4),
        PredictedInsurance DECIMAL(18,4),
        ActualAllowed      DECIMAL(18,4),
        ActualInsurance    DECIMAL(18,4)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetPredictionValidationByPayer
        @WeekStartDate = @WeekStartDate,
        @RunId         = @RunId;

    DELETE FROM dbo.PV_ValidationByPayer
    WHERE  RunId = @RunId
      AND  ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

    INSERT INTO dbo.PV_ValidationByPayer
        (RunId, WeekStartDate, PayerName, PayerType, TotalLineItems,
         PaidCount, DeniedCount, NoResponseCount, AdjustedCount, UnpaidCount,
         PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance)
    SELECT @RunId, @WeekStartDate, PayerName, PayerType, TotalLineItems,
           PaidCount, DeniedCount, NoResponseCount, AdjustedCount, UnpaidCount,
           PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance
    FROM   @Rows;
END
GO

-- ============================================================
-- SP : usp_RefreshPV_ValidationByPanel   (snapshot of SP 8)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_ValidationByPanel
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PanelName          NVARCHAR(255),
        TotalLineItems     INT,
        PaidCount          INT,
        DeniedCount        INT,
        NoResponseCount    INT,
        AdjustedCount      INT,
        UnpaidCount        INT,
        PredictedAllowed   DECIMAL(18,4),
        PredictedInsurance DECIMAL(18,4),
        ActualAllowed      DECIMAL(18,4),
        ActualInsurance    DECIMAL(18,4)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetPredictionValidationByPanel
        @WeekStartDate = @WeekStartDate,
        @RunId         = @RunId;

    DELETE FROM dbo.PV_ValidationByPanel
    WHERE  RunId = @RunId
      AND  ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

    INSERT INTO dbo.PV_ValidationByPanel
        (RunId, WeekStartDate, PanelName, TotalLineItems,
         PaidCount, DeniedCount, NoResponseCount, AdjustedCount, UnpaidCount,
         PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance)
    SELECT @RunId, @WeekStartDate, PanelName, TotalLineItems,
           PaidCount, DeniedCount, NoResponseCount, AdjustedCount, UnpaidCount,
           PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance
    FROM   @Rows;
END
GO

-- ============================================================
-- SP : usp_RefreshPV_ValidationByCPT   (snapshot of SP 9)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_ValidationByCPT
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        CPTCode            NVARCHAR(50),
        LineItemCount      INT,
        BilledAmount       DECIMAL(18,4),
        PredictedAllowed   DECIMAL(18,4),
        PredictedInsurance DECIMAL(18,4)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetPredictionValidationByCPT
        @WeekStartDate = @WeekStartDate,
        @RunId         = @RunId;

    DELETE FROM dbo.PV_ValidationByCPT
    WHERE  RunId = @RunId
      AND  ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

    INSERT INTO dbo.PV_ValidationByCPT
        (RunId, WeekStartDate, CPTCode, LineItemCount,
         BilledAmount, PredictedAllowed, PredictedInsurance)
    SELECT @RunId, @WeekStartDate, CPTCode, LineItemCount,
           BilledAmount, PredictedAllowed, PredictedInsurance
    FROM   @Rows;
END
GO

-- ============================================================
-- SP : usp_RefreshPV_DenialBreakdown   (snapshot of SP 10)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_DenialBreakdown
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PayerName            NVARCHAR(255),
        DenialCode           NVARCHAR(100),
        DenialDescription    NVARCHAR(1000),
        ExpectedPaymentMonth NVARCHAR(100),
        LineItemCount        INT,
        PredictedAllowed     DECIMAL(18,4),
        PredictedInsurance   DECIMAL(18,4)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetPredictionDenialBreakdown
        @WeekStartDate = @WeekStartDate,
        @RunId         = @RunId;

    DELETE FROM dbo.PV_DenialBreakdown
    WHERE  RunId = @RunId
      AND  ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

    INSERT INTO dbo.PV_DenialBreakdown
        (RunId, WeekStartDate, PayerName, DenialCode, DenialDescription,
         ExpectedPaymentMonth, LineItemCount, PredictedAllowed, PredictedInsurance)
    SELECT @RunId, @WeekStartDate, PayerName, DenialCode, DenialDescription,
           ExpectedPaymentMonth, LineItemCount, PredictedAllowed, PredictedInsurance
    FROM   @Rows;
END
GO

-- ============================================================
-- SP : usp_RefreshPV_NoResponseBreakdown   (snapshot of SP 11)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_NoResponseBreakdown
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PayerName          NVARCHAR(255),
        AgeBucket          NVARCHAR(50),
        LineItemCount      INT,
        PredictedAllowed   DECIMAL(18,4),
        PredictedInsurance DECIMAL(18,4)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetPredictionNoResponseBreakdown
        @WeekStartDate = @WeekStartDate,
        @RunId         = @RunId;

    DELETE FROM dbo.PV_NoResponseBreakdown
    WHERE  RunId = @RunId
      AND  ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

    INSERT INTO dbo.PV_NoResponseBreakdown
        (RunId, WeekStartDate, PayerName, AgeBucket, LineItemCount,
         PredictedAllowed, PredictedInsurance)
    SELECT @RunId, @WeekStartDate, PayerName, AgeBucket, LineItemCount,
           PredictedAllowed, PredictedInsurance
    FROM   @Rows;
END
GO

-- ============================================================
-- SP : usp_RefreshPV_SummaryMetrics   (snapshot of SP 12)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_SummaryMetrics
(
    @RunId         NVARCHAR(100),
    @WeekStartDate DATE = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        ToPay_LineItems               INT,
        ToPay_ModeAllowed             DECIMAL(18,4),
        ToPay_ModeIns                 DECIMAL(18,4),
        Paid_LineItems                INT,
        Paid_ModeAllowed              DECIMAL(18,4),
        Paid_ModeIns                  DECIMAL(18,4),
        Paid_ActAllowed               DECIMAL(18,4),
        Paid_ActIns                   DECIMAL(18,4),
        Unpaid_LineItems              INT,
        Unpaid_ModeAllowed            DECIMAL(18,4),
        Unpaid_ModeIns                DECIMAL(18,4),
        Denied_LineItems              INT,
        Denied_ModeAllowed            DECIMAL(18,4),
        Denied_ModeIns                DECIMAL(18,4),
        NoResp_LineItems              INT,
        NoResp_ModeAllowed            DECIMAL(18,4),
        NoResp_ModeIns                DECIMAL(18,4),
        Adj_LineItems                 INT,
        Adj_ModeAllowed               DECIMAL(18,4),
        Adj_ModeIns                   DECIMAL(18,4),
        PaymentRatio_Claim            DECIMAL(10,2) NULL,
        PaymentRatio_Allowed          DECIMAL(10,2) NULL,
        PaymentRatio_Insurance        DECIMAL(10,2) NULL,
        NonPaymentRate_Claim          DECIMAL(10,2) NULL,
        NonPaymentRate_Allowed        DECIMAL(10,2) NULL,
        NonPaymentRate_Insurance      DECIMAL(10,2) NULL,
        DeniedPct_Claim               DECIMAL(10,2) NULL,
        DeniedPct_Allowed             DECIMAL(10,2) NULL,
        DeniedPct_Insurance           DECIMAL(10,2) NULL,
        NoResponsePct_Claim           DECIMAL(10,2) NULL,
        NoResponsePct_Allowed         DECIMAL(10,2) NULL,
        NoResponsePct_Insurance       DECIMAL(10,2) NULL,
        AdjustedPct_Claim             DECIMAL(10,2) NULL,
        AdjustedPct_Allowed           DECIMAL(10,2) NULL,
        AdjustedPct_Insurance         DECIMAL(10,2) NULL,
        PredAccuracy_Claim            DECIMAL(10,2) NULL,
        PredAccuracy_AllowedAmount    DECIMAL(10,2) NULL,
        PredAccuracy_InsurancePayment DECIMAL(10,2) NULL
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetPredictionSummaryMetrics
        @WeekStartDate = @WeekStartDate,
        @RunId         = @RunId;

    DELETE FROM dbo.PV_SummaryMetrics
    WHERE  RunId = @RunId
      AND  ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

    INSERT INTO dbo.PV_SummaryMetrics
        (RunId, WeekStartDate,
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
         PredAccuracy_Claim,       PredAccuracy_AllowedAmount, PredAccuracy_InsurancePayment)
    SELECT @RunId, @WeekStartDate,
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
    FROM   @Rows;
END
GO

-- ============================================================
-- Master SP : usp_RefreshAllPredictionAggregates
-- Runs all seven refresh SPs for the given RunId.
--
-- @RunId is OPTIONAL. When NULL the SP resolves to the most-recent
-- RunId in dbo.PayerValidationReport automatically, so callers that
-- just want to refresh the current run do not need to pass anything.
--
-- @WeekStartDate is also optional (NULL = unfiltered snapshot).
--
-- Each child SP runs in its own TRY/CATCH so a failure in one does not
-- block the others. The first error (if any) is re-raised at the end.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAllPredictionAggregates
(
    @RunId         NVARCHAR(100) = NULL,
    @WeekStartDate DATE          = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Auto-resolve RunId when not supplied
    IF @RunId IS NULL OR LTRIM(RTRIM(@RunId)) = ''
    BEGIN
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER  BY InsertedDateTime DESC;
    END

    IF @RunId IS NULL OR LTRIM(RTRIM(@RunId)) = ''
    BEGIN
        RAISERROR('usp_RefreshAllPredictionAggregates: no RunId found in PayerValidationReport � nothing to refresh.', 16, 1);
        RETURN;
    END

    DECLARE @FirstError NVARCHAR(4000) = NULL;

    BEGIN TRY EXEC dbo.usp_RefreshPV_SummaryBuckets        @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @FirstError = ISNULL(@FirstError, 'SummaryBuckets: '       + ERROR_MESSAGE()); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_ValidationByPayer     @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @FirstError = ISNULL(@FirstError, 'ValidationByPayer: '    + ERROR_MESSAGE()); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_ValidationByPanel     @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @FirstError = ISNULL(@FirstError, 'ValidationByPanel: '    + ERROR_MESSAGE()); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_ValidationByCPT       @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @FirstError = ISNULL(@FirstError, 'ValidationByCPT: '      + ERROR_MESSAGE()); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_DenialBreakdown       @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @FirstError = ISNULL(@FirstError, 'DenialBreakdown: '      + ERROR_MESSAGE()); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_NoResponseBreakdown   @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @FirstError = ISNULL(@FirstError, 'NoResponseBreakdown: '  + ERROR_MESSAGE()); END CATCH

    BEGIN TRY EXEC dbo.usp_RefreshPV_SummaryMetrics        @RunId, @WeekStartDate; END TRY
    BEGIN CATCH SET @FirstError = ISNULL(@FirstError, 'SummaryMetrics: '        + ERROR_MESSAGE()); END CATCH

    -- RETENTION: keep only the current run's snapshots.
    -- The dashboard read SPs (usp_PV_Read*) always resolve the newest RunId,
    -- so snapshots from older runs are never read. Purge them here so the
    -- PV_* tables hold exactly one run.
    BEGIN TRY
        DELETE FROM dbo.PV_SummaryBuckets       WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_ValidationByPayer    WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_ValidationByPanel    WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_ValidationByCPT      WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_DenialBreakdown      WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_NoResponseBreakdown  WHERE RunId <> @RunId;
        DELETE FROM dbo.PV_SummaryMetrics       WHERE RunId <> @RunId;
    END TRY
    BEGIN CATCH SET @FirstError = ISNULL(@FirstError, 'PurgeOldRuns: ' + ERROR_MESSAGE()); END CATCH

    IF @FirstError IS NOT NULL
        RAISERROR(@FirstError, 16, 1);
END
GO
