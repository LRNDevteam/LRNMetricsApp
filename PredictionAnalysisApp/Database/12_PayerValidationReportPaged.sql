-- ============================================================
-- 12_PayerValidationReportPaged.sql
-- Server-side paging for the Payer Policy Validation screen.
--
-- usp_GetPayerValidationReportPaged returns TWO result sets:
--   1) TotalFiltered / TotalAll row counts (for the pager)
--   2) One page of rows (OFFSET/FETCH) — same columns as
--      usp_GetPayerValidationReport, including WeekFolder.
--
-- @PageSize NULL or <= 0 returns ALL filtered rows (Excel export).
-- Deploy on each lab database (run after 02_CreateStoredProcedures.sql).
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPayerValidationReportPaged
(
    @RunId                                NVARCHAR(100) = NULL,  -- NULL = latest run
    @FilterPayerName                      NVARCHAR(255) = NULL,
    @FilterPanelName                      NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus            NVARCHAR(100) = NULL,
    @FilterCPTCode                        NVARCHAR(50)  = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(255) = NULL,
    @FilterPredictionStatus               NVARCHAR(255) = NULL,
    @FilterPayStatus                      NVARCHAR(100) = NULL,
    @PageNumber                           INT           = 1,
    @PageSize                             INT           = 50
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve RunId: if not supplied use the most recent one.
    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER BY InsertedDateTime DESC;
    END

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    -- ── Result set 1 : counts ────────────────────────────────────────────
    SELECT
        TotalFiltered = COUNT_BIG(*),
        TotalAll      = (SELECT COUNT_BIG(*)
                         FROM dbo.PayerValidationReport
                         WHERE (@RunId IS NULL OR RunId = @RunId))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND (@FilterPayerName                      IS NULL OR PayerNameNormalized            = @FilterPayerName)
      AND (@FilterPanelName                      IS NULL OR PanelName                      = @FilterPanelName)
      AND (@FilterFinalCoverageStatus            IS NULL OR FinalCoverageStatus            = @FilterFinalCoverageStatus)
      AND (@FilterCPTCode                        IS NULL OR CPTCode                        = @FilterCPTCode)
      AND (@FilterForecastingPayabilitySubstatus IS NULL OR ForecastingPayabilitySubstatus = @FilterForecastingPayabilitySubstatus)
      AND (@FilterPredictionStatus               IS NULL OR PredictionStatus               = @FilterPredictionStatus)
      AND (@FilterPayStatus                      IS NULL OR PayStatus                      = @FilterPayStatus);

    -- ── Result set 2 : one page of rows ─────────────────────────────────
    SELECT
        -- Identifiers
        RunId,
        WeekFolder,
        AccessionNo,
        VisitNumber,
        CPTCode,
        PatientDOB,
        PayerCode,
        PayerName,
        PayerNameNormalized,

        -- Pay / claim status
        PayStatus,
        HistoricalPayment,
        HistoricalPaidLineItemCount,
        HistoricalPaymentConfidenceScore,
        TotalLineItemCount,
        PaidLineItemCount,
        PctPaidLineItemCount,
        PayerType,
        PayerFoundInPolicy,

        -- Dates
        DateOfService,
        FirstBilledDate,

        -- Panel / ICD
        PanelName,
        LISIcd10Codes,
        CCWIcd10Code,
        Units,
        Modifier,
        DenialCode,
        DenialDescription,

        -- Financials
        BilledAmount,
        AllowedAmount,
        InsurancePayment,
        InsuranceAdjustment,
        PatientPaidAmount,
        PatientAdjustment,
        InsuranceBalance,
        PatientBalance,
        TotalBalance,
        MedicareFee,

        -- Coverage / claim
        FinalClaimStatus,
        CoveredIcd10CodesBilled,
        NonCoveredIcd10CodesBilled,
        BilledIcdCodesNotAvailableInPolicy,
        CoverageStatus,
        FinalCoverageStatus,
        CoveredIcd10CodesAsPerPayerPolicy,
        NonCoveredIcd10CodesAsPerPayerPolicy,

        -- Action
        ActionComment,
        Resolution,
        LabName2,

        -- Coding / ICD validation
        CodingValidation,
        CodingValidationSubStatus,
        ICDComplianceStatus,
        ICDComplianceSubstatus,
        ICDPrimaryIndicatorAvailable,
        CoveredICDPresence,
        ICDValidationConfidence,

        -- Policy / payability
        FrequencyConditionMet,
        GenderConditionMet,
        Payability,
        ForecastingPayability,
        PolicyCoverageExpectation,
        DenialValidity,
        CoverageExpectationRemarks,

        -- Expected amounts
        ExpectedAverageAllowedAmount,
        ExpectedAverageInsurancePayment,
        ExpectedAllowedAmountSameLab,
        ExpectedInsurancePaymentSameLab,
        ModeAllowedAmountSameLab,
        ModeInsurancePaidSameLab,
        ModeAllowedAmountPeer,
        ModeInsurancePaidPeer,
        MedianAllowedAmountSameLab,
        MedianInsurancePaidSameLab,
        MedianAllowedAmountPeer,
        MedianInsurancePaidPeer,
        ModeAllowedAmountDifference,
        ModeInsurancePaidDifference,
        MedianAllowedAmountDifference,
        MedianInsurancePaidDifference,

        -- Rates / dates
        DenialRate,
        AdjustmentRate,
        PaymentDays,
        ExpectedPaymentDate,
        ExpectedPaymentMonth,

        -- Provider / clinic
        BillingProvider,
        ReferringProvider,
        ClinicName,
        SalesRepName,

        -- Billing
        PatientID,
        ChargeEnteredDate,
        POS,
        TOS,
        CheckDate,
        DaysToDOS,
        RollingDays,
        DaysToBill,
        DaysToPost,

        ForecastingPayabilitySubstatus,
        PredictionStatus,
        Variance_AllowedAmount,
        Variance_PaidAmount,
        InsertedDateTime

    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND (@FilterPayerName                      IS NULL OR PayerNameNormalized            = @FilterPayerName)
      AND (@FilterPanelName                      IS NULL OR PanelName                      = @FilterPanelName)
      AND (@FilterFinalCoverageStatus            IS NULL OR FinalCoverageStatus            = @FilterFinalCoverageStatus)
      AND (@FilterCPTCode                        IS NULL OR CPTCode                        = @FilterCPTCode)
      AND (@FilterForecastingPayabilitySubstatus IS NULL OR ForecastingPayabilitySubstatus = @FilterForecastingPayabilitySubstatus)
      AND (@FilterPredictionStatus               IS NULL OR PredictionStatus               = @FilterPredictionStatus)
      AND (@FilterPayStatus                      IS NULL OR PayStatus                      = @FilterPayStatus)
    -- Deterministic order so OFFSET/FETCH pages never overlap or skip rows.
    ORDER BY InsertedDateTime DESC,
             CAST(AccessionNo AS NVARCHAR(450)),
             CAST(VisitNumber AS NVARCHAR(450)),
             CAST(CPTCode     AS NVARCHAR(450))
    OFFSET CASE WHEN @PageSize IS NULL OR @PageSize <= 0
                THEN 0
                ELSE (@PageNumber - 1) * @PageSize END ROWS
    FETCH NEXT CASE WHEN @PageSize IS NULL OR @PageSize <= 0
                    THEN 2147483647
                    ELSE @PageSize END ROWS ONLY;
END
GO
