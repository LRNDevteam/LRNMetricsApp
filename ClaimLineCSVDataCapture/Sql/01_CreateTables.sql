-- ClaimLineCSVDataCapture  –  Claim Level & Line Level CSV Tables
-- Run once per lab database.
-- ============================================================

-- ?? 0. LineClaimFileLogs  (one row per processed file) ??????????????????????
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LineClaimFileLogs')
CREATE TABLE dbo.LineClaimFileLogs
(
    FileLogId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RunId                 NVARCHAR(500)  NOT NULL,   -- filename without extension, unique per run
    WeekFolder            NVARCHAR(500)  NULL,
    LabName               NVARCHAR(500)  NULL,
    SourceFullPath        NVARCHAR(1000) NULL,
    FileName              NVARCHAR(500)  NULL,
    FileType              NVARCHAR(100)  NOT NULL,   -- 'claimlevel' or 'linelevel'
    FileCreatedDateTime   DATETIME       NULL,
    InsertedDateTime      DATETIME       NOT NULL DEFAULT GETDATE()
);
GO


-- ?? 1. ClaimLevelData  (row-level detail from Claim Level CSV) ??????????????
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ClaimLevelData')
CREATE TABLE dbo.ClaimLevelData
(
    RecordId              INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    FileLogId             NVARCHAR(500)  NULL,
    RunId                 NVARCHAR(500)  NULL,
    WeekFolder            NVARCHAR(500)  NULL,
    SourceFullPath        NVARCHAR(1000) NULL,
    FileName              NVARCHAR(500)  NULL,
    FileType              NVARCHAR(100)  NULL,
    RowHash               NVARCHAR(64)   NULL,        -- SHA256 of all data columns for change detection
    LabID                 NVARCHAR(500)  NULL,
    LabName               NVARCHAR(500)  NULL,
    ClaimID               NVARCHAR(500)  NULL,
    AccessionNumber       NVARCHAR(500)  NULL,
    SourceFileID          NVARCHAR(1000) NULL,
    IngestedOn            NVARCHAR(500)  NULL,
    CsvRowHash            NVARCHAR(500)  NULL,        -- RowHash from CSV
    PayerName_Raw         NVARCHAR(500)  NULL,
    PayerName             NVARCHAR(500)  NULL,
    Payer_Code            NVARCHAR(500)  NULL,
    Payer_Common_Code     NVARCHAR(500)  NULL,
    Payer_Group_Code      NVARCHAR(500)  NULL,
    Global_Payer_ID       NVARCHAR(500)  NULL,
    PayerType             NVARCHAR(500)  NULL,
    BillingProvider       NVARCHAR(500)  NULL,
    ReferringProvider     NVARCHAR(500)  NULL,
    ClinicName            NVARCHAR(500)  NULL,
    SalesRepname          NVARCHAR(500)  NULL,
    PatientID             NVARCHAR(500)  NULL,
    PatientDOB            NVARCHAR(500)  NULL,
    DateofService         NVARCHAR(500)  NULL,
    ChargeEnteredDate     NVARCHAR(500)  NULL,
    FirstBilledDate       NVARCHAR(500)  NULL,
    Panelname             NVARCHAR(500)  NULL,
    CPTCodeXUnitsXModifier NVARCHAR(MAX) NULL,
    POS                   NVARCHAR(500)  NULL,
    TOS                   NVARCHAR(500)  NULL,
    ChargeAmount          NVARCHAR(500)  NULL,
    AllowedAmount         NVARCHAR(500)  NULL,
    InsurancePayment      NVARCHAR(500)  NULL,
    PatientPayment        NVARCHAR(500)  NULL,
    TotalPayments         NVARCHAR(500)  NULL,
    InsuranceAdjustments  NVARCHAR(500)  NULL,
    PatientAdjustments    NVARCHAR(500)  NULL,
    TotalAdjustments      NVARCHAR(500)  NULL,
    InsuranceBalance      NVARCHAR(500)  NULL,
    PatientBalance        NVARCHAR(500)  NULL,
    TotalBalance          NVARCHAR(500)  NULL,
    CheckDate             NVARCHAR(500)  NULL,
    ClaimStatus           NVARCHAR(500)  NULL,
    DenialCode            NVARCHAR(MAX)  NULL,
    ICDCode               NVARCHAR(500)  NULL,
    DaystoDOS             NVARCHAR(500)  NULL,
    RollingDays           NVARCHAR(500)  NULL,
    DaystoBill            NVARCHAR(500)  NULL,
    DaystoPost            NVARCHAR(500)  NULL,
    ICDPointer            NVARCHAR(500)  NULL,
    -- Additional lab-specific fields
    UID                   NVARCHAR(500)  NULL,
    Aging                 NVARCHAR(100)  NULL,
    PatientName           NVARCHAR(1000) NULL,
    LISPatientName        NVARCHAR(1000) NULL,
    SubscriberId          NVARCHAR(1000) NULL,
    PanelType             NVARCHAR(MAX)  NULL,
    EnteredWeek           NVARCHAR(500)  NULL,
    EnteredStatus         NVARCHAR(1000) NULL,
    LastActivityDate      NVARCHAR(100)  NULL,
    EmedixSubmissionDate  NVARCHAR(100)  NULL,
    ClaimType             NVARCHAR(MAX)  NULL,
    BilledStatus          NVARCHAR(MAX)  NULL,
    BilledWeek            NVARCHAR(500)  NULL,
    PostedWeek            NVARCHAR(500)  NULL,
    ModField              NVARCHAR(100)  NULL,
    CheqNo                NVARCHAR(500)  NULL,
    DuplicatePaymentPosted NVARCHAR(100) NULL,
    ActualPayment         NVARCHAR(500)  NULL,
    ProcTotalBal          NVARCHAR(500)  NULL,
    DeniedStatus          NVARCHAR(500)  NULL,
    ScrubberEditReason    NVARCHAR(MAX)  NULL,
    EmedixRejectionDate   NVARCHAR(100)  NULL,
    EmedixRejection       NVARCHAR(500)  NULL,
    RejectionCategory     NVARCHAR(MAX)  NULL,
    TimeToPay             NVARCHAR(500)  NULL,
    PaymentPercent        NVARCHAR(100)  NULL,
    FullyPaidCount        NVARCHAR(500)  NULL,
    FullyPaidAmount       NVARCHAR(500)  NULL,
    Adjudicated           NVARCHAR(500)  NULL,
    AdjudicatedAmount     NVARCHAR(500)  NULL,
    Bucket30              NVARCHAR(500)  NULL,
    Bucket30Amount        NVARCHAR(500)  NULL,
    Bucket60              NVARCHAR(500)  NULL,
    Bucket60Amount        NVARCHAR(500)  NULL,
    InsertedDateTime      DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

-- ?? 1b. ClaimLevelDataArchive ???????????????????????????????????????????????
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ClaimLevelDataArchive')
CREATE TABLE dbo.ClaimLevelDataArchive
(
    ArchiveId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    OriginalRecordId      INT            NULL,
    ArchivedDateTime      DATETIME       NOT NULL DEFAULT GETDATE(),
    ArchiveRemark         NVARCHAR(MAX)  NULL,       -- describes what changed or 'new_file_replacement'
    FileLogId             NVARCHAR(500)  NULL,
    RunId                 NVARCHAR(500)  NULL,
    WeekFolder            NVARCHAR(500)  NULL,
    SourceFullPath        NVARCHAR(1000) NULL,
    FileName              NVARCHAR(500)  NULL,
    FileType              NVARCHAR(100)  NULL,
    RowHash               NVARCHAR(64)   NULL,
    LabID                 NVARCHAR(500)  NULL,
    LabName               NVARCHAR(500)  NULL,
    ClaimID               NVARCHAR(500)  NULL,
    AccessionNumber       NVARCHAR(500)  NULL,
    SourceFileID          NVARCHAR(1000) NULL,
    IngestedOn            NVARCHAR(500)  NULL,
    CsvRowHash            NVARCHAR(500)  NULL,
    PayerName_Raw         NVARCHAR(500)  NULL,
    PayerName             NVARCHAR(500)  NULL,
    Payer_Code            NVARCHAR(500)  NULL,
    Payer_Common_Code     NVARCHAR(500)  NULL,
    Payer_Group_Code      NVARCHAR(500)  NULL,
    Global_Payer_ID       NVARCHAR(500)  NULL,
    PayerType             NVARCHAR(500)  NULL,
    BillingProvider       NVARCHAR(500)  NULL,
    ReferringProvider     NVARCHAR(500)  NULL,
    ClinicName            NVARCHAR(500)  NULL,
    SalesRepname          NVARCHAR(500)  NULL,
    PatientID             NVARCHAR(500)  NULL,
    PatientDOB            NVARCHAR(500)  NULL,
    DateofService         NVARCHAR(500)  NULL,
    ChargeEnteredDate     NVARCHAR(500)  NULL,
    FirstBilledDate       NVARCHAR(500)  NULL,
    Panelname             NVARCHAR(500)  NULL,
    CPTCodeXUnitsXModifier NVARCHAR(MAX) NULL,
    POS                   NVARCHAR(500)  NULL,
    TOS                   NVARCHAR(500)  NULL,
    ChargeAmount          NVARCHAR(500)  NULL,
    AllowedAmount         NVARCHAR(500)  NULL,
    InsurancePayment      NVARCHAR(500)  NULL,
    PatientPayment        NVARCHAR(500)  NULL,
    TotalPayments         NVARCHAR(500)  NULL,
    InsuranceAdjustments  NVARCHAR(500)  NULL,
    PatientAdjustments    NVARCHAR(500)  NULL,
    TotalAdjustments      NVARCHAR(500)  NULL,
    InsuranceBalance      NVARCHAR(500)  NULL,
    PatientBalance        NVARCHAR(500)  NULL,
    TotalBalance          NVARCHAR(500)  NULL,
    CheckDate             NVARCHAR(500)  NULL,
    ClaimStatus           NVARCHAR(500)  NULL,
    DenialCode            NVARCHAR(MAX)  NULL,
    ICDCode               NVARCHAR(500)  NULL,
    DaystoDOS             NVARCHAR(500)  NULL,
    RollingDays           NVARCHAR(500)  NULL,
    DaystoBill            NVARCHAR(500)  NULL,
    DaystoPost            NVARCHAR(500)  NULL,
    ICDPointer            NVARCHAR(500)  NULL,
    -- Additional lab-specific fields (archived)
    UID                   NVARCHAR(500)  NULL,
    Aging                 NVARCHAR(100)  NULL,
    PatientName           NVARCHAR(1000) NULL,
    LISPatientName        NVARCHAR(1000) NULL,
    SubscriberId          NVARCHAR(1000) NULL,
    PanelType             NVARCHAR(MAX)  NULL,
    EnteredWeek           NVARCHAR(500)  NULL,
    EnteredStatus         NVARCHAR(1000) NULL,
    LastActivityDate      NVARCHAR(100)  NULL,
    EmedixSubmissionDate  NVARCHAR(100)  NULL,
    ClaimType             NVARCHAR(MAX)  NULL,
    BilledStatus          NVARCHAR(MAX)  NULL,
    BilledWeek            NVARCHAR(500)  NULL,
    PostedWeek            NVARCHAR(500)  NULL,
    ModField              NVARCHAR(100)  NULL,
    CheqNo                NVARCHAR(500)  NULL,
    DuplicatePaymentPosted NVARCHAR(100) NULL,
    ActualPayment         NVARCHAR(500)  NULL,
    ProcTotalBal          NVARCHAR(500)  NULL,
    DeniedStatus          NVARCHAR(500)  NULL,
    ScrubberEditReason    NVARCHAR(MAX)  NULL,
    EmedixRejectionDate   NVARCHAR(100)  NULL,
    EmedixRejection       NVARCHAR(500)  NULL,
    RejectionCategory     NVARCHAR(MAX)  NULL,
    TimeToPay             NVARCHAR(500)  NULL,
    PaymentPercent        NVARCHAR(100)  NULL,
    FullyPaidCount        NVARCHAR(500)  NULL,
    FullyPaidAmount       NVARCHAR(500)  NULL,
    Adjudicated           NVARCHAR(500)  NULL,
    AdjudicatedAmount     NVARCHAR(500)  NULL,
    Bucket30              NVARCHAR(500)  NULL,
    Bucket30Amount        NVARCHAR(500)  NULL,
    Bucket60              NVARCHAR(500)  NULL,
    Bucket60Amount        NVARCHAR(500)  NULL,
    OriginalInsertedDateTime DATETIME    NULL
);
GO

-- ?? 2. LineLevelData  (row-level detail from Line Level CSV) ????????????????
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LineLevelData')
CREATE TABLE dbo.LineLevelData
(
    RecordId              INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    FileLogId             NVARCHAR(500)  NULL,
    RunId                 NVARCHAR(500)  NULL,
    WeekFolder            NVARCHAR(500)  NULL,
    SourceFullPath        NVARCHAR(1000) NULL,
    FileName              NVARCHAR(500)  NULL,
    FileType              NVARCHAR(100)  NULL,
    RowHash               NVARCHAR(64)   NULL,
    LabID                 NVARCHAR(500)  NULL,
    LabName               NVARCHAR(500)  NULL,
    ClaimID               NVARCHAR(500)  NULL,
    AccessionNumber       NVARCHAR(500)  NULL,
    SourceFileID          NVARCHAR(1000) NULL,
    IngestedOn            NVARCHAR(500)  NULL,
    CsvRowHash            NVARCHAR(500)  NULL,
    PayerName_Raw         NVARCHAR(500)  NULL,
    PayerName             NVARCHAR(500)  NULL,
    Payer_Code            NVARCHAR(500)  NULL,
    Payer_Common_Code     NVARCHAR(500)  NULL,
    Payer_Group_Code      NVARCHAR(500)  NULL,
    Global_Payer_ID       NVARCHAR(500)  NULL,
    PayerType             NVARCHAR(500)  NULL,
    BillingProvider       NVARCHAR(500)  NULL,
    ReferringProvider     NVARCHAR(500)  NULL,
    ClinicName            NVARCHAR(500)  NULL,
    SalesRepname          NVARCHAR(500)  NULL,
    PatientID             NVARCHAR(500)  NULL,
    PatientDOB            NVARCHAR(500)  NULL,
    DateofService         NVARCHAR(500)  NULL,
    ChargeEnteredDate     NVARCHAR(500)  NULL,
    FirstBilledDate       NVARCHAR(500)  NULL,
    Panelname             NVARCHAR(500)  NULL,
    CPTCode               NVARCHAR(500)  NULL,
    Units                 NVARCHAR(500)  NULL,
    Modifier              NVARCHAR(500)  NULL,
    POS                   NVARCHAR(500)  NULL,
    TOS                   NVARCHAR(500)  NULL,
    ChargeAmount          NVARCHAR(500)  NULL,
    ChargeAmountPerUnit   NVARCHAR(500)  NULL,
    AllowedAmount         NVARCHAR(500)  NULL,
    AllowedAmountPerUnit  NVARCHAR(500)  NULL,
    InsurancePayment      NVARCHAR(500)  NULL,
    InsurancePaymentPerUnit NVARCHAR(500) NULL,
    PatientPayment        NVARCHAR(500)  NULL,
    PatientPaymentPerUnit NVARCHAR(500)  NULL,
    TotalPayments         NVARCHAR(500)  NULL,
    InsuranceAdjustments  NVARCHAR(500)  NULL,
    PatientAdjustments    NVARCHAR(500)  NULL,
    TotalAdjustments      NVARCHAR(500)  NULL,
    InsuranceBalance      NVARCHAR(500)  NULL,
    PatientBalance        NVARCHAR(500)  NULL,
    PatientBalancePerUnit NVARCHAR(500)  NULL,
    TotalBalance          NVARCHAR(500)  NULL,
    CheckDate             NVARCHAR(500)  NULL,
    PostingDate           NVARCHAR(500)  NULL,
    ClaimStatus           NVARCHAR(500)  NULL,
    PayStatus             NVARCHAR(500)  NULL,
    DenialCode            NVARCHAR(MAX)  NULL,
    DenialDate            NVARCHAR(500)  NULL,
    ICDCode               NVARCHAR(500)  NULL,
    DaystoDOS             NVARCHAR(500)  NULL,
    RollingDays           NVARCHAR(500)  NULL,
    DaystoBill            NVARCHAR(500)  NULL,
    DaystoPost            NVARCHAR(500)  NULL,
    ICDPointer            NVARCHAR(500)  NULL,
    InsertedDateTime      DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

-- ?? 2b. LineLevelDataArchive ????????????????????????????????????????????????
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LineLevelDataArchive')
CREATE TABLE dbo.LineLevelDataArchive
(
    ArchiveId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    OriginalRecordId      INT            NULL,
    ArchivedDateTime      DATETIME       NOT NULL DEFAULT GETDATE(),
    ArchiveRemark         NVARCHAR(MAX)  NULL,
    FileLogId             NVARCHAR(500)  NULL,
    RunId                 NVARCHAR(500)  NULL,
    WeekFolder            NVARCHAR(500)  NULL,
    SourceFullPath        NVARCHAR(1000) NULL,
    FileName              NVARCHAR(500)  NULL,
    FileType              NVARCHAR(100)  NULL,
    RowHash               NVARCHAR(64)   NULL,
    LabID                 NVARCHAR(500)  NULL,
    LabName               NVARCHAR(500)  NULL,
    ClaimID               NVARCHAR(500)  NULL,
    AccessionNumber       NVARCHAR(500)  NULL,
    SourceFileID          NVARCHAR(1000) NULL,
    IngestedOn            NVARCHAR(500)  NULL,
    CsvRowHash            NVARCHAR(500)  NULL,
    PayerName_Raw         NVARCHAR(500)  NULL,
    PayerName             NVARCHAR(500)  NULL,
    Payer_Code            NVARCHAR(500)  NULL,
    Payer_Common_Code     NVARCHAR(500)  NULL,
    Payer_Group_Code      NVARCHAR(500)  NULL,
    Global_Payer_ID       NVARCHAR(500)  NULL,
    PayerType             NVARCHAR(500)  NULL,
    BillingProvider       NVARCHAR(500)  NULL,
    ReferringProvider     NVARCHAR(500)  NULL,
    ClinicName            NVARCHAR(500)  NULL,
    SalesRepname          NVARCHAR(500)  NULL,
    PatientID             NVARCHAR(500)  NULL,
    PatientDOB            NVARCHAR(500)  NULL,
    DateofService         NVARCHAR(500)  NULL,
    ChargeEnteredDate     NVARCHAR(500)  NULL,
    FirstBilledDate       NVARCHAR(500)  NULL,
    Panelname             NVARCHAR(500)  NULL,
    CPTCode               NVARCHAR(500)  NULL,
    Units                 NVARCHAR(500)  NULL,
    Modifier              NVARCHAR(500)  NULL,
    POS                   NVARCHAR(500)  NULL,
    TOS                   NVARCHAR(500)  NULL,
    ChargeAmount          NVARCHAR(500)  NULL,
    ChargeAmountPerUnit   NVARCHAR(500)  NULL,
    AllowedAmount         NVARCHAR(500)  NULL,
    AllowedAmountPerUnit  NVARCHAR(500)  NULL,
    InsurancePayment      NVARCHAR(500)  NULL,
    InsurancePaymentPerUnit NVARCHAR(500) NULL,
    PatientPayment        NVARCHAR(500)  NULL,
    PatientPaymentPerUnit NVARCHAR(500)  NULL,
    TotalPayments         NVARCHAR(500)  NULL,
    InsuranceAdjustments  NVARCHAR(500)  NULL,
    PatientAdjustments    NVARCHAR(500)  NULL,
    TotalAdjustments      NVARCHAR(500)  NULL,
    InsuranceBalance      NVARCHAR(500)  NULL,
    PatientBalance        NVARCHAR(500)  NULL,
    PatientBalancePerUnit NVARCHAR(500)  NULL,
    TotalBalance          NVARCHAR(500)  NULL,
    CheckDate             NVARCHAR(500)  NULL,
    PostingDate           NVARCHAR(500)  NULL,
    ClaimStatus           NVARCHAR(500)  NULL,
    PayStatus             NVARCHAR(500)  NULL,
    DenialCode            NVARCHAR(MAX)  NULL,
    DenialDate            NVARCHAR(500)  NULL,
    ICDCode               NVARCHAR(500)  NULL,
    DaystoDOS             NVARCHAR(500)  NULL,
    RollingDays           NVARCHAR(500)  NULL,
    DaystoBill            NVARCHAR(500)  NULL,
    DaystoPost            NVARCHAR(500)  NULL,
    ICDPointer            NVARCHAR(500)  NULL,
    OriginalInsertedDateTime DATETIME    NULL
);
GO

-- ?? 3. TVP type for bulk-inserting ClaimLevelData rows ??????????????????????
IF NOT EXISTS (SELECT 1 FROM sys.types WHERE name = 'ClaimLevelDataTVP')
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
    ICDPointer            NVARCHAR(500)
    -- Additional lab-specific fields for TVP
    , UID                   NVARCHAR(500)
    , Aging                 NVARCHAR(100)
    , PatientName           NVARCHAR(1000)
    , LISPatientName        NVARCHAR(1000)
    , SubscriberId          NVARCHAR(1000)
    , PanelType             NVARCHAR(MAX)
    , EnteredWeek           NVARCHAR(500)
    , EnteredStatus         NVARCHAR(1000)
    , LastActivityDate      NVARCHAR(100)
    , EmedixSubmissionDate  NVARCHAR(100)
    , ClaimType             NVARCHAR(MAX)
    , BilledStatus          NVARCHAR(MAX)
    , BilledWeek            NVARCHAR(500)
    , PostedWeek            NVARCHAR(500)
    , ModField              NVARCHAR(100)
    , CheqNo                NVARCHAR(500)
    , DuplicatePaymentPosted NVARCHAR(100)
    , ActualPayment         NVARCHAR(500)
    , ProcTotalBal          NVARCHAR(500)
    , DeniedStatus          NVARCHAR(500)
    , ScrubberEditReason    NVARCHAR(MAX)
    , EmedixRejectionDate   NVARCHAR(100)
    , EmedixRejection       NVARCHAR(500)
    , RejectionCategory     NVARCHAR(MAX)
    , TimeToPay             NVARCHAR(500)
    , PaymentPercent        NVARCHAR(100)
    , FullyPaidCount        NVARCHAR(500)
    , FullyPaidAmount       NVARCHAR(500)
    , Adjudicated           NVARCHAR(500)
    , AdjudicatedAmount     NVARCHAR(500)
    , Bucket30              NVARCHAR(500)
    , Bucket30Amount        NVARCHAR(500)
    , Bucket60              NVARCHAR(500)
    , Bucket60Amount        NVARCHAR(500)
);
GO

-- ?? 4. TVP type for bulk-inserting LineLevelData rows ???????????????????????
IF NOT EXISTS (SELECT 1 FROM sys.types WHERE name = 'LineLevelDataTVP')
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
    ICDPointer            NVARCHAR(500)
);
GO

