/*
    Analyze Pathology - LineLevel TVP type and insert procedure for ClaimLineCSVDataCapture.
    Run against the ANALYZE PATHOLOGY lab database. Re-runnable (drops and recreates both).

    GENERATED from LRN.MasterFileProcessorWorker/Schemas/LabMappings/AnalyzePathologyFieldMappings.json:
    the 7 system columns, then every LineLevel field in the mapping's own order. ClaimLineCSVDataCapture
    sends this TVP positionally, so the type must match the mapping - regenerate this file whenever
    the mapping changes rather than editing the column list by hand.

    The insert names every column on both sides, so the table's own column order does not matter.
    Analyze Pathology has no archive table: the previous load is replaced, exactly as
    LRN.MasterFileProcessorWorker does with TRUNCATE.

    The type is Analyze-only (dbo.LineLevelDataTVP_AnalyzePathology), so it is never blocked by another object that
    still uses the shared type (e.g. a *_bkp copy of the procedure). The mapping's TvpTypeName names it.
*/
SET NOCOUNT ON;
GO

-- 1. Every mapped column must exist before the procedure can be created. Adds only what is missing.
IF COL_LENGTH('dbo.LineLevelData', 'FileLogId') IS NULL ALTER TABLE dbo.LineLevelData ADD [FileLogId] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'RunId') IS NULL ALTER TABLE dbo.LineLevelData ADD [RunId] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'WeekFolder') IS NULL ALTER TABLE dbo.LineLevelData ADD [WeekFolder] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SourceFullPath') IS NULL ALTER TABLE dbo.LineLevelData ADD [SourceFullPath] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'FileName') IS NULL ALTER TABLE dbo.LineLevelData ADD [FileName] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'FileType') IS NULL ALTER TABLE dbo.LineLevelData ADD [FileType] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'RowHash') IS NULL ALTER TABLE dbo.LineLevelData ADD [RowHash] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LabID') IS NULL ALTER TABLE dbo.LineLevelData ADD [LabID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LabName') IS NULL ALTER TABLE dbo.LineLevelData ADD [LabName] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimID') IS NULL ALTER TABLE dbo.LineLevelData ADD [ClaimID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'AccessionNumber') IS NULL ALTER TABLE dbo.LineLevelData ADD [AccessionNumber] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SourceFileID') IS NULL ALTER TABLE dbo.LineLevelData ADD [SourceFileID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'IngestedOn') IS NULL ALTER TABLE dbo.LineLevelData ADD [IngestedOn] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CsvRowHash') IS NULL ALTER TABLE dbo.LineLevelData ADD [CsvRowHash] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PayerName_Raw') IS NULL ALTER TABLE dbo.LineLevelData ADD [PayerName_Raw] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PayerName') IS NULL ALTER TABLE dbo.LineLevelData ADD [PayerName] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Payer_Code') IS NULL ALTER TABLE dbo.LineLevelData ADD [Payer_Code] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Payer_Common_Code') IS NULL ALTER TABLE dbo.LineLevelData ADD [Payer_Common_Code] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Payer_Group_Code') IS NULL ALTER TABLE dbo.LineLevelData ADD [Payer_Group_Code] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Global_Payer_ID') IS NULL ALTER TABLE dbo.LineLevelData ADD [Global_Payer_ID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PayerType') IS NULL ALTER TABLE dbo.LineLevelData ADD [PayerType] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'BillingProvider') IS NULL ALTER TABLE dbo.LineLevelData ADD [BillingProvider] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ReferringProvider') IS NULL ALTER TABLE dbo.LineLevelData ADD [ReferringProvider] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClinicName') IS NULL ALTER TABLE dbo.LineLevelData ADD [ClinicName] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SalesRepname') IS NULL ALTER TABLE dbo.LineLevelData ADD [SalesRepname] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientID') IS NULL ALTER TABLE dbo.LineLevelData ADD [PatientID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientDOB') IS NULL ALTER TABLE dbo.LineLevelData ADD [PatientDOB] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DateofService') IS NULL ALTER TABLE dbo.LineLevelData ADD [DateofService] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeEnteredDate') IS NULL ALTER TABLE dbo.LineLevelData ADD [ChargeEnteredDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'FirstBilledDate') IS NULL ALTER TABLE dbo.LineLevelData ADD [FirstBilledDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LastBilledDate') IS NULL ALTER TABLE dbo.LineLevelData ADD [LastBilledDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Panelname') IS NULL ALTER TABLE dbo.LineLevelData ADD [Panelname] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CPTCode') IS NULL ALTER TABLE dbo.LineLevelData ADD [CPTCode] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Units') IS NULL ALTER TABLE dbo.LineLevelData ADD [Units] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Modifier') IS NULL ALTER TABLE dbo.LineLevelData ADD [Modifier] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'POS') IS NULL ALTER TABLE dbo.LineLevelData ADD [POS] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TOS') IS NULL ALTER TABLE dbo.LineLevelData ADD [TOS] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeAmount') IS NULL ALTER TABLE dbo.LineLevelData ADD [ChargeAmount] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeAmountPerUnit') IS NULL ALTER TABLE dbo.LineLevelData ADD [ChargeAmountPerUnit] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'AllowedAmount') IS NULL ALTER TABLE dbo.LineLevelData ADD [AllowedAmount] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'AllowedAmountPerUnit') IS NULL ALTER TABLE dbo.LineLevelData ADD [AllowedAmountPerUnit] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'InsurancePayment') IS NULL ALTER TABLE dbo.LineLevelData ADD [InsurancePayment] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'InsurancePaymentPerUnit') IS NULL ALTER TABLE dbo.LineLevelData ADD [InsurancePaymentPerUnit] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientPayment') IS NULL ALTER TABLE dbo.LineLevelData ADD [PatientPayment] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientPaymentPerUnit') IS NULL ALTER TABLE dbo.LineLevelData ADD [PatientPaymentPerUnit] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TotalPayments') IS NULL ALTER TABLE dbo.LineLevelData ADD [TotalPayments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'InsuranceAdjustments') IS NULL ALTER TABLE dbo.LineLevelData ADD [InsuranceAdjustments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientAdjustments') IS NULL ALTER TABLE dbo.LineLevelData ADD [PatientAdjustments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TotalAdjustments') IS NULL ALTER TABLE dbo.LineLevelData ADD [TotalAdjustments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'InsuranceBalance') IS NULL ALTER TABLE dbo.LineLevelData ADD [InsuranceBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientBalance') IS NULL ALTER TABLE dbo.LineLevelData ADD [PatientBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientBalancePerUnit') IS NULL ALTER TABLE dbo.LineLevelData ADD [PatientBalancePerUnit] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TotalBalance') IS NULL ALTER TABLE dbo.LineLevelData ADD [TotalBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TotalInsuranceBalance') IS NULL ALTER TABLE dbo.LineLevelData ADD [TotalInsuranceBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OtherBalance') IS NULL ALTER TABLE dbo.LineLevelData ADD [OtherBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CheckDate') IS NULL ALTER TABLE dbo.LineLevelData ADD [CheckDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PostingDate') IS NULL ALTER TABLE dbo.LineLevelData ADD [PostingDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PaymentPostedDate') IS NULL ALTER TABLE dbo.LineLevelData ADD [PaymentPostedDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimStatus') IS NULL ALTER TABLE dbo.LineLevelData ADD [ClaimStatus] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PayStatus') IS NULL ALTER TABLE dbo.LineLevelData ADD [PayStatus] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DenialCode') IS NULL ALTER TABLE dbo.LineLevelData ADD [DenialCode] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DenialDate') IS NULL ALTER TABLE dbo.LineLevelData ADD [DenialDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ICDCode') IS NULL ALTER TABLE dbo.LineLevelData ADD [ICDCode] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ICDPointer') IS NULL ALTER TABLE dbo.LineLevelData ADD [ICDPointer] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DaystoDOS') IS NULL ALTER TABLE dbo.LineLevelData ADD [DaystoDOS] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'RollingDays') IS NULL ALTER TABLE dbo.LineLevelData ADD [RollingDays] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DaystoBill') IS NULL ALTER TABLE dbo.LineLevelData ADD [DaystoBill] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DaystoPost') IS NULL ALTER TABLE dbo.LineLevelData ADD [DaystoPost] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LineLevelUID') IS NULL ALTER TABLE dbo.LineLevelData ADD [LineLevelUID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'UID') IS NULL ALTER TABLE dbo.LineLevelData ADD [UID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Facility') IS NULL ALTER TABLE dbo.LineLevelData ADD [Facility] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientName') IS NULL ALTER TABLE dbo.LineLevelData ADD [PatientName] NVARCHAR(1000) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SubscriberId') IS NULL ALTER TABLE dbo.LineLevelData ADD [SubscriberId] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CptWithUnits') IS NULL ALTER TABLE dbo.LineLevelData ADD [CptWithUnits] NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CPTModifier') IS NULL ALTER TABLE dbo.LineLevelData ADD [CPTModifier] NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimCPTs') IS NULL ALTER TABLE dbo.LineLevelData ADD [ClaimCPTs] NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeToDate') IS NULL ALTER TABLE dbo.LineLevelData ADD [ChargeToDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeTotalPayments') IS NULL ALTER TABLE dbo.LineLevelData ADD [ChargeTotalPayments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeTotalAdjustments') IS NULL ALTER TABLE dbo.LineLevelData ADD [ChargeTotalAdjustments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OrderingProviderID') IS NULL ALTER TABLE dbo.LineLevelData ADD [OrderingProviderID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TF') IS NULL ALTER TABLE dbo.LineLevelData ADD [TF] NVARCHAR(10) NULL;
GO

