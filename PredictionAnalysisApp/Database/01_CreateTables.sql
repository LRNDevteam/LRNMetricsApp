-- ============================================================
-- 01_CreateTables.sql
-- Core Prediction Analysis tables for per-lab databases.
-- Safe to re-run: uses IF NOT EXISTS / conditional ALTER.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ?? File log ????????????????????????????????????????????????????????????????
IF OBJECT_ID('dbo.PayerValidationFileLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PayerValidationFileLog
    (
        FileLogId           INT            IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId               NVARCHAR(100)  NULL,
        WeekFolder          NVARCHAR(255)  NULL,
        LabName             NVARCHAR(255)  NOT NULL,
        SourceFullPath      NVARCHAR(1000) NOT NULL,
        FileName            NVARCHAR(500)  NOT NULL,
        FileCreatedDateTime DATETIME2      NULL,
        InsertedDateTime    DATETIME2      NOT NULL CONSTRAINT DF_PayerValidationFileLog_Inserted DEFAULT SYSUTCDATETIME()
    );
END
GO

-- ?? Main report table (per-lab prediction source data) ???????????????????????
IF OBJECT_ID('dbo.PayerValidationReport', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PayerValidationReport
    (
        ReportId                         BIGINT         IDENTITY(1,1) NOT NULL PRIMARY KEY,
        FileLogId                        INT            NULL,
        RunId                            NVARCHAR(MAX)  NULL,
        WeekFolder                       NVARCHAR(MAX)  NULL,
        LabName                          NVARCHAR(MAX)  NULL,
        SourceFullPath                   NVARCHAR(MAX)  NULL,
        AccessionNo                      NVARCHAR(MAX)  NULL,
        VisitNumber                      NVARCHAR(MAX)  NULL,
        CPTCode                          NVARCHAR(MAX)  NULL,
        PatientDOB                       NVARCHAR(MAX)  NULL,
        PayerCode                        NVARCHAR(MAX)  NULL,
        PayerName                        NVARCHAR(MAX)  NULL,
        PayerNameNormalized              NVARCHAR(MAX)  NULL,
        PayStatus                        NVARCHAR(MAX)  NULL,
        HistoricalPayment                NVARCHAR(MAX)  NULL,
        HistoricalPaidLineItemCount      NVARCHAR(MAX)  NULL,
        HistoricalPaymentConfidenceScore NVARCHAR(MAX)  NULL,
        TotalLineItemCount               NVARCHAR(MAX)  NULL,
        PaidLineItemCount                NVARCHAR(MAX)  NULL,
        PctPaidLineItemCount             NVARCHAR(MAX)  NULL,
        PayerType                        NVARCHAR(MAX)  NULL,
        PayerFoundInPolicy               NVARCHAR(MAX)  NULL,
        DateOfService                    NVARCHAR(MAX)  NULL,
        FirstBilledDate                  NVARCHAR(MAX)  NULL,
        PanelName                        NVARCHAR(MAX)  NULL,
        LISIcd10Codes                    NVARCHAR(MAX)  NULL,
        CCWIcd10Code                     NVARCHAR(MAX)  NULL,
        Units                            NVARCHAR(MAX)  NULL,
        Modifier                         NVARCHAR(MAX)  NULL,
        DenialCode                       NVARCHAR(MAX)  NULL,
        DenialDescription                NVARCHAR(MAX)  NULL,
        BilledAmount                     NVARCHAR(MAX)  NULL,
        AllowedAmount                    NVARCHAR(MAX)  NULL,
        InsurancePayment                 NVARCHAR(MAX)  NULL,
        InsuranceAdjustment              NVARCHAR(MAX)  NULL,
        PatientPaidAmount                NVARCHAR(MAX)  NULL,
        PatientAdjustment                NVARCHAR(MAX)  NULL,
        InsuranceBalance                 NVARCHAR(MAX)  NULL,
        PatientBalance                   NVARCHAR(MAX)  NULL,
        TotalBalance                     NVARCHAR(MAX)  NULL,
        MedicareFee                      NVARCHAR(MAX)  NULL,
        FinalClaimStatus                 NVARCHAR(MAX)  NULL,
        CoveredIcd10CodesBilled          NVARCHAR(MAX)  NULL,
        NonCoveredIcd10CodesBilled       NVARCHAR(MAX)  NULL,
        BilledIcdCodesNotAvailableInPolicy NVARCHAR(MAX) NULL,
        CoverageStatus                   NVARCHAR(MAX)  NULL,
        FinalCoverageStatus              NVARCHAR(MAX)  NULL,
        CoveredIcd10CodesAsPerPayerPolicy NVARCHAR(MAX) NULL,
        NonCoveredIcd10CodesAsPerPayerPolicy NVARCHAR(MAX) NULL,
        ActionComment                    NVARCHAR(MAX)  NULL,
        Resolution                       NVARCHAR(MAX)  NULL,
        LabName2                         NVARCHAR(MAX)  NULL,
        CodingValidation                 NVARCHAR(MAX)  NULL,
        CodingValidationSubStatus        NVARCHAR(MAX)  NULL,
        ICDComplianceStatus              NVARCHAR(MAX)  NULL,
        ICDComplianceSubstatus           NVARCHAR(MAX)  NULL,
        ICDPrimaryIndicatorAvailable     NVARCHAR(MAX)  NULL,
        CoveredICDPresence               NVARCHAR(MAX)  NULL,
        ICDValidationConfidence          NVARCHAR(MAX)  NULL,
        FrequencyConditionMet            NVARCHAR(MAX)  NULL,
        GenderConditionMet               NVARCHAR(MAX)  NULL,
        Payability                       NVARCHAR(MAX)  NULL,
        ForecastingPayability            NVARCHAR(MAX)  NULL,
        PolicyCoverageExpectation        NVARCHAR(MAX)  NULL,
        DenialValidity                   NVARCHAR(MAX)  NULL,
        CoverageExpectationRemarks       NVARCHAR(MAX)  NULL,
        ExpectedAverageAllowedAmount     NVARCHAR(MAX)  NULL,
        ExpectedAverageInsurancePayment  NVARCHAR(MAX)  NULL,
        ExpectedAllowedAmountSameLab     NVARCHAR(MAX)  NULL,
        ExpectedInsurancePaymentSameLab  NVARCHAR(MAX)  NULL,
        ModeAllowedAmountSameLab         NVARCHAR(MAX)  NULL,
        ModeInsurancePaidSameLab         NVARCHAR(MAX)  NULL,
        ModeAllowedAmountPeer            NVARCHAR(MAX)  NULL,
        ModeInsurancePaidPeer            NVARCHAR(MAX)  NULL,
        MedianAllowedAmountSameLab       NVARCHAR(MAX)  NULL,
        MedianInsurancePaidSameLab       NVARCHAR(MAX)  NULL,
        MedianAllowedAmountPeer          NVARCHAR(MAX)  NULL,
        MedianInsurancePaidPeer          NVARCHAR(MAX)  NULL,
        ModeAllowedAmountDifference      NVARCHAR(MAX)  NULL,
        ModeInsurancePaidDifference      NVARCHAR(MAX)  NULL,
        MedianAllowedAmountDifference    NVARCHAR(MAX)  NULL,
        MedianInsurancePaidDifference    NVARCHAR(MAX)  NULL,
        DenialRate                       NVARCHAR(MAX)  NULL,
        AdjustmentRate                   NVARCHAR(MAX)  NULL,
        PaymentDays                      NVARCHAR(MAX)  NULL,
        ExpectedPaymentDate              NVARCHAR(MAX)  NULL,
        ExpectedPaymentMonth             NVARCHAR(MAX)  NULL,
        BillingProvider                  NVARCHAR(MAX)  NULL,
        ReferringProvider                NVARCHAR(MAX)  NULL,
        ClinicName                       NVARCHAR(MAX)  NULL,
        SalesRepName                     NVARCHAR(MAX)  NULL,
        PatientID                        NVARCHAR(MAX)  NULL,
        ChargeEnteredDate                NVARCHAR(MAX)  NULL,
        POS                              NVARCHAR(MAX)  NULL,
        TOS                              NVARCHAR(MAX)  NULL,
        CheckDate                        NVARCHAR(MAX)  NULL,
        DaysToDOS                        NVARCHAR(MAX)  NULL,
        RollingDays                      NVARCHAR(MAX)  NULL,
        DaysToBill                       NVARCHAR(MAX)  NULL,
        DaysToPost                       NVARCHAR(MAX)  NULL,
        ForecastingPayabilitySubstatus   NVARCHAR(100)  NULL,
        PredictionStatus                 NVARCHAR(100)  NULL,
        Variance_AllowedAmount           NVARCHAR(50)   NULL,
        Variance_PaidAmount              NVARCHAR(50)   NULL,
        InsertedDateTime                 DATETIME2      NOT NULL CONSTRAINT DF_PayerValidationReport_Inserted DEFAULT SYSUTCDATETIME()
    );
END
GO

-- Add prediction-derived columns to existing deployments
IF COL_LENGTH('dbo.PayerValidationReport', 'ForecastingPayabilitySubstatus') IS NULL
    ALTER TABLE dbo.PayerValidationReport ADD ForecastingPayabilitySubstatus NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.PayerValidationReport', 'PredictionStatus') IS NULL
    ALTER TABLE dbo.PayerValidationReport ADD PredictionStatus NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.PayerValidationReport', 'Variance_AllowedAmount') IS NULL
    ALTER TABLE dbo.PayerValidationReport ADD Variance_AllowedAmount NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.PayerValidationReport', 'Variance_PaidAmount') IS NULL
    ALTER TABLE dbo.PayerValidationReport ADD Variance_PaidAmount NVARCHAR(50) NULL;
GO