-- ?? 5. Stored procedure – bulk insert ClaimLevelData rows ???????????????????
CREATE OR ALTER PROCEDURE dbo.usp_BulkInsertClaimLevelData
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

    -- 1. Skip if this exact RunId + FileType was already processed
    IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'claimlevel')
    BEGIN
        PRINT 'RunId already in FileLog for claimlevel — skipping: ' + @RunId;
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    -- 2. Log this file run
    DECLARE @FileLogId INT;

    INSERT INTO dbo.LineClaimFileLogs
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'claimlevel', @FileCreatedDateTime);

    SET @FileLogId = SCOPE_IDENTITY();

    -- 3. Archive only CHANGED or REMOVED rows into ClaimLevelDataArchive.
    --    Unchanged rows (same RowHash) are not archived.
    --    Changed rows get a remark listing which columns differ.
    --    Removed rows (in old data but not in new file) get 'row_removed'.
    --    Single-pass inserts (no WHILE/OFFSET) for speed — archive result sets are small.
    IF EXISTS (SELECT 1 FROM dbo.ClaimLevelData)
    BEGIN
        -- 3a. Archive rows whose data changed (matched by ClaimID+LabID, RowHash differs)
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
            -- include archived column values
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

        -- 3b. Archive rows removed from the new file (in old data but not in new)
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

    -- 4. Insert new rows in chunks
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
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer
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
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer
        FROM @Rows
        ORDER BY (SELECT NULL)
        OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

        SET @InsertBatch  = @@ROWCOUNT;
        SET @InsertOffset = @InsertOffset + @ChunkSize;
    END

    SELECT @InsertOffset AS InsertedCount;
