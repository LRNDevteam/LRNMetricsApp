-- ============================================================
-- 10_ChunkedAggregateRefresh_LargeLabs.sql
-- For LARGE labs: NorthWest OR any lab with PayerValidationReport
-- row count >= ~7 lakh (700,000). Safe for small labs too (1–2 chunks).
--
-- Strategy (results IDENTICAL to single-pass refresh):
--   1. Chunked usp_UpdatePayerValidationPredictionFields (same CASE formulas)
--   2. Load dbo.PV_WorkingBase in ReportId CHUNKS (typed columns, one convert pass)
--   3. Build ALL PV_* snapshots from PV_WorkingBase with the SAME
--      COUNT(DISTINCT VisitKey) / SUM formulas as usp_GetPrediction*
--      → counts and dollar totals do not change vs live Get SPs
--
-- Deploy on each large-lab DB (e.g. NWL). App auto-detects row count >= 7 lakh
-- and uses ChunkSize=100000 + 3600s timeout (JSON overrides optional).
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.PV_WorkingBase', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PV_WorkingBase
    (
        ReportId           BIGINT         NOT NULL,
        RunId              NVARCHAR(100)  NOT NULL,
        VisitKey           NVARCHAR(200)  NULL,
        Substatus          NVARCHAR(100)  NULL,
        PredStatus         NVARCHAR(100)  NULL,
        PayStatusNorm      NVARCHAR(100)  NULL,
        PayerName          NVARCHAR(255)  NULL,
        PayerType          NVARCHAR(100)  NULL,
        PanelName          NVARCHAR(255)  NULL,
        FinalCoverageStatus NVARCHAR(100) NULL,
        Payability         NVARCHAR(100)  NULL,
        CPTCode            NVARCHAR(50)   NULL,
        DenialCode         NVARCHAR(100)  NULL,
        DenialDescription  NVARCHAR(1000) NULL,
        ForecastingPayability NVARCHAR(255) NULL,
        DaysInt            INT            NOT NULL DEFAULT 0,
        PredAllowed        DECIMAL(18,4)  NOT NULL DEFAULT 0,
        PredIns            DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActAllowed         DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActIns             DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VarAllowed         DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VarPaid            DECIMAL(18,4)  NOT NULL DEFAULT 0
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PV_WorkingBase_Run' AND object_id = OBJECT_ID('dbo.PV_WorkingBase'))
    CREATE CLUSTERED INDEX IX_PV_WorkingBase_Run ON dbo.PV_WorkingBase (RunId, ReportId);
GO

-- Helpful supporting index on source (best-effort; skip if RunId is NVARCHAR(MAX) and cannot index)
-- ReportId PK range scans for chunking do not require RunId index.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PVR_ReportId' AND object_id = OBJECT_ID('dbo.PayerValidationReport'))
BEGIN
    -- ReportId is already PK in most deployments; ignore failures.
    PRINT 'IX_PVR_ReportId: using existing PK on ReportId if present.';
END
GO

-- Chunked field update (same results as single UPDATE; avoids lock/log blow-ups on 1M+ rows)
CREATE OR ALTER PROCEDURE dbo.usp_UpdatePayerValidationPredictionFields
(
    @RunId     NVARCHAR(100) = NULL,
    @LabName   NVARCHAR(255) = NULL,
    @ChunkSize INT           = 100000
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @ChunkSize IS NULL OR @ChunkSize <= 0 SET @ChunkSize = 100000;

    IF @RunId IS NULL OR LTRIM(RTRIM(@RunId)) = ''
    BEGIN
        SELECT TOP 1 @RunId = CONVERT(NVARCHAR(100), RunId)
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
          AND (@LabName IS NULL OR LabName = @LabName)
        ORDER  BY InsertedDateTime DESC;
    END

    IF @RunId IS NULL RETURN;

    DECLARE @MinId BIGINT, @MaxId BIGINT, @Cur BIGINT, @Next BIGINT;

    SELECT @MinId = MIN(ReportId), @MaxId = MAX(ReportId)
    FROM dbo.PayerValidationReport
    WHERE CONVERT(NVARCHAR(100), RunId) = @RunId
      AND (@LabName IS NULL OR LabName = @LabName);

    IF @MinId IS NULL RETURN;

    SET @Cur = @MinId;
    WHILE @Cur <= @MaxId
    BEGIN
        SET @Next = @Cur + CAST(@ChunkSize AS BIGINT);

        ;WITH Step1 AS
        (
            SELECT
                ReportId,
                Substatus = CASE
                    WHEN LTRIM(RTRIM(ISNULL(ForecastingPayability, N''))) IN
                         (N'Payable', N'Potentially Payable', N'Payable - Need Action')
                    THEN N'Predicted To Pay'
                    ELSE N'Not Predicted'
                END,
                PayStatusRaw = LTRIM(RTRIM(ISNULL(PayStatus, N''))),
                ModeAllowed = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeAllowedAmountSameLab)), N'')), 0),
                AllowedAmt  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(AllowedAmount)), N'')), 0),
                ModeIns     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeInsurancePaidSameLab)), N'')), 0),
                InsPaid     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(InsurancePayment)), N'')), 0)
            FROM dbo.PayerValidationReport
            WHERE CONVERT(NVARCHAR(100), RunId) = @RunId
              AND (@LabName IS NULL OR LabName = @LabName)
              AND ReportId >= @Cur
              AND ReportId < @Next
        ),
        Step2 AS
        (
            SELECT
                ReportId,
                Substatus,
                PredictionStatus = CASE
                    WHEN Substatus = N'Predicted To Pay'
                         AND PayStatusRaw IN (N'Paid', N'Patient Responsibility')
                    THEN N'Predicted - Paid'
                    WHEN Substatus = N'Predicted To Pay'
                    THEN N'Predicted - Unpaid'
                    WHEN Substatus = N'Not Predicted'
                         AND PayStatusRaw IN (N'Paid', N'Patient Responsibility')
                    THEN N'Not Predicted - Paid'
                    ELSE N'Not Predicted - Unpaid'
                END,
                VarAllowed = ModeAllowed - AllowedAmt,
                VarPaid    = ModeIns - InsPaid
            FROM Step1
        )
        UPDATE r
        SET
            r.ForecastingPayabilitySubstatus = s.Substatus,
            r.PredictionStatus               = s.PredictionStatus,
            r.Variance_AllowedAmount         = CONVERT(NVARCHAR(50), s.VarAllowed),
            r.Variance_PaidAmount            = CONVERT(NVARCHAR(50), s.VarPaid)
        FROM dbo.PayerValidationReport r
        INNER JOIN Step2 s ON s.ReportId = r.ReportId;

        SET @Cur = @Next;
    END
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAllPredictionAggregates
(
    @RunId         NVARCHAR(100) = NULL,
    @WeekStartDate DATE          = NULL,
    @LabName       NVARCHAR(255) = NULL,
    @ChunkSize     INT           = 100000   -- ReportId window size; 0 = single INSERT (still into WorkingBase)
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @FirstError NVARCHAR(4000) = NULL;
    DECLARE @StepErr NVARCHAR(4000);
    DECLARE @UpdateFieldsErr NVARCHAR(4000);
    DECLARE @MinId BIGINT, @MaxId BIGINT, @Cur BIGINT, @Next BIGINT, @ChunkRows INT;
    DECLARE @TotalLoaded BIGINT = 0;

    IF @ChunkSize IS NULL OR @ChunkSize < 0 SET @ChunkSize = 100000;

    IF @RunId IS NULL OR LTRIM(RTRIM(@RunId)) = ''
    BEGIN
        SELECT TOP 1 @RunId = CONVERT(NVARCHAR(100), RunId)
        FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL AND (@LabName IS NULL OR LabName = @LabName)
        ORDER BY InsertedDateTime DESC;
    END

    IF @RunId IS NULL
    BEGIN
        RAISERROR('usp_RefreshAllPredictionAggregates: no RunId found.', 16, 1);
        RETURN;
    END

    -- Step 1: derived prediction fields
    BEGIN TRY
        EXEC dbo.usp_UpdatePayerValidationPredictionFields @RunId = @RunId, @LabName = @LabName;
    END TRY
    BEGIN CATCH
        SET @UpdateFieldsErr = ERROR_MESSAGE();
        RAISERROR('UpdatePredictionFields: %s', 16, 1, @UpdateFieldsErr);
        RETURN;
    END CATCH

    -- Step 2: chunked materialization into PV_WorkingBase (typed / converted once)
    BEGIN TRY
        DELETE FROM dbo.PV_WorkingBase; -- DELETE (not TRUNCATE) so callers without ALTER rights still work

        SELECT
            @MinId = MIN(ReportId),
            @MaxId = MAX(ReportId)
        FROM dbo.PayerValidationReport
        WHERE CONVERT(NVARCHAR(100), RunId) = @RunId
          AND (@LabName IS NULL OR LabName = @LabName);

        IF @MinId IS NULL
        BEGIN
            RAISERROR('usp_RefreshAllPredictionAggregates: no rows for RunId.', 16, 1);
            RETURN;
        END

        IF @ChunkSize = 0
            SET @ChunkSize = (@MaxId - @MinId + 1);

        SET @Cur = @MinId;
        WHILE @Cur <= @MaxId
        BEGIN
            SET @Next = @Cur + CAST(@ChunkSize AS BIGINT);

            INSERT INTO dbo.PV_WorkingBase
            (
                ReportId, RunId, VisitKey, Substatus, PredStatus, PayStatusNorm,
                PayerName, PayerType, PanelName, FinalCoverageStatus, Payability, CPTCode,
                DenialCode, DenialDescription, ForecastingPayability, DaysInt,
                PredAllowed, PredIns, ActAllowed, ActIns, VarAllowed, VarPaid
            )
            SELECT
                ReportId,
                @RunId,
                VisitKey = NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), VisitNumber))), N''),
                Substatus = LTRIM(RTRIM(ForecastingPayabilitySubstatus)),
                PredStatus = LTRIM(RTRIM(ISNULL(PredictionStatus, N''))),
                PayStatusNorm = LTRIM(RTRIM(ISNULL(PayStatus, N''))),
                PayerName = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                     NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown'),
                PayerType = ISNULL(NULLIF(LTRIM(RTRIM(PayerType)), N''), N''),
                PanelName = LTRIM(RTRIM(PanelName)),
                FinalCoverageStatus = LTRIM(RTRIM(FinalCoverageStatus)),
                Payability = LTRIM(RTRIM(Payability)),
                CPTCode = LTRIM(RTRIM(CPTCode)),
                DenialCode = ISNULL(NULLIF(LTRIM(RTRIM(DenialCode)), N''), N'(Blank)'),
                DenialDescription = ISNULL(NULLIF(LTRIM(RTRIM(DenialDescription)), N''), N''),
                ForecastingPayability = LTRIM(RTRIM(ISNULL(ForecastingPayability, N''))),
                DaysInt = ISNULL(TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(DaysToDOS)), N'')), 0),
                PredAllowed = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeAllowedAmountSameLab)), N'')), 0),
                PredIns     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeInsurancePaidSameLab)), N'')), 0),
                ActAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(AllowedAmount)), N'')), 0),
                ActIns      = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(InsurancePayment)), N'')), 0),
                VarAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_AllowedAmount)), N'')), 0),
                VarPaid     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_PaidAmount)), N'')), 0)
            FROM dbo.PayerValidationReport
            WHERE CONVERT(NVARCHAR(100), RunId) = @RunId
              AND (@LabName IS NULL OR LabName = @LabName)
              AND ReportId >= @Cur
              AND ReportId < @Next;

            SET @ChunkRows = @@ROWCOUNT;
            SET @TotalLoaded = @TotalLoaded + @ChunkRows;
            SET @Cur = @Next;
        END

        PRINT 'PV_WorkingBase loaded rows=' + CAST(@TotalLoaded AS NVARCHAR(20));
    END TRY
    BEGIN CATCH
        SET @StepErr = ERROR_MESSAGE();
        RAISERROR('MaterializeWorkingBase: %s', 16, 1, @StepErr);
        RETURN;
    END CATCH

    -- Step 3: PV_SummaryBuckets (same logic as usp_GetPredictionSummaryBuckets)
    BEGIN TRY
        DELETE FROM dbo.PV_SummaryBuckets WHERE RunId = @RunId
          AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

        ;WITH Base AS
        (
            SELECT * FROM dbo.PV_WorkingBase
            WHERE RunId = @RunId
              AND Substatus IN (N'Predicted To Pay', N'Not Predicted')
        ),
        GroupTotals AS
        (
            SELECT
                GroupName = Substatus,
                PayStatus = CAST(NULL AS NVARCHAR(100)),
                IsGroupTotal = CAST(1 AS BIT),
                SortBase = CASE Substatus WHEN N'Predicted To Pay' THEN 10 ELSE 20 END,
                LineItemCount = COUNT(DISTINCT VisitKey),
                PredictedAllowed = SUM(PredAllowed),
                PredictedInsurance = SUM(PredIns),
                ActualAllowed = SUM(ActAllowed),
                ActualInsurance = SUM(ActIns),
                VarianceAllowed = SUM(VarAllowed),
                VariancePaid = SUM(VarPaid)
            FROM Base
            GROUP BY Substatus
        ),
        PayStatusBreakdown AS
        (
            SELECT
                GroupName = Substatus,
                PayStatus = NULLIF(PayStatusNorm, N''),
                IsGroupTotal = CAST(0 AS BIT),
                SortBase = CASE Substatus WHEN N'Predicted To Pay' THEN 10 ELSE 20 END,
                LineItemCount = COUNT(DISTINCT VisitKey),
                PredictedAllowed = SUM(PredAllowed),
                PredictedInsurance = SUM(PredIns),
                ActualAllowed = SUM(ActAllowed),
                ActualInsurance = SUM(ActIns),
                VarianceAllowed = SUM(VarAllowed),
                VariancePaid = SUM(VarPaid)
            FROM Base
            GROUP BY Substatus, PayStatusNorm
        ),
        Combined AS
        (
            SELECT * FROM GroupTotals
            UNION ALL
            SELECT * FROM PayStatusBreakdown
        )
        INSERT INTO dbo.PV_SummaryBuckets
        (RunId, WeekStartDate, GroupName, BucketName, PayStatus, IsGroupTotal, SortOrder,
         LineItemCount, PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
        SELECT
            @RunId, @WeekStartDate,
            GroupName,
            BucketName = CASE WHEN IsGroupTotal = 1 THEN GroupName
                ELSE COALESCE(NULLIF(PayStatus, N''), N'(Blank)') END,
            PayStatus,
            IsGroupTotal,
            SortOrder = SortBase + CASE WHEN IsGroupTotal = 1 THEN 0
                ELSE ROW_NUMBER() OVER (PARTITION BY GroupName, IsGroupTotal ORDER BY PayStatus) END,
            LineItemCount, PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
        FROM Combined;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'SummaryBuckets: ' + @StepErr); END CATCH

    -- Step 4: Validation by Payer (forecast payable only — same as live SP)
    BEGIN TRY
        DELETE FROM dbo.PV_ValidationByPayer WHERE RunId = @RunId
          AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

        IF OBJECT_ID('tempdb..#VbpAgg') IS NOT NULL DROP TABLE #VbpAgg;

        SELECT
            PayerName,
            PayerType = MAX(PayerType),
            TotalLineItems = COUNT(DISTINCT VisitKey),
            PredictedAllowed = SUM(PredAllowed),
            PredictedInsurance = SUM(PredIns),
            ActualAllowed = SUM(ActAllowed),
            ActualInsurance = SUM(ActIns),
            VarianceAllowed = SUM(VarAllowed),
            VariancePaid = SUM(VarPaid)
        INTO #VbpAgg
        FROM dbo.PV_WorkingBase
        WHERE RunId = @RunId
          AND ForecastingPayability IN (N'Payable', N'Potentially Payable', N'Payable - Need Action')
        GROUP BY PayerName;

        IF COL_LENGTH('dbo.PV_ValidationByPayer', 'PaidCount') IS NOT NULL
        BEGIN
            INSERT INTO dbo.PV_ValidationByPayer
            (RunId, WeekStartDate, PayerName, PayerType, TotalLineItems,
             PaidCount, DeniedCount, NoResponseCount, AdjustedCount, UnpaidCount,
             PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
            SELECT @RunId, @WeekStartDate, PayerName, PayerType, TotalLineItems,
                   0, 0, 0, 0, 0,
                   PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
            FROM #VbpAgg;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.PV_ValidationByPayer
            (RunId, WeekStartDate, PayerName, PayerType, TotalLineItems,
             PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
            SELECT @RunId, @WeekStartDate, PayerName, PayerType, TotalLineItems,
                   PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid
            FROM #VbpAgg;
        END

        DROP TABLE #VbpAgg;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'ValidationByPayer: ' + @StepErr); END CATCH

    -- Step 5: Payer x PayStatus
    BEGIN TRY
        DELETE FROM dbo.PV_PayerPayStatusBreakdown WHERE RunId = @RunId
          AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

        INSERT INTO dbo.PV_PayerPayStatusBreakdown
        (RunId, WeekStartDate, PayerName, PayStatus, LineItemCount,
         PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
        SELECT
            @RunId, @WeekStartDate,
            PayerName,
            PayStatus = COALESCE(NULLIF(PayStatusNorm, N''), N'(Blank)'),
            LineItemCount = COUNT(DISTINCT VisitKey),
            PredictedAllowed = SUM(PredAllowed),
            PredictedInsurance = SUM(PredIns),
            ActualAllowed = SUM(ActAllowed),
            ActualInsurance = SUM(ActIns),
            VarianceAllowed = SUM(VarAllowed),
            VariancePaid = SUM(VarPaid)
        FROM dbo.PV_WorkingBase
        WHERE RunId = @RunId
          AND ForecastingPayability IN (N'Payable', N'Potentially Payable', N'Payable - Need Action')
        GROUP BY PayerName, COALESCE(NULLIF(PayStatusNorm, N''), N'(Blank)');
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'PayerPayStatus: ' + @StepErr); END CATCH

    -- Step 6: Denial breakdown
    BEGIN TRY
        DELETE FROM dbo.PV_DenialBreakdown WHERE RunId = @RunId
          AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

        INSERT INTO dbo.PV_DenialBreakdown
        (RunId, WeekStartDate, PayerName, DenialCode, DenialDescription,
         LineItemCount, PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
        SELECT
            @RunId, @WeekStartDate,
            PayerName, DenialCode, DenialDescription,
            LineItemCount = COUNT(DISTINCT VisitKey),
            PredictedAllowed = SUM(PredAllowed),
            PredictedInsurance = SUM(PredIns),
            ActualAllowed = SUM(ActAllowed),
            ActualInsurance = SUM(ActIns),
            VarianceAllowed = SUM(VarAllowed),
            VariancePaid = SUM(VarPaid)
        FROM dbo.PV_WorkingBase
        WHERE RunId = @RunId
          AND ForecastingPayability IN (N'Payable', N'Potentially Payable', N'Payable - Need Action')
          AND PayStatusNorm = N'Denied'
        GROUP BY PayerName, DenialCode, DenialDescription;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'DenialBreakdown: ' + @StepErr); END CATCH

    -- Step 6b: Denial description enrich (same-server LRNMaster)
    BEGIN TRY
        IF OBJECT_ID('dbo.usp_EnrichPV_DenialDescriptionFromMaster', 'P') IS NOT NULL
            EXEC dbo.usp_EnrichPV_DenialDescriptionFromMaster;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'DenialDescEnrich: ' + @StepErr); END CATCH

    -- Step 7: No Response aging
    -- NWL/legacy tables may still have PredictedAllowed/PredictedInsurance/Actual*
    -- as NOT NULL — include them when present (SUM over rows, not DISTINCT).
    BEGIN TRY
        DELETE FROM dbo.PV_NoResponseBreakdown WHERE RunId = @RunId
          AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

        IF OBJECT_ID('tempdb..#NrSrc') IS NOT NULL DROP TABLE #NrSrc;
        IF OBJECT_ID('tempdb..#NrAgg') IS NOT NULL DROP TABLE #NrAgg;

        SELECT
            PayerName,
            AgeBucket = CASE
                WHEN DaysInt <= 30  THEN N'Current'
                WHEN DaysInt <= 60  THEN N'30+'
                WHEN DaysInt <= 90  THEN N'60+'
                WHEN DaysInt <= 120 THEN N'90+'
                ELSE N'120+'
            END,
            VisitKey, PredAllowed, PredIns, ActAllowed, ActIns, VarAllowed, VarPaid
        INTO #NrSrc
        FROM dbo.PV_WorkingBase
        WHERE RunId = @RunId
          AND ForecastingPayability IN (N'Payable', N'Potentially Payable', N'Payable - Need Action')
          AND PayStatusNorm = N'No Response';

        SELECT
            PayerName, AgeBucket,
            LineItemCount = COUNT(DISTINCT VisitKey),
            PredictedAllowed = ISNULL(SUM(PredAllowed), 0),
            PredictedInsurance = ISNULL(SUM(PredIns), 0),
            ActualAllowed = ISNULL(SUM(ActAllowed), 0),
            ActualInsurance = ISNULL(SUM(ActIns), 0),
            VarianceAllowed = ISNULL(SUM(VarAllowed), 0),
            VariancePaid = ISNULL(SUM(VarPaid), 0),
            BucketActAllowed = ISNULL(SUM(ActAllowed), 0),
            BucketActIns = ISNULL(SUM(ActIns), 0)
        INTO #NrAgg
        FROM #NrSrc
        GROUP BY PayerName, AgeBucket;

        DECLARE @NrSql NVARCHAR(MAX);
        DECLARE @NrHasPredicted BIT = CASE WHEN COL_LENGTH('dbo.PV_NoResponseBreakdown', 'PredictedAllowed') IS NOT NULL THEN 1 ELSE 0 END;
        DECLARE @NrHasActual    BIT = CASE WHEN COL_LENGTH('dbo.PV_NoResponseBreakdown', 'ActualAllowed') IS NOT NULL THEN 1 ELSE 0 END;

        -- Dynamic INSERT: static CREATE would fail when ActualAllowed is missing on NWL.
        IF @NrHasPredicted = 1 AND @NrHasActual = 1
            SET @NrSql = N'
            INSERT INTO dbo.PV_NoResponseBreakdown
            (RunId, WeekStartDate, PayerName, AgeBucket, LineItemCount,
             PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance,
             VarianceAllowed, VariancePaid, PctVarianceAllowed, PctVariancePaid)
            SELECT @RunId, @WeekStartDate, a.PayerName, a.AgeBucket, a.LineItemCount,
                   a.PredictedAllowed, a.PredictedInsurance, a.ActualAllowed, a.ActualInsurance,
                   a.VarianceAllowed, a.VariancePaid,
                   CASE WHEN t.TotalActAllowed = 0 THEN NULL
                        ELSE ROUND(a.BucketActAllowed / NULLIF(t.TotalActAllowed, 0) * 100, 2) END,
                   CASE WHEN t.TotalActIns = 0 THEN NULL
                        ELSE ROUND(a.BucketActIns / NULLIF(t.TotalActIns, 0) * 100, 2) END
            FROM #NrAgg a
            INNER JOIN (
                SELECT PayerName, TotalActAllowed = SUM(BucketActAllowed), TotalActIns = SUM(BucketActIns)
                FROM #NrAgg GROUP BY PayerName
            ) t ON t.PayerName = a.PayerName;';
        ELSE IF @NrHasPredicted = 1
            SET @NrSql = N'
            INSERT INTO dbo.PV_NoResponseBreakdown
            (RunId, WeekStartDate, PayerName, AgeBucket, LineItemCount,
             PredictedAllowed, PredictedInsurance,
             VarianceAllowed, VariancePaid, PctVarianceAllowed, PctVariancePaid)
            SELECT @RunId, @WeekStartDate, a.PayerName, a.AgeBucket, a.LineItemCount,
                   a.PredictedAllowed, a.PredictedInsurance,
                   a.VarianceAllowed, a.VariancePaid,
                   CASE WHEN t.TotalActAllowed = 0 THEN NULL
                        ELSE ROUND(a.BucketActAllowed / NULLIF(t.TotalActAllowed, 0) * 100, 2) END,
                   CASE WHEN t.TotalActIns = 0 THEN NULL
                        ELSE ROUND(a.BucketActIns / NULLIF(t.TotalActIns, 0) * 100, 2) END
            FROM #NrAgg a
            INNER JOIN (
                SELECT PayerName, TotalActAllowed = SUM(BucketActAllowed), TotalActIns = SUM(BucketActIns)
                FROM #NrAgg GROUP BY PayerName
            ) t ON t.PayerName = a.PayerName;';
        ELSE
            SET @NrSql = N'
            INSERT INTO dbo.PV_NoResponseBreakdown
            (RunId, WeekStartDate, PayerName, AgeBucket, LineItemCount,
             VarianceAllowed, VariancePaid, PctVarianceAllowed, PctVariancePaid)
            SELECT @RunId, @WeekStartDate, a.PayerName, a.AgeBucket, a.LineItemCount,
                   a.VarianceAllowed, a.VariancePaid,
                   CASE WHEN t.TotalActAllowed = 0 THEN NULL
                        ELSE ROUND(a.BucketActAllowed / NULLIF(t.TotalActAllowed, 0) * 100, 2) END,
                   CASE WHEN t.TotalActIns = 0 THEN NULL
                        ELSE ROUND(a.BucketActIns / NULLIF(t.TotalActIns, 0) * 100, 2) END
            FROM #NrAgg a
            INNER JOIN (
                SELECT PayerName, TotalActAllowed = SUM(BucketActAllowed), TotalActIns = SUM(BucketActIns)
                FROM #NrAgg GROUP BY PayerName
            ) t ON t.PayerName = a.PayerName;';

        EXEC sp_executesql @NrSql,
            N'@RunId NVARCHAR(100), @WeekStartDate DATE',
            @RunId = @RunId, @WeekStartDate = @WeekStartDate;

        DROP TABLE #NrSrc;
        DROP TABLE #NrAgg;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'NoResponseBreakdown: ' + @StepErr); END CATCH

    -- Step 8: Adjusted by payer
    BEGIN TRY
        DELETE FROM dbo.PV_AdjustedByPayer WHERE RunId = @RunId
          AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

        INSERT INTO dbo.PV_AdjustedByPayer
        (RunId, WeekStartDate, PayerName, LineItemCount,
         PredictedAllowed, PredictedInsurance, ActualAllowed, ActualInsurance, VarianceAllowed, VariancePaid)
        SELECT
            @RunId, @WeekStartDate,
            PayerName,
            LineItemCount = COUNT(DISTINCT VisitKey),
            PredictedAllowed = SUM(PredAllowed),
            PredictedInsurance = SUM(PredIns),
            ActualAllowed = SUM(ActAllowed),
            ActualInsurance = SUM(ActIns),
            VarianceAllowed = SUM(VarAllowed),
            VariancePaid = SUM(VarPaid)
        FROM dbo.PV_WorkingBase
        WHERE RunId = @RunId
          AND ForecastingPayability IN (N'Payable', N'Potentially Payable', N'Payable - Need Action')
          AND PayStatusNorm = N'Adjusted'
        GROUP BY PayerName;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'AdjustedByPayer: ' + @StepErr); END CATCH

    -- Step 9: Summary metrics (identical formulas to usp_GetPredictionSummaryMetrics)
    BEGIN TRY
        DELETE FROM dbo.PV_SummaryMetrics WHERE RunId = @RunId
          AND ((WeekStartDate IS NULL AND @WeekStartDate IS NULL) OR WeekStartDate = @WeekStartDate);

        ;WITH Base AS
        (
            SELECT * FROM dbo.PV_WorkingBase
            WHERE RunId = @RunId
              AND Substatus IN (N'Predicted To Pay', N'Not Predicted')
        ),
        Buckets AS
        (
            SELECT
                ToPay_LineItems     = COUNT(DISTINCT CASE WHEN Substatus = N'Predicted To Pay' THEN VisitKey END),
                ToPay_ModeAllowed   = SUM(CASE WHEN Substatus = N'Predicted To Pay' THEN PredAllowed ELSE 0 END),
                ToPay_ModeIns       = SUM(CASE WHEN Substatus = N'Predicted To Pay' THEN PredIns ELSE 0 END),
                Paid_LineItems      = COUNT(DISTINCT CASE WHEN PredStatus = N'Predicted - Paid' THEN VisitKey END),
                Paid_ModeAllowed    = SUM(CASE WHEN PredStatus = N'Predicted - Paid' THEN PredAllowed ELSE 0 END),
                Paid_ModeIns        = SUM(CASE WHEN PredStatus = N'Predicted - Paid' THEN PredIns ELSE 0 END),
                Paid_ActAllowed     = SUM(CASE WHEN Substatus = N'Predicted To Pay' THEN ActAllowed ELSE 0 END),
                Paid_ActIns         = SUM(CASE WHEN Substatus = N'Predicted To Pay' THEN ActIns ELSE 0 END),
                Unpaid_LineItems    = COUNT(DISTINCT CASE WHEN PredStatus = N'Predicted - Unpaid' THEN VisitKey END),
                Unpaid_ModeAllowed  = SUM(CASE WHEN PredStatus = N'Predicted - Unpaid' THEN PredAllowed ELSE 0 END),
                Unpaid_ModeIns      = SUM(CASE WHEN PredStatus = N'Predicted - Unpaid' THEN PredIns ELSE 0 END),
                Denied_LineItems    = COUNT(DISTINCT CASE WHEN Substatus = N'Predicted To Pay' AND PayStatusNorm = N'Denied' THEN VisitKey END),
                Denied_ModeAllowed  = SUM(CASE WHEN Substatus = N'Predicted To Pay' AND PayStatusNorm = N'Denied' THEN PredAllowed ELSE 0 END),
                Denied_ModeIns      = SUM(CASE WHEN Substatus = N'Predicted To Pay' AND PayStatusNorm = N'Denied' THEN PredIns ELSE 0 END),
                NoResp_LineItems    = COUNT(DISTINCT CASE WHEN Substatus = N'Predicted To Pay' AND PayStatusNorm = N'No Response' THEN VisitKey END),
                NoResp_ModeAllowed  = SUM(CASE WHEN Substatus = N'Predicted To Pay' AND PayStatusNorm = N'No Response' THEN PredAllowed ELSE 0 END),
                NoResp_ModeIns      = SUM(CASE WHEN Substatus = N'Predicted To Pay' AND PayStatusNorm = N'No Response' THEN PredIns ELSE 0 END),
                Adj_LineItems       = COUNT(DISTINCT CASE WHEN Substatus = N'Predicted To Pay' AND PayStatusNorm = N'Adjusted' THEN VisitKey END),
                Adj_ModeAllowed     = SUM(CASE WHEN Substatus = N'Predicted To Pay' AND PayStatusNorm = N'Adjusted' THEN PredAllowed ELSE 0 END),
                Adj_ModeIns         = SUM(CASE WHEN Substatus = N'Predicted To Pay' AND PayStatusNorm = N'Adjusted' THEN PredIns ELSE 0 END)
            FROM Base
        )
        INSERT INTO dbo.PV_SummaryMetrics
        (RunId, WeekStartDate,
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
        SELECT
            @RunId, @WeekStartDate,
            ToPay_LineItems, ToPay_ModeAllowed, ToPay_ModeIns,
            Paid_LineItems, Paid_ModeAllowed, Paid_ModeIns, Paid_ActAllowed, Paid_ActIns,
            Unpaid_LineItems, Unpaid_ModeAllowed, Unpaid_ModeIns,
            Denied_LineItems, Denied_ModeAllowed, Denied_ModeIns,
            NoResp_LineItems, NoResp_ModeAllowed, NoResp_ModeIns,
            Adj_LineItems, Adj_ModeAllowed, Adj_ModeIns,
            -- Ratios must match usp_GetPredictionSummaryMetrics exactly
            -- (Denied/NoResponse/Adjusted % are of Unpaid, not ToPay).
            PaymentRatio_Claim = CASE WHEN ToPay_LineItems = 0 THEN NULL ELSE ROUND(CAST(Paid_LineItems AS DECIMAL(18,4)) / ToPay_LineItems * 100, 2) END,
            PaymentRatio_Allowed = CASE WHEN ToPay_ModeAllowed = 0 THEN NULL ELSE ROUND(Paid_ModeAllowed / ToPay_ModeAllowed * 100, 2) END,
            PaymentRatio_Insurance = CASE WHEN ToPay_ModeIns = 0 THEN NULL ELSE ROUND(Paid_ModeIns / ToPay_ModeIns * 100, 2) END,
            NonPaymentRate_Claim = CASE WHEN ToPay_LineItems = 0 THEN NULL ELSE ROUND(CAST(Unpaid_LineItems AS DECIMAL(18,4)) / ToPay_LineItems * 100, 2) END,
            NonPaymentRate_Allowed = CASE WHEN ToPay_ModeAllowed = 0 THEN NULL ELSE ROUND(Unpaid_ModeAllowed / ToPay_ModeAllowed * 100, 2) END,
            NonPaymentRate_Insurance = CASE WHEN ToPay_ModeIns = 0 THEN NULL ELSE ROUND(Unpaid_ModeIns / ToPay_ModeIns * 100, 2) END,
            DeniedPct_Claim = CASE WHEN Unpaid_LineItems = 0 THEN NULL ELSE ROUND(CAST(Denied_LineItems AS DECIMAL(18,4)) / Unpaid_LineItems * 100, 2) END,
            DeniedPct_Allowed = CASE WHEN Unpaid_ModeAllowed = 0 THEN NULL ELSE ROUND(Denied_ModeAllowed / Unpaid_ModeAllowed * 100, 2) END,
            DeniedPct_Insurance = CASE WHEN Unpaid_ModeIns = 0 THEN NULL ELSE ROUND(Denied_ModeIns / Unpaid_ModeIns * 100, 2) END,
            NoResponsePct_Claim = CASE WHEN Unpaid_LineItems = 0 THEN NULL ELSE ROUND(CAST(NoResp_LineItems AS DECIMAL(18,4)) / Unpaid_LineItems * 100, 2) END,
            NoResponsePct_Allowed = CASE WHEN Unpaid_ModeAllowed = 0 THEN NULL ELSE ROUND(NoResp_ModeAllowed / Unpaid_ModeAllowed * 100, 2) END,
            NoResponsePct_Insurance = CASE WHEN Unpaid_ModeIns = 0 THEN NULL ELSE ROUND(NoResp_ModeIns / Unpaid_ModeIns * 100, 2) END,
            AdjustedPct_Claim = CASE WHEN Unpaid_LineItems = 0 THEN NULL ELSE ROUND(CAST(Adj_LineItems AS DECIMAL(18,4)) / Unpaid_LineItems * 100, 2) END,
            AdjustedPct_Allowed = CASE WHEN Unpaid_ModeAllowed = 0 THEN NULL ELSE ROUND(Adj_ModeAllowed / Unpaid_ModeAllowed * 100, 2) END,
            AdjustedPct_Insurance = CASE WHEN Unpaid_ModeIns = 0 THEN NULL ELSE ROUND(Adj_ModeIns / Unpaid_ModeIns * 100, 2) END,
            PredAccuracy_Claim = CASE WHEN ToPay_LineItems = 0 THEN NULL ELSE ROUND(CAST(Paid_LineItems AS DECIMAL(18,4)) / ToPay_LineItems * 100, 2) END,
            PredAccuracy_AllowedAmount = CASE WHEN ToPay_ModeAllowed = 0 THEN NULL ELSE ROUND(Paid_ActAllowed / ToPay_ModeAllowed * 100, 2) END,
            PredAccuracy_InsurancePayment = CASE WHEN ToPay_ModeIns = 0 THEN NULL ELSE ROUND(Paid_ActIns / ToPay_ModeIns * 100, 2) END
        FROM Buckets;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'SummaryMetrics: ' + @StepErr); END CATCH

    -- Step 10: Filter options from WorkingBase (cheap — no DISTINCT on raw report)
    BEGIN TRY
        IF OBJECT_ID('dbo.PV_FilterOptions', 'U') IS NOT NULL
        BEGIN
            DELETE FROM dbo.PV_FilterOptions;

            INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
            SELECT DISTINCT @RunId, N'PayerName', PayerName FROM dbo.PV_WorkingBase WHERE RunId = @RunId AND NULLIF(PayerName, N'') IS NOT NULL
            UNION ALL
            SELECT DISTINCT @RunId, N'ForecastingPayability', ForecastingPayability FROM dbo.PV_WorkingBase WHERE RunId = @RunId AND NULLIF(ForecastingPayability, N'') IS NOT NULL
            UNION ALL
            SELECT DISTINCT @RunId, N'PayStatus', COALESCE(NULLIF(PayStatusNorm, N''), N'(Blank)') FROM dbo.PV_WorkingBase WHERE RunId = @RunId
            UNION ALL
            SELECT DISTINCT @RunId, N'ForecastingPayabilitySubstatus', Substatus FROM dbo.PV_WorkingBase WHERE RunId = @RunId AND NULLIF(Substatus, N'') IS NOT NULL
            UNION ALL
            SELECT DISTINCT @RunId, N'PredictionStatus', PredStatus FROM dbo.PV_WorkingBase WHERE RunId = @RunId AND NULLIF(PredStatus, N'') IS NOT NULL
            UNION ALL
            SELECT DISTINCT @RunId, N'PayerType', PayerType FROM dbo.PV_WorkingBase WHERE RunId = @RunId AND NULLIF(PayerType, N'') IS NOT NULL
            UNION ALL
            SELECT DISTINCT @RunId, N'PanelName', PanelName FROM dbo.PV_WorkingBase WHERE RunId = @RunId AND NULLIF(PanelName, N'') IS NOT NULL
            UNION ALL
            SELECT DISTINCT @RunId, N'FinalCoverageStatus', FinalCoverageStatus FROM dbo.PV_WorkingBase WHERE RunId = @RunId AND NULLIF(FinalCoverageStatus, N'') IS NOT NULL
            UNION ALL
            SELECT DISTINCT @RunId, N'Payability', Payability FROM dbo.PV_WorkingBase WHERE RunId = @RunId AND NULLIF(Payability, N'') IS NOT NULL
            UNION ALL
            SELECT DISTINCT @RunId, N'CPTCode', CPTCode FROM dbo.PV_WorkingBase WHERE RunId = @RunId AND NULLIF(CPTCode, N'') IS NOT NULL;
        END
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'FilterOptions: ' + @StepErr); END CATCH

    -- Purge older RunIds from PV_*
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
        DELETE FROM dbo.PV_WorkingBase WHERE RunId <> @RunId;
    END TRY
    BEGIN CATCH SET @StepErr = ERROR_MESSAGE(); SET @FirstError = ISNULL(@FirstError, 'PurgeOldRuns: ' + @StepErr); END CATCH

    IF @FirstError IS NOT NULL
        RAISERROR(@FirstError, 16, 1);
END
GO
