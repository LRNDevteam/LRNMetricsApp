/*
    Analyze Pathology - ClaimLevel TVP type and insert procedure for ClaimLineCSVDataCapture.
    Run against the ANALYZE PATHOLOGY lab database. Re-runnable (drops and recreates both).

    GENERATED from LRN.MasterFileProcessorWorker/Schemas/LabMappings/AnalyzePathologyFieldMappings.json:
    the 7 system columns, then every ClaimLevel field in the mapping's own order. ClaimLineCSVDataCapture
    sends this TVP positionally, so the type must match the mapping - regenerate this file whenever
    the mapping changes rather than editing the column list by hand.

    The insert names every column on both sides, so the table's own column order does not matter.
    Analyze Pathology has no archive table: the previous load is replaced, exactly as
    LRN.MasterFileProcessorWorker does with TRUNCATE.

    The type is Analyze-only (dbo.ClaimLevelDataTVP_AnalyzePathology), so it is never blocked by another object that
    still uses the shared type (e.g. a *_bkp copy of the procedure). The mapping's TvpTypeName names it.
*/
SET NOCOUNT ON;
GO

-- 1. Every mapped column must exist before the procedure can be created. Adds only what is missing.
IF COL_LENGTH('dbo.ClaimLevelData', 'FileLogId') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [FileLogId] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'RunId') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [RunId] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'WeekFolder') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [WeekFolder] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SourceFullPath') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [SourceFullPath] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'FileName') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [FileName] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'FileType') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [FileType] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'RowHash') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [RowHash] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LabID') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [LabID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LabName') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [LabName] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimID') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ClaimID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'AccessionNumber') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [AccessionNumber] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SourceFileID') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [SourceFileID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'IngestedOn') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [IngestedOn] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CsvRowHash') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [CsvRowHash] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PayerName_Raw') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PayerName_Raw] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PayerName') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PayerName] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Payer_Code') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Payer_Code] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Payer_Common_Code') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Payer_Common_Code] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Payer_Group_Code') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Payer_Group_Code] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Global_Payer_ID') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Global_Payer_ID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PayerType') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PayerType] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'BillingProvider') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [BillingProvider] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ReferringProvider') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ReferringProvider] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClinicName') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ClinicName] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SalesRepname') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [SalesRepname] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PatientID') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PatientID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PatientDOB') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PatientDOB] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DateofService') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [DateofService] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeEnteredDate') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ChargeEnteredDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'FirstBilledDate') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [FirstBilledDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LastBilledDate') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [LastBilledDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Panelname') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Panelname] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CPTCodeXUnitsXModifierOrginal') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [CPTCodeXUnitsXModifierOrginal] NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CPTCodeXUnitsXModifier') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [CPTCodeXUnitsXModifier] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'POS') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [POS] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TOS') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [TOS] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeAmount') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ChargeAmount] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'AllowedAmount') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [AllowedAmount] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'InsurancePayment') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [InsurancePayment] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PatientPayment') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PatientPayment] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TotalPayments') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [TotalPayments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'InsuranceAdjustments') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [InsuranceAdjustments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PatientAdjustments') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PatientAdjustments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TotalAdjustments') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [TotalAdjustments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'InsuranceBalance') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [InsuranceBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PatientBalance') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PatientBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TotalBalance') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [TotalBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TotalInsuranceBalance') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [TotalInsuranceBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OtherBalance') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [OtherBalance] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CheckDate') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [CheckDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimStatus') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ClaimStatus] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DenialCode') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [DenialCode] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DenialDate') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [DenialDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ICDCode') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ICDCode] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ICDPointer') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ICDPointer] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DaystoDOS') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [DaystoDOS] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'RollingDays') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [RollingDays] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DaystoBill') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [DaystoBill] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DaystoPost') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [DaystoPost] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimUID') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ClaimUID] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'AgingDOS') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [AgingDOS] NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Facility') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Facility] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PatientName') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PatientName] NVARCHAR(1000) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SubscriberId') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [SubscriberId] NVARCHAR(1000) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'BilledWeek') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [BilledWeek] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'BilledStatus') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [BilledStatus] NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PostedWeek') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PostedWeek] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PaymentPercent') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [PaymentPercent] NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'FullyPaidCount') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [FullyPaidCount] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'FullyPaidAmount') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [FullyPaidAmount] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Adjudicated') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Adjudicated] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'AdjudicatedAmount') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [AdjudicatedAmount] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Bucket30') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Bucket30] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Bucket30Amount') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Bucket30Amount] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Bucket60') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Bucket60] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Bucket60Amount') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [Bucket60Amount] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CPTCodeList') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [CPTCodeList] NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'UnitsList') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [UnitsList] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ModifierList') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ModifierList] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CptWithUnits') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [CptWithUnits] NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeToDate') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ChargeToDate] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalPayments') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ChargeTotalPayments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalAdjustments') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [ChargeTotalAdjustments] NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OrderingProviderID') IS NULL ALTER TABLE dbo.ClaimLevelData ADD [OrderingProviderID] NVARCHAR(500) NULL;
GO