END;
GO

-- ?? 6. Stored procedure – bulk insert LineLevelData rows ????????????????????
CREATE OR ALTER PROCEDURE dbo.usp_BulkInsertLineLevelData
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

    -- 1. Skip if this exact RunId + FileType was already processed
    IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'linelevel')
    BEGIN
        PRINT 'RunId already in FileLog for linelevel — skipping: ' + @RunId;
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    -- 2. Log this file run
    DECLARE @FileLogId INT;

    INSERT INTO dbo.LineClaimFileLogs
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'linelevel', @FileCreatedDateTime);

    SET @FileLogId = SCOPE_IDENTITY();

    -- 3. Archive only CHANGED or REMOVED rows into LineLevelDataArchive.
    --    Unchanged rows (same RowHash) are not archived.
    --    Changed rows get a remark listing which columns differ.
    --    Removed rows (in old data but not in new file) get 'row_removed'.
    --    Single-pass inserts (no WHILE/OFFSET) for speed — archive result sets are small.
    IF EXISTS (SELECT 1 FROM dbo.LineLevelData)
    BEGIN
        -- 3a. Archive rows whose data changed (matched by ClaimID+LabID+CPTCode, RowHash differs)
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
                CASE WHEN ISNULL(l.ChargeAmountPerUnit,'') <> ISNULL(n.ChargeAmountPerUnit,'') THEN 'ChargeAmountPerUnit,' ELSE '' END +
                CASE WHEN ISNULL(l.AllowedAmount,'')      <> ISNULL(n.AllowedAmount,'')      THEN 'AllowedAmount,' ELSE '' END +
                CASE WHEN ISNULL(l.AllowedAmountPerUnit,'') <> ISNULL(n.AllowedAmountPerUnit,'') THEN 'AllowedAmountPerUnit,' ELSE '' END +
                CASE WHEN ISNULL(l.InsurancePayment,'')   <> ISNULL(n.InsurancePayment,'')   THEN 'InsurancePayment,' ELSE '' END +
                CASE WHEN ISNULL(l.InsurancePaymentPerUnit,'') <> ISNULL(n.InsurancePaymentPerUnit,'') THEN 'InsurancePaymentPerUnit,' ELSE '' END +
                CASE WHEN ISNULL(l.PatientPayment,'')     <> ISNULL(n.PatientPayment,'')     THEN 'PatientPayment,' ELSE '' END +
                CASE WHEN ISNULL(l.PatientPaymentPerUnit,'') <> ISNULL(n.PatientPaymentPerUnit,'') THEN 'PatientPaymentPerUnit,' ELSE '' END +
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
            l.InsertedDateTime
        FROM dbo.LineLevelData l
        INNER JOIN @Rows n ON n.ClaimID = l.ClaimID AND n.LabID = l.LabID AND n.CPTCode = l.CPTCode
        WHERE n.RowHash <> l.RowHash;

        -- 3b. Archive rows removed from the new file (in old data but not in new)
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
            l.InsertedDateTime
        FROM dbo.LineLevelData l
        LEFT JOIN @Rows n ON n.ClaimID = l.ClaimID AND n.LabID = l.LabID AND n.CPTCode = l.CPTCode
        WHERE n.ClaimID IS NULL;

        DELETE FROM dbo.LineLevelData;
    END

    -- 4. Insert new rows in chunks
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
            ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer
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
            ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer
        FROM @Rows
        ORDER BY (SELECT NULL)
        OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

        SET @InsertBatch  = @@ROWCOUNT;
        SET @InsertOffset = @InsertOffset + @ChunkSize;
    END

    SELECT @InsertOffset AS InsertedCount;
END;
GO
