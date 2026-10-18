-- ============================================================
-- 03_PredictionAggregatedSPs.sql
-- Prediction Analysis aggregate + field-update stored procedures.
-- Run AFTER 01_CreateTables.sql and 02_CreateStoredProcedures.sql.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Claim counts use COUNT(DISTINCT VisitNumber) � blank/null visits are excluded.
-- VisitKey expression reused in every aggregate SP below.
--   VisitKey = NULLIF(LTRIM(RTRIM(VisitNumber)), N'')

-- ============================================================
-- SP : usp_UpdatePayerValidationPredictionFields
-- Called ONCE after all bulk-insert chunks complete.
-- Does NOT run during bulk insert � keeps TVP insert fast.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_UpdatePayerValidationPredictionFields
(
    @RunId   NVARCHAR(100) = NULL,
    @LabName NVARCHAR(255) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL OR LTRIM(RTRIM(@RunId)) = ''
    BEGIN
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
          AND (@LabName IS NULL OR LabName = @LabName)
        ORDER  BY InsertedDateTime DESC;
    END

    IF @RunId IS NULL RETURN;

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
        WHERE RunId = @RunId
          AND (@LabName IS NULL OR LabName = @LabName)
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
END
GO

-- ============================================================
-- SP : usp_PV_IsFileLogged
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PV_IsFileLogged
(
    @SourceFullPath NVARCHAR(1000)
)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(CASE WHEN EXISTS (
        SELECT 1 FROM dbo.PayerValidationFileLog WHERE SourceFullPath = @SourceFullPath
    ) THEN 1 ELSE 0 END AS BIT);
END
GO

-- ============================================================
-- SP : usp_GetPredictionFilterOptions
-- Distinct dropdown values for Prediction Analysis filters.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionFilterOptions
(
    @RunId NVARCHAR(100) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER  BY InsertedDateTime DESC;
    END

    SELECT DISTINCT PayerName = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                         NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown')
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
    ORDER BY 1;

    SELECT DISTINCT ForecastingPayability = LTRIM(RTRIM(ForecastingPayability))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(ForecastingPayability)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT PayStatus = COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)')
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
    ORDER BY 1;

    SELECT DISTINCT ForecastingPayabilitySubstatus
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(ForecastingPayabilitySubstatus)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT PredictionStatus
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(PredictionStatus)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT PayerType = LTRIM(RTRIM(PayerType))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(PayerType)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT PanelName = LTRIM(RTRIM(PanelName))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(PanelName)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT FinalCoverageStatus = LTRIM(RTRIM(FinalCoverageStatus))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(FinalCoverageStatus)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT Payability = LTRIM(RTRIM(Payability))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(Payability)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT CPTCode = LTRIM(RTRIM(CPTCode))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(CPTCode)), N'') IS NOT NULL
    ORDER BY 1;
END
GO

-- ============================================================
-- Helper inline: shared base CTE pattern used by aggregate SPs.
-- Each SP below duplicates the filter CTE for self-containment.
-- ============================================================

-- ============================================================
-- SP 6 : usp_GetPredictionSummaryBuckets
-- Section A � Predicted To Pay / Not Predicted to Pay hierarchy
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionSummaryBuckets
(
    @WeekStartDate                       DATE          = NULL,
    @RunId                               NVARCHAR(100) = NULL,
    @FilterPayerName                     NVARCHAR(255) = NULL,
    @FilterForecastingPayability         NVARCHAR(255) = NULL,
    @FilterPayStatus                     NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL,
    @FilterPredictionStatus              NVARCHAR(100) = NULL,
    @FilterPayerType                     NVARCHAR(100) = NULL,
    @FilterPanelName                     NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus           NVARCHAR(100) = NULL,
    @FilterPayability                    NVARCHAR(100) = NULL,
    @FilterCPTCode                       NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    END

    ;WITH Base AS
    (
        SELECT
            Substatus     = LTRIM(RTRIM(ForecastingPayabilitySubstatus)),
            PredStatus    = LTRIM(RTRIM(ISNULL(PredictionStatus, N''))),
            PayStatusNorm = LTRIM(RTRIM(ISNULL(PayStatus, N''))),
            PredAllowed   = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeAllowedAmountSameLab)), N'')), 0),
            PredIns       = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeInsurancePaidSameLab)), N'')), 0),
            ActAllowed    = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(AllowedAmount)), N'')), 0),
            ActIns        = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(InsurancePayment)), N'')), 0),
            VarAllowed    = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_AllowedAmount)), N'')), 0),
            VarPaid       = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_PaidAmount)), N'')), 0),
            VisitKey      = NULLIF(LTRIM(RTRIM(VisitNumber)), N'')
        FROM dbo.PayerValidationReport
        WHERE (@RunId IS NULL OR RunId = @RunId)
          AND LTRIM(RTRIM(ForecastingPayabilitySubstatus)) IN (N'Predicted To Pay', N'Not Predicted')
          AND (@FilterPayerName IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') = @FilterPayerName)
          AND (@FilterForecastingPayability IS NULL OR LTRIM(RTRIM(ForecastingPayability)) = @FilterForecastingPayability)
          AND (@FilterPayStatus IS NULL OR LTRIM(RTRIM(ISNULL(PayStatus, N''))) = CASE WHEN @FilterPayStatus = N'(Blank)' THEN N'' ELSE @FilterPayStatus END)
          AND (@FilterForecastingPayabilitySubstatus IS NULL OR LTRIM(RTRIM(ForecastingPayabilitySubstatus)) = @FilterForecastingPayabilitySubstatus)
          AND (@FilterPredictionStatus IS NULL OR LTRIM(RTRIM(PredictionStatus)) = @FilterPredictionStatus)
          AND (@FilterPayerType IS NULL OR LTRIM(RTRIM(PayerType)) = @FilterPayerType)
          AND (@FilterPanelName IS NULL OR LTRIM(RTRIM(PanelName)) = @FilterPanelName)
          AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) = @FilterFinalCoverageStatus)
          AND (@FilterPayability IS NULL OR LTRIM(RTRIM(Payability)) = @FilterPayability)
          AND (@FilterCPTCode IS NULL OR LTRIM(RTRIM(CPTCode)) = @FilterCPTCode)
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
    SELECT
        GroupName,
        BucketName = CASE WHEN IsGroupTotal = 1 THEN GroupName
            ELSE COALESCE(NULLIF(PayStatus, N''), N'(Blank)') END,
        PayStatus,
        IsGroupTotal,
        SortOrder = SortBase + CASE WHEN IsGroupTotal = 1 THEN 0
            ELSE ROW_NUMBER() OVER (PARTITION BY GroupName, IsGroupTotal ORDER BY PayStatus) END,
        LineItemCount,
        PredictedAllowed,
        PredictedInsurance,
        ActualAllowed,
        ActualInsurance,
        VarianceAllowed,
        VariancePaid
    FROM Combined
    ORDER BY SortOrder;
