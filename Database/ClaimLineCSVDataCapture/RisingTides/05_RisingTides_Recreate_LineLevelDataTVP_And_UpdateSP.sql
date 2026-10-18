SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.usp_BulkInsertLineLevelData', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_BulkInsertLineLevelData;
GO

IF TYPE_ID('dbo.LineLevelDataTVP') IS NOT NULL
    DROP TYPE dbo.LineLevelDataTVP;
GO

CREATE TYPE dbo.LineLevelDataTVP AS TABLE
(
    FileLogId            NVARCHAR(500),
    RunId                NVARCHAR(500),
    WeekFolder           NVARCHAR(500),
    SourceFullPath       NVARCHAR(1000),
    FileName             NVARCHAR(500),
    FileType             NVARCHAR(100),
    RowHash              NVARCHAR(64),
    LabID                NVARCHAR(500),
    LabName              NVARCHAR(500),
    ClaimID              NVARCHAR(500),
    AccessionNumber      NVARCHAR(500),
    SourceFileID         NVARCHAR(1000),
    IngestedOn           NVARCHAR(500),
    CsvRowHash           NVARCHAR(500),
    PayerName_Raw        NVARCHAR(500),
    PayerName            NVARCHAR(500),
    Payer_Code           NVARCHAR(500),
    Payer_Common_Code    NVARCHAR(500),
    Payer_Group_Code     NVARCHAR(500),
    Global_Payer_ID      NVARCHAR(500),
    PayerType            NVARCHAR(500),
    BillingProvider      NVARCHAR(500),
    ReferringProvider    NVARCHAR(500),
    ClinicName           NVARCHAR(500),
    SalesRepname         NVARCHAR(500),
    PatientID            NVARCHAR(500),
    PatientDOB           NVARCHAR(500),
    DateofService        NVARCHAR(500),
    ChargeEnteredDate    NVARCHAR(500),
    FirstBilledDate      NVARCHAR(500),
    Panelname            NVARCHAR(500),
    CPTCode              NVARCHAR(500),
    Units                NVARCHAR(500),
    Modifier             NVARCHAR(500),
    POS                  NVARCHAR(500),
    TOS                  NVARCHAR(500),
    ChargeAmount         NVARCHAR(500),
    ChargeAmountPerUnit  NVARCHAR(500),
    AllowedAmount        NVARCHAR(500),
    AllowedAmountPerUnit NVARCHAR(500),
    InsurancePayment     NVARCHAR(500),
    InsurancePaymentPerUnit NVARCHAR(500),
    PatientPayment       NVARCHAR(500),
    PatientPaymentPerUnit NVARCHAR(500),
    TotalPayments        NVARCHAR(500),
    InsuranceAdjustments NVARCHAR(500),
    PatientAdjustments   NVARCHAR(500),
    TotalAdjustments     NVARCHAR(500),
    InsuranceBalance     NVARCHAR(500),
    PatientBalance       NVARCHAR(500),
    PatientBalancePerUnit NVARCHAR(500),
    TotalBalance         NVARCHAR(500),
    CheckDate            NVARCHAR(500),
    PostingDate          NVARCHAR(500),
    PaymentPostedDate    NVARCHAR(500),
    ClaimStatus          NVARCHAR(500),
    PayStatus            NVARCHAR(500),
    DenialCode           NVARCHAR(MAX),
    DenialDate           NVARCHAR(500),
    ICDCode              NVARCHAR(500),
    DaystoDOS            NVARCHAR(500),
    RollingDays          NVARCHAR(500),
    DaystoBill           NVARCHAR(500),
    DaystoPost           NVARCHAR(500),
    ICDPointer           NVARCHAR(500),
    Facility             NVARCHAR(500),
    PatientName          NVARCHAR(1000),
    ResponsibleParty     NVARCHAR(500),
    SubscriberId         NVARCHAR(500),
    ClientAccNum         NVARCHAR(500),
    EndDOS               NVARCHAR(500),
    BillOccurance        NVARCHAR(500),
    EntryUser            NVARCHAR(500),
    CPTUnits             NVARCHAR(500),
    CPTMOD               NVARCHAR(500),
    CPTs                 NVARCHAR(MAX),
    PostedWeek           NVARCHAR(500)
);
GO

