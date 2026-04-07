-- ============================================================
-- CaptureDataApp  –  Coding Validation Tables
-- Run once per lab database.
-- ============================================================

-- ?? 0. CodingValidationFileLog  (one row per processed file) ?????????????????
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CodingValidationFileLog')
CREATE TABLE dbo.CodingValidationFileLog
(
    FileLogId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RunId                 NVARCHAR(500)  NOT NULL,   -- filename without extension, unique per run
    WeekFolder            NVARCHAR(500)  NULL,
    LabName               NVARCHAR(500)  NULL,
    SourceFullPath        NVARCHAR(1000) NULL,
    FileName              NVARCHAR(500)  NULL,
    FileType              NVARCHAR(100)  NOT NULL DEFAULT 'codingmaster',
    FileCreatedDateTime   DATETIME       NULL,
    InsertedDateTime      DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'UX_CodingValidationFileLog_RunId'
      AND object_id = OBJECT_ID('dbo.CodingValidationFileLog')
)
CREATE UNIQUE INDEX UX_CodingValidationFileLog_RunId
    ON dbo.CodingValidationFileLog (RunId);
GO

-- ?? 1. CodingValidation  (row-level detail from CodingValidated sheet) ????????
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CodingValidation')
CREATE TABLE dbo.CodingValidation
(
    ReportId                                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    FileLogId                                 NVARCHAR(500)  NULL,
    WeekFolder                                NVARCHAR(500)  NULL,
    SourceFilePath                            NVARCHAR(500)  NULL,
    RunNumber                                 NVARCHAR(500)  NULL,
    AccessionNo                               NVARCHAR(500)  NULL,
    VisitNumber                               NVARCHAR(500)  NULL,
    PayerName_Raw                             NVARCHAR(500)  NULL,
    Carrier                                   NVARCHAR(500)  NULL,
    Payer_Code                                NVARCHAR(500)  NULL,
    PayerCommonCode                           NVARCHAR(500)  NULL,
    Payer_Group_Code                          NVARCHAR(500)  NULL,
    Global_Payer_ID                           NVARCHAR(500)  NULL,
    PayerType                                 NVARCHAR(500)  NULL,
    BillingProvider                           NVARCHAR(500)  NULL,
    ReferringProvider                         NVARCHAR(500)  NULL,
    ClinicName                                NVARCHAR(500)  NULL,
    SalesRepname                              NVARCHAR(500)  NULL,
    PatientID                                 NVARCHAR(500)  NULL,
    PatientDOB                                NVARCHAR(500)  NULL,
    DateofService                             NVARCHAR(500)  NULL,
    ChargeEnteredDate                         NVARCHAR(500)  NULL,
    FirstBillDate                             NVARCHAR(500)  NULL,
    PanelName                                 NVARCHAR(500)  NULL,
    POS                                       NVARCHAR(500)  NULL,
    TOS                                       NVARCHAR(500)  NULL,
    TotalCharge                               NVARCHAR(500)  NULL,
    AllowedAmount                             NVARCHAR(500)  NULL,
    InsurancePayment                          NVARCHAR(500)  NULL,
    PatientPayment                            NVARCHAR(500)  NULL,
    TotalPayments                             NVARCHAR(500)  NULL,
    InsuranceAdjustments                      NVARCHAR(500)  NULL,
    PatientAdjustments                        NVARCHAR(500)  NULL,
    TotalAdjustments                          NVARCHAR(500)  NULL,
    InsuranceBalance                          NVARCHAR(500)  NULL,
    PatientBalance                            NVARCHAR(500)  NULL,
    TotalBalance                              NVARCHAR(500)  NULL,
    CheckDate                                 NVARCHAR(500)  NULL,
    ClaimStatus                               NVARCHAR(500)  NULL,
    DenialCode                                NVARCHAR(Max)  NULL,
    ICDCode                                   NVARCHAR(500)  NULL,
    DaystoDOS                                 NVARCHAR(500)  NULL,
    RollingDays                               NVARCHAR(500)  NULL,
    DaystoBill                                NVARCHAR(500)  NULL,
    DaystoPost                                NVARCHAR(500)  NULL,
    ICDPointer                                NVARCHAR(500)  NULL,
    ActualCPTCode                             NVARCHAR(MAX)  NULL,
    ExpectedCPTCode                           NVARCHAR(MAX)  NULL,
    MissingCPTCodes                           NVARCHAR(Max)  NULL,
    AdditionalCPTCodes                        NVARCHAR(Max)  NULL,
    MissingCPT_Charges                        NVARCHAR(500)  NULL,
    MissingCPT_ChargeSource                   NVARCHAR(500)  NULL,
    AdditionalCPT_Charges                     NVARCHAR(500)  NULL,
    AdditionalCPT_ChargeSource                NVARCHAR(500)  NULL,
    ExpectedCharges                           NVARCHAR(500)  NULL,
    ValidationStatus                          NVARCHAR(Max)  NULL,
    Remarks                                   NVARCHAR(Max)  NULL,
    MissingCPT_AvgAllowedAmount               NVARCHAR(500)  NULL,
    MissingCPT_AvgPaidAmount                  NVARCHAR(500)  NULL,
    MissingCPT_AvgPatientResponsibilityAmount NVARCHAR(500)  NULL,
    AdditionalCPT_AvgAllowedAmount            NVARCHAR(500)  NULL,
    AdditionalCPT_AvgPaidAmount               NVARCHAR(500)  NULL,
    AdditionalCPT_AvgPatientResponsibilityAmount NVARCHAR(500) NULL,
    LabID                                     NVARCHAR(500)  NULL,
    LabName                                   NVARCHAR(500)  NULL,
    InsertedDateTime                          DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

-- ?? 1b. CodingValidationData  (archive — rows moved here before CodingValidation is replaced) ??
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CodingValidationData')
CREATE TABLE dbo.CodingValidationData
(
    ArchiveId                                 INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    OriginalReportId                          INT            NULL,       -- ReportId from CodingValidation at archive time
    ArchivedDateTime                          DATETIME       NOT NULL DEFAULT GETDATE(),
    FileLogId                                 NVARCHAR(500)  NULL,
    WeekFolder                                NVARCHAR(500)  NULL,
    SourceFilePath                            NVARCHAR(500)  NULL,
    RunNumber                                 NVARCHAR(500)  NULL,
    AccessionNo                               NVARCHAR(500)  NULL,
    VisitNumber                               NVARCHAR(500)  NULL,
    PayerName_Raw                             NVARCHAR(500)  NULL,
    Carrier                                   NVARCHAR(500)  NULL,
    Payer_Code                                NVARCHAR(500)  NULL,
    PayerCommonCode                           NVARCHAR(500)  NULL,
    Payer_Group_Code                          NVARCHAR(500)  NULL,
    Global_Payer_ID                           NVARCHAR(500)  NULL,
    PayerType                                 NVARCHAR(500)  NULL,
    BillingProvider                           NVARCHAR(500)  NULL,
    ReferringProvider                         NVARCHAR(500)  NULL,
    ClinicName                                NVARCHAR(500)  NULL,
    SalesRepname                              NVARCHAR(500)  NULL,
    PatientID                                 NVARCHAR(500)  NULL,
    PatientDOB                                NVARCHAR(500)  NULL,
    DateofService                             NVARCHAR(500)  NULL,
    ChargeEnteredDate                         NVARCHAR(500)  NULL,
    FirstBillDate                             NVARCHAR(500)  NULL,
    PanelName                                 NVARCHAR(500)  NULL,
    POS                                       NVARCHAR(500)  NULL,
    TOS                                       NVARCHAR(500)  NULL,
    TotalCharge                               NVARCHAR(500)  NULL,
    AllowedAmount                             NVARCHAR(500)  NULL,
    InsurancePayment                          NVARCHAR(500)  NULL,
    PatientPayment                            NVARCHAR(500)  NULL,
    TotalPayments                             NVARCHAR(500)  NULL,
    InsuranceAdjustments                      NVARCHAR(500)  NULL,
    PatientAdjustments                        NVARCHAR(500)  NULL,
    TotalAdjustments                          NVARCHAR(500)  NULL,
    InsuranceBalance                          NVARCHAR(500)  NULL,
    PatientBalance                            NVARCHAR(500)  NULL,
    TotalBalance                              NVARCHAR(500)  NULL,
    CheckDate                                 NVARCHAR(500)  NULL,
    ClaimStatus                               NVARCHAR(500)  NULL,
    DenialCode                                NVARCHAR(Max)  NULL,
    ICDCode                                   NVARCHAR(500)  NULL,
    DaystoDOS                                 NVARCHAR(500)  NULL,
    RollingDays                               NVARCHAR(500)  NULL,
    DaystoBill                                NVARCHAR(500)  NULL,
    DaystoPost                                NVARCHAR(500)  NULL,
    ICDPointer                                NVARCHAR(500)  NULL,
    ActualCPTCode                             NVARCHAR(MAX)  NULL,
    ExpectedCPTCode                           NVARCHAR(MAX)  NULL,
    MissingCPTCodes                           NVARCHAR(Max)  NULL,
    AdditionalCPTCodes                        NVARCHAR(Max)  NULL,
    MissingCPT_Charges                        NVARCHAR(500)  NULL,
    MissingCPT_ChargeSource                   NVARCHAR(500)  NULL,
    AdditionalCPT_Charges                     NVARCHAR(500)  NULL,
    AdditionalCPT_ChargeSource                NVARCHAR(500)  NULL,
    ExpectedCharges                           NVARCHAR(500)  NULL,
    ValidationStatus                          NVARCHAR(Max)  NULL,
    Remarks                                   NVARCHAR(Max)  NULL,
    MissingCPT_AvgAllowedAmount               NVARCHAR(500)  NULL,
    MissingCPT_AvgPaidAmount                  NVARCHAR(500)  NULL,
    MissingCPT_AvgPatientResponsibilityAmount NVARCHAR(500)  NULL,
    AdditionalCPT_AvgAllowedAmount            NVARCHAR(500)  NULL,
    AdditionalCPT_AvgPaidAmount               NVARCHAR(500)  NULL,
    AdditionalCPT_AvgPatientResponsibilityAmount NVARCHAR(500) NULL,
    LabID                                     NVARCHAR(500)  NULL,
    LabName                                   NVARCHAR(500)  NULL,
    OriginalInsertedDateTime                  DATETIME       NULL
);
GO

-- ?? 2. CodingFinancialSummary  (summary blocks from Financial Dashboard sheet) ?
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CodingFinancialSummary')
CREATE TABLE dbo.CodingFinancialSummary
(
    SummaryId                       INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    LabName                         NVARCHAR(500)  NULL,
    WeekFolder                      NVARCHAR(500)  NULL,
    SourceFilePath                  NVARCHAR(500)  NULL,
    ReportDate                      NVARCHAR(100)  NULL,
    -- Totals block
    TotalClaims                     INT            NULL,
    TotalBilledCharges              DECIMAL(18,2)  NULL,
    ExpectedBilledCharges           DECIMAL(18,2)  NULL,
    -- Revenue Impact block
    RevenueImpact_Claims            INT            NULL,
    RevenueImpact_ActualBilled      DECIMAL(18,2)  NULL,
    RevenueImpact_PotentialLoss     DECIMAL(18,2)  NULL,
    RevenueImpact_ExpectedRecoup    DECIMAL(18,2)  NULL,
    -- Revenue Loss block
    RevenueLoss_Claims              INT            NULL,
    RevenueLoss_ActualBilled        DECIMAL(18,2)  NULL,
    RevenueLoss_PotentialLoss       DECIMAL(18,2)  NULL,
    -- Revenue at Risk block
    RevenueAtRisk_Claims            INT            NULL,
    RevenueAtRisk_ActualBilled      DECIMAL(18,2)  NULL,
    RevenueAtRisk_PotentialRecoup   DECIMAL(18,2)  NULL,
    -- Compliance block
    Compliance_TotalClaims          INT            NULL,
    Compliance_ClaimsWithIssues     INT            NULL,
    ComplianceRate                  NVARCHAR(20)   NULL,
    -- Detail breakdown
    ClaimsWithMissingCPTs           INT            NULL,
    ClaimsWithAdditionalCPTs        INT            NULL,
    ClaimsWithBothMissingAndAdditional INT         NULL,
    TotalErrorClaims                INT            NULL,
    ComplianceRatePct               NVARCHAR(20)   NULL,
    InsertedDateTime                DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

-- ?? 3. TVP type for bulk-inserting CodingValidation rows ?????????????????????
IF NOT EXISTS (SELECT 1 FROM sys.types WHERE name = 'CodingValidationTVP')
CREATE TYPE dbo.CodingValidationTVP AS TABLE
(
    FileLogId                                 NVARCHAR(500),
    WeekFolder                                NVARCHAR(500),
    SourceFilePath                            NVARCHAR(500),
    RunNumber                                 NVARCHAR(500),
    AccessionNo                               NVARCHAR(500),
    VisitNumber                               NVARCHAR(500),
    PayerName_Raw                             NVARCHAR(500),
    Carrier                                   NVARCHAR(500),
    Payer_Code                                NVARCHAR(500),
    PayerCommonCode                           NVARCHAR(500),
    Payer_Group_Code                          NVARCHAR(500),
    Global_Payer_ID                           NVARCHAR(500),
    PayerType                                 NVARCHAR(500),
    BillingProvider                           NVARCHAR(500),
    ReferringProvider                         NVARCHAR(500),
    ClinicName                                NVARCHAR(500),
    SalesRepname                              NVARCHAR(500),
    PatientID                                 NVARCHAR(500),
    PatientDOB                                NVARCHAR(500),
    DateofService                             NVARCHAR(500),
    ChargeEnteredDate                         NVARCHAR(500),
    FirstBillDate                             NVARCHAR(500),
    PanelName                                 NVARCHAR(500),
    POS                                       NVARCHAR(500),
    TOS                                       NVARCHAR(500),
    TotalCharge                               NVARCHAR(500),
    AllowedAmount                             NVARCHAR(500),
    InsurancePayment                          NVARCHAR(500),
    PatientPayment                            NVARCHAR(500),
    TotalPayments                             NVARCHAR(500),
    InsuranceAdjustments                      NVARCHAR(500),
    PatientAdjustments                        NVARCHAR(500),
    TotalAdjustments                          NVARCHAR(500),
    InsuranceBalance                          NVARCHAR(500),
    PatientBalance                            NVARCHAR(500),
    TotalBalance                              NVARCHAR(500),
    CheckDate                                 NVARCHAR(500),
    ClaimStatus                               NVARCHAR(500),
    DenialCode                                NVARCHAR(Max),
    ICDCode                                   NVARCHAR(500),
    DaystoDOS                                 NVARCHAR(500),
    RollingDays                               NVARCHAR(500),
    DaystoBill                                NVARCHAR(500),
    DaystoPost                                NVARCHAR(500),
    ICDPointer                                NVARCHAR(500),
    ActualCPTCode                             NVARCHAR(MAX),
    ExpectedCPTCode                           NVARCHAR(MAX),
    MissingCPTCodes                           NVARCHAR(Max),
    AdditionalCPTCodes                        NVARCHAR(Max),
    MissingCPT_Charges                        NVARCHAR(500),
    MissingCPT_ChargeSource                   NVARCHAR(500),
    AdditionalCPT_Charges                     NVARCHAR(500),
    AdditionalCPT_ChargeSource                NVARCHAR(500),
    ExpectedCharges                           NVARCHAR(500),
    ValidationStatus                          NVARCHAR(Max),
    Remarks                                   NVARCHAR(Max),
    MissingCPT_AvgAllowedAmount               NVARCHAR(500),
    MissingCPT_AvgPaidAmount                  NVARCHAR(500),
    MissingCPT_AvgPatientResponsibilityAmount NVARCHAR(500),
    AdditionalCPT_AvgAllowedAmount            NVARCHAR(500),
    AdditionalCPT_AvgPaidAmount               NVARCHAR(500),
    AdditionalCPT_AvgPatientResponsibilityAmount NVARCHAR(500),
    LabID                                     NVARCHAR(500),
    LabName                                   NVARCHAR(500)
);
GO

-- ?? 4. Stored procedure – bulk insert CodingValidation rows ??????????????????
CREATE OR ALTER PROCEDURE dbo.usp_BulkInsertCodingValidation
    @Rows           dbo.CodingValidationTVP READONLY,
    @LabName        NVARCHAR(500),
    @WeekFolder     NVARCHAR(500),
    @SourceFilePath NVARCHAR(500),
    @RunId          NVARCHAR(500),      -- filename without extension, used as the unique run key
    @FileName       NVARCHAR(500),
    @FileCreatedDateTime DATETIME = NULL,
    @ChunkSize      INT = 1000          -- rows per archive chunk
AS
BEGIN
    SET NOCOUNT ON;

    -- ?? 1. Skip if this exact RunId was already processed ?????????????????????
    IF EXISTS (SELECT 1 FROM dbo.CodingValidationFileLog WHERE RunId = @RunId)
    BEGIN
        PRINT 'RunId already in FileLog — skipping: ' + @RunId;
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    -- ?? 2. Log this file run (FileType hardcoded = 'codingmaster') ????????????
    DECLARE @FileLogId INT;

    INSERT INTO dbo.CodingValidationFileLog
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'codingmaster', @FileCreatedDateTime);

    SET @FileLogId = SCOPE_IDENTITY();

    -- ?? 3. Archive existing rows for this lab/week into CodingValidationData ??
    --      Done in chunks to avoid large transactions on big datasets.
    IF EXISTS (
        SELECT 1 FROM dbo.CodingValidation
        WHERE LabName = @LabName AND WeekFolder = @WeekFolder
    )
    BEGIN
        DECLARE @ArchiveOffset INT = 0;
        DECLARE @ArchiveBatch  INT = 1;

        WHILE @ArchiveBatch > 0
        BEGIN
            INSERT INTO dbo.CodingValidationData
            (
                OriginalReportId, FileLogId, WeekFolder, SourceFilePath, RunNumber,
                AccessionNo, VisitNumber, PayerName_Raw, Carrier,
                Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
                BillingProvider, ReferringProvider, ClinicName, SalesRepname,
                PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
                PanelName, POS, TOS,
                TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
                InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
                InsuranceBalance, PatientBalance, TotalBalance,
                CheckDate, ClaimStatus, DenialCode, ICDCode,
                DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
                ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
                MissingCPT_Charges, MissingCPT_ChargeSource,
                AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
                ValidationStatus, Remarks,
                MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount, MissingCPT_AvgPatientResponsibilityAmount,
                AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount, AdditionalCPT_AvgPatientResponsibilityAmount,
                LabID, LabName, OriginalInsertedDateTime
            )
            SELECT
                ReportId, FileLogId, WeekFolder, SourceFilePath, RunNumber,
                AccessionNo, VisitNumber, PayerName_Raw, Carrier,
                Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
                BillingProvider, ReferringProvider, ClinicName, SalesRepname,
                PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
                PanelName, POS, TOS,
                TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
                InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
                InsuranceBalance, PatientBalance, TotalBalance,
                CheckDate, ClaimStatus, DenialCode, ICDCode,
                DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
                ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
                MissingCPT_Charges, MissingCPT_ChargeSource,
                AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
                ValidationStatus, Remarks,
                MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount, MissingCPT_AvgPatientResponsibilityAmount,
                AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount, AdditionalCPT_AvgPatientResponsibilityAmount,
                LabID, LabName, InsertedDateTime
            FROM dbo.CodingValidation
            WHERE LabName = @LabName AND WeekFolder = @WeekFolder
            ORDER BY ReportId
            OFFSET @ArchiveOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

            SET @ArchiveBatch = @@ROWCOUNT;
            SET @ArchiveOffset = @ArchiveOffset + @ChunkSize;
        END

        -- All chunks archived — delete the old live rows
        DELETE FROM dbo.CodingValidation
        WHERE LabName = @LabName AND WeekFolder = @WeekFolder;

        PRINT 'Archived and deleted existing rows for ' + @LabName + ' / ' + @WeekFolder;
    END

    -- ?? 4. Insert new rows, stamping the FileLogId from step 2 ???????????????
    DECLARE @InsertOffset INT = 0;
    DECLARE @InsertBatch  INT = 1;

    WHILE @InsertBatch > 0
    BEGIN
        INSERT INTO dbo.CodingValidation
        (
            FileLogId, WeekFolder, SourceFilePath, RunNumber,
            AccessionNo, VisitNumber, PayerName_Raw, Carrier,
            Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
            PanelName, POS, TOS,
            TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
            MissingCPT_Charges, MissingCPT_ChargeSource,
            AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
            ValidationStatus, Remarks,
            MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount, MissingCPT_AvgPatientResponsibilityAmount,
            AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount, AdditionalCPT_AvgPatientResponsibilityAmount,
            LabID, LabName
        )
        SELECT
            CAST(@FileLogId AS NVARCHAR(500)),  -- real FileLogId from file log table
            WeekFolder, SourceFilePath, RunNumber,
            AccessionNo, VisitNumber, PayerName_Raw, Carrier,
            Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
            PanelName, POS, TOS,
            TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
            MissingCPT_Charges, MissingCPT_ChargeSource,
            AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
            ValidationStatus, Remarks,
            MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount, MissingCPT_AvgPatientResponsibilityAmount,
            AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount, AdditionalCPT_AvgPatientResponsibilityAmount,
            LabID, LabName
        FROM @Rows
        ORDER BY (SELECT NULL)
        OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

        SET @InsertBatch  = @@ROWCOUNT;
        SET @InsertOffset = @InsertOffset + @ChunkSize;
    END

    PRINT 'Inserted ' + CAST(@InsertOffset AS NVARCHAR) + ' rows for ' + @LabName + ' / ' + @WeekFolder
          + ' (FileLogId=' + CAST(@FileLogId AS NVARCHAR) + ')';

    SELECT @InsertOffset AS InsertedCount;
END;
GO

-- ?? 5. Stored procedure – upsert CodingFinancialSummary ??????????????????????
CREATE OR ALTER PROCEDURE dbo.usp_UpsertCodingFinancialSummary
    @LabName                           NVARCHAR(500),
    @WeekFolder                        NVARCHAR(500),
    @SourceFilePath                    NVARCHAR(500),
    @ReportDate                        NVARCHAR(100),
    @TotalClaims                       INT,
    @TotalBilledCharges                DECIMAL(18,2),
    @ExpectedBilledCharges             DECIMAL(18,2),
    @RevenueImpact_Claims              INT,
    @RevenueImpact_ActualBilled        DECIMAL(18,2),
    @RevenueImpact_PotentialLoss       DECIMAL(18,2),
    @RevenueImpact_ExpectedRecoup      DECIMAL(18,2),
    @RevenueLoss_Claims                INT,
    @RevenueLoss_ActualBilled          DECIMAL(18,2),
    @RevenueLoss_PotentialLoss         DECIMAL(18,2),
    @RevenueAtRisk_Claims              INT,
    @RevenueAtRisk_ActualBilled        DECIMAL(18,2),
    @RevenueAtRisk_PotentialRecoup     DECIMAL(18,2),
    @Compliance_TotalClaims            INT,
    @Compliance_ClaimsWithIssues       INT,
    @ComplianceRate                    NVARCHAR(20),
    @ClaimsWithMissingCPTs             INT,
    @ClaimsWithAdditionalCPTs          INT,
    @ClaimsWithBothMissingAndAdditional INT,
    @TotalErrorClaims                  INT,
    @ComplianceRatePct                 NVARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1 FROM dbo.CodingFinancialSummary
        WHERE LabName = @LabName AND WeekFolder = @WeekFolder
    )
    BEGIN
        UPDATE dbo.CodingFinancialSummary
        SET
            SourceFilePath                     = @SourceFilePath,
            ReportDate                         = @ReportDate,
            TotalClaims                        = @TotalClaims,
            TotalBilledCharges                 = @TotalBilledCharges,
            ExpectedBilledCharges              = @ExpectedBilledCharges,
            RevenueImpact_Claims               = @RevenueImpact_Claims,
            RevenueImpact_ActualBilled         = @RevenueImpact_ActualBilled,
            RevenueImpact_PotentialLoss        = @RevenueImpact_PotentialLoss,
            RevenueImpact_ExpectedRecoup       = @RevenueImpact_ExpectedRecoup,
            RevenueLoss_Claims                 = @RevenueLoss_Claims,
            RevenueLoss_ActualBilled           = @RevenueLoss_ActualBilled,
            RevenueLoss_PotentialLoss          = @RevenueLoss_PotentialLoss,
            RevenueAtRisk_Claims               = @RevenueAtRisk_Claims,
            RevenueAtRisk_ActualBilled         = @RevenueAtRisk_ActualBilled,
            RevenueAtRisk_PotentialRecoup      = @RevenueAtRisk_PotentialRecoup,
            Compliance_TotalClaims             = @Compliance_TotalClaims,
            Compliance_ClaimsWithIssues        = @Compliance_ClaimsWithIssues,
            ComplianceRate                     = @ComplianceRate,
            ClaimsWithMissingCPTs              = @ClaimsWithMissingCPTs,
            ClaimsWithAdditionalCPTs           = @ClaimsWithAdditionalCPTs,
            ClaimsWithBothMissingAndAdditional = @ClaimsWithBothMissingAndAdditional,
            TotalErrorClaims                   = @TotalErrorClaims,
            ComplianceRatePct                  = @ComplianceRatePct,
            InsertedDateTime                   = GETDATE()
        WHERE LabName = @LabName AND WeekFolder = @WeekFolder;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.CodingFinancialSummary
        (
            LabName, WeekFolder, SourceFilePath, ReportDate,
            TotalClaims, TotalBilledCharges, ExpectedBilledCharges,
            RevenueImpact_Claims, RevenueImpact_ActualBilled, RevenueImpact_PotentialLoss, RevenueImpact_ExpectedRecoup,
            RevenueLoss_Claims, RevenueLoss_ActualBilled, RevenueLoss_PotentialLoss,
            RevenueAtRisk_Claims, RevenueAtRisk_ActualBilled, RevenueAtRisk_PotentialRecoup,
            Compliance_TotalClaims, Compliance_ClaimsWithIssues, ComplianceRate,
            ClaimsWithMissingCPTs, ClaimsWithAdditionalCPTs, ClaimsWithBothMissingAndAdditional,
            TotalErrorClaims, ComplianceRatePct
        )
        VALUES
        (
            @LabName, @WeekFolder, @SourceFilePath, @ReportDate,
            @TotalClaims, @TotalBilledCharges, @ExpectedBilledCharges,
            @RevenueImpact_Claims, @RevenueImpact_ActualBilled, @RevenueImpact_PotentialLoss, @RevenueImpact_ExpectedRecoup,
            @RevenueLoss_Claims, @RevenueLoss_ActualBilled, @RevenueLoss_PotentialLoss,
            @RevenueAtRisk_Claims, @RevenueAtRisk_ActualBilled, @RevenueAtRisk_PotentialRecoup,
            @Compliance_TotalClaims, @Compliance_ClaimsWithIssues, @ComplianceRate,
            @ClaimsWithMissingCPTs, @ClaimsWithAdditionalCPTs, @ClaimsWithBothMissingAndAdditional,
            @TotalErrorClaims, @ComplianceRatePct
        );
    END
