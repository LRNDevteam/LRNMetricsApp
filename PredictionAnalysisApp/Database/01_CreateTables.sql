-- ============================================================
-- 01_CreateTables.sql
-- Creates staging tables for PayerValidation source data.
-- Run once against your target database.
-- ============================================================

-- ------------------------------------------------------------
-- Table 1 : PayerValidationFileLog
-- One row per source file processed by the Prediction app.
-- ------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.tables WHERE name = 'PayerValidationFileLog'
)
BEGIN
    CREATE TABLE dbo.PayerValidationFileLog
    (
        FileLogId           INT             NOT NULL IDENTITY(1,1) CONSTRAINT PK_PayerValidationFileLog PRIMARY KEY,
        RunId               NVARCHAR(100)   NULL,
        WeekFolder          NVARCHAR(255)   NULL,
        LabName             NVARCHAR(255)   NOT NULL,
        SourceFullPath      NVARCHAR(1000)  NOT NULL,
        FileName            NVARCHAR(500)   NOT NULL,
        FileCreatedDateTime DATETIME2       NULL,
        InsertedDateTime    DATETIME2       NOT NULL CONSTRAINT DF_PayerValidationFileLog_InsertedDateTime DEFAULT SYSUTCDATETIME()
    );
END
GO

-- ------------------------------------------------------------
-- Table 2 : PayerValidationReport
-- One row per claim line read from the PayerValidation Excel.
-- All 90+ source columns are persisted here.
-- ------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.tables WHERE name = 'PayerValidationReport'
)
BEGIN
    CREATE TABLE dbo.PayerValidationReport
    (
        ReportId                             INT             NOT NULL IDENTITY(1,1) CONSTRAINT PK_PayerValidationReport PRIMARY KEY,
        FileLogId                            INT             NOT NULL CONSTRAINT FK_PayerValidationReport_FileLog FOREIGN KEY REFERENCES dbo.PayerValidationFileLog(FileLogId),
        RunId                                NVARCHAR(100)   NULL,
        WeekFolder                           NVARCHAR(255)   NULL,
        LabName                              NVARCHAR(255)   NULL,
        SourceFullPath                       NVARCHAR(1000)  NULL,

        -- ?? Core identifiers ?????????????????????????????????????????????????
        AccessionNo                          NVARCHAR(100)   NULL,
        VisitNumber                          NVARCHAR(100)   NULL,
        CPTCode                              NVARCHAR(50)    NULL,
        PatientDOB                           NVARCHAR(50)    NULL,
        PayerCode                            NVARCHAR(100)   NULL,
        PayerName                            NVARCHAR(255)   NULL,
        PayerNameNormalized                  NVARCHAR(255)   NULL,

        -- ?? Pay / claim status ????????????????????????????????????????????????
        PayStatus                            NVARCHAR(100)   NULL,
        HistoricalPayment                    NVARCHAR(100)   NULL,
        HistoricalPaidLineItemCount          NVARCHAR(50)    NULL,
        HistoricalPaymentConfidenceScore     NVARCHAR(50)    NULL,
        TotalLineItemCount                   NVARCHAR(50)    NULL,
        PaidLineItemCount                    NVARCHAR(50)    NULL,
        PctPaidLineItemCount                 NVARCHAR(50)    NULL,
        PayerType                            NVARCHAR(100)   NULL,
        PayerFoundInPolicy                   NVARCHAR(50)    NULL,

        -- ?? Dates ?????????????????????????????????????????????????????????????
        DateOfService                        NVARCHAR(50)    NULL,
        FirstBilledDate                      NVARCHAR(50)    NULL,

        -- ?? Panel / ICD / procedure ????????????????????????????????????????????
        PanelName                            NVARCHAR(255)   NULL,
        LISIcd10Codes                        NVARCHAR(500)   NULL,
        CCWIcd10Code                         NVARCHAR(500)   NULL,
        Units                                NVARCHAR(50)    NULL,
        Modifier                             NVARCHAR(50)    NULL,
        DenialCode                           NVARCHAR(100)   NULL,
        DenialDescription                    NVARCHAR(500)   NULL,

        -- ?? Financials ????????????????????????????????????????????????????????
        BilledAmount                         NVARCHAR(50)    NULL,
        AllowedAmount                        NVARCHAR(50)    NULL,
        InsurancePayment                     NVARCHAR(50)    NULL,
        InsuranceAdjustment                  NVARCHAR(50)    NULL,
        PatientPaidAmount                    NVARCHAR(50)    NULL,
        PatientAdjustment                    NVARCHAR(50)    NULL,
        InsuranceBalance                     NVARCHAR(50)    NULL,
        PatientBalance                       NVARCHAR(50)    NULL,
        TotalBalance                         NVARCHAR(50)    NULL,
        MedicareFee                          NVARCHAR(50)    NULL,

        -- ?? Claim / coverage status ????????????????????????????????????????????
        FinalClaimStatus                     NVARCHAR(100)   NULL,
        CoveredIcd10CodesBilled              NVARCHAR(MAX)   NULL,
        NonCoveredIcd10CodesBilled           NVARCHAR(MAX)   NULL,
        BilledIcdCodesNotAvailableInPolicy   NVARCHAR(MAX)   NULL,
        CoverageStatus                       NVARCHAR(MAX)   NULL,
        FinalCoverageStatus                  NVARCHAR(MAX)   NULL,
        CoveredIcd10CodesAsPerPayerPolicy    NVARCHAR(MAX)   NULL,
        NonCoveredIcd10CodesAsPerPayerPolicy NVARCHAR(MAX)   NULL,

        -- ?? Action / resolution ????????????????????????????????????????????????
        ActionComment                        NVARCHAR(MAX)  NULL,
        Resolution                           NVARCHAR(MAX)   NULL,
        LabName2                             NVARCHAR(255)   NULL,

        -- ?? Coding / ICD validation ????????????????????????????????????????????
        CodingValidation                     NVARCHAR(MAX)   NULL,
        CodingValidationSubStatus            NVARCHAR(MAX)   NULL,
        ICDComplianceStatus                  NVARCHAR(MAX)   NULL,
        ICDComplianceSubstatus              NVARCHAR(MAX)  NULL,
        ICDPrimaryIndicatorAvailable        NVARCHAR(MAX)   NULL,
        CoveredICDPresence                   NVARCHAR(MAX)    NULL,
        ICDValidationConfidence             NVARCHAR(MAX)    NULL,

        -- ?? Policy / payability ????????????????????????????????????????????????
        FrequencyConditionMet                NVARCHAR(500)    NULL,
        GenderConditionMet                   NVARCHAR(500)    NULL,
        Payability                           NVARCHAR(100)   NULL,
        ForecastingPayability                NVARCHAR(100)   NULL,
        PolicyCoverageExpectation            NVARCHAR(100)   NULL,
        DenialValidity                       NVARCHAR(100)   NULL,
        CoverageExpectationRemarks           NVARCHAR(MAX)   NULL,

        -- ?? Expected payment amounts ??????????????????????????????????????????
        ExpectedAverageAllowedAmount         NVARCHAR(50)    NULL,
        ExpectedAverageInsurancePayment      NVARCHAR(50)    NULL,
        ExpectedAllowedAmountSameLab         NVARCHAR(50)    NULL,
        ExpectedInsurancePaymentSameLab      NVARCHAR(50)    NULL,
        ModeAllowedAmountSameLab             NVARCHAR(50)    NULL,
        ModeInsurancePaidSameLab             NVARCHAR(50)    NULL,
        ModeAllowedAmountPeer                NVARCHAR(50)    NULL,
        ModeInsurancePaidPeer                NVARCHAR(50)    NULL,
        MedianAllowedAmountSameLab           NVARCHAR(50)    NULL,
        MedianInsurancePaidSameLab           NVARCHAR(50)    NULL,
        MedianAllowedAmountPeer              NVARCHAR(50)    NULL,
        MedianInsurancePaidPeer              NVARCHAR(50)    NULL,
        ModeAllowedAmountDifference          NVARCHAR(50)    NULL,
        ModeInsurancePaidDifference          NVARCHAR(50)    NULL,
        MedianAllowedAmountDifference        NVARCHAR(50)    NULL,
        MedianInsurancePaidDifference        NVARCHAR(50)    NULL,

        -- ?? Denial / adjustment rates ?????????????????????????????????????????
        DenialRate                           NVARCHAR(50)    NULL,
        AdjustmentRate                       NVARCHAR(50)    NULL,
        PaymentDays                          NVARCHAR(50)    NULL,
        ExpectedPaymentDate                  NVARCHAR(50)    NULL,
        ExpectedPaymentMonth                 NVARCHAR(50)    NULL,

        -- ?? Provider / clinic ?????????????????????????????????????????????????
        BillingProvider                      NVARCHAR(255)   NULL,
        ReferringProvider                    NVARCHAR(255)   NULL,
        ClinicName                           NVARCHAR(255)   NULL,
        SalesRepName                         NVARCHAR(255)   NULL,

        -- ?? Additional billing fields ?????????????????????????????????????????
        PatientID                            NVARCHAR(100)   NULL,
        ChargeEnteredDate                    NVARCHAR(50)    NULL,
        POS                                  NVARCHAR(50)    NULL,
        TOS                                  NVARCHAR(50)    NULL,
        CheckDate                            NVARCHAR(50)    NULL,
        DaysToDOS                            NVARCHAR(50)    NULL,
        RollingDays                          NVARCHAR(50)    NULL,
        DaysToBill                           NVARCHAR(50)    NULL,
        DaysToPost                           NVARCHAR(50)    NULL,

        InsertedDateTime                     DATETIME2       NOT NULL CONSTRAINT DF_PayerValidationReport_InsertedDateTime DEFAULT SYSUTCDATETIME()
    );

    CREATE NONCLUSTERED INDEX IX_PayerValidationReport_FileLogId
        ON dbo.PayerValidationReport (FileLogId);

    CREATE NONCLUSTERED INDEX IX_PayerValidationReport_RunId
        ON dbo.PayerValidationReport (RunId);
END
GO

-- ------------------------------------------------------------
-- Patch script — run once on an already-created database.
-- Makes RunId / WeekFolder nullable in PayerValidationFileLog
-- so files without a standard naming pattern insert NULL.
-- ------------------------------------------------------------
IF EXISTS (
    SELECT 1
    FROM   sys.columns c
    JOIN   sys.tables  t ON c.object_id = t.object_id
    WHERE  t.name   = 'PayerValidationFileLog'
      AND  c.name   = 'RunId'
      AND  c.is_nullable = 0
)
BEGIN
    ALTER TABLE dbo.PayerValidationFileLog ALTER COLUMN RunId      NVARCHAR(100) NULL;
    ALTER TABLE dbo.PayerValidationFileLog ALTER COLUMN WeekFolder NVARCHAR(255) NULL;
    PRINT 'PayerValidationFileLog: RunId and WeekFolder set to NULL-able.';
END
GO
