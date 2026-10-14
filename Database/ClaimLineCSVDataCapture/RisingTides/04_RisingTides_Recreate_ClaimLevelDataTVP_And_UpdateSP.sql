SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.usp_BulkInsertClaimLevelData', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_BulkInsertClaimLevelData;
GO

IF TYPE_ID('dbo.ClaimLevelDataTVP') IS NOT NULL
    DROP TYPE dbo.ClaimLevelDataTVP;
GO

CREATE TYPE dbo.ClaimLevelDataTVP AS TABLE
(
    FileLogId                     NVARCHAR(500),
    RunId                         NVARCHAR(500),
    WeekFolder                    NVARCHAR(500),
    SourceFullPath                NVARCHAR(1000),
    FileName                      NVARCHAR(500),
    FileType                      NVARCHAR(100),
    RowHash                       NVARCHAR(64),
    LabID                         NVARCHAR(500),
    LabName                       NVARCHAR(500),
    ClaimID                       NVARCHAR(500),
    AccessionNumber               NVARCHAR(500),
    SourceFileID                  NVARCHAR(1000),
    IngestedOn                    NVARCHAR(500),
    CsvRowHash                    NVARCHAR(500),
    PayerName_Raw                 NVARCHAR(500),
    PayerName                     NVARCHAR(500),
    Payer_Code                    NVARCHAR(500),
    Payer_Common_Code             NVARCHAR(500),
    Payer_Group_Code              NVARCHAR(500),
    Global_Payer_ID               NVARCHAR(500),
    PayerType                     NVARCHAR(500),
    BillingProvider               NVARCHAR(500),
    ReferringProvider             NVARCHAR(500),
    ClinicName                    NVARCHAR(500),
    SalesRepname                  NVARCHAR(500),
    PatientID                     NVARCHAR(500),
    PatientDOB                    NVARCHAR(500),
    DateofService                 NVARCHAR(500),
    ChargeEnteredDate             NVARCHAR(500),
    FirstBilledDate               NVARCHAR(500),
    Panelname                     NVARCHAR(500),
    CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX),
    CPTCodeXUnitsXModifier        NVARCHAR(MAX),
    POS                           NVARCHAR(500),
    TOS                           NVARCHAR(500),
    ChargeAmount                  NVARCHAR(500),
    AllowedAmount                 NVARCHAR(500),
    InsurancePayment              NVARCHAR(500),
    PatientPayment                NVARCHAR(500),
    TotalPayments                 NVARCHAR(500),
    InsuranceAdjustments          NVARCHAR(500),
    PatientAdjustments            NVARCHAR(500),
    TotalAdjustments              NVARCHAR(500),
    InsuranceBalance              NVARCHAR(500),
    PatientBalance                NVARCHAR(500),
    TotalBalance                  NVARCHAR(500),
    CheckDate                     NVARCHAR(500),
    ClaimStatus                   NVARCHAR(500),
    DenialCode                    NVARCHAR(MAX),
    ICDCode                       NVARCHAR(500),
    DaystoDOS                     NVARCHAR(500),
    RollingDays                   NVARCHAR(500),
    DaystoBill                    NVARCHAR(500),
    DaystoPost                    NVARCHAR(500),
    ICDPointer                    NVARCHAR(500),
    Facility                      NVARCHAR(500),
    PatientName                   NVARCHAR(1000),
    BilledUnbilled                NVARCHAR(100),
    ModifierField                 NVARCHAR(500),
    PaymentPercent                NVARCHAR(100),
    Aging                         NVARCHAR(100),
    AgingBucket                   NVARCHAR(200),
    BilledWeek                    NVARCHAR(500),
    PostedWeek                    NVARCHAR(500),
    FullyPaidCount                NVARCHAR(500),
    FullyPaidAmount               NVARCHAR(500),
    AdjucticatedCount             NVARCHAR(500),
    AdjucticatedAmount            NVARCHAR(500),
    Bucket30Count                 NVARCHAR(500),
    Bucket30Amount                NVARCHAR(500),
    Bucket60Count                 NVARCHAR(500),
    Bucket60Amount                NVARCHAR(500),
    DOE_Year                      NVARCHAR(20),
    DOE_Month                     NVARCHAR(20)
);
GO

