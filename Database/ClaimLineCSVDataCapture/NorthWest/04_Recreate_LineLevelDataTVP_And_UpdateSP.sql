-- Drop and recreate LineLevelDataTVP and recreate usp_BulkInsertLineLevelData
-- Run on the target database. This script will:
-- 1) DROP the stored procedure that references the TVP (if exists)
-- 2) DROP the TVP type (if exists)
-- 3) CREATE the TVP type with the updated column list
-- 4) CREATE the stored procedure that accepts the TVP

SET NOCOUNT ON;
GO

PRINT 'Dropping stored procedure dbo.usp_BulkInsertLineLevelData if it exists...';
IF OBJECT_ID('dbo.usp_BulkInsertLineLevelData', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE dbo.usp_BulkInsertLineLevelData;
    PRINT 'Dropped stored procedure dbo.usp_BulkInsertLineLevelData.';
END
ELSE
    PRINT 'Stored procedure dbo.usp_BulkInsertLineLevelData does not exist.';

PRINT 'Dropping type dbo.LineLevelDataTVP if it exists...';
IF TYPE_ID('dbo.LineLevelDataTVP') IS NOT NULL
BEGIN
    DROP TYPE dbo.LineLevelDataTVP;
    PRINT 'Dropped type dbo.LineLevelDataTVP.';
END
ELSE
    PRINT 'Type dbo.LineLevelDataTVP does not exist.';

PRINT 'Creating type dbo.LineLevelDataTVP...';
CREATE TYPE dbo.LineLevelDataTVP AS TABLE
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
    CPTCode               NVARCHAR(500),
    Units                 NVARCHAR(500),
    Modifier              NVARCHAR(500),
    POS                   NVARCHAR(500),
    TOS                   NVARCHAR(500),
    ChargeAmount          NVARCHAR(500),
    ChargeAmountPerUnit   NVARCHAR(500),
    AllowedAmount         NVARCHAR(500),
    AllowedAmountPerUnit  NVARCHAR(500),
    InsurancePayment      NVARCHAR(500),
    InsurancePaymentPerUnit NVARCHAR(500),
    PatientPayment        NVARCHAR(500),
    PatientPaymentPerUnit NVARCHAR(500),
    TotalPayments         NVARCHAR(500),
    InsuranceAdjustments  NVARCHAR(500),
    PatientAdjustments    NVARCHAR(500),
    TotalAdjustments      NVARCHAR(500),
    InsuranceBalance      NVARCHAR(500),
    PatientBalance        NVARCHAR(500),
    PatientBalancePerUnit NVARCHAR(500),
    TotalBalance          NVARCHAR(500),
    CheckDate             NVARCHAR(500),
    PostingDate           NVARCHAR(500),
    ClaimStatus           NVARCHAR(500),
    PayStatus             NVARCHAR(500),
    DenialCode            NVARCHAR(MAX),
    DenialDate            NVARCHAR(500),
    ICDCode               NVARCHAR(500),
    DaystoDOS             NVARCHAR(500),
    RollingDays           NVARCHAR(500),
    DaystoBill            NVARCHAR(500),
    DaystoPost            NVARCHAR(500),
    ICDPointer            NVARCHAR(500),
    -- Additional lab-specific fields
    UID                   NVARCHAR(500),
    T_F                   NVARCHAR(100),
    PatientName           NVARCHAR(1000),
    CombinedLineLevelICD  NVARCHAR(MAX),
    SubscriberId          NVARCHAR(500),
    ClaimAmount           NVARCHAR(500),
    CptWithUnits          NVARCHAR(MAX),
    [Proc]                  NVARCHAR(MAX),
    EnteredStatus         NVARCHAR(MAX),
    BilledStatus          NVARCHAR(MAX),
    ProcTotalBal          NVARCHAR(500),
    UpdatedDenialCode     NVARCHAR(MAX),
    CombinedLineLevelDenialCode NVARCHAR(MAX),
    Loc                   NVARCHAR(MAX),
    ProcInsLastRefiledDeniedReason NVARCHAR(MAX),
    ProcInsResponsibleCarrierOriginalFilingDate NVARCHAR(100),
    ProcInsStatus         NVARCHAR(MAX),
    ProcInsLastRefiledDeniedDate NVARCHAR(100)
);
GO