-- 2. Procedure first (it depends on the type), then the type.
IF OBJECT_ID('dbo.usp_BulkInsertClaimLevelData', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_BulkInsertClaimLevelData;
GO

IF TYPE_ID('dbo.ClaimLevelDataTVP_AnalyzePathology') IS NOT NULL
    DROP TYPE dbo.ClaimLevelDataTVP_AnalyzePathology;
GO

CREATE TYPE dbo.ClaimLevelDataTVP_AnalyzePathology AS TABLE
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
    CPTCodeXUnitsXModifierOrginal  NVARCHAR(MAX),
    CPTCodeXUnitsXModifier         NVARCHAR(MAX),
    POS                            NVARCHAR(MAX),
    TOS                            NVARCHAR(MAX),
    ChargeAmount                   NVARCHAR(MAX),
    AllowedAmount                  NVARCHAR(MAX),
    InsurancePayment               NVARCHAR(MAX),
    PatientPayment                 NVARCHAR(MAX),
    TotalPayments                  NVARCHAR(MAX),
    InsuranceAdjustments           NVARCHAR(MAX),
    PatientAdjustments             NVARCHAR(MAX),
    TotalAdjustments               NVARCHAR(MAX),
    InsuranceBalance               NVARCHAR(MAX),
    PatientBalance                 NVARCHAR(MAX),
    TotalBalance                   NVARCHAR(MAX),
    TotalInsuranceBalance          NVARCHAR(MAX),
    OtherBalance                   NVARCHAR(MAX),
    CheckDate                      NVARCHAR(MAX),
    ClaimStatus                    NVARCHAR(MAX),
    DenialCode                     NVARCHAR(MAX),
    DenialDate                     NVARCHAR(MAX),
    ICDCode                        NVARCHAR(MAX),
    ICDPointer                     NVARCHAR(MAX),
    DaystoDOS                      NVARCHAR(MAX),
    RollingDays                    NVARCHAR(MAX),
    DaystoBill                     NVARCHAR(MAX),
    DaystoPost                     NVARCHAR(MAX),
    ClaimUID                       NVARCHAR(MAX),
    AgingDOS                       NVARCHAR(MAX),
    Facility                       NVARCHAR(MAX),
    PatientName                    NVARCHAR(MAX),
    SubscriberId                   NVARCHAR(MAX),
    BilledWeek                     NVARCHAR(MAX),
    BilledStatus                   NVARCHAR(MAX),
    PostedWeek                     NVARCHAR(MAX),
    PaymentPercent                 NVARCHAR(MAX),
    FullyPaidCount                 NVARCHAR(MAX),
    FullyPaidAmount                NVARCHAR(MAX),
    Adjudicated                    NVARCHAR(MAX),
    AdjudicatedAmount              NVARCHAR(MAX),
    Bucket30                       NVARCHAR(MAX),
    Bucket30Amount                 NVARCHAR(MAX),
    Bucket60                       NVARCHAR(MAX),
    Bucket60Amount                 NVARCHAR(MAX),
    CPTCodeList                    NVARCHAR(MAX),
    UnitsList                      NVARCHAR(MAX),
    ModifierList                   NVARCHAR(MAX),
    CptWithUnits                   NVARCHAR(MAX),
    ChargeToDate                   NVARCHAR(MAX),
    ChargeTotalPayments            NVARCHAR(MAX),
    ChargeTotalAdjustments         NVARCHAR(MAX),
    OrderingProviderID             NVARCHAR(MAX)
);
GO

