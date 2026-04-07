-- ============================================================
-- 02_CreateStoredProcedures.sql
-- Run this script to recreate the TVP type and both SPs.
-- Must drop SP2 before dropping the TVP type, then recreate both.
-- ============================================================

-- Step 1: drop SP that references the TVP first
IF OBJECT_ID('dbo.usp_BulkInsertPayerValidationReport', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_BulkInsertPayerValidationReport;
GO

-- Step 2: drop the TVP type
IF EXISTS (SELECT 1 FROM sys.table_types WHERE name = 'TVP_PayerValidationReport')
    DROP TYPE dbo.TVP_PayerValidationReport;
GO

-- Step 3: recreate TVP — all text columns use NVARCHAR(MAX)
--         so no truncation regardless of data length.
CREATE TYPE dbo.TVP_PayerValidationReport AS TABLE
(
    FileLogId                            INT             NULL,
    RunId                                NVARCHAR(MAX)   NULL,
    WeekFolder                           NVARCHAR(MAX)   NULL,
    LabName                              NVARCHAR(MAX)   NULL,
    SourceFullPath                       NVARCHAR(MAX)   NULL,
    AccessionNo                          NVARCHAR(MAX)   NULL,
    VisitNumber                          NVARCHAR(MAX)   NULL,
    CPTCode                              NVARCHAR(MAX)   NULL,
    PatientDOB                           NVARCHAR(MAX)   NULL,
    PayerCode                            NVARCHAR(MAX)   NULL,
    PayerName                            NVARCHAR(MAX)   NULL,
    PayerNameNormalized                  NVARCHAR(MAX)   NULL,
    PayStatus                            NVARCHAR(MAX)   NULL,
    HistoricalPayment                    NVARCHAR(MAX)   NULL,
    HistoricalPaidLineItemCount          NVARCHAR(MAX)   NULL,
    HistoricalPaymentConfidenceScore     NVARCHAR(MAX)   NULL,
    TotalLineItemCount                   NVARCHAR(MAX)   NULL,
    PaidLineItemCount                    NVARCHAR(MAX)   NULL,
    PctPaidLineItemCount                 NVARCHAR(MAX)   NULL,
    PayerType                            NVARCHAR(MAX)   NULL,
    PayerFoundInPolicy                   NVARCHAR(MAX)   NULL,
    DateOfService                        NVARCHAR(MAX)   NULL,
    FirstBilledDate                      NVARCHAR(MAX)   NULL,
    PanelName                            NVARCHAR(MAX)   NULL,
    LISIcd10Codes                        NVARCHAR(MAX)   NULL,
    CCWIcd10Code                         NVARCHAR(MAX)   NULL,
    Units                                NVARCHAR(MAX)   NULL,
    Modifier                             NVARCHAR(MAX)   NULL,
    DenialCode                           NVARCHAR(MAX)   NULL,
    DenialDescription                    NVARCHAR(MAX)   NULL,
    BilledAmount                         NVARCHAR(MAX)   NULL,
    AllowedAmount                        NVARCHAR(MAX)   NULL,
    InsurancePayment                     NVARCHAR(MAX)   NULL,
    InsuranceAdjustment                  NVARCHAR(MAX)   NULL,
    PatientPaidAmount                    NVARCHAR(MAX)   NULL,
    PatientAdjustment                    NVARCHAR(MAX)   NULL,
    InsuranceBalance                     NVARCHAR(MAX)   NULL,
    PatientBalance                       NVARCHAR(MAX)   NULL,
    TotalBalance                         NVARCHAR(MAX)   NULL,
    MedicareFee                          NVARCHAR(MAX)   NULL,
    FinalClaimStatus                     NVARCHAR(MAX)   NULL,
    CoveredIcd10CodesBilled              NVARCHAR(MAX)   NULL,
    NonCoveredIcd10CodesBilled           NVARCHAR(MAX)   NULL,
    BilledIcdCodesNotAvailableInPolicy   NVARCHAR(MAX)   NULL,
    CoverageStatus                       NVARCHAR(MAX)   NULL,
    FinalCoverageStatus                  NVARCHAR(MAX)   NULL,
    CoveredIcd10CodesAsPerPayerPolicy    NVARCHAR(MAX)   NULL,
    NonCoveredIcd10CodesAsPerPayerPolicy NVARCHAR(MAX)   NULL,
    ActionComment                        NVARCHAR(MAX)   NULL,
    Resolution                           NVARCHAR(MAX)   NULL,
    LabName2                             NVARCHAR(MAX)   NULL,
    CodingValidation                     NVARCHAR(MAX)   NULL,
    CodingValidationSubStatus            NVARCHAR(MAX)   NULL,
    ICDComplianceStatus                  NVARCHAR(MAX)   NULL,
    ICDComplianceSubstatus               NVARCHAR(MAX)   NULL,
    ICDPrimaryIndicatorAvailable         NVARCHAR(MAX)   NULL,
    CoveredICDPresence                   NVARCHAR(MAX)   NULL,
    ICDValidationConfidence              NVARCHAR(MAX)   NULL,
    FrequencyConditionMet                NVARCHAR(MAX)   NULL,
    GenderConditionMet                   NVARCHAR(MAX)   NULL,
    Payability                           NVARCHAR(MAX)   NULL,
    ForecastingPayability                NVARCHAR(MAX)   NULL,
    PolicyCoverageExpectation            NVARCHAR(MAX)   NULL,
    DenialValidity                       NVARCHAR(MAX)   NULL,
    CoverageExpectationRemarks           NVARCHAR(MAX)   NULL,
    ExpectedAverageAllowedAmount         NVARCHAR(MAX)   NULL,
    ExpectedAverageInsurancePayment      NVARCHAR(MAX)   NULL,
    ExpectedAllowedAmountSameLab         NVARCHAR(MAX)   NULL,
    ExpectedInsurancePaymentSameLab      NVARCHAR(MAX)   NULL,
    ModeAllowedAmountSameLab             NVARCHAR(MAX)   NULL,
    ModeInsurancePaidSameLab             NVARCHAR(MAX)   NULL,
    ModeAllowedAmountPeer                NVARCHAR(MAX)   NULL,
    ModeInsurancePaidPeer                NVARCHAR(MAX)   NULL,
    MedianAllowedAmountSameLab           NVARCHAR(MAX)   NULL,
    MedianInsurancePaidSameLab           NVARCHAR(MAX)   NULL,
    MedianAllowedAmountPeer              NVARCHAR(MAX)   NULL,
    MedianInsurancePaidPeer              NVARCHAR(MAX)   NULL,
    ModeAllowedAmountDifference          NVARCHAR(MAX)   NULL,
    ModeInsurancePaidDifference          NVARCHAR(MAX)   NULL,
    MedianAllowedAmountDifference        NVARCHAR(MAX)   NULL,
    MedianInsurancePaidDifference        NVARCHAR(MAX)   NULL,
    DenialRate                           NVARCHAR(MAX)   NULL,
    AdjustmentRate                       NVARCHAR(MAX)   NULL,
    PaymentDays                          NVARCHAR(MAX)   NULL,
    ExpectedPaymentDate                  NVARCHAR(MAX)   NULL,
    ExpectedPaymentMonth                 NVARCHAR(MAX)   NULL,
    BillingProvider                      NVARCHAR(MAX)   NULL,
    ReferringProvider                    NVARCHAR(MAX)   NULL,
    ClinicName                           NVARCHAR(MAX)   NULL,
    SalesRepName                         NVARCHAR(MAX)   NULL,
    PatientID                            NVARCHAR(MAX)   NULL,
    ChargeEnteredDate                    NVARCHAR(MAX)   NULL,
    POS                                  NVARCHAR(MAX)   NULL,
    TOS                                  NVARCHAR(MAX)   NULL,
    CheckDate                            NVARCHAR(MAX)   NULL,
    DaysToDOS                            NVARCHAR(MAX)   NULL,
    RollingDays                          NVARCHAR(MAX)   NULL,
    DaysToBill                           NVARCHAR(MAX)   NULL,
    DaysToPost                           NVARCHAR(MAX)   NULL
);
GO

-- ------------------------------------------------------------
-- SP 1 : usp_SavePayerValidationFileLog
-- RunId and WeekFolder are nullable — files without a standard
-- naming pattern will insert NULL for these fields.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_SavePayerValidationFileLog
(
    @RunId               NVARCHAR(100)   = NULL,
    @WeekFolder          NVARCHAR(255)   = NULL,
    @LabName             NVARCHAR(255),
    @SourceFullPath      NVARCHAR(1000),
    @FileName            NVARCHAR(500),
    @FileCreatedDateTime DATETIME2       = NULL,
    @FileLogId           INT             OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.PayerValidationFileLog
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFullPath, @FileName, @FileCreatedDateTime);

    SET @FileLogId = SCOPE_IDENTITY();
END
GO

-- ------------------------------------------------------------
-- SP 2 : usp_BulkInsertPayerValidationReport
-- Deletes existing rows for the RunId+LabName combo (idempotent).
-- When RunId is NULL, matches by LabName only to avoid deleting
-- unrelated NULL-RunId rows from other files.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_BulkInsertPayerValidationReport
(
    @Rows dbo.TVP_PayerValidationReport READONLY
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Delete existing rows for the same lab+run so re-runs are idempotent.
    -- When RunId IS NULL, scope deletion to FileLogId to avoid over-deleting.
    DELETE r
    FROM dbo.PayerValidationReport r
    WHERE r.LabName IN (SELECT DISTINCT LabName FROM @Rows)
      AND (
            -- Normal case: RunId present — match on RunId + LabName
            (r.RunId IS NOT NULL AND r.RunId IN (SELECT DISTINCT RunId FROM @Rows WHERE RunId IS NOT NULL))
            OR
            -- Null RunId case: match on FileLogId to scope tightly
            (r.RunId IS NULL AND r.FileLogId IN (SELECT DISTINCT FileLogId FROM @Rows WHERE RunId IS NULL))
          );

    INSERT INTO dbo.PayerValidationReport
    (
        FileLogId, RunId, WeekFolder, LabName, SourceFullPath,
        AccessionNo, VisitNumber, CPTCode, PatientDOB,
        PayerCode, PayerName, PayerNameNormalized,
        PayStatus, HistoricalPayment, HistoricalPaidLineItemCount,
        HistoricalPaymentConfidenceScore, TotalLineItemCount,
        PaidLineItemCount, PctPaidLineItemCount, PayerType, PayerFoundInPolicy,
        DateOfService, FirstBilledDate,
        PanelName, LISIcd10Codes, CCWIcd10Code, Units, Modifier,
        DenialCode, DenialDescription,
        BilledAmount, AllowedAmount, InsurancePayment, InsuranceAdjustment,
        PatientPaidAmount, PatientAdjustment, InsuranceBalance,
        PatientBalance, TotalBalance, MedicareFee,
        FinalClaimStatus, CoveredIcd10CodesBilled, NonCoveredIcd10CodesBilled,
        BilledIcdCodesNotAvailableInPolicy, CoverageStatus, FinalCoverageStatus,
        CoveredIcd10CodesAsPerPayerPolicy, NonCoveredIcd10CodesAsPerPayerPolicy,
        ActionComment, Resolution, LabName2,
        CodingValidation, CodingValidationSubStatus,
        ICDComplianceStatus, ICDComplianceSubstatus,
        ICDPrimaryIndicatorAvailable, CoveredICDPresence, ICDValidationConfidence,
        FrequencyConditionMet, GenderConditionMet,
        Payability, ForecastingPayability, PolicyCoverageExpectation,
        DenialValidity, CoverageExpectationRemarks,
        ExpectedAverageAllowedAmount, ExpectedAverageInsurancePayment,
        ExpectedAllowedAmountSameLab, ExpectedInsurancePaymentSameLab,
        ModeAllowedAmountSameLab, ModeInsurancePaidSameLab,
        ModeAllowedAmountPeer, ModeInsurancePaidPeer,
        MedianAllowedAmountSameLab, MedianInsurancePaidSameLab,
        MedianAllowedAmountPeer, MedianInsurancePaidPeer,
        ModeAllowedAmountDifference, ModeInsurancePaidDifference,
        MedianAllowedAmountDifference, MedianInsurancePaidDifference,
        DenialRate, AdjustmentRate, PaymentDays,
        ExpectedPaymentDate, ExpectedPaymentMonth,
        BillingProvider, ReferringProvider, ClinicName, SalesRepName,
        PatientID, ChargeEnteredDate, POS, TOS, CheckDate,
        DaysToDOS, RollingDays, DaysToBill, DaysToPost
    )
    SELECT
        FileLogId, RunId, WeekFolder, LabName, SourceFullPath,
        AccessionNo, VisitNumber, CPTCode, PatientDOB,
        PayerCode, PayerName, PayerNameNormalized,
        PayStatus, HistoricalPayment, HistoricalPaidLineItemCount,
        HistoricalPaymentConfidenceScore, TotalLineItemCount,
        PaidLineItemCount, PctPaidLineItemCount, PayerType, PayerFoundInPolicy,
        DateOfService, FirstBilledDate,
        PanelName, LISIcd10Codes, CCWIcd10Code, Units, Modifier,
        DenialCode, DenialDescription,
        BilledAmount, AllowedAmount, InsurancePayment, InsuranceAdjustment,
        PatientPaidAmount, PatientAdjustment, InsuranceBalance,
        PatientBalance, TotalBalance, MedicareFee,
        FinalClaimStatus, CoveredIcd10CodesBilled, NonCoveredIcd10CodesBilled,
        BilledIcdCodesNotAvailableInPolicy, CoverageStatus, FinalCoverageStatus,
        CoveredIcd10CodesAsPerPayerPolicy, NonCoveredIcd10CodesAsPerPayerPolicy,
        ActionComment, Resolution, LabName2,
        CodingValidation, CodingValidationSubStatus,
        ICDComplianceStatus, ICDComplianceSubstatus,
        ICDPrimaryIndicatorAvailable, CoveredICDPresence, ICDValidationConfidence,
        FrequencyConditionMet, GenderConditionMet,
        Payability, ForecastingPayability, PolicyCoverageExpectation,
        DenialValidity, CoverageExpectationRemarks,
        ExpectedAverageAllowedAmount, ExpectedAverageInsurancePayment,
        ExpectedAllowedAmountSameLab, ExpectedInsurancePaymentSameLab,
        ModeAllowedAmountSameLab, ModeInsurancePaidSameLab,
        ModeAllowedAmountPeer, ModeInsurancePaidPeer,
        MedianAllowedAmountSameLab, MedianInsurancePaidSameLab,
        MedianAllowedAmountPeer, MedianInsurancePaidPeer,
        ModeAllowedAmountDifference, ModeInsurancePaidDifference,
        MedianAllowedAmountDifference, MedianInsurancePaidDifference,
        DenialRate, AdjustmentRate, PaymentDays,
        ExpectedPaymentDate, ExpectedPaymentMonth,
        BillingProvider, ReferringProvider, ClinicName, SalesRepName,
        PatientID, ChargeEnteredDate, POS, TOS, CheckDate,
        DaysToDOS, RollingDays, DaysToBill, DaysToPost
    FROM @Rows;
END
GO

-- ============================================================
-- SP 3 : usp_GetPayerValidationReport
-- Returns PayerValidationReport rows for a given lab.
-- Supports optional filters: RunId, PayStatus, ForecastingPayability.
-- The caller controls which columns are returned — add or remove
-- columns from the SELECT without changing C# by adjusting this SP.
-- ============================================================
  
-- ============================================================  
-- SP 3 : usp_GetPayerValidationReport  
-- Returns PayerValidationReport rows for a given lab.  
-- Supports optional filters: RunId, PayStatus, ForecastingPayability.  
-- The caller controls which columns are returned — add or remove  
-- columns from the SELECT without changing C# by adjusting this SP.  
-- ============================================================  
CREATE or alter  PROCEDURE dbo.usp_GetPayerValidationReport  
(  
    @LabName                NVARCHAR(255)  = NULL,  
    @RunId                  NVARCHAR(100)  = NULL,   -- NULL = latest run for the lab  
    @FilterPayerName        NVARCHAR(255)  = NULL,  
    @FilterPayerType        NVARCHAR(100)  = NULL,  
    @FilterPanelName        NVARCHAR(255)  = NULL,  
    @FilterFinalCoverageStatus NVARCHAR(100) = NULL,  
    @FilterPayability       NVARCHAR(100)  = NULL,  
    @FilterCPTCode          NVARCHAR(50)   = NULL  
)  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    -- Resolve RunId: if not supplied use the most recent one for this lab.  
    IF @RunId IS NULL  
    BEGIN  
        SELECT TOP 1 @RunId = RunId  
        FROM   dbo.PayerValidationReport  
        WHERE  
		--LabName = @LabName  AND  
          RunId   IS NOT NULL  
        ORDER BY InsertedDateTime DESC;  
    END  
  
    SELECT  
        -- ?? Identifiers ??????????????????????????????????????????????????????  
        RunId,  
        AccessionNo,  
        VisitNumber,  
        CPTCode,  
        PatientDOB,  
        PayerCode,  
        PayerName,  
        PayerNameNormalized,  
  
        -- ?? Pay / claim status ???????????????????????????????????????????????  
        PayStatus,  
        HistoricalPayment,  
        HistoricalPaidLineItemCount,  
        HistoricalPaymentConfidenceScore,  
        TotalLineItemCount,  
        PaidLineItemCount,  
        PctPaidLineItemCount,  
        PayerType,  
        PayerFoundInPolicy,  
  
        -- ?? Dates ????????????????????????????????????????????????????????????  
        DateOfService,  
        FirstBilledDate,  
  
        -- ?? Panel / ICD ??????????????????????????????????????????????????????  
        PanelName,  
        LISIcd10Codes,  
        CCWIcd10Code,  
        Units,  
        Modifier,  
        DenialCode,  
        DenialDescription,  
  
        -- ?? Financials ???????????????????????????????????????????????????????  
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
  
        -- ?? Coverage / claim ?????????????????????????????????????????????????  
        FinalClaimStatus,  
        CoveredIcd10CodesBilled,  
        NonCoveredIcd10CodesBilled,  
        BilledIcdCodesNotAvailableInPolicy,  
        CoverageStatus,  
        FinalCoverageStatus,  
        CoveredIcd10CodesAsPerPayerPolicy,  
        NonCoveredIcd10CodesAsPerPayerPolicy,  
  
        -- ?? Action ???????????????????????????????????????????????????????????  
        ActionComment,  
        Resolution,  
        LabName2,  
  
        -- ?? Coding / ICD validation ???????????????????????????????????????????  
        CodingValidation,  
        CodingValidationSubStatus,  
        ICDComplianceStatus,  
        ICDComplianceSubstatus,  
        ICDPrimaryIndicatorAvailable,  
        CoveredICDPresence,  
        ICDValidationConfidence,  
  
        -- ?? Policy / payability ???????????????????????????????????????????????  
        FrequencyConditionMet,  
        GenderConditionMet,  
        Payability,  
        ForecastingPayability,  
        PolicyCoverageExpectation,  
        DenialValidity,  
        CoverageExpectationRemarks,  
  
        -- ?? Expected amounts ?????????????????????????????????????????????????  
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
  
        -- ?? Rates / dates ?????????????????????????????????????????????????????  
        DenialRate,  
        AdjustmentRate,  
        PaymentDays,  
        ExpectedPaymentDate,  
        ExpectedPaymentMonth,  
  
        -- ?? Provider / clinic ?????????????????????????????????????????????????  
        BillingProvider,  
        ReferringProvider,  
        ClinicName,  
        SalesRepName,  
  
        -- ?? Billing ???????????????????????????????????????????????????????????  
        PatientID,  
        ChargeEnteredDate,  
        POS,  
        TOS,  
        CheckDate,  
        DaysToDOS,  
        RollingDays,  
        DaysToBill,  
        DaysToPost,  
  
        InsertedDateTime  
  
    FROM dbo.PayerValidationReport  
    WHERE 
	--LabName = @LabName   AND
       (@RunId    IS NULL OR RunId    = @RunId)  
      AND (@FilterPayerName  IS NULL OR PayerNameNormalized = @FilterPayerName)  
      AND (@FilterPayerType  IS NULL OR PayerType           = @FilterPayerType)  
      AND (@FilterPanelName  IS NULL OR PanelName           = @FilterPanelName)  
      AND (@FilterFinalCoverageStatus IS NULL OR FinalCoverageStatus = @FilterFinalCoverageStatus)  
      AND (@FilterPayability IS NULL OR Payability          = @FilterPayability)  
      AND (@FilterCPTCode    IS NULL OR CPTCode             = @FilterCPTCode)  
    ORDER BY InsertedDateTime DESC;  
END  
GO