PRINT 'Creating stored procedure dbo.usp_BulkInsertLineLevelData...';
Go;

CREATE PROCEDURE dbo.usp_BulkInsertLineLevelData
    @Rows               dbo.LineLevelDataTVP READONLY,
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

    IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'linelevel')
    BEGIN
        PRINT 'RunId already in FileLog for linelevel — skipping: ' + @RunId;
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    DECLARE @FileLogId INT;

    INSERT INTO dbo.LineClaimFileLogs
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'linelevel', @FileCreatedDateTime);

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
            CheckDate, PostingDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
            ICDCode, ICDPointer,
            UID, T_F, PatientName, CombinedLineLevelICD, SubscriberId, ClaimAmount,
            CptWithUnits, [Proc], EnteredStatus, BilledStatus, ProcTotalBal,
            UpdatedDenialCode, CombinedLineLevelDenialCode, Loc,
            ProcInsLastRefiledDeniedReason, ProcInsResponsibleCarrierOriginalFilingDate,
            ProcInsStatus, ProcInsLastRefiledDeniedDate,
            OriginalInsertedDateTime
        )
        SELECT
            l.RecordId,
            'data_changed: ' +
                CASE WHEN ISNULL(l.PayerName_Raw,'')      <> ISNULL(n.PayerName_Raw,'')      THEN 'PayerName_Raw,' ELSE '' END +
                CASE WHEN ISNULL(l.PayerName,'')          <> ISNULL(n.PayerName,'')          THEN 'PayerName,' ELSE '' END +
                CASE WHEN ISNULL(l.Payer_Code,'')         <> ISNULL(n.Payer_Code,'')         THEN 'Payer_Code,' ELSE '' END +
                CASE WHEN ISNULL(l.Payer_Common_Code,'')  <> ISNULL(n.Payer_Common_Code,'')  THEN 'Payer_Common_Code,' ELSE '' END +
                CASE WHEN ISNULL(l.Payer_Group_Code,'')   <> ISNULL(n.Payer_Group_Code,'')   THEN 'Payer_Group_Code,' ELSE '' END +
                CASE WHEN ISNULL(l.Global_Payer_ID,'')    <> ISNULL(n.Global_Payer_ID,'')    THEN 'Global_Payer_ID,' ELSE '' END +
                CASE WHEN ISNULL(l.PayerType,'')          <> ISNULL(n.PayerType,'')          THEN 'PayerType,' ELSE '' END +
                CASE WHEN ISNULL(l.BillingProvider,'')    <> ISNULL(n.BillingProvider,'')    THEN 'BillingProvider,' ELSE '' END +
                CASE WHEN ISNULL(l.ReferringProvider,'')  <> ISNULL(n.ReferringProvider,'')  THEN 'ReferringProvider,' ELSE '' END +
                CASE WHEN ISNULL(l.ClinicName,'')         <> ISNULL(n.ClinicName,'')         THEN 'ClinicName,' ELSE '' END +
                CASE WHEN ISNULL(l.SalesRepname,'')       <> ISNULL(n.SalesRepname,'')       THEN 'SalesRepname,' ELSE '' END +
                CASE WHEN ISNULL(l.PatientID,'')          <> ISNULL(n.PatientID,'')          THEN 'PatientID,' ELSE '' END +
                CASE WHEN ISNULL(l.PatientDOB,'')         <> ISNULL(n.PatientDOB,'')         THEN 'PatientDOB,' ELSE '' END +
                CASE WHEN ISNULL(l.DateofService,'')      <> ISNULL(n.DateofService,'')      THEN 'DateofService,' ELSE '' END +
                CASE WHEN ISNULL(l.ChargeEnteredDate,'')  <> ISNULL(n.ChargeEnteredDate,'')  THEN 'ChargeEnteredDate,' ELSE '' END +
                CASE WHEN ISNULL(l.FirstBilledDate,'')    <> ISNULL(n.FirstBilledDate,'')    THEN 'FirstBilledDate,' ELSE '' END +
                CASE WHEN ISNULL(l.Panelname,'')          <> ISNULL(n.Panelname,'')          THEN 'Panelname,' ELSE '' END +
                CASE WHEN ISNULL(l.CPTCode,'')            <> ISNULL(n.CPTCode,'')            THEN 'CPTCode,' ELSE '' END +
                CASE WHEN ISNULL(l.Units,'')              <> ISNULL(n.Units,'')              THEN 'Units,' ELSE '' END +
                CASE WHEN ISNULL(l.Modifier,'')           <> ISNULL(n.Modifier,'')           THEN 'Modifier,' ELSE '' END +
                CASE WHEN ISNULL(l.POS,'')                <> ISNULL(n.POS,'')                THEN 'POS,' ELSE '' END +
                CASE WHEN ISNULL(l.TOS,'')                <> ISNULL(n.TOS,'')                THEN 'TOS,' ELSE '' END +
                CASE WHEN ISNULL(l.ChargeAmount,'')       <> ISNULL(n.ChargeAmount,'')       THEN 'ChargeAmount,' ELSE '' END +
                CASE WHEN ISNULL(l.AllowedAmount,'')      <> ISNULL(n.AllowedAmount,'')      THEN 'AllowedAmount,' ELSE '' END +
                CASE WHEN ISNULL(l.InsurancePayment,'')   <> ISNULL(n.InsurancePayment,'')   THEN 'InsurancePayment,' ELSE '' END +
                CASE WHEN ISNULL(l.PatientPayment,'')     <> ISNULL(n.PatientPayment,'')     THEN 'PatientPayment,' ELSE '' END +
                CASE WHEN ISNULL(l.TotalPayments,'')      <> ISNULL(n.TotalPayments,'')      THEN 'TotalPayments,' ELSE '' END +
                CASE WHEN ISNULL(l.InsuranceAdjustments,'') <> ISNULL(n.InsuranceAdjustments,'') THEN 'InsuranceAdjustments,' ELSE '' END +
                CASE WHEN ISNULL(l.PatientAdjustments,'') <> ISNULL(n.PatientAdjustments,'') THEN 'PatientAdjustments,' ELSE '' END +
                CASE WHEN ISNULL(l.TotalAdjustments,'')   <> ISNULL(n.TotalAdjustments,'')   THEN 'TotalAdjustments,' ELSE '' END +
                CASE WHEN ISNULL(l.InsuranceBalance,'')   <> ISNULL(n.InsuranceBalance,'')   THEN 'InsuranceBalance,' ELSE '' END +
                CASE WHEN ISNULL(l.PatientBalance,'')     <> ISNULL(n.PatientBalance,'')     THEN 'PatientBalance,' ELSE '' END +
                CASE WHEN ISNULL(l.PatientBalancePerUnit,'') <> ISNULL(n.PatientBalancePerUnit,'') THEN 'PatientBalancePerUnit,' ELSE '' END +
                CASE WHEN ISNULL(l.TotalBalance,'')       <> ISNULL(n.TotalBalance,'')       THEN 'TotalBalance,' ELSE '' END +
                CASE WHEN ISNULL(l.CheckDate,'')          <> ISNULL(n.CheckDate,'')          THEN 'CheckDate,' ELSE '' END +
                CASE WHEN ISNULL(l.PostingDate,'')        <> ISNULL(n.PostingDate,'')        THEN 'PostingDate,' ELSE '' END +
                CASE WHEN ISNULL(l.ClaimStatus,'')        <> ISNULL(n.ClaimStatus,'')        THEN 'ClaimStatus,' ELSE '' END +
                CASE WHEN ISNULL(l.PayStatus,'')          <> ISNULL(n.PayStatus,'')          THEN 'PayStatus,' ELSE '' END +
                CASE WHEN ISNULL(l.DenialCode,'')         <> ISNULL(n.DenialCode,'')         THEN 'DenialCode,' ELSE '' END +
                CASE WHEN ISNULL(l.DenialDate,'')         <> ISNULL(n.DenialDate,'')         THEN 'DenialDate,' ELSE '' END +
                CASE WHEN ISNULL(l.ICDCode,'')            <> ISNULL(n.ICDCode,'')            THEN 'ICDCode,' ELSE '' END +
                CASE WHEN ISNULL(l.ICDPointer,'')         <> ISNULL(n.ICDPointer,'')         THEN 'ICDPointer,' ELSE '' END,
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
            l.CheckDate, l.PostingDate, l.ClaimStatus, l.PayStatus, l.DenialCode, l.DenialDate,
            l.ICDCode, l.ICDPointer,
            l.UID, l.T_F, l.PatientName, l.CombinedLineLevelICD, l.SubscriberId, l.ClaimAmount,
            l.CptWithUnits, l.[Proc], l.EnteredStatus, l.BilledStatus, l.ProcTotalBal,
            l.UpdatedDenialCode, l.CombinedLineLevelDenialCode, l.Loc,
            l.ProcInsLastRefiledDeniedReason, l.ProcInsResponsibleCarrierOriginalFilingDate,
            l.ProcInsStatus, l.ProcInsLastRefiledDeniedDate,
            l.InsertedDateTime
        FROM dbo.LineLevelData l
        INNER JOIN @Rows n ON n.ClaimID = l.ClaimID AND n.LabID = l.LabID AND n.CPTCode = l.CPTCode
        WHERE n.RowHash <> l.RowHash;

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
            CheckDate, PostingDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
            ICDCode, ICDPointer,
            UID, T_F, PatientName, CombinedLineLevelICD, SubscriberId, ClaimAmount,
            CptWithUnits, [Proc], EnteredStatus, BilledStatus, ProcTotalBal,
            UpdatedDenialCode, CombinedLineLevelDenialCode, Loc,
            ProcInsLastRefiledDeniedReason, ProcInsResponsibleCarrierOriginalFilingDate,
            ProcInsStatus, ProcInsLastRefiledDeniedDate,
            OriginalInsertedDateTime
        )
        SELECT
            l.RecordId,
            'row_removed',
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
            l.CheckDate, l.PostingDate, l.ClaimStatus, l.PayStatus, l.DenialCode, l.DenialDate,
            l.ICDCode, l.ICDPointer,
            l.UID, l.T_F, l.PatientName, l.CombinedLineLevelICD, l.SubscriberId, l.ClaimAmount,
            l.CptWithUnits, l.[Proc], l.EnteredStatus, l.BilledStatus, l.ProcTotalBal,
            l.UpdatedDenialCode, l.CombinedLineLevelDenialCode, l.Loc,
            l.ProcInsLastRefiledDeniedReason, l.ProcInsResponsibleCarrierOriginalFilingDate,
            l.ProcInsStatus, l.ProcInsLastRefiledDeniedDate,
            l.InsertedDateTime
        FROM dbo.LineLevelData l
        LEFT JOIN @Rows n ON n.ClaimID = l.ClaimID AND n.LabID = l.LabID AND n.CPTCode = l.CPTCode
        WHERE n.ClaimID IS NULL;

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
            Panelname, CPTCode, Units, Modifier, POS, TOS,
            ChargeAmount, ChargeAmountPerUnit, AllowedAmount, AllowedAmountPerUnit,
            InsurancePayment, InsurancePaymentPerUnit, PatientPayment, PatientPaymentPerUnit,
            TotalPayments, InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, PatientBalancePerUnit, TotalBalance,
            CheckDate, PostingDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
            ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            UID, T_F, PatientName, CombinedLineLevelICD, SubscriberId, ClaimAmount,
            CptWithUnits, [Proc], EnteredStatus, BilledStatus, ProcTotalBal,
            UpdatedDenialCode, CombinedLineLevelDenialCode, Loc,
            ProcInsLastRefiledDeniedReason, ProcInsResponsibleCarrierOriginalFilingDate,
            ProcInsStatus, ProcInsLastRefiledDeniedDate
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
            CheckDate, PostingDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
            ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            UID, T_F, PatientName, CombinedLineLevelICD, SubscriberId, ClaimAmount,
            CptWithUnits, [Proc], EnteredStatus, BilledStatus, ProcTotalBal,
            UpdatedDenialCode, CombinedLineLevelDenialCode, Loc,
            ProcInsLastRefiledDeniedReason, ProcInsResponsibleCarrierOriginalFilingDate,
            ProcInsStatus, ProcInsLastRefiledDeniedDate
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
