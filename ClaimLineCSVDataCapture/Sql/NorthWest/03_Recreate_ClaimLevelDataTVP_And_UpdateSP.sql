-- Drop and recreate ClaimLevelDataTVP and recreate usp_BulkInsertClaimLevelData
-- Run on the target database. This script will:
-- 1) DROP the stored procedure that references the TVP (if exists)
-- 2) DROP the TVP type (if exists)
-- 3) CREATE the TVP type with the updated column list
-- 4) CREATE the stored procedure that accepts the TVP

SET NOCOUNT ON;
GO

PRINT 'Dropping stored procedure dbo.usp_BulkInsertClaimLevelData if it exists...';
IF OBJECT_ID('dbo.usp_BulkInsertClaimLevelData', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE dbo.usp_BulkInsertClaimLevelData;
    PRINT 'Dropped stored procedure dbo.usp_BulkInsertClaimLevelData.';
END
ELSE
    PRINT 'Stored procedure dbo.usp_BulkInsertClaimLevelData does not exist.';

PRINT 'Dropping type dbo.ClaimLevelDataTVP if it exists...';
IF TYPE_ID('dbo.ClaimLevelDataTVP') IS NOT NULL
BEGIN
    DROP TYPE dbo.ClaimLevelDataTVP;
    PRINT 'Dropped type dbo.ClaimLevelDataTVP.';
END
ELSE
    PRINT 'Type dbo.ClaimLevelDataTVP does not exist.';

PRINT 'Creating type dbo.ClaimLevelDataTVP...';
CREATE TYPE dbo.ClaimLevelDataTVP AS TABLE
(
    FileLogId             NVARCHAR(500),
    RunId                 NVARCHAR(500),
    WeekFolder            NVARCHAR(500),
    SourceFullPath        NVARCHAR(1000),
    FileName              NVARCHAR(500),
    FileType              NVARCHAR(100),
    RowHash               NVARCHAR(64),
    LabID                 NVARCHAR(500),
    LabName               NVARCHAR(500),
    ClaimID               NVARCHAR(500),
    AccessionNumber       NVARCHAR(500),
    SourceFileID          NVARCHAR(1000),
    IngestedOn            NVARCHAR(500),
    CsvRowHash            NVARCHAR(500),
    PayerName_Raw         NVARCHAR(500),
    PayerName             NVARCHAR(500),
    Payer_Code            NVARCHAR(500),
    Payer_Common_Code     NVARCHAR(500),
    Payer_Group_Code      NVARCHAR(500),
    Global_Payer_ID       NVARCHAR(500),
    PayerType             NVARCHAR(500),
    BillingProvider       NVARCHAR(500),
    ReferringProvider     NVARCHAR(500),
    ClinicName            NVARCHAR(500),
    SalesRepname          NVARCHAR(500),
    PatientID             NVARCHAR(500),
    PatientDOB            NVARCHAR(500),
    DateofService         NVARCHAR(500),
    ChargeEnteredDate     NVARCHAR(500),
    FirstBilledDate       NVARCHAR(500),
    Panelname             NVARCHAR(500),
    CPTCodeXUnitsXModifier NVARCHAR(MAX),
    POS                   NVARCHAR(500),
    TOS                   NVARCHAR(500),
    ChargeAmount          NVARCHAR(500),
    AllowedAmount         NVARCHAR(500),
    InsurancePayment      NVARCHAR(500),
    PatientPayment        NVARCHAR(500),
    TotalPayments         NVARCHAR(500),
    InsuranceAdjustments  NVARCHAR(500),
    PatientAdjustments    NVARCHAR(500),
    TotalAdjustments      NVARCHAR(500),
    InsuranceBalance      NVARCHAR(500),
    PatientBalance        NVARCHAR(500),
    TotalBalance          NVARCHAR(500),
    CheckDate             NVARCHAR(500),
    ClaimStatus           NVARCHAR(500),
    DenialCode            NVARCHAR(MAX),
    ICDCode               NVARCHAR(500),
    DaystoDOS             NVARCHAR(500),
    RollingDays           NVARCHAR(500),
    DaystoBill            NVARCHAR(500),
    DaystoPost            NVARCHAR(500),
    ICDPointer            NVARCHAR(500),
    UID                   NVARCHAR(500),
    Aging                 NVARCHAR(100),
    PatientName           NVARCHAR(1000),
    LISPatientName        NVARCHAR(1000),
    SubscriberId          NVARCHAR(1000),
    PanelType             NVARCHAR(MAX),
    EnteredWeek           NVARCHAR(500),
    EnteredStatus         NVARCHAR(1000),
    LastActivityDate      NVARCHAR(100),
    EmedixSubmissionDate  NVARCHAR(100),
    ClaimType             NVARCHAR(MAX),
    BilledStatus          NVARCHAR(MAX),
    BilledWeek            NVARCHAR(500),
    PostedWeek            NVARCHAR(500),
    ModField              NVARCHAR(100),
    CheqNo                NVARCHAR(500),
    DuplicatePaymentPosted NVARCHAR(100),
    ActualPayment         NVARCHAR(500),
    ProcTotalBal          NVARCHAR(500),
    DeniedStatus          NVARCHAR(500),
    ScrubberEditReason    NVARCHAR(MAX),
    EmedixRejectionDate   NVARCHAR(100),
    EmedixRejection       NVARCHAR(Max),
    RejectionCategory     NVARCHAR(MAX),
    TimeToPay             NVARCHAR(500),
    PaymentPercent        NVARCHAR(100),
    FullyPaidCount        NVARCHAR(500),
    FullyPaidAmount       NVARCHAR(500),
    Adjudicated           NVARCHAR(500),
    AdjudicatedAmount     NVARCHAR(500),
    Bucket30              NVARCHAR(500),
    Bucket30Amount        NVARCHAR(500),
    Bucket60              NVARCHAR(500),
    Bucket60Amount        NVARCHAR(500)
);
GO

PRINT 'Creating stored procedure dbo.usp_BulkInsertClaimLevelData...';
Go
-- Recreate the stored procedure. This is the updated SP that expects the new TVP definition.
CREATE PROCEDURE dbo.usp_BulkInsertClaimLevelData
    @Rows               dbo.ClaimLevelDataTVP READONLY,
    @LabName            NVARCHAR(500),
    @WeekFolder         NVARCHAR(500),
    @SourceFilePath     NVARCHAR(1000),
    @RunId              NVARCHAR(500),
    @FileName           NVARCHAR(500),
    @FileCreatedDateTime DATETIME = NULL,
    @ChunkSize          INT = 5000
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'claimlevel')
    BEGIN
        PRINT 'RunId already in FileLog for claimlevel — skipping: ' + @RunId;
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    DECLARE @FileLogId INT;

    INSERT INTO dbo.LineClaimFileLogs
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'claimlevel', @FileCreatedDateTime);

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
            Panelname, CPTCodeXUnitsXModifier, POS, TOS,
            ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            ICDPointer,
            UID, Aging, PatientName, LISPatientName, SubscriberId, PanelType,
            EnteredWeek, EnteredStatus, LastActivityDate, EmedixSubmissionDate,
            ClaimType, BilledStatus, BilledWeek, PostedWeek, ModField, CheqNo,
            DuplicatePaymentPosted, ActualPayment, ProcTotalBal, DeniedStatus,
            ScrubberEditReason, EmedixRejectionDate, EmedixRejection, RejectionCategory,
            TimeToPay, PaymentPercent, FullyPaidCount, FullyPaidAmount,
            Adjudicated, AdjudicatedAmount, Bucket30, Bucket30Amount,
            Bucket60, Bucket60Amount,
            OriginalInsertedDateTime
        )
        SELECT
            c.RecordId,
            'data_changed: ' +
                CASE WHEN ISNULL(c.PayerName_Raw,'')      <> ISNULL(n.PayerName_Raw,'')      THEN 'PayerName_Raw,' ELSE '' END +
                CASE WHEN ISNULL(c.PayerName,'')          <> ISNULL(n.PayerName,'')          THEN 'PayerName,' ELSE '' END +
                CASE WHEN ISNULL(c.Payer_Code,'')         <> ISNULL(n.Payer_Code,'')         THEN 'Payer_Code,' ELSE '' END +
                CASE WHEN ISNULL(c.Payer_Common_Code,'')  <> ISNULL(n.Payer_Common_Code,'')  THEN 'Payer_Common_Code,' ELSE '' END +
                CASE WHEN ISNULL(c.Payer_Group_Code,'')   <> ISNULL(n.Payer_Group_Code,'')   THEN 'Payer_Group_Code,' ELSE '' END +
                CASE WHEN ISNULL(c.Global_Payer_ID,'')    <> ISNULL(n.Global_Payer_ID,'')    THEN 'Global_Payer_ID,' ELSE '' END +
                CASE WHEN ISNULL(c.PayerType,'')          <> ISNULL(n.PayerType,'')          THEN 'PayerType,' ELSE '' END +
                CASE WHEN ISNULL(c.BillingProvider,'')    <> ISNULL(n.BillingProvider,'')    THEN 'BillingProvider,' ELSE '' END +
                CASE WHEN ISNULL(c.ReferringProvider,'')  <> ISNULL(n.ReferringProvider,'')  THEN 'ReferringProvider,' ELSE '' END +
                CASE WHEN ISNULL(c.ClinicName,'')         <> ISNULL(n.ClinicName,'')         THEN 'ClinicName,' ELSE '' END +
                CASE WHEN ISNULL(c.SalesRepname,'')       <> ISNULL(n.SalesRepname,'')       THEN 'SalesRepname,' ELSE '' END +
                CASE WHEN ISNULL(c.PatientID,'')          <> ISNULL(n.PatientID,'')          THEN 'PatientID,' ELSE '' END +
                CASE WHEN ISNULL(c.PatientDOB,'')         <> ISNULL(n.PatientDOB,'')         THEN 'PatientDOB,' ELSE '' END +
                CASE WHEN ISNULL(c.DateofService,'')      <> ISNULL(n.DateofService,'')      THEN 'DateofService,' ELSE '' END +
                CASE WHEN ISNULL(c.ChargeEnteredDate,'')  <> ISNULL(n.ChargeEnteredDate,'')  THEN 'ChargeEnteredDate,' ELSE '' END +
                CASE WHEN ISNULL(c.FirstBilledDate,'')    <> ISNULL(n.FirstBilledDate,'')    THEN 'FirstBilledDate,' ELSE '' END +
                CASE WHEN ISNULL(c.Panelname,'')          <> ISNULL(n.Panelname,'')          THEN 'Panelname,' ELSE '' END +
                CASE WHEN ISNULL(c.CPTCodeXUnitsXModifier,'') <> ISNULL(n.CPTCodeXUnitsXModifier,'') THEN 'CPTCodeXUnitsXModifier,' ELSE '' END +
                CASE WHEN ISNULL(c.POS,'')                <> ISNULL(n.POS,'')                THEN 'POS,' ELSE '' END +
                CASE WHEN ISNULL(c.TOS,'')                <> ISNULL(n.TOS,'')                THEN 'TOS,' ELSE '' END +
                CASE WHEN ISNULL(c.ChargeAmount,'')       <> ISNULL(n.ChargeAmount,'')       THEN 'ChargeAmount,' ELSE '' END +
                CASE WHEN ISNULL(c.AllowedAmount,'')      <> ISNULL(n.AllowedAmount,'')      THEN 'AllowedAmount,' ELSE '' END +
                CASE WHEN ISNULL(c.InsurancePayment,'')   <> ISNULL(n.InsurancePayment,'')   THEN 'InsurancePayment,' ELSE '' END +
                CASE WHEN ISNULL(c.PatientPayment,'')     <> ISNULL(n.PatientPayment,'')     THEN 'PatientPayment,' ELSE '' END +
                CASE WHEN ISNULL(c.TotalPayments,'')      <> ISNULL(n.TotalPayments,'')      THEN 'TotalPayments,' ELSE '' END +
                CASE WHEN ISNULL(c.InsuranceAdjustments,'') <> ISNULL(n.InsuranceAdjustments,'') THEN 'InsuranceAdjustments,' ELSE '' END +
                CASE WHEN ISNULL(c.PatientAdjustments,'') <> ISNULL(n.PatientAdjustments,'') THEN 'PatientAdjustments,' ELSE '' END +
                CASE WHEN ISNULL(c.TotalAdjustments,'')   <> ISNULL(n.TotalAdjustments,'')   THEN 'TotalAdjustments,' ELSE '' END +
                CASE WHEN ISNULL(c.InsuranceBalance,'')   <> ISNULL(n.InsuranceBalance,'')   THEN 'InsuranceBalance,' ELSE '' END +
                CASE WHEN ISNULL(c.PatientBalance,'')     <> ISNULL(n.PatientBalance,'')     THEN 'PatientBalance,' ELSE '' END +
                CASE WHEN ISNULL(c.TotalBalance,'')       <> ISNULL(n.TotalBalance,'')       THEN 'TotalBalance,' ELSE '' END +
                CASE WHEN ISNULL(c.CheckDate,'')          <> ISNULL(n.CheckDate,'')          THEN 'CheckDate,' ELSE '' END +
                CASE WHEN ISNULL(c.ClaimStatus,'')        <> ISNULL(n.ClaimStatus,'')        THEN 'ClaimStatus,' ELSE '' END +
                CASE WHEN ISNULL(c.DenialCode,'')         <> ISNULL(n.DenialCode,'')         THEN 'DenialCode,' ELSE '' END +
                CASE WHEN ISNULL(c.ICDCode,'')            <> ISNULL(n.ICDCode,'')            THEN 'ICDCode,' ELSE '' END +
                CASE WHEN ISNULL(c.ICDPointer,'')         <> ISNULL(n.ICDPointer,'')         THEN 'ICDPointer,' ELSE '' END,
            c.FileLogId, c.RunId, c.WeekFolder, c.SourceFullPath, c.FileName, c.FileType, c.RowHash,
            c.LabID, c.LabName, c.ClaimID, c.AccessionNumber, c.SourceFileID, c.IngestedOn, c.CsvRowHash,
            c.PayerName_Raw, c.PayerName, c.Payer_Code, c.Payer_Common_Code, c.Payer_Group_Code, c.Global_Payer_ID, c.PayerType,
            c.BillingProvider, c.ReferringProvider, c.ClinicName, c.SalesRepname,
            c.PatientID, c.PatientDOB, c.DateofService, c.ChargeEnteredDate, c.FirstBilledDate,
            c.Panelname, c.CPTCodeXUnitsXModifier, c.POS, c.TOS,
            c.ChargeAmount, c.AllowedAmount, c.InsurancePayment, c.PatientPayment, c.TotalPayments,
            c.InsuranceAdjustments, c.PatientAdjustments, c.TotalAdjustments,
            c.InsuranceBalance, c.PatientBalance, c.TotalBalance,
            c.CheckDate, c.ClaimStatus, c.DenialCode, c.ICDCode,
            c.ICDPointer,
            c.UID, c.Aging, c.PatientName, c.LISPatientName, c.SubscriberId, c.PanelType,
            c.EnteredWeek, c.EnteredStatus, c.LastActivityDate, c.EmedixSubmissionDate,
            c.ClaimType, c.BilledStatus, c.BilledWeek, c.PostedWeek, c.ModField, c.CheqNo,
            c.DuplicatePaymentPosted, c.ActualPayment, c.ProcTotalBal, c.DeniedStatus,
            c.ScrubberEditReason, c.EmedixRejectionDate, c.EmedixRejection, c.RejectionCategory,
            c.TimeToPay, c.PaymentPercent, c.FullyPaidCount, c.FullyPaidAmount,
            c.Adjudicated, c.AdjudicatedAmount, c.Bucket30, c.Bucket30Amount,
            c.Bucket60, c.Bucket60Amount,
            c.InsertedDateTime
        FROM dbo.ClaimLevelData c
        INNER JOIN @Rows n ON n.ClaimID = c.ClaimID AND n.LabID = c.LabID
        WHERE n.RowHash <> c.RowHash;

        INSERT INTO dbo.ClaimLevelDataArchive
        (
            OriginalRecordId, ArchiveRemark,
            FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
            LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
            PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
            Panelname, CPTCodeXUnitsXModifier, POS, TOS,
            ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            ICDPointer,
            UID, Aging, PatientName, LISPatientName, SubscriberId, PanelType,
            EnteredWeek, EnteredStatus, LastActivityDate, EmedixSubmissionDate,
            ClaimType, BilledStatus, BilledWeek, PostedWeek, ModField, CheqNo,
            DuplicatePaymentPosted, ActualPayment, ProcTotalBal, DeniedStatus,
            ScrubberEditReason, EmedixRejectionDate, EmedixRejection, RejectionCategory,
            TimeToPay, PaymentPercent, FullyPaidCount, FullyPaidAmount,
            Adjudicated, AdjudicatedAmount, Bucket30, Bucket30Amount,
            Bucket60, Bucket60Amount,
            OriginalInsertedDateTime
        )
        SELECT
            c.RecordId,
            'row_removed',
            c.FileLogId, c.RunId, c.WeekFolder, c.SourceFullPath, c.FileName, c.FileType, c.RowHash,
            c.LabID, c.LabName, c.ClaimID, c.AccessionNumber, c.SourceFileID, c.IngestedOn, c.CsvRowHash,
            c.PayerName_Raw, c.PayerName, c.Payer_Code, c.Payer_Common_Code, c.Payer_Group_Code, c.Global_Payer_ID, c.PayerType,
            c.BillingProvider, c.ReferringProvider, c.ClinicName, c.SalesRepname,
            c.PatientID, c.PatientDOB, c.DateofService, c.ChargeEnteredDate, c.FirstBilledDate,
            c.Panelname, c.CPTCodeXUnitsXModifier, c.POS, c.TOS,
            c.ChargeAmount, c.AllowedAmount, c.InsurancePayment, c.PatientPayment, c.TotalPayments,
            c.InsuranceAdjustments, c.PatientAdjustments, c.TotalAdjustments,
            c.InsuranceBalance, c.PatientBalance, c.TotalBalance,
            c.CheckDate, c.ClaimStatus, c.DenialCode, c.ICDCode,
            c.ICDPointer,
            c.UID, c.Aging, c.PatientName, c.LISPatientName, c.SubscriberId, c.PanelType,
            c.EnteredWeek, c.EnteredStatus, c.LastActivityDate, c.EmedixSubmissionDate,
            c.ClaimType, c.BilledStatus, c.BilledWeek, c.PostedWeek, c.ModField, c.CheqNo,
            c.DuplicatePaymentPosted, c.ActualPayment, c.ProcTotalBal, c.DeniedStatus,
            c.ScrubberEditReason, c.EmedixRejectionDate, c.EmedixRejection, c.RejectionCategory,
            c.TimeToPay, c.PaymentPercent, c.FullyPaidCount, c.FullyPaidAmount,
            c.Adjudicated, c.AdjudicatedAmount, c.Bucket30, c.Bucket30Amount,
            c.Bucket60, c.Bucket60Amount,
            c.InsertedDateTime
        FROM dbo.ClaimLevelData c
        LEFT JOIN @Rows n ON n.ClaimID = c.ClaimID AND n.LabID = c.LabID
        WHERE n.ClaimID IS NULL;

        DELETE FROM dbo.ClaimLevelData;
    END

    DECLARE @InsertOffset INT = 0;
    DECLARE @InsertBatch  INT = 1;

    WHILE @InsertBatch > 0
    BEGIN
        INSERT INTO dbo.ClaimLevelData
        (
            FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
            LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
            PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
            Panelname, CPTCodeXUnitsXModifier, POS, TOS,
            ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            UID, Aging, PatientName, LISPatientName, SubscriberId, PanelType,
            EnteredWeek, EnteredStatus, LastActivityDate, EmedixSubmissionDate,
            ClaimType, BilledStatus, BilledWeek, PostedWeek, ModField, CheqNo,
            DuplicatePaymentPosted, ActualPayment, ProcTotalBal, DeniedStatus,
            ScrubberEditReason, EmedixRejectionDate, EmedixRejection, RejectionCategory,
            TimeToPay, PaymentPercent, FullyPaidCount, FullyPaidAmount,
            Adjudicated, AdjudicatedAmount, Bucket30, Bucket30Amount,
            Bucket60, Bucket60Amount
        )
        SELECT
            CAST(@FileLogId AS NVARCHAR(500)), RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
            LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
            PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
            Panelname, CPTCodeXUnitsXModifier, POS, TOS,
            ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            UID, Aging, PatientName, LISPatientName, SubscriberId, PanelType,
            EnteredWeek, EnteredStatus, LastActivityDate, EmedixSubmissionDate,
            ClaimType, BilledStatus, BilledWeek, PostedWeek, ModField, CheqNo,
            DuplicatePaymentPosted, ActualPayment, ProcTotalBal, DeniedStatus,
            ScrubberEditReason, EmedixRejectionDate, EmedixRejection, RejectionCategory,
            TimeToPay, PaymentPercent, FullyPaidCount, FullyPaidAmount,
            Adjudicated, AdjudicatedAmount, Bucket30, Bucket30Amount,
            Bucket60, Bucket60Amount
        FROM @Rows
        ORDER BY (SELECT NULL)
        OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

        SET @InsertBatch  = @@ROWCOUNT;
        SET @InsertOffset = @InsertOffset + @ChunkSize;
    END

    SELECT @InsertOffset AS InsertedCount;
END;
GO

PRINT 'Script completed.';