CREATE PROCEDURE dbo.usp_BulkInsertLineLevelData
    @Rows dbo.LineLevelDataTVP READONLY,
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

    IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'linelevel')
    BEGIN
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    DECLARE @FileLogId INT;
    INSERT INTO dbo.LineClaimFileLogs (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'linelevel', @FileCreatedDateTime);
    SET @FileLogId = SCOPE_IDENTITY();

    IF EXISTS (SELECT 1 FROM dbo.LineLevelData)
    BEGIN
        INSERT INTO dbo.LineLevelDataArchive
        (
            OriginalRecordId, ArchiveRemark,
            FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
            LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
            PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
            Panelname, CPTCode, Units, Modifier, POS, TOS,
            ChargeAmount, ChargeAmountPerUnit, AllowedAmount, AllowedAmountPerUnit,
            InsurancePayment, InsurancePaymentPerUnit, PatientPayment, PatientPaymentPerUnit,
            TotalPayments, InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, PatientBalancePerUnit, TotalBalance,
            CheckDate, PostingDate, PaymentPostedDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
            ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            Facility, PatientName, ResponsibleParty, SubscriberId, ClientAccNum, EndDOS,
            BillOccurance, EntryUser, CPTUnits, CPTMOD, CPTs, PostedWeek,
            OriginalInsertedDateTime
        )
        SELECT
            l.RecordId,
            'row_replaced',
            l.FileLogId, l.RunId, l.WeekFolder, l.SourceFullPath, l.FileName, l.FileType, l.RowHash,
            l.LabID, l.LabName, l.ClaimID, l.AccessionNumber, l.SourceFileID, l.IngestedOn, l.CsvRowHash,
            l.PayerName_Raw, l.PayerName, l.Payer_Code, l.Payer_Common_Code, l.Payer_Group_Code, l.Global_Payer_ID, l.PayerType,
            l.BillingProvider, l.ReferringProvider, l.ClinicName, l.SalesRepname,
            l.PatientID, l.PatientDOB, l.DateofService, l.ChargeEnteredDate, l.FirstBilledDate,
            l.Panelname, l.CPTCode, l.Units, l.Modifier, l.POS, l.TOS,
            l.ChargeAmount, l.ChargeAmountPerUnit, l.AllowedAmount, l.AllowedAmountPerUnit,
            l.InsurancePayment, l.InsurancePaymentPerUnit, l.PatientPayment, l.PatientPaymentPerUnit,
            l.TotalPayments, l.InsuranceAdjustments, l.PatientAdjustments, l.TotalAdjustments,
            l.InsuranceBalance, l.PatientBalance, l.PatientBalancePerUnit, l.TotalBalance,
            l.CheckDate, l.PostingDate, l.PaymentPostedDate, l.ClaimStatus, l.PayStatus, l.DenialCode, l.DenialDate,
            l.ICDCode, l.DaystoDOS, l.RollingDays, l.DaystoBill, l.DaystoPost, l.ICDPointer,
            l.Facility, l.PatientName, l.ResponsibleParty, l.SubscriberId, l.ClientAccNum, l.EndDOS,
            l.BillOccurance, l.EntryUser, l.CPTUnits, l.CPTMOD, l.CPTs, l.PostedWeek,
            l.InsertedDateTime
        FROM dbo.LineLevelData l;

        DELETE FROM dbo.LineLevelData;
    END

    INSERT INTO dbo.LineLevelData
    (
        FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
        LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
        PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
        BillingProvider, ReferringProvider, ClinicName, SalesRepname,
        PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
        Panelname, CPTCode, Units, Modifier, POS, TOS,
        ChargeAmount, ChargeAmountPerUnit, AllowedAmount, AllowedAmountPerUnit,
        InsurancePayment, InsurancePaymentPerUnit, PatientPayment, PatientPaymentPerUnit,
        TotalPayments, InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
        InsuranceBalance, PatientBalance, PatientBalancePerUnit, TotalBalance,
        CheckDate, PostingDate, PaymentPostedDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
        ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
        Facility, PatientName, ResponsibleParty, SubscriberId, ClientAccNum, EndDOS,
        BillOccurance, EntryUser, CPTUnits, CPTMOD, CPTs, PostedWeek
    )
    SELECT
        CAST(@FileLogId AS NVARCHAR(500)), RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
        LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
        PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
        BillingProvider, ReferringProvider, ClinicName, SalesRepname,
        PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
        Panelname, CPTCode, Units, Modifier, POS, TOS,
        ChargeAmount, ChargeAmountPerUnit, AllowedAmount, AllowedAmountPerUnit,
        InsurancePayment, InsurancePaymentPerUnit, PatientPayment, PatientPaymentPerUnit,
        TotalPayments, InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
        InsuranceBalance, PatientBalance, PatientBalancePerUnit, TotalBalance,
        CheckDate, COALESCE(NULLIF(PostingDate,''), PaymentPostedDate), PaymentPostedDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
        ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
        Facility, PatientName, ResponsibleParty, SubscriberId, ClientAccNum, EndDOS,
        BillOccurance, EntryUser, CPTUnits, CPTMOD, CPTs, PostedWeek
    FROM @Rows;

    SELECT @@ROWCOUNT AS InsertedCount;
END;
GO

PRINT 'RisingTides LineLevel TVP/SP recreate script completed.';