CREATE PROCEDURE dbo.usp_BulkInsertClaimLevelData
    @Rows dbo.ClaimLevelDataTVP READONLY,
    @LabName NVARCHAR(500),
    @WeekFolder NVARCHAR(500),
    @SourceFilePath NVARCHAR(1000),
    @RunId NVARCHAR(500),
    @FileName NVARCHAR(500),
    @FileCreatedDateTime DATETIME = NULL,
    @ChunkSize INT = 5000
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'claimlevel')
    BEGIN
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    DECLARE @FileLogId INT;
    INSERT INTO dbo.LineClaimFileLogs (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'claimlevel', @FileCreatedDateTime);
    SET @FileLogId = SCOPE_IDENTITY();

    IF EXISTS (SELECT 1 FROM dbo.ClaimLevelData)
    BEGIN
        INSERT INTO dbo.ClaimLevelDataArchive
        (
            OriginalRecordId, ArchiveRemark,
            FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
            LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
            PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
            Panelname, CPTCodeXUnitsXModifierOrginal, CPTCodeXUnitsXModifier, POS, TOS,
            ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            Facility, PatientName, BilledUnbilled, ModifierField, PaymentPercent,
            Aging, AgingBucket, BilledWeek, PostedWeek,
            FullyPaidCount, FullyPaidAmount, AdjucticatedCount, AdjucticatedAmount,
            Bucket30Count, Bucket30Amount, Bucket60Count, Bucket60Amount,
            DOE_Year, DOE_Month,
            OriginalInsertedDateTime
        )
        SELECT
            c.RecordId, 'row_replaced',
            c.FileLogId, c.RunId, c.WeekFolder, c.SourceFullPath, c.FileName, c.FileType, c.RowHash,
            c.LabID, c.LabName, c.ClaimID, c.AccessionNumber, c.SourceFileID, c.IngestedOn, c.CsvRowHash,
            c.PayerName_Raw, c.PayerName, c.Payer_Code, c.Payer_Common_Code, c.Payer_Group_Code, c.Global_Payer_ID, c.PayerType,
            c.BillingProvider, c.ReferringProvider, c.ClinicName, c.SalesRepname,
            c.PatientID, c.PatientDOB, c.DateofService, c.ChargeEnteredDate, c.FirstBilledDate,
            c.Panelname, c.CPTCodeXUnitsXModifierOrginal, c.CPTCodeXUnitsXModifier, c.POS, c.TOS,
            c.ChargeAmount, c.AllowedAmount, c.InsurancePayment, c.PatientPayment, c.TotalPayments,
            c.InsuranceAdjustments, c.PatientAdjustments, c.TotalAdjustments,
            c.InsuranceBalance, c.PatientBalance, c.TotalBalance,
            c.CheckDate, c.ClaimStatus, c.DenialCode, c.ICDCode,
            c.DaystoDOS, c.RollingDays, c.DaystoBill, c.DaystoPost, c.ICDPointer,
            c.Facility, c.PatientName, c.BilledUnbilled, c.ModifierField, c.PaymentPercent,
            c.Aging, c.AgingBucket, c.BilledWeek, c.PostedWeek,
            c.FullyPaidCount, c.FullyPaidAmount, c.AdjucticatedCount, c.AdjucticatedAmount,
            c.Bucket30Count, c.Bucket30Amount, c.Bucket60Count, c.Bucket60Amount,
            c.DOE_Year, c.DOE_Month,
            c.InsertedDateTime
        FROM dbo.ClaimLevelData c;

        DELETE FROM dbo.ClaimLevelData;
    END

    INSERT INTO dbo.ClaimLevelData
    (
        FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
        LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
        PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
        BillingProvider, ReferringProvider, ClinicName, SalesRepname,
        PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
        Panelname, CPTCodeXUnitsXModifierOrginal, CPTCodeXUnitsXModifier, POS, TOS,
        ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
        InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
        InsuranceBalance, PatientBalance, TotalBalance,
        CheckDate, ClaimStatus, DenialCode, ICDCode,
        DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
        Facility, PatientName, BilledUnbilled, ModifierField, PaymentPercent,
        Aging, AgingBucket, BilledWeek, PostedWeek,
        FullyPaidCount, FullyPaidAmount, AdjucticatedCount, AdjucticatedAmount,
        Bucket30Count, Bucket30Amount, Bucket60Count, Bucket60Amount,
        DOE_Year, DOE_Month
    )
    SELECT
        CAST(@FileLogId AS NVARCHAR(500)), RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
        LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
        PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
        BillingProvider, ReferringProvider, ClinicName, SalesRepname,
        PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
        Panelname, CPTCodeXUnitsXModifierOrginal, CPTCodeXUnitsXModifier, POS, TOS,
        ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
        InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
        InsuranceBalance, PatientBalance, TotalBalance,
        CheckDate, ClaimStatus, DenialCode, ICDCode,
        DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
        Facility, PatientName, BilledUnbilled, ModifierField, PaymentPercent,
        Aging, AgingBucket, BilledWeek, PostedWeek,
        FullyPaidCount, FullyPaidAmount, AdjucticatedCount, AdjucticatedAmount,
        Bucket30Count, Bucket30Amount, Bucket60Count, Bucket60Amount,
        DOE_Year, DOE_Month
    FROM @Rows;

    SELECT @@ROWCOUNT AS InsertedCount;
END;
GO

PRINT 'RisingTides ClaimLevel TVP/SP recreate script completed.';