END;
GO

-- ?? 6. Views for YTD / WTD reports ???????????????????????????????????????????
CREATE OR ALTER VIEW dbo.vw_CodingInsights_YTD AS
SELECT
    LabName,
    YEAR(TRY_CAST(DateofService AS DATE))   AS ServiceYear,
    PanelName,
    ValidationStatus,
    COUNT(*)                                AS TotalClaims,
    SUM(TRY_CAST(TotalCharge    AS DECIMAL(18,2)))  AS TotalCharge,
    SUM(TRY_CAST(AllowedAmount  AS DECIMAL(18,2)))  AS AllowedAmount,
    SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2)))  AS TotalBalance
FROM dbo.CodingValidation
WHERE YEAR(TRY_CAST(DateofService AS DATE)) = YEAR(GETDATE())
GROUP BY
    LabName,
    YEAR(TRY_CAST(DateofService AS DATE)),
    PanelName,
    ValidationStatus;
GO

CREATE OR ALTER VIEW dbo.vw_CodingSummary_YTD AS
SELECT
    LabName,
    YEAR(InsertedDateTime)         AS SummaryYear,
    SUM(TotalClaims)               AS TotalClaims,
    SUM(TotalBilledCharges)        AS TotalBilledCharges,
    SUM(ExpectedBilledCharges)     AS ExpectedBilledCharges,
    SUM(RevenueImpact_PotentialLoss) AS TotalPotentialLoss,
    SUM(RevenueAtRisk_PotentialRecoup) AS TotalPotentialRecoup,
    SUM(Compliance_ClaimsWithIssues)   AS TotalClaimsWithIssues
FROM dbo.CodingFinancialSummary
WHERE YEAR(InsertedDateTime) = YEAR(GETDATE())
GROUP BY LabName, YEAR(InsertedDateTime);
GO

CREATE OR ALTER VIEW dbo.vw_CodingInsights_WTD AS
SELECT
    LabName,
    WeekFolder,
    PanelName,
    ValidationStatus,
    COUNT(*)                                AS TotalClaims,
    SUM(TRY_CAST(TotalCharge    AS DECIMAL(18,2)))  AS TotalCharge,
    SUM(TRY_CAST(AllowedAmount  AS DECIMAL(18,2)))  AS AllowedAmount,
    SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2)))  AS TotalBalance
FROM dbo.CodingValidation cv
WHERE WeekFolder = (
    SELECT TOP 1 WeekFolder
    FROM dbo.CodingValidation
    WHERE LabName = cv.LabName
    ORDER BY InsertedDateTime DESC
)
GROUP BY LabName, WeekFolder, PanelName, ValidationStatus;
GO

CREATE OR ALTER VIEW dbo.vw_CodingSummary_WTD AS
SELECT TOP (1) WITH TIES
    LabName,
    WeekFolder,
    TotalClaims,
    TotalBilledCharges,
    ExpectedBilledCharges,
    RevenueImpact_PotentialLoss,
    RevenueAtRisk_PotentialRecoup,
    ComplianceRate,
    ComplianceRatePct,
    Compliance_ClaimsWithIssues,
    ClaimsWithMissingCPTs,
    ClaimsWithAdditionalCPTs
FROM dbo.CodingFinancialSummary
ORDER BY ROW_NUMBER() OVER (PARTITION BY LabName ORDER BY InsertedDateTime DESC);
GO