END
GO

-- ============================================================
-- SP 7 : usp_GetPredictionValidationByPayer
-- Section B � Prediction vs Actual By Payer
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionValidationByPayer
(
    @WeekStartDate                       DATE          = NULL,
    @RunId                               NVARCHAR(100) = NULL,
    @FilterPayerName                     NVARCHAR(255) = NULL,
    @FilterForecastingPayability         NVARCHAR(255) = NULL,
    @FilterPayStatus                     NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL,
    @FilterPredictionStatus              NVARCHAR(100) = NULL,
    @FilterPayerType                     NVARCHAR(100) = NULL,
    @FilterPanelName                     NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus           NVARCHAR(100) = NULL,
    @FilterPayability                    NVARCHAR(100) = NULL,
    @FilterCPTCode                       NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    END

    ;WITH Base AS
    (
        SELECT
            PayerName = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                 NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown'),
            PayerType = ISNULL(NULLIF(LTRIM(RTRIM(PayerType)), N''), N''),
            PredAllowed = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeAllowedAmountSameLab)), N'')), 0),
            PredIns     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeInsurancePaidSameLab)), N'')), 0),
            ActAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(AllowedAmount)), N'')), 0),
            ActIns      = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(InsurancePayment)), N'')), 0),
            VarAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_AllowedAmount)), N'')), 0),
            VarPaid     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_PaidAmount)), N'')), 0),
            ExpPmtDate  = COALESCE(
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate)), 101),
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate))),
                CASE WHEN TRY_CONVERT(FLOAT, ExpectedPaymentDate) BETWEEN 2 AND 2958465
                     THEN DATEADD(DAY, CAST(TRY_CONVERT(FLOAT, ExpectedPaymentDate) AS INT), '18991230')
                END),
            ForecastingPayability,
            VisitKey     = NULLIF(LTRIM(RTRIM(VisitNumber)), N'')
        FROM dbo.PayerValidationReport
        WHERE (@RunId IS NULL OR RunId = @RunId)
          AND LTRIM(RTRIM(ISNULL(ForecastingPayability, N''))) IN
              (N'Payable', N'Potentially Payable', N'Payable - Need Action')
          AND (@FilterPayerName IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') = @FilterPayerName)
          AND (@FilterForecastingPayability IS NULL OR LTRIM(RTRIM(ForecastingPayability)) = @FilterForecastingPayability)
          AND (@FilterPayStatus IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)') = @FilterPayStatus)
          AND (@FilterForecastingPayabilitySubstatus IS NULL OR LTRIM(RTRIM(ForecastingPayabilitySubstatus)) = @FilterForecastingPayabilitySubstatus)
          AND (@FilterPredictionStatus IS NULL OR LTRIM(RTRIM(PredictionStatus)) = @FilterPredictionStatus)
          AND (@FilterPayerType IS NULL OR LTRIM(RTRIM(PayerType)) = @FilterPayerType)
          AND (@FilterPanelName IS NULL OR LTRIM(RTRIM(PanelName)) = @FilterPanelName)
          AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) = @FilterFinalCoverageStatus)
          AND (@FilterPayability IS NULL OR LTRIM(RTRIM(Payability)) = @FilterPayability)
          AND (@FilterCPTCode IS NULL OR LTRIM(RTRIM(CPTCode)) = @FilterCPTCode)
    ),
    Filtered AS
    (
        SELECT * FROM Base
    )
    SELECT
        PayerName,
        PayerType = MAX(PayerType),
        TotalLineItems     = COUNT(DISTINCT VisitKey),
        PaidCount          = 0,
        DeniedCount        = 0,
        NoResponseCount    = 0,
        AdjustedCount      = 0,
        UnpaidCount        = 0,
        PredictedAllowed   = SUM(PredAllowed),
        PredictedInsurance = SUM(PredIns),
        ActualAllowed      = SUM(ActAllowed),
        ActualInsurance    = SUM(ActIns),
        VarianceAllowed    = SUM(VarAllowed),
        VariancePaid       = SUM(VarPaid)
    FROM Filtered
    GROUP BY PayerName
    ORDER BY VarianceAllowed DESC;