-- 2. Procedure first (it depends on the type), then the type.
IF OBJECT_ID('dbo.usp_BulkInsertLineLevelData', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_BulkInsertLineLevelData;
GO

IF TYPE_ID('dbo.LineLevelDataTVP_AnalyzePathology') IS NOT NULL
    DROP TYPE dbo.LineLevelDataTVP_AnalyzePathology;
GO

CREATE TYPE dbo.LineLevelDataTVP_AnalyzePathology AS TABLE
(
    FileLogId                      NVARCHAR(500),
    RunId                          NVARCHAR(500),
    WeekFolder                     NVARCHAR(500),
    SourceFullPath                 NVARCHAR(1000),
    FileName                       NVARCHAR(500),
    FileType                       NVARCHAR(100),
    RowHash                        NVARCHAR(64),
    LabID                          NVARCHAR(MAX),
    LabName                        NVARCHAR(MAX),
    ClaimID                        NVARCHAR(MAX),
    AccessionNumber                NVARCHAR(MAX),
    SourceFileID                   NVARCHAR(MAX),
    IngestedOn                     NVARCHAR(MAX),
    CsvRowHash                     NVARCHAR(MAX),
    PayerName_Raw                  NVARCHAR(MAX),
    PayerName                      NVARCHAR(MAX),
    Payer_Code                     NVARCHAR(MAX),
    Payer_Common_Code              NVARCHAR(MAX),
    Payer_Group_Code               NVARCHAR(MAX),
    Global_Payer_ID                NVARCHAR(MAX),
    PayerType                      NVARCHAR(MAX),
    BillingProvider                NVARCHAR(MAX),
    ReferringProvider              NVARCHAR(MAX),
    ClinicName                     NVARCHAR(MAX),
    SalesRepname                   NVARCHAR(MAX),
    PatientID                      NVARCHAR(MAX),
    PatientDOB                     NVARCHAR(MAX),
    DateofService                  NVARCHAR(MAX),
    ChargeEnteredDate              NVARCHAR(MAX),
    FirstBilledDate                NVARCHAR(MAX),
    LastBilledDate                 NVARCHAR(MAX),
    Panelname                      NVARCHAR(MAX),
    CPTCode                        NVARCHAR(MAX),
    Units                          NVARCHAR(MAX),
    Modifier                       NVARCHAR(MAX),
    POS                            NVARCHAR(MAX),
    TOS                            NVARCHAR(MAX),
    ChargeAmount                   NVARCHAR(MAX),
    ChargeAmountPerUnit            NVARCHAR(MAX),
    AllowedAmount                  NVARCHAR(MAX),
    AllowedAmountPerUnit           NVARCHAR(MAX),
    InsurancePayment               NVARCHAR(MAX),
    InsurancePaymentPerUnit        NVARCHAR(MAX),
    PatientPayment                 NVARCHAR(MAX),
    PatientPaymentPerUnit          NVARCHAR(MAX),
    TotalPayments                  NVARCHAR(MAX),
    InsuranceAdjustments           NVARCHAR(MAX),
    PatientAdjustments             NVARCHAR(MAX),
    TotalAdjustments               NVARCHAR(MAX),
    InsuranceBalance               NVARCHAR(MAX),
    PatientBalance                 NVARCHAR(MAX),
    PatientBalancePerUnit          NVARCHAR(MAX),
    TotalBalance                   NVARCHAR(MAX),
    TotalInsuranceBalance          NVARCHAR(MAX),
    OtherBalance                   NVARCHAR(MAX),
    CheckDate                      NVARCHAR(MAX),
    PostingDate                    NVARCHAR(MAX),
    PaymentPostedDate              NVARCHAR(MAX),
    ClaimStatus                    NVARCHAR(MAX),
    PayStatus                      NVARCHAR(MAX),
    DenialCode                     NVARCHAR(MAX),
    DenialDate                     NVARCHAR(MAX),
    ICDCode                        NVARCHAR(MAX),
    ICDPointer                     NVARCHAR(MAX),
    DaystoDOS                      NVARCHAR(MAX),
    RollingDays                    NVARCHAR(MAX),
    DaystoBill                     NVARCHAR(MAX),
    DaystoPost                     NVARCHAR(MAX),
    LineLevelUID                   NVARCHAR(MAX),
    UID                            NVARCHAR(MAX),
    Facility                       NVARCHAR(MAX),
    PatientName                    NVARCHAR(MAX),
    SubscriberId                   NVARCHAR(MAX),
    CptWithUnits                   NVARCHAR(MAX),
    CPTModifier                    NVARCHAR(MAX),
    ClaimCPTs                      NVARCHAR(MAX),
    ChargeToDate                   NVARCHAR(MAX),
    ChargeTotalPayments            NVARCHAR(MAX),
    ChargeTotalAdjustments         NVARCHAR(MAX),
    OrderingProviderID             NVARCHAR(MAX),
    TF                             NVARCHAR(MAX)
);
GO

CREATE PROCEDURE dbo.usp_BulkInsertLineLevelData
    @Rows                dbo.LineLevelDataTVP_AnalyzePathology READONLY,
    @LabName             NVARCHAR(500),
    @WeekFolder          NVARCHAR(500),
    @SourceFilePath      NVARCHAR(1000),
    @RunId               NVARCHAR(500),
    @FileName            NVARCHAR(500),
    @FileCreatedDateTime DATETIME = NULL,
    @ChunkSize           INT = 5000
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'linelevel')
    BEGIN
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    DECLARE @FileLogId INT;

    INSERT INTO dbo.LineClaimFileLogs
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'linelevel', @FileCreatedDateTime);

    SET @FileLogId = SCOPE_IDENTITY();

    DELETE FROM dbo.LineLevelData;

    DECLARE @InsertOffset INT = 0;
    DECLARE @InsertBatch  INT = 1;
    DECLARE @Inserted     INT = 0;

    WHILE @InsertBatch > 0
    BEGIN
        INSERT INTO dbo.LineLevelData
            ([FileLogId], [RunId], [WeekFolder], [SourceFullPath], [FileName], [FileType], [RowHash], [LabID], [LabName], [ClaimID], [AccessionNumber], [SourceFileID], [IngestedOn], [CsvRowHash], [PayerName_Raw], [PayerName], [Payer_Code], [Payer_Common_Code], [Payer_Group_Code], [Global_Payer_ID], [PayerType], [BillingProvider], [ReferringProvider], [ClinicName], [SalesRepname], [PatientID], [PatientDOB], [DateofService], [ChargeEnteredDate], [FirstBilledDate], [LastBilledDate], [Panelname], [CPTCode], [Units], [Modifier], [POS], [TOS], [ChargeAmount], [ChargeAmountPerUnit], [AllowedAmount], [AllowedAmountPerUnit], [InsurancePayment], [InsurancePaymentPerUnit], [PatientPayment], [PatientPaymentPerUnit], [TotalPayments], [InsuranceAdjustments], [PatientAdjustments], [TotalAdjustments], [InsuranceBalance], [PatientBalance], [PatientBalancePerUnit], [TotalBalance], [TotalInsuranceBalance], [OtherBalance], [CheckDate], [PostingDate], [PaymentPostedDate], [ClaimStatus], [PayStatus], [DenialCode], [DenialDate], [ICDCode], [ICDPointer], [DaystoDOS], [RollingDays], [DaystoBill], [DaystoPost], [LineLevelUID], [UID], [Facility], [PatientName], [SubscriberId], [CptWithUnits], [CPTModifier], [ClaimCPTs], [ChargeToDate], [ChargeTotalPayments], [ChargeTotalAdjustments], [OrderingProviderID], [TF])
        SELECT
            CAST(@FileLogId AS NVARCHAR(500)), [RunId], [WeekFolder], [SourceFullPath], [FileName], [FileType], [RowHash], [LabID], [LabName], [ClaimID], [AccessionNumber], [SourceFileID], [IngestedOn], [CsvRowHash], [PayerName_Raw], [PayerName], [Payer_Code], [Payer_Common_Code], [Payer_Group_Code], [Global_Payer_ID], [PayerType], [BillingProvider], [ReferringProvider], [ClinicName], [SalesRepname], [PatientID], [PatientDOB], [DateofService], [ChargeEnteredDate], [FirstBilledDate], [LastBilledDate], [Panelname], [CPTCode], [Units], [Modifier], [POS], [TOS], [ChargeAmount], [ChargeAmountPerUnit], [AllowedAmount], [AllowedAmountPerUnit], [InsurancePayment], [InsurancePaymentPerUnit], [PatientPayment], [PatientPaymentPerUnit], [TotalPayments], [InsuranceAdjustments], [PatientAdjustments], [TotalAdjustments], [InsuranceBalance], [PatientBalance], [PatientBalancePerUnit], [TotalBalance], [TotalInsuranceBalance], [OtherBalance], [CheckDate], [PostingDate], [PaymentPostedDate], [ClaimStatus], [PayStatus], [DenialCode], [DenialDate], [ICDCode], [ICDPointer], [DaystoDOS], [RollingDays], [DaystoBill], [DaystoPost], [LineLevelUID], [UID], [Facility], [PatientName], [SubscriberId], [CptWithUnits], [CPTModifier], [ClaimCPTs], [ChargeToDate], [ChargeTotalPayments], [ChargeTotalAdjustments], [OrderingProviderID], [TF]
        FROM @Rows
        ORDER BY (SELECT NULL)
        OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

        SET @InsertBatch  = @@ROWCOUNT;
        SET @Inserted     = @Inserted + @InsertBatch;
        SET @InsertOffset = @InsertOffset + @ChunkSize;
    END

    SELECT @Inserted AS InsertedCount;
END;
GO

PRINT 'Analyze Pathology LineLevel TVP/SP created.';
GO