CREATE PROCEDURE dbo.usp_BulkInsertClaimLevelData
    @Rows                dbo.ClaimLevelDataTVP_AnalyzePathology READONLY,
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

    IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'claimlevel')
    BEGIN
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    DECLARE @FileLogId INT;

    INSERT INTO dbo.LineClaimFileLogs
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'claimlevel', @FileCreatedDateTime);

    SET @FileLogId = SCOPE_IDENTITY();

    DELETE FROM dbo.ClaimLevelData;

    DECLARE @InsertOffset INT = 0;
    DECLARE @InsertBatch  INT = 1;
    DECLARE @Inserted     INT = 0;

    WHILE @InsertBatch > 0
    BEGIN
        INSERT INTO dbo.ClaimLevelData
            ([FileLogId], [RunId], [WeekFolder], [SourceFullPath], [FileName], [FileType], [RowHash], [LabID], [LabName], [ClaimID], [AccessionNumber], [SourceFileID], [IngestedOn], [CsvRowHash], [PayerName_Raw], [PayerName], [Payer_Code], [Payer_Common_Code], [Payer_Group_Code], [Global_Payer_ID], [PayerType], [BillingProvider], [ReferringProvider], [ClinicName], [SalesRepname], [PatientID], [PatientDOB], [DateofService], [ChargeEnteredDate], [FirstBilledDate], [LastBilledDate], [Panelname], [CPTCodeXUnitsXModifierOrginal], [CPTCodeXUnitsXModifier], [POS], [TOS], [ChargeAmount], [AllowedAmount], [InsurancePayment], [PatientPayment], [TotalPayments], [InsuranceAdjustments], [PatientAdjustments], [TotalAdjustments], [InsuranceBalance], [PatientBalance], [TotalBalance], [TotalInsuranceBalance], [OtherBalance], [CheckDate], [ClaimStatus], [DenialCode], [DenialDate], [ICDCode], [ICDPointer], [DaystoDOS], [RollingDays], [DaystoBill], [DaystoPost], [ClaimUID], [AgingDOS], [Facility], [PatientName], [SubscriberId], [BilledWeek], [BilledStatus], [PostedWeek], [PaymentPercent], [FullyPaidCount], [FullyPaidAmount], [Adjudicated], [AdjudicatedAmount], [Bucket30], [Bucket30Amount], [Bucket60], [Bucket60Amount], [CPTCodeList], [UnitsList], [ModifierList], [CptWithUnits], [ChargeToDate], [ChargeTotalPayments], [ChargeTotalAdjustments], [OrderingProviderID])
        SELECT
            CAST(@FileLogId AS NVARCHAR(500)), [RunId], [WeekFolder], [SourceFullPath], [FileName], [FileType], [RowHash], [LabID], [LabName], [ClaimID], [AccessionNumber], [SourceFileID], [IngestedOn], [CsvRowHash], [PayerName_Raw], [PayerName], [Payer_Code], [Payer_Common_Code], [Payer_Group_Code], [Global_Payer_ID], [PayerType], [BillingProvider], [ReferringProvider], [ClinicName], [SalesRepname], [PatientID], [PatientDOB], [DateofService], [ChargeEnteredDate], [FirstBilledDate], [LastBilledDate], [Panelname], [CPTCodeXUnitsXModifierOrginal], [CPTCodeXUnitsXModifier], [POS], [TOS], [ChargeAmount], [AllowedAmount], [InsurancePayment], [PatientPayment], [TotalPayments], [InsuranceAdjustments], [PatientAdjustments], [TotalAdjustments], [InsuranceBalance], [PatientBalance], [TotalBalance], [TotalInsuranceBalance], [OtherBalance], [CheckDate], [ClaimStatus], [DenialCode], [DenialDate], [ICDCode], [ICDPointer], [DaystoDOS], [RollingDays], [DaystoBill], [DaystoPost], [ClaimUID], [AgingDOS], [Facility], [PatientName], [SubscriberId], [BilledWeek], [BilledStatus], [PostedWeek], [PaymentPercent], [FullyPaidCount], [FullyPaidAmount], [Adjudicated], [AdjudicatedAmount], [Bucket30], [Bucket30Amount], [Bucket60], [Bucket60Amount], [CPTCodeList], [UnitsList], [ModifierList], [CptWithUnits], [ChargeToDate], [ChargeTotalPayments], [ChargeTotalAdjustments], [OrderingProviderID]
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

PRINT 'Analyze Pathology ClaimLevel TVP/SP created.';
GO