END
GO

-- ============================================================
-- SP 7B : usp_GetPredictionPayerPayStatusBreakdown
-- Section B.1 � Modal drill-down by PayStatus
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionPayerPayStatusBreakdown
(
    @WeekStartDate               DATE          = NULL,
    @RunId                       NVARCHAR(100) = NULL,
    @FilterPayerName             NVARCHAR(255) = NULL,
    @FilterForecastingPayability NVARCHAR(255) = NULL,
    @FilterPayStatus             NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL,
    @FilterPredictionStatus      NVARCHAR(100) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    END

    ;WITH Base AS
    (
        SELECT
            PayerName = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                 NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown'),
            PayStatusNorm = COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)'),
            PredAllowed = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeAllowedAmountSameLab)), N'')), 0),
            PredIns     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeInsurancePaidSameLab)), N'')), 0),
            ActAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(AllowedAmount)), N'')), 0),
            ActIns      = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(InsurancePayment)), N'')), 0),
            VarAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_AllowedAmount)), N'')), 0),
            VarPaid     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_PaidAmount)), N'')), 0),
            ExpPmtDate  = COALESCE(
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate)), 101),
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate))),
                CASE WHEN TRY_CONVERT(FLOAT, ExpectedPaymentDate) BETWEEN 2 AND 2958465
                     THEN DATEADD(DAY, CAST(TRY_CONVERT(FLOAT, ExpectedPaymentDate) AS INT), '18991230')
                END),
            VisitKey     = NULLIF(LTRIM(RTRIM(VisitNumber)), N'')
        FROM dbo.PayerValidationReport
        WHERE (@RunId IS NULL OR RunId = @RunId)
          AND LTRIM(RTRIM(ISNULL(ForecastingPayability, N''))) IN
              (N'Payable', N'Potentially Payable', N'Payable - Need Action')
          AND ISNULL(NULLIF(LTRIM(RTRIM(ForecastingPayabilitySubstatus)), N''), N'Not Predicted') = N'Predicted To Pay'
          AND (@FilterPayerName IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') = @FilterPayerName)
          AND (@FilterForecastingPayability IS NULL OR LTRIM(RTRIM(ForecastingPayability)) = @FilterForecastingPayability)
          AND (@FilterPayStatus IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)') = @FilterPayStatus)
          AND (@FilterForecastingPayabilitySubstatus IS NULL OR LTRIM(RTRIM(ForecastingPayabilitySubstatus)) = @FilterForecastingPayabilitySubstatus)
          AND (@FilterPredictionStatus IS NULL OR LTRIM(RTRIM(PredictionStatus)) = @FilterPredictionStatus)
    ),
    Filtered AS
    (
        SELECT * FROM Base
    )
    SELECT
        PayerName,
        PayStatus = PayStatusNorm,
        LineItemCount      = COUNT(DISTINCT VisitKey),
        PredictedAllowed   = SUM(PredAllowed),
        PredictedInsurance = SUM(PredIns),
        ActualAllowed      = SUM(ActAllowed),
        ActualInsurance    = SUM(ActIns),
        VarianceAllowed    = SUM(VarAllowed),
        VariancePaid       = SUM(VarPaid)
    FROM Filtered
    GROUP BY PayerName, PayStatusNorm
    ORDER BY PayerName, PayStatusNorm;
END
GO

