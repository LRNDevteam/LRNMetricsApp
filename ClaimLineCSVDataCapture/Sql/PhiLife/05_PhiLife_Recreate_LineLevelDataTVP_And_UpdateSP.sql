SET NOCOUNT ON;
GO

PRINT 'Dropping stored procedure dbo.usp_BulkInsertLineLevelData if it exists...';
IF OBJECT_ID('dbo.usp_BulkInsertLineLevelData', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE dbo.usp_BulkInsertLineLevelData;
END
GO

PRINT 'Dropping type dbo.LineLevelDataTVP if it exists...';
IF TYPE_ID('dbo.LineLevelDataTVP') IS NOT NULL
BEGIN
    DROP TYPE dbo.LineLevelDataTVP;
END
GO

PRINT 'Creating type dbo.LineLevelDataTVP (PhiLife)...';
-- Column order MUST match the field order in PhiLifeFieldMappings.Json LineLevel > Fields.
-- System columns (FileLogId..RowHash) are always first; then all mapped SQL columns in JSON order.
CREATE TYPE dbo.LineLevelDataTVP AS TABLE
(
    -- System columns (injected by the application)
    FileLogId                       NVARCHAR(500),
    RunId                           NVARCHAR(500),
    WeekFolder                      NVARCHAR(500),
    SourceFullPath                  NVARCHAR(1000),
    FileName                        NVARCHAR(500),
    FileType                        NVARCHAR(100),
    RowHash                         NVARCHAR(64),

    -- CSV-mapped columns (in PhiLifeFieldMappings.Json LineLevel field order)
    LabID                           NVARCHAR(500),
    LabName                         NVARCHAR(500),
    ClaimID                         NVARCHAR(500),
    AccessionNumber                 NVARCHAR(500),
    SourceFileID                    NVARCHAR(1000),
    IngestedOn                      NVARCHAR(500),
    CsvRowHash                      NVARCHAR(500),
    PayerName_Raw                   NVARCHAR(500),
    PayerName                       NVARCHAR(500),
    Payer_Code                      NVARCHAR(500),
    Payer_Common_Code               NVARCHAR(500),
    Payer_Group_Code                NVARCHAR(500),
    Global_Payer_ID                 NVARCHAR(500),
    PayerType                       NVARCHAR(500),
    BillingProvider                 NVARCHAR(500),
    ReferringProvider               NVARCHAR(500),
    ClinicName                      NVARCHAR(500),
    SalesRepname                    NVARCHAR(500),
    PatientID                       NVARCHAR(500),
    PatientDOB                      NVARCHAR(500),
    DateofService                   NVARCHAR(500),
    ChargeEnteredDate               NVARCHAR(500),
    FirstBilledDate                 NVARCHAR(500),
    Panelname                       NVARCHAR(500),
    CPTCodeXUnitsXModifierOrginal   NVARCHAR(MAX),
    CPTCodeXUnitsXModifier          NVARCHAR(MAX),
    POS                             NVARCHAR(500),
    TOS                             NVARCHAR(500),
    ChargeAmount                    NVARCHAR(500),
    AllowedAmount                   NVARCHAR(500),
    InsurancePayment                NVARCHAR(500),
    PatientPayment                  NVARCHAR(500),
    TotalPayments                   NVARCHAR(500),
    InsuranceAdjustments            NVARCHAR(500),
    PatientAdjustments              NVARCHAR(500),
    TotalAdjustments                NVARCHAR(500),
    InsuranceBalance                NVARCHAR(500),
    PatientBalance                  NVARCHAR(500),
    TotalBalance                    NVARCHAR(500),
    CheckDate                       NVARCHAR(500),
    ClaimStatus                     NVARCHAR(500),
    DenialCode                      NVARCHAR(MAX),
    ICDCode                         NVARCHAR(500),
    DaystoDOS                       NVARCHAR(500),
    RollingDays                     NVARCHAR(500),
    DaystoBill                      NVARCHAR(500),
    DaystoPost                      NVARCHAR(500),
    ICDPointer                      NVARCHAR(500),
    PatientName                     NVARCHAR(1000),
    BilledUnbilled                  NVARCHAR(100),
    Modifier                        NVARCHAR(500),
    PaymentPercent                  NVARCHAR(100),
    Aging                           NVARCHAR(100),
    AgingBucket                     NVARCHAR(200),
    BilledWeek                      NVARCHAR(500),
    PostedWeek                      NVARCHAR(500),
    FullyPaidCount                  NVARCHAR(500),
    FullyPaidAmount                 NVARCHAR(500),
    AdjudicatedCount                NVARCHAR(500),
    AdjudicatedAmount               NVARCHAR(500),
    Days30Count                     NVARCHAR(500),
    Days30Amount                    NVARCHAR(500),
    Days60Count                     NVARCHAR(500),
    Days60Amount                    NVARCHAR(500),
    DOE_Year                        NVARCHAR(20),
    DOE_Month                       NVARCHAR(20)
);
GO

CREATE PROCEDURE dbo.usp_BulkInsertLineLevelData
    @Rows                dbo.LineLevelDataTVP READONLY,
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

    -- Archive existing rows before full replacement
    IF EXISTS (SELECT 1 FROM dbo.LineLevelData)
    BEGIN
        --INSERT INTO dbo.LineLevelDataArchive
        --(
        --    OriginalRecordId, ArchiveRemark,
        --    FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
        --    LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
        --    PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
        --    BillingProvider, ReferringProvider, ClinicName, SalesRepname,
        --    PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
        --    Panelname, CPTCodeXUnitsXModifierOrginal, CPTCodeXUnitsXModifier, POS, TOS,
        --    ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
        --    InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
        --    InsuranceBalance, PatientBalance, TotalBalance,
        --    CheckDate, ClaimStatus, DenialCode, ICDCode,
        --    ICDPointer, PatientName, BilledUnbilled, Modifier, PaymentPercent,
        --    Aging, AgingBucket, BilledWeek, PostedWeek,
        --    FullyPaidCount, FullyPaidAmount, AdjudicatedCount, AdjudicatedAmount,
        --    Days30Count, Days30Amount, Days60Count, Days60Amount,
        --    DOE_Year, DOE_Month,
        --    OriginalInsertedDateTime
        --)
        --SELECT
        --    l.RecordId,
        --    'row_replaced',
        --    l.FileLogId, l.RunId, l.WeekFolder, l.SourceFullPath, l.FileName, l.FileType, l.RowHash,
        --    l.LabID, l.LabName, l.ClaimID, l.AccessionNumber, l.SourceFileID, l.IngestedOn, l.CsvRowHash,
        --    l.PayerName_Raw, l.PayerName, l.Payer_Code, l.Payer_Common_Code, l.Payer_Group_Code, l.Global_Payer_ID, l.PayerType,
        --    l.BillingProvider, l.ReferringProvider, l.ClinicName, l.SalesRepname,
        --    l.PatientID, l.PatientDOB, l.DateofService, l.ChargeEnteredDate, l.FirstBilledDate,
        --    l.Panelname, l.CPTCodeXUnitsXModifierOrginal, l.CPTCodeXUnitsXModifier, l.POS, l.TOS,
        --    l.ChargeAmount, l.AllowedAmount, l.InsurancePayment, l.PatientPayment, l.TotalPayments,
        --    l.InsuranceAdjustments, l.PatientAdjustments, l.TotalAdjustments,
        --    l.InsuranceBalance, l.PatientBalance, l.TotalBalance,
        --    l.CheckDate, l.ClaimStatus, l.DenialCode, l.ICDCode,
        --    l.ICDPointer, l.PatientName, l.BilledUnbilled, l.Modifier, l.PaymentPercent,
        --    l.Aging, l.AgingBucket, l.BilledWeek, l.PostedWeek,
        --    l.FullyPaidCount, l.FullyPaidAmount, l.AdjudicatedCount, l.AdjudicatedAmount,
        --    l.Days30Count, l.Days30Amount, l.Days60Count, l.Days60Amount,
        --    l.DOE_Year, l.DOE_Month,
        --    l.InsertedDateTime
        --FROM dbo.LineLevelData l;

        DELETE FROM dbo.LineLevelData;
    END

    DECLARE @InsertOffset INT = 0;
    DECLARE @InsertBatch  INT = 1;

    WHILE @InsertBatch > 0
    BEGIN
        INSERT INTO dbo.LineLevelData
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
            PatientName, BilledUnbilled, Modifier, PaymentPercent,
            Aging, AgingBucket, BilledWeek, PostedWeek,
            FullyPaidCount, FullyPaidAmount, AdjudicatedCount, AdjudicatedAmount,
            Days30Count, Days30Amount, Days60Count, Days60Amount,
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
            PatientName, BilledUnbilled, Modifier, PaymentPercent,
            Aging, AgingBucket, BilledWeek, PostedWeek,
            FullyPaidCount, FullyPaidAmount, AdjudicatedCount, AdjudicatedAmount,
            Days30Count, Days30Amount, Days60Count, Days60Amount,
            DOE_Year, DOE_Month
        FROM @Rows
        ORDER BY (SELECT NULL)
        OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

        SET @InsertBatch  = @@ROWCOUNT;
        SET @InsertOffset = @InsertOffset + @ChunkSize;
    END

    SELECT @InsertOffset AS InsertedCount;
END;
GO

PRINT 'PhiLife LineLevel TVP/SP recreate script completed.';
