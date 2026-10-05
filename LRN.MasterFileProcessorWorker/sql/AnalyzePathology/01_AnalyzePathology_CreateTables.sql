/*
    Analyze Pathology - lab database tables for LRN.MasterFileProcessorWorker.
    Run against the ANALYZE PATHOLOGY lab database (AnalyzePathology_LRN), not LRNMaster.

    What the worker writes here:
      dbo.LineClaimFileLogs  one row per load (LineClaimFileLogRepository)
      dbo.ClaimLevelData     claim sheet ("Master")   - TRUNCATE + SqlBulkCopy per run
      dbo.LineLevelData      line sheet ("Line Level") - TRUNCATE + SqlBulkCopy per run
      dbo.LIMSMaster         "LIMS Master" sheet       - TRUNCATE + SqlBulkCopy per run

    Every column named in Schemas/LabMappings/AnalyzePathologyFieldMappings.json and
    Schemas/AnalyzePathology_LIMS_Schema.json exists below. SqlBulkCopy fails the load outright if a
    mapped column is missing, and the LIMS importer silently skips one, so keep them in step.

    Column types follow ClaimLineCSVDataCapture/Sql/01_CreateTables.sql (text columns throughout)
    so the dashboards read this lab exactly as they read every other lab.

    AdditionalFields catches every CSV column the mapping does not claim (Charge To Date, T/F,
    Claim Ordering Provider ID, Charge Total Payments, ...) as JSON, so nothing in the file is lost.

    Re-runnable: tables are created only when missing and every lab-specific column is added only
    when missing, so it is also safe on a database already built from 01_CreateTables.sql.
*/

SET NOCOUNT ON;
GO

/* ── 1. LineClaimFileLogs ─────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.LineClaimFileLogs', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LineClaimFileLogs
    (
        FileLogId            INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
        RunId                NVARCHAR(500)  NOT NULL,
        WeekFolder           NVARCHAR(500)  NULL,
        LabName              NVARCHAR(500)  NULL,
        SourceFullPath       NVARCHAR(1000) NULL,
        FileName             NVARCHAR(500)  NULL,
        FileType             NVARCHAR(100)  NOT NULL,
        FileCreatedDateTime  DATETIME       NULL,
        InsertedDateTime     DATETIME       NOT NULL DEFAULT GETDATE()
    );
    PRINT 'Created dbo.LineClaimFileLogs.';
END
GO

-- Load outcome columns (written by LineClaimFileLogRepository.TryCompleteAsync when present).
IF COL_LENGTH('dbo.LineClaimFileLogs', 'Status') IS NULL            ALTER TABLE dbo.LineClaimFileLogs ADD Status NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LineClaimFileLogs', 'RowsCopied') IS NULL        ALTER TABLE dbo.LineClaimFileLogs ADD RowsCopied BIGINT NULL;
IF COL_LENGTH('dbo.LineClaimFileLogs', 'ErrorMessage') IS NULL      ALTER TABLE dbo.LineClaimFileLogs ADD ErrorMessage NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineClaimFileLogs', 'CompletedDateTime') IS NULL ALTER TABLE dbo.LineClaimFileLogs ADD CompletedDateTime DATETIME2 NULL;
GO

/* ── 2. ClaimLevelData ────────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.ClaimLevelData', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ClaimLevelData
    (
        RecordId               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
        -- audit block stamped by the loader
        FileLogId              NVARCHAR(500)  NULL,
        RunId                  NVARCHAR(500)  NULL,
        WeekFolder             NVARCHAR(500)  NULL,
        SourceFullPath         NVARCHAR(1000) NULL,
        FileName               NVARCHAR(500)  NULL,
        FileType               NVARCHAR(100)  NULL,
        RowHash                NVARCHAR(64)   NULL,
        LabID                  NVARCHAR(500)  NULL,
        LabName                NVARCHAR(500)  NULL,
        -- standard claim columns
        ClaimID                NVARCHAR(500)  NULL,
        AccessionNumber        NVARCHAR(500)  NULL,
        SourceFileID           NVARCHAR(1000) NULL,
        IngestedOn             NVARCHAR(500)  NULL,
        CsvRowHash             NVARCHAR(500)  NULL,
        PayerName_Raw          NVARCHAR(500)  NULL,
        PayerName              NVARCHAR(500)  NULL,
        Payer_Code             NVARCHAR(500)  NULL,
        Payer_Common_Code      NVARCHAR(500)  NULL,
        Payer_Group_Code       NVARCHAR(500)  NULL,
        Global_Payer_ID        NVARCHAR(500)  NULL,
        PayerType              NVARCHAR(500)  NULL,
        BillingProvider        NVARCHAR(500)  NULL,
        ReferringProvider      NVARCHAR(500)  NULL,
        ClinicName             NVARCHAR(500)  NULL,
        SalesRepname           NVARCHAR(500)  NULL,
        PatientID              NVARCHAR(500)  NULL,
        PatientDOB             NVARCHAR(500)  NULL,
        DateofService          NVARCHAR(500)  NULL,
        ChargeEnteredDate      NVARCHAR(500)  NULL,
        FirstBilledDate        NVARCHAR(500)  NULL,
        Panelname              NVARCHAR(500)  NULL,
        CPTCodeXUnitsXModifier NVARCHAR(MAX)  NULL,
        POS                    NVARCHAR(500)  NULL,
        TOS                    NVARCHAR(500)  NULL,
        ChargeAmount           NVARCHAR(500)  NULL,
        AllowedAmount          NVARCHAR(500)  NULL,
        InsurancePayment       NVARCHAR(500)  NULL,
        PatientPayment         NVARCHAR(500)  NULL,
        TotalPayments          NVARCHAR(500)  NULL,
        InsuranceAdjustments   NVARCHAR(500)  NULL,
        PatientAdjustments     NVARCHAR(500)  NULL,
        TotalAdjustments       NVARCHAR(500)  NULL,
        InsuranceBalance       NVARCHAR(500)  NULL,
        PatientBalance         NVARCHAR(500)  NULL,
        TotalBalance           NVARCHAR(500)  NULL,
        CheckDate              NVARCHAR(500)  NULL,
        ClaimStatus            NVARCHAR(500)  NULL,
        DenialCode             NVARCHAR(MAX)  NULL,
        ICDCode                NVARCHAR(500)  NULL,
        DaystoDOS              NVARCHAR(500)  NULL,
        RollingDays            NVARCHAR(500)  NULL,
        DaystoBill             NVARCHAR(500)  NULL,
        DaystoPost             NVARCHAR(500)  NULL,
        ICDPointer             NVARCHAR(500)  NULL,
        -- shared lab-specific columns (same as 01_CreateTables.sql)
        PatientName            NVARCHAR(1000) NULL,
        SubscriberId           NVARCHAR(1000) NULL,
        BilledStatus           NVARCHAR(MAX)  NULL,
        BilledWeek             NVARCHAR(500)  NULL,
        PostedWeek             NVARCHAR(500)  NULL,
        PaymentPercent         NVARCHAR(100)  NULL,
        FullyPaidCount         NVARCHAR(500)  NULL,
        FullyPaidAmount        NVARCHAR(500)  NULL,
        Adjudicated            NVARCHAR(500)  NULL,
        AdjudicatedAmount      NVARCHAR(500)  NULL,
        Bucket30               NVARCHAR(500)  NULL,
        Bucket30Amount         NVARCHAR(500)  NULL,
        Bucket60               NVARCHAR(500)  NULL,
        Bucket60Amount         NVARCHAR(500)  NULL,
        InsertedDateTime       DATETIME       NOT NULL DEFAULT GETDATE()
    );
    PRINT 'Created dbo.ClaimLevelData.';
END
GO

-- Analyze Pathology claim columns (also brings a 01_CreateTables.sql database up to date).
IF COL_LENGTH('dbo.ClaimLevelData', 'PatientName') IS NULL                   ALTER TABLE dbo.ClaimLevelData ADD PatientName NVARCHAR(1000) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SubscriberId') IS NULL                  ALTER TABLE dbo.ClaimLevelData ADD SubscriberId NVARCHAR(1000) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'BilledStatus') IS NULL                  ALTER TABLE dbo.ClaimLevelData ADD BilledStatus NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'BilledWeek') IS NULL                    ALTER TABLE dbo.ClaimLevelData ADD BilledWeek NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PostedWeek') IS NULL                    ALTER TABLE dbo.ClaimLevelData ADD PostedWeek NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PaymentPercent') IS NULL                ALTER TABLE dbo.ClaimLevelData ADD PaymentPercent NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'FullyPaidCount') IS NULL                ALTER TABLE dbo.ClaimLevelData ADD FullyPaidCount NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'FullyPaidAmount') IS NULL               ALTER TABLE dbo.ClaimLevelData ADD FullyPaidAmount NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Adjudicated') IS NULL                   ALTER TABLE dbo.ClaimLevelData ADD Adjudicated NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'AdjudicatedAmount') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD AdjudicatedAmount NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Bucket30') IS NULL                      ALTER TABLE dbo.ClaimLevelData ADD Bucket30 NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Bucket30Amount') IS NULL                ALTER TABLE dbo.ClaimLevelData ADD Bucket30Amount NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Bucket60') IS NULL                      ALTER TABLE dbo.ClaimLevelData ADD Bucket60 NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Bucket60Amount') IS NULL                ALTER TABLE dbo.ClaimLevelData ADD Bucket60Amount NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CPTCodeXUnitsXModifierOrginal') IS NULL ALTER TABLE dbo.ClaimLevelData ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimUID') IS NULL                      ALTER TABLE dbo.ClaimLevelData ADD ClaimUID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'AgingDOS') IS NULL                      ALTER TABLE dbo.ClaimLevelData ADD AgingDOS NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LastBilledDate') IS NULL                ALTER TABLE dbo.ClaimLevelData ADD LastBilledDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DenialDate') IS NULL                    ALTER TABLE dbo.ClaimLevelData ADD DenialDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Facility') IS NULL                      ALTER TABLE dbo.ClaimLevelData ADD Facility NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TotalInsuranceBalance') IS NULL         ALTER TABLE dbo.ClaimLevelData ADD TotalInsuranceBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OtherBalance') IS NULL                  ALTER TABLE dbo.ClaimLevelData ADD OtherBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CPTCodeList') IS NULL                 ALTER TABLE dbo.ClaimLevelData ADD CPTCodeList NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'UnitsList') IS NULL                   ALTER TABLE dbo.ClaimLevelData ADD UnitsList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ModifierList') IS NULL                ALTER TABLE dbo.ClaimLevelData ADD ModifierList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CptWithUnits') IS NULL                  ALTER TABLE dbo.ClaimLevelData ADD CptWithUnits NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeToDate') IS NULL                  ALTER TABLE dbo.ClaimLevelData ADD ChargeToDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalPayments') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD ChargeTotalPayments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalAdjustments') IS NULL        ALTER TABLE dbo.ClaimLevelData ADD ChargeTotalAdjustments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OrderingProviderID') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD OrderingProviderID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'AdditionalFields') IS NULL              ALTER TABLE dbo.ClaimLevelData ADD AdditionalFields NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ClaimLevelData') AND name = 'IX_ClaimLevelData_ClaimID')
    CREATE NONCLUSTERED INDEX IX_ClaimLevelData_ClaimID ON dbo.ClaimLevelData (ClaimID);
GO

/* ── 3. LineLevelData ─────────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.LineLevelData', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LineLevelData
    (
        RecordId                INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
        -- audit block stamped by the loader
        FileLogId               NVARCHAR(500)  NULL,
        RunId                   NVARCHAR(500)  NULL,
        WeekFolder              NVARCHAR(500)  NULL,
        SourceFullPath          NVARCHAR(1000) NULL,
        FileName                NVARCHAR(500)  NULL,
        FileType                NVARCHAR(100)  NULL,
        RowHash                 NVARCHAR(64)   NULL,
        LabID                   NVARCHAR(500)  NULL,
        LabName                 NVARCHAR(500)  NULL,
        -- standard line columns
        ClaimID                 NVARCHAR(500)  NULL,
        AccessionNumber         NVARCHAR(500)  NULL,
        SourceFileID            NVARCHAR(1000) NULL,
        IngestedOn              NVARCHAR(500)  NULL,
        CsvRowHash              NVARCHAR(500)  NULL,
        PayerName_Raw           NVARCHAR(500)  NULL,
        PayerName               NVARCHAR(500)  NULL,
        Payer_Code              NVARCHAR(500)  NULL,
        Payer_Common_Code       NVARCHAR(500)  NULL,
        Payer_Group_Code        NVARCHAR(500)  NULL,
        Global_Payer_ID         NVARCHAR(500)  NULL,
        PayerType               NVARCHAR(500)  NULL,
        BillingProvider         NVARCHAR(500)  NULL,
        ReferringProvider       NVARCHAR(500)  NULL,
        ClinicName              NVARCHAR(500)  NULL,
        SalesRepname            NVARCHAR(500)  NULL,
        PatientID               NVARCHAR(500)  NULL,
        PatientDOB              NVARCHAR(500)  NULL,
        DateofService           NVARCHAR(500)  NULL,
        ChargeEnteredDate       NVARCHAR(500)  NULL,
        FirstBilledDate         NVARCHAR(500)  NULL,
        Panelname               NVARCHAR(500)  NULL,
        CPTCode                 NVARCHAR(MAX)  NULL,
        Units                   NVARCHAR(500)  NULL,
        Modifier                NVARCHAR(500)  NULL,
        POS                     NVARCHAR(500)  NULL,
        TOS                     NVARCHAR(500)  NULL,
        ChargeAmount            NVARCHAR(500)  NULL,
        ChargeAmountPerUnit     NVARCHAR(500)  NULL,
        AllowedAmount           NVARCHAR(500)  NULL,
        AllowedAmountPerUnit    NVARCHAR(500)  NULL,
        InsurancePayment        NVARCHAR(500)  NULL,
        InsurancePaymentPerUnit NVARCHAR(500)  NULL,
        PatientPayment          NVARCHAR(500)  NULL,
        PatientPaymentPerUnit   NVARCHAR(500)  NULL,
        TotalPayments           NVARCHAR(500)  NULL,
        InsuranceAdjustments    NVARCHAR(500)  NULL,
        PatientAdjustments      NVARCHAR(500)  NULL,
        TotalAdjustments        NVARCHAR(500)  NULL,
        InsuranceBalance        NVARCHAR(500)  NULL,
        PatientBalance          NVARCHAR(500)  NULL,
        PatientBalancePerUnit   NVARCHAR(500)  NULL,
        TotalBalance            NVARCHAR(500)  NULL,
        CheckDate               NVARCHAR(500)  NULL,
        PostingDate             NVARCHAR(500)  NULL,
        ClaimStatus             NVARCHAR(500)  NULL,
        PayStatus               NVARCHAR(500)  NULL,
        DenialCode              NVARCHAR(MAX)  NULL,
        DenialDate              NVARCHAR(500)  NULL,
        ICDCode                 NVARCHAR(500)  NULL,
        DaystoDOS               NVARCHAR(500)  NULL,
        RollingDays             NVARCHAR(500)  NULL,
        DaystoBill              NVARCHAR(500)  NULL,
        DaystoPost              NVARCHAR(500)  NULL,
        ICDPointer              NVARCHAR(500)  NULL,
        InsertedDateTime        DATETIME       NOT NULL DEFAULT GETDATE()
    );
    PRINT 'Created dbo.LineLevelData.';
END
GO

-- Analyze Pathology line columns (also brings a 01_CreateTables.sql database up to date).
IF COL_LENGTH('dbo.LineLevelData', 'PaymentPostedDate') IS NULL     ALTER TABLE dbo.LineLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LineLevelUID') IS NULL          ALTER TABLE dbo.LineLevelData ADD LineLevelUID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'UID') IS NULL                   ALTER TABLE dbo.LineLevelData ADD UID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LastBilledDate') IS NULL        ALTER TABLE dbo.LineLevelData ADD LastBilledDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Facility') IS NULL              ALTER TABLE dbo.LineLevelData ADD Facility NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientName') IS NULL           ALTER TABLE dbo.LineLevelData ADD PatientName NVARCHAR(1000) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SubscriberId') IS NULL          ALTER TABLE dbo.LineLevelData ADD SubscriberId NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CptWithUnits') IS NULL          ALTER TABLE dbo.LineLevelData ADD CptWithUnits NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CPTModifier') IS NULL           ALTER TABLE dbo.LineLevelData ADD CPTModifier NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimCPTs') IS NULL             ALTER TABLE dbo.LineLevelData ADD ClaimCPTs NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TotalInsuranceBalance') IS NULL ALTER TABLE dbo.LineLevelData ADD TotalInsuranceBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OtherBalance') IS NULL          ALTER TABLE dbo.LineLevelData ADD OtherBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeToDate') IS NULL          ALTER TABLE dbo.LineLevelData ADD ChargeToDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeTotalPayments') IS NULL   ALTER TABLE dbo.LineLevelData ADD ChargeTotalPayments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeTotalAdjustments') IS NULL ALTER TABLE dbo.LineLevelData ADD ChargeTotalAdjustments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OrderingProviderID') IS NULL    ALTER TABLE dbo.LineLevelData ADD OrderingProviderID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TF') IS NULL                    ALTER TABLE dbo.LineLevelData ADD TF NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'AdditionalFields') IS NULL      ALTER TABLE dbo.LineLevelData ADD AdditionalFields NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LineLevelData') AND name = 'IX_LineLevelData_ClaimID')
    CREATE NONCLUSTERED INDEX IX_LineLevelData_ClaimID ON dbo.LineLevelData (ClaimID);
GO

/* ── 4. LIMSMaster ────────────────────────────────────────────────────────── */
-- Column names match Schemas/AnalyzePathology_LIMS_Schema.json (SQLColName). The importer loads
-- by destination column, so a column missing here is skipped without an error.
IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LIMSMaster
    (
        Accession          NVARCHAR(50)   NULL,   -- Refer_No
        TrueFalse          NVARCHAR(10)   NULL,   -- T/F
        PatientLastName    NVARCHAR(255)  NULL,   -- Last
        PatientFirstName   NVARCHAR(255)  NULL,   -- First
        OrganizationCode   NVARCHAR(100)  NULL,   -- Acctno
        EnteredDate        DATE           NULL,   -- Entered
        RequestCollectDate DATE           NULL,   -- Collection Date
        ReqReceivedDate    DATE           NULL,   -- Rcvdate
        ReqReportedDate    DATE           NULL,   -- Printed
        Status             NVARCHAR(255)  NULL,   -- Status
        PatientDateofBirth DATE           NULL,   -- Dob
        PatientCode        NVARCHAR(100)  NULL,   -- Patient_No
        Samples            NVARCHAR(500)  NULL,   -- Samples
        ClinicName         NVARCHAR(500)  NULL,   -- Aname
        DoctorFullName     NVARCHAR(500)  NULL,   -- Dname
        DoctorNPI          NVARCHAR(50)   NULL,   -- Dnpi
        ReferringProvider  NVARCHAR(500)  NULL,   -- Rdname
        SystemName         NVARCHAR(255)  NULL,   -- System Name
        ResultStatus       NVARCHAR(255)  NULL,   -- Result Status
        NewStatus          NVARCHAR(255)  NULL,   -- New Status
        SubStatus          NVARCHAR(255)  NULL,   -- Sub Status
        BillCategory       NVARCHAR(255)  NULL,   -- Bill Category
        ChargeClaimId      NVARCHAR(100)  NULL,   -- Charge Claim Id (joins to ClaimLevelData.ClaimID)
        BilledDate         DATE           NULL,   -- Billed Date
        TimetoResult       NVARCHAR(50)   NULL,   -- Time To Result (text: values such as "<1")
        TimetoBill         NVARCHAR(50)   NULL,   -- Time To Bill
        PanelName          NVARCHAR(500)  NULL,   -- Panel Name
        -- filled by the importer, not the sheet
        LabId              INT            NULL,
        LabName            NVARCHAR(200)  NULL,
        SourceFile         NVARCHAR(260)  NULL,
        RunId              VARCHAR(30)    NULL,
        AdditionalFields   NVARCHAR(MAX)  NULL,
        CreatedOn          DATETIME       NOT NULL CONSTRAINT DF_LIMSMaster_CreatedOn DEFAULT (GETDATE())
    );
    PRINT 'Created dbo.LIMSMaster.';
END
GO

IF COL_LENGTH('dbo.LIMSMaster', 'TrueFalse') IS NULL          ALTER TABLE dbo.LIMSMaster ADD TrueFalse NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientLastName') IS NULL    ALTER TABLE dbo.LIMSMaster ADD PatientLastName NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientFirstName') IS NULL   ALTER TABLE dbo.LIMSMaster ADD PatientFirstName NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'OrganizationCode') IS NULL   ALTER TABLE dbo.LIMSMaster ADD OrganizationCode NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'EnteredDate') IS NULL        ALTER TABLE dbo.LIMSMaster ADD EnteredDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'RequestCollectDate') IS NULL ALTER TABLE dbo.LIMSMaster ADD RequestCollectDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ReqReceivedDate') IS NULL    ALTER TABLE dbo.LIMSMaster ADD ReqReceivedDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ReqReportedDate') IS NULL    ALTER TABLE dbo.LIMSMaster ADD ReqReportedDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Status') IS NULL             ALTER TABLE dbo.LIMSMaster ADD Status NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientDateofBirth') IS NULL ALTER TABLE dbo.LIMSMaster ADD PatientDateofBirth DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientCode') IS NULL        ALTER TABLE dbo.LIMSMaster ADD PatientCode NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Samples') IS NULL            ALTER TABLE dbo.LIMSMaster ADD Samples NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ClinicName') IS NULL         ALTER TABLE dbo.LIMSMaster ADD ClinicName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DoctorFullName') IS NULL     ALTER TABLE dbo.LIMSMaster ADD DoctorFullName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DoctorNPI') IS NULL          ALTER TABLE dbo.LIMSMaster ADD DoctorNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ReferringProvider') IS NULL  ALTER TABLE dbo.LIMSMaster ADD ReferringProvider NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SystemName') IS NULL         ALTER TABLE dbo.LIMSMaster ADD SystemName NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ResultStatus') IS NULL       ALTER TABLE dbo.LIMSMaster ADD ResultStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'NewStatus') IS NULL          ALTER TABLE dbo.LIMSMaster ADD NewStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SubStatus') IS NULL          ALTER TABLE dbo.LIMSMaster ADD SubStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BillCategory') IS NULL       ALTER TABLE dbo.LIMSMaster ADD BillCategory NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ChargeClaimId') IS NULL      ALTER TABLE dbo.LIMSMaster ADD ChargeClaimId NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BilledDate') IS NULL         ALTER TABLE dbo.LIMSMaster ADD BilledDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'TimetoResult') IS NULL       ALTER TABLE dbo.LIMSMaster ADD TimetoResult NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'TimetoBill') IS NULL         ALTER TABLE dbo.LIMSMaster ADD TimetoBill NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PanelName') IS NULL          ALTER TABLE dbo.LIMSMaster ADD PanelName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'LabId') IS NULL              ALTER TABLE dbo.LIMSMaster ADD LabId INT NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'LabName') IS NULL            ALTER TABLE dbo.LIMSMaster ADD LabName NVARCHAR(200) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SourceFile') IS NULL         ALTER TABLE dbo.LIMSMaster ADD SourceFile NVARCHAR(260) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'RunId') IS NULL              ALTER TABLE dbo.LIMSMaster ADD RunId VARCHAR(30) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'AdditionalFields') IS NULL   ALTER TABLE dbo.LIMSMaster ADD AdditionalFields NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'IX_LIMSMaster_Accession')
    CREATE NONCLUSTERED INDEX IX_LIMSMaster_Accession ON dbo.LIMSMaster (Accession);
GO

PRINT 'Analyze Pathology lab tables are up to date.';
GO