-- ============================================================
-- SP 10 : usp_GetPredictionDenialBreakdown
-- Section C � Predicted to Pay - Denied
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionDenialBreakdown
(
    @WeekStartDate                       DATE          = NULL,
    @RunId                               NVARCHAR(100) = NULL,
    @FilterPayerName                     NVARCHAR(255) = NULL,
    @FilterForecastingPayability         NVARCHAR(255) = NULL,
    @FilterPayStatus                     NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL,
    @FilterPredictionStatus              NVARCHAR(100) = NULL,
    @FilterPayerType                     NVARCHAR(100) = NULL,
    @FilterPanelName                     NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus           NVARCHAR(100) = NULL,
    @FilterPayability                    NVARCHAR(100) = NULL,
    @FilterCPTCode                       NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    END

    ;WITH Base AS
    (
        SELECT
            PayerName = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                 NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown'),
            DenialCode = ISNULL(NULLIF(LTRIM(RTRIM(DenialCode)), N''), N'(Blank)'),
            DenialDescription = ISNULL(NULLIF(LTRIM(RTRIM(DenialDescription)), N''), N''),
            PredAllowed = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeAllowedAmountSameLab)), N'')), 0),
            PredIns     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeInsurancePaidSameLab)), N'')), 0),
            ActAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(AllowedAmount)), N'')), 0),
            ActIns      = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(InsurancePayment)), N'')), 0),
            VarAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_AllowedAmount)), N'')), 0),
            VarPaid     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_PaidAmount)), N'')), 0),
            ExpPmtDate  = COALESCE(
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate)), 101),
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate))),
                CASE WHEN TRY_CONVERT(FLOAT, ExpectedPaymentDate) BETWEEN 2 AND 2958465
                     THEN DATEADD(DAY, CAST(TRY_CONVERT(FLOAT, ExpectedPaymentDate) AS INT), '18991230')
                END),
            VisitKey     = NULLIF(LTRIM(RTRIM(VisitNumber)), N'')
        FROM dbo.PayerValidationReport
        WHERE (@RunId IS NULL OR RunId = @RunId)
          AND LTRIM(RTRIM(ISNULL(ForecastingPayability, N''))) IN
              (N'Payable', N'Potentially Payable', N'Payable - Need Action')
          AND LTRIM(RTRIM(ISNULL(PayStatus, N''))) = N'Denied'
          AND (@FilterPayerName IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') = @FilterPayerName)
          AND (@FilterForecastingPayability IS NULL OR LTRIM(RTRIM(ForecastingPayability)) = @FilterForecastingPayability)
          AND (@FilterPayStatus IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)') = @FilterPayStatus)
          AND (@FilterForecastingPayabilitySubstatus IS NULL OR LTRIM(RTRIM(ForecastingPayabilitySubstatus)) = @FilterForecastingPayabilitySubstatus)
          AND (@FilterPredictionStatus IS NULL OR LTRIM(RTRIM(PredictionStatus)) = @FilterPredictionStatus)
          AND (@FilterPayerType IS NULL OR LTRIM(RTRIM(PayerType)) = @FilterPayerType)
          AND (@FilterPanelName IS NULL OR LTRIM(RTRIM(PanelName)) = @FilterPanelName)
          AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) = @FilterFinalCoverageStatus)
          AND (@FilterPayability IS NULL OR LTRIM(RTRIM(Payability)) = @FilterPayability)
          AND (@FilterCPTCode IS NULL OR LTRIM(RTRIM(CPTCode)) = @FilterCPTCode)
    ),
    Filtered AS
    (
        SELECT * FROM Base
    )
    SELECT
        PayerName,
        DenialCode,
        DenialDescription,
        ExpectedPaymentMonth = N'',
        LineItemCount        = COUNT(DISTINCT VisitKey),
        PredictedAllowed     = SUM(PredAllowed),
        PredictedInsurance   = SUM(PredIns),
        ActualAllowed        = SUM(ActAllowed),
        ActualInsurance      = SUM(ActIns),
        VarianceAllowed      = SUM(VarAllowed),
        VariancePaid         = SUM(VarPaid)
    FROM Filtered
    GROUP BY PayerName, DenialCode, DenialDescription
    ORDER BY PayerName, VarianceAllowed DESC;
END
GO

-- ============================================================
-- SP 11 : usp_GetPredictionNoResponseBreakdown
-- Section D � Predicted to Pay - No Response (DaysToDOS aging)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionNoResponseBreakdown
(
    @WeekStartDate                       DATE          = NULL,
    @RunId                               NVARCHAR(100) = NULL,
    @FilterPayerName                     NVARCHAR(255) = NULL,
    @FilterForecastingPayability         NVARCHAR(255) = NULL,
    @FilterPayStatus                     NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL,
    @FilterPredictionStatus              NVARCHAR(100) = NULL,
    @FilterPayerType                     NVARCHAR(100) = NULL,
    @FilterPanelName                     NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus           NVARCHAR(100) = NULL,
    @FilterPayability                    NVARCHAR(100) = NULL,
    @FilterCPTCode                       NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    END

    ;WITH Base AS
    (
        SELECT
            PayerName = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                 NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown'),
            DaysInt = ISNULL(TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(DaysToDOS)), N'')), 0),
            ActAllowed = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(AllowedAmount)), N'')), 0),
            ActIns     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(InsurancePayment)), N'')), 0),
            VarAllowed = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_AllowedAmount)), N'')), 0),
            VarPaid    = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_PaidAmount)), N'')), 0),
            ExpPmtDate = COALESCE(
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate)), 101),
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate))),
                CASE WHEN TRY_CONVERT(FLOAT, ExpectedPaymentDate) BETWEEN 2 AND 2958465
                     THEN DATEADD(DAY, CAST(TRY_CONVERT(FLOAT, ExpectedPaymentDate) AS INT), '18991230')
                END),
            VisitKey = NULLIF(LTRIM(RTRIM(VisitNumber)), N'')
        FROM dbo.PayerValidationReport
        WHERE (@RunId IS NULL OR RunId = @RunId)
          AND LTRIM(RTRIM(ISNULL(ForecastingPayability, N''))) IN
              (N'Payable', N'Potentially Payable', N'Payable - Need Action')
          AND LTRIM(RTRIM(ISNULL(PayStatus, N''))) = N'No Response'
          AND (@FilterPayerName IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') = @FilterPayerName)
          AND (@FilterForecastingPayability IS NULL OR LTRIM(RTRIM(ForecastingPayability)) = @FilterForecastingPayability)
          AND (@FilterPayStatus IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)') = @FilterPayStatus)
          AND (@FilterForecastingPayabilitySubstatus IS NULL OR LTRIM(RTRIM(ForecastingPayabilitySubstatus)) = @FilterForecastingPayabilitySubstatus)
          AND (@FilterPredictionStatus IS NULL OR LTRIM(RTRIM(PredictionStatus)) = @FilterPredictionStatus)
          AND (@FilterPayerType IS NULL OR LTRIM(RTRIM(PayerType)) = @FilterPayerType)
          AND (@FilterPanelName IS NULL OR LTRIM(RTRIM(PanelName)) = @FilterPanelName)
          AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) = @FilterFinalCoverageStatus)
          AND (@FilterPayability IS NULL OR LTRIM(RTRIM(Payability)) = @FilterPayability)
          AND (@FilterCPTCode IS NULL OR LTRIM(RTRIM(CPTCode)) = @FilterCPTCode)
    ),
    Filtered AS
    (
        SELECT
            PayerName,
            AgeBucket = CASE
                WHEN DaysInt <= 30  THEN N'Current'
                WHEN DaysInt <= 60  THEN N'30+'
                WHEN DaysInt <= 90  THEN N'60+'
                WHEN DaysInt <= 120 THEN N'90+'
                ELSE N'120+'
            END,
            VisitKey, ActAllowed, ActIns, VarAllowed, VarPaid
        FROM Base
    ),
    Agg AS
    (
        SELECT
            PayerName,
            AgeBucket,
            LineItemCount   = COUNT(DISTINCT VisitKey),
            VarianceAllowed = SUM(VarAllowed),
            VariancePaid    = SUM(VarPaid),
            BucketActAllowed = SUM(ActAllowed),
            BucketActIns     = SUM(ActIns)
        FROM Filtered
        GROUP BY PayerName, AgeBucket
    ),
    Totals AS
    (
        SELECT
            PayerName,
            TotalActAllowed = SUM(BucketActAllowed),
            TotalActIns     = SUM(BucketActIns),
            TotalVarAllowed = SUM(VarianceAllowed),
            TotalVarPaid    = SUM(VariancePaid)
        FROM Agg
        GROUP BY PayerName
    )
    SELECT
        a.PayerName,
        a.AgeBucket,
        a.LineItemCount,
        a.VarianceAllowed,
        a.VariancePaid,
        PctVarianceAllowed = CASE WHEN t.TotalActAllowed = 0 THEN NULL
            ELSE ROUND(a.BucketActAllowed / t.TotalActAllowed * 100, 2) END,
        PctVariancePaid = CASE WHEN t.TotalActIns = 0 THEN NULL
            ELSE ROUND(a.BucketActIns / t.TotalActIns * 100, 2) END,
        TotalVarianceAllowed = t.TotalVarAllowed,
        TotalVariancePaid    = t.TotalVarPaid
    FROM Agg a
    INNER JOIN Totals t ON t.PayerName = a.PayerName
    ORDER BY a.PayerName,
        CASE a.AgeBucket WHEN N'Current' THEN 1 WHEN N'30+' THEN 2 WHEN N'60+' THEN 3
                         WHEN N'90+' THEN 4 ELSE 5 END;
END
GO

-- ============================================================
-- SP 11B : usp_GetPredictionAdjustedByPayer
-- Section E � Predicted to Pay - Adjusted
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionAdjustedByPayer
(
    @WeekStartDate                       DATE          = NULL,
    @RunId                               NVARCHAR(100) = NULL,
    @FilterPayerName                     NVARCHAR(255) = NULL,
    @FilterForecastingPayability         NVARCHAR(255) = NULL,
    @FilterPayStatus                     NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL,
    @FilterPredictionStatus              NVARCHAR(100) = NULL,
    @FilterPayerType                     NVARCHAR(100) = NULL,
    @FilterPanelName                     NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus           NVARCHAR(100) = NULL,
    @FilterPayability                    NVARCHAR(100) = NULL,
    @FilterCPTCode                       NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    END

    ;WITH Base AS
    (
        SELECT
            PayerName = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                 NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown'),
            PredAllowed = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeAllowedAmountSameLab)), N'')), 0),
            PredIns     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeInsurancePaidSameLab)), N'')), 0),
            ActAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(AllowedAmount)), N'')), 0),
            ActIns      = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(InsurancePayment)), N'')), 0),
            VarAllowed  = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_AllowedAmount)), N'')), 0),
            VarPaid     = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_PaidAmount)), N'')), 0),
            ExpPmtDate  = COALESCE(
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate)), 101),
                TRY_CONVERT(DATE, LTRIM(RTRIM(ExpectedPaymentDate))),
                CASE WHEN TRY_CONVERT(FLOAT, ExpectedPaymentDate) BETWEEN 2 AND 2958465
                     THEN DATEADD(DAY, CAST(TRY_CONVERT(FLOAT, ExpectedPaymentDate) AS INT), '18991230')
                END),
            VisitKey     = NULLIF(LTRIM(RTRIM(VisitNumber)), N'')
        FROM dbo.PayerValidationReport
        WHERE (@RunId IS NULL OR RunId = @RunId)
          AND LTRIM(RTRIM(ISNULL(ForecastingPayability, N''))) IN
              (N'Payable', N'Potentially Payable', N'Payable - Need Action')
          AND LTRIM(RTRIM(ISNULL(PayStatus, N''))) = N'Adjusted'
          AND (@FilterPayerName IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') = @FilterPayerName)
          AND (@FilterForecastingPayability IS NULL OR LTRIM(RTRIM(ForecastingPayability)) = @FilterForecastingPayability)
          AND (@FilterPayStatus IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)') = @FilterPayStatus)
          AND (@FilterForecastingPayabilitySubstatus IS NULL OR LTRIM(RTRIM(ForecastingPayabilitySubstatus)) = @FilterForecastingPayabilitySubstatus)
          AND (@FilterPredictionStatus IS NULL OR LTRIM(RTRIM(PredictionStatus)) = @FilterPredictionStatus)
          AND (@FilterPayerType IS NULL OR LTRIM(RTRIM(PayerType)) = @FilterPayerType)
          AND (@FilterPanelName IS NULL OR LTRIM(RTRIM(PanelName)) = @FilterPanelName)
          AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) = @FilterFinalCoverageStatus)
          AND (@FilterPayability IS NULL OR LTRIM(RTRIM(Payability)) = @FilterPayability)
          AND (@FilterCPTCode IS NULL OR LTRIM(RTRIM(CPTCode)) = @FilterCPTCode)
    ),
    Filtered AS
    (
        SELECT * FROM Base
    )
    SELECT
        PayerName,
        LineItemCount      = COUNT(DISTINCT VisitKey),
        PredictedAllowed   = SUM(PredAllowed),
        PredictedInsurance = SUM(PredIns),
        ActualAllowed      = SUM(ActAllowed),
        ActualInsurance    = SUM(ActIns),
        VarianceAllowed    = SUM(VarAllowed),
        VariancePaid       = SUM(VarPaid)
    FROM Filtered
    GROUP BY PayerName
    ORDER BY VarianceAllowed DESC;
END
GO

-- ============================================================
-- SP 12 : usp_GetPredictionSummaryMetrics
-- Ratios + Prediction Accuracy (logic unchanged, uses new fields)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionSummaryMetrics
(
    @WeekStartDate                       DATE          = NULL,
    @RunId                               NVARCHAR(100) = NULL,
    @FilterPayerName                     NVARCHAR(255) = NULL,
    @FilterForecastingPayability         NVARCHAR(255) = NULL,
    @FilterPayStatus                     NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL,
    @FilterPredictionStatus              NVARCHAR(100) = NULL,
    @FilterPayerType                     NVARCHAR(100) = NULL,
    @FilterPanelName                     NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus           NVARCHAR(100) = NULL,
    @FilterPayability                    NVARCHAR(100) = NULL,
    @FilterCPTCode                       NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    END

    ;WITH Base AS
    (
        SELECT
            Substatus     = LTRIM(RTRIM(ForecastingPayabilitySubstatus)),
            PredStatus    = LTRIM(RTRIM(ISNULL(PredictionStatus, N''))),
            PayStatusNorm = LTRIM(RTRIM(ISNULL(PayStatus, N''))),
            PredAllowed   = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeAllowedAmountSameLab)), N'')), 0),
            PredIns       = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(ModeInsurancePaidSameLab)), N'')), 0),
            ActAllowed    = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(AllowedAmount)), N'')), 0),
            ActIns        = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(InsurancePayment)), N'')), 0),
            VisitKey      = NULLIF(LTRIM(RTRIM(VisitNumber)), N'')
        FROM dbo.PayerValidationReport
        WHERE (@RunId IS NULL OR RunId = @RunId)
          AND LTRIM(RTRIM(ForecastingPayabilitySubstatus)) IN (N'Predicted To Pay', N'Not Predicted')
          AND (@FilterPayerName IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') = @FilterPayerName)
          AND (@FilterForecastingPayability IS NULL OR LTRIM(RTRIM(ForecastingPayability)) = @FilterForecastingPayability)
          AND (@FilterPayStatus IS NULL OR LTRIM(RTRIM(ISNULL(PayStatus, N''))) = CASE WHEN @FilterPayStatus = N'(Blank)' THEN N'' ELSE @FilterPayStatus END)
          AND (@FilterForecastingPayabilitySubstatus IS NULL OR LTRIM(RTRIM(ForecastingPayabilitySubstatus)) = @FilterForecastingPayabilitySubstatus)
          AND (@FilterPredictionStatus IS NULL OR LTRIM(RTRIM(PredictionStatus)) = @FilterPredictionStatus)
          AND (@FilterPayerType IS NULL OR LTRIM(RTRIM(PayerType)) = @FilterPayerType)
          AND (@FilterPanelName IS NULL OR LTRIM(RTRIM(PanelName)) = @FilterPanelName)
          AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) = @FilterFinalCoverageStatus)
          AND (@FilterPayability IS NULL OR LTRIM(RTRIM(Payability)) = @FilterPayability)
          AND (@FilterCPTCode IS NULL OR LTRIM(RTRIM(CPTCode)) = @FilterCPTCode)
    ),
    Buckets AS
    (
        SELECT
            -- Claim metrics are distinct VisitNumber counts. Amount metrics
            -- intentionally remain sums across every matching line item.
            ToPay_LineItems     = COUNT(DISTINCT CASE WHEN Substatus = N'Predicted To Pay' THEN VisitKey END),
            ToPay_ModeAllowed   = SUM(CASE WHEN Substatus = N'Predicted To Pay' THEN PredAllowed ELSE 0 END),
            ToPay_ModeIns       = SUM(CASE WHEN Substatus = N'Predicted To Pay' THEN PredIns ELSE 0 END),
            Paid_LineItems      = COUNT(DISTINCT CASE WHEN PredStatus = N'Predicted - Paid' THEN VisitKey END),
            Paid_ModeAllowed    = SUM(CASE WHEN PredStatus = N'Predicted - Paid' THEN PredAllowed ELSE 0 END),
            Paid_ModeIns        = SUM(CASE WHEN PredStatus = N'Predicted - Paid' THEN PredIns ELSE 0 END),
            -- Legacy output names retained for snapshot compatibility; these
            -- now hold actual totals for the complete Predicted To Pay group.
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
    SELECT
        b.*,
        PaymentRatio_Claim       = CASE WHEN b.ToPay_LineItems = 0 THEN NULL ELSE ROUND(CAST(b.Paid_LineItems AS DECIMAL(18,4)) / b.ToPay_LineItems * 100, 2) END,
        PaymentRatio_Allowed     = CASE WHEN b.ToPay_ModeAllowed = 0 THEN NULL ELSE ROUND(b.Paid_ModeAllowed / b.ToPay_ModeAllowed * 100, 2) END,
        PaymentRatio_Insurance   = CASE WHEN b.ToPay_ModeIns = 0 THEN NULL ELSE ROUND(b.Paid_ModeIns / b.ToPay_ModeIns * 100, 2) END,
        NonPaymentRate_Claim     = CASE WHEN b.ToPay_LineItems = 0 THEN NULL ELSE ROUND(CAST(b.Unpaid_LineItems AS DECIMAL(18,4)) / b.ToPay_LineItems * 100, 2) END,
        NonPaymentRate_Allowed   = CASE WHEN b.ToPay_ModeAllowed = 0 THEN NULL ELSE ROUND(b.Unpaid_ModeAllowed / b.ToPay_ModeAllowed * 100, 2) END,
        NonPaymentRate_Insurance = CASE WHEN b.ToPay_ModeIns = 0 THEN NULL ELSE ROUND(b.Unpaid_ModeIns / b.ToPay_ModeIns * 100, 2) END,
        DeniedPct_Claim          = CASE WHEN b.Unpaid_LineItems = 0 THEN NULL ELSE ROUND(CAST(b.Denied_LineItems AS DECIMAL(18,4)) / b.Unpaid_LineItems * 100, 2) END,
        DeniedPct_Allowed        = CASE WHEN b.Unpaid_ModeAllowed = 0 THEN NULL ELSE ROUND(b.Denied_ModeAllowed / b.Unpaid_ModeAllowed * 100, 2) END,
        DeniedPct_Insurance      = CASE WHEN b.Unpaid_ModeIns = 0 THEN NULL ELSE ROUND(b.Denied_ModeIns / b.Unpaid_ModeIns * 100, 2) END,
        NoResponsePct_Claim      = CASE WHEN b.Unpaid_LineItems = 0 THEN NULL ELSE ROUND(CAST(b.NoResp_LineItems AS DECIMAL(18,4)) / b.Unpaid_LineItems * 100, 2) END,
        NoResponsePct_Allowed    = CASE WHEN b.Unpaid_ModeAllowed = 0 THEN NULL ELSE ROUND(b.NoResp_ModeAllowed / b.Unpaid_ModeAllowed * 100, 2) END,
        NoResponsePct_Insurance  = CASE WHEN b.Unpaid_ModeIns = 0 THEN NULL ELSE ROUND(b.NoResp_ModeIns / b.Unpaid_ModeIns * 100, 2) END,
        AdjustedPct_Claim        = CASE WHEN b.Unpaid_LineItems = 0 THEN NULL ELSE ROUND(CAST(b.Adj_LineItems AS DECIMAL(18,4)) / b.Unpaid_LineItems * 100, 2) END,
        AdjustedPct_Allowed      = CASE WHEN b.Unpaid_ModeAllowed = 0 THEN NULL ELSE ROUND(b.Adj_ModeAllowed / b.Unpaid_ModeAllowed * 100, 2) END,
        AdjustedPct_Insurance    = CASE WHEN b.Unpaid_ModeIns = 0 THEN NULL ELSE ROUND(b.Adj_ModeIns / b.Unpaid_ModeIns * 100, 2) END,
        PredAccuracy_Claim            = CASE WHEN b.ToPay_LineItems = 0 THEN NULL ELSE ROUND(CAST(b.Paid_LineItems AS DECIMAL(18,4)) / b.ToPay_LineItems * 100, 2) END,
        PredAccuracy_AllowedAmount    = CASE WHEN b.ToPay_ModeAllowed = 0 THEN NULL ELSE ROUND(b.Paid_ActAllowed / b.ToPay_ModeAllowed * 100, 2) END,
        PredAccuracy_InsurancePayment = CASE WHEN b.ToPay_ModeIns = 0 THEN NULL ELSE ROUND(b.Paid_ActIns / b.ToPay_ModeIns * 100, 2) END
    FROM Buckets b;
END
GO

-- Legacy compatibility stubs (panels/CPT � unchanged shape)
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionValidationByPanel
(
    @WeekStartDate DATE = NULL, @RunId NVARCHAR(100) = NULL,
    @FilterPayerName NVARCHAR(255) = NULL, @FilterPayerType NVARCHAR(100) = NULL,
    @FilterPanelName NVARCHAR(255) = NULL, @FilterFinalCoverageStatus NVARCHAR(100) = NULL,
    @FilterPayability NVARCHAR(100) = NULL, @FilterCPTCode NVARCHAR(50) = NULL,
    @FilterForecastingPayability NVARCHAR(255) = NULL, @FilterPayStatus NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL, @FilterPredictionStatus NVARCHAR(100) = NULL
)
AS
BEGIN SET NOCOUNT ON;
    IF @RunId IS NULL SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    SELECT PanelName = ISNULL(NULLIF(LTRIM(RTRIM(PanelName)), N''), N'Unknown'),
        TotalLineItems = COUNT(DISTINCT NULLIF(LTRIM(RTRIM(VisitNumber)), N'')), PaidCount = 0, DeniedCount = 0, NoResponseCount = 0,
        AdjustedCount = 0, UnpaidCount = 0,
        PredictedAllowed = SUM(ISNULL(TRY_CONVERT(DECIMAL(18,4), ModeAllowedAmountSameLab), 0)),
        PredictedInsurance = SUM(ISNULL(TRY_CONVERT(DECIMAL(18,4), ModeInsurancePaidSameLab), 0)),
        ActualAllowed = SUM(ISNULL(TRY_CONVERT(DECIMAL(18,4), AllowedAmount), 0)),
        ActualInsurance = SUM(ISNULL(TRY_CONVERT(DECIMAL(18,4), InsurancePayment), 0))
    FROM dbo.PayerValidationReport WHERE (@RunId IS NULL OR RunId = @RunId)
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(PanelName)), N''), N'Unknown');
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionValidationByCPT
(
    @WeekStartDate DATE = NULL, @RunId NVARCHAR(100) = NULL,
    @FilterPayerName NVARCHAR(255) = NULL, @FilterPayerType NVARCHAR(100) = NULL,
    @FilterPanelName NVARCHAR(255) = NULL, @FilterFinalCoverageStatus NVARCHAR(100) = NULL,
    @FilterPayability NVARCHAR(100) = NULL, @FilterCPTCode NVARCHAR(50) = NULL,
    @FilterForecastingPayability NVARCHAR(255) = NULL, @FilterPayStatus NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL, @FilterPredictionStatus NVARCHAR(100) = NULL
)
AS
BEGIN SET NOCOUNT ON;
    IF @RunId IS NULL SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    SELECT CPTCode = ISNULL(NULLIF(LTRIM(RTRIM(CPTCode)), N''), N'Unknown'),
        LineItemCount = COUNT(DISTINCT NULLIF(LTRIM(RTRIM(VisitNumber)), N'')),
        BilledAmount = SUM(ISNULL(TRY_CONVERT(DECIMAL(18,4), BilledAmount), 0)),
        PredictedAllowed = SUM(ISNULL(TRY_CONVERT(DECIMAL(18,4), ModeAllowedAmountSameLab), 0)),
        PredictedInsurance = SUM(ISNULL(TRY_CONVERT(DECIMAL(18,4), ModeInsurancePaidSameLab), 0))
    FROM dbo.PayerValidationReport WHERE (@RunId IS NULL OR RunId = @RunId)
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(CPTCode)), N''), N'Unknown');
END
GO
