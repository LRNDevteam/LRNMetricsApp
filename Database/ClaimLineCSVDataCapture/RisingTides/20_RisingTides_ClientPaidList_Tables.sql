-- ============================================================
-- RisingTides – ClientPaidList (Master) CSV tables
-- File : 20_RisingTides_ClientPaidList_Tables.sql
-- DB   : Rising_Tides
--
-- ClientPaidList is a RisingTides-only "Master" CSV, synced the same
-- way as ClaimLevel / LineLevel: latest matching file in the current
-- WeekFolder is bulk-inserted via dbo.usp_BulkInsertClientPaidListData.
--
--   dbo.ClientPaidListFileLogs   – one row per processed file
--   dbo.ClientPaidListData       – row-level detail from the CSV
--   dbo.ClientPaidListDataArchive– snapshot of rows replaced by a newer run
--   dbo.ClientPaidListDataTVP    – TVP type used by the bulk-insert SP
--                                   (created in 21_RisingTides_ClientPaidList_TVP_And_BulkInsertSP.sql)
-- ============================================================
SET NOCOUNT ON;
GO

-- ── 0. ClientPaidListFileLogs (one row per processed file) ──────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ClientPaidListFileLogs')
CREATE TABLE dbo.ClientPaidListFileLogs
(
    FileLogId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RunId                 NVARCHAR(500)  NOT NULL,   -- filename without extension, unique per run
    WeekFolder            NVARCHAR(500)  NULL,
    LabName               NVARCHAR(500)  NULL,
    SourceFullPath        NVARCHAR(1000) NULL,
    FileName              NVARCHAR(500)  NULL,
    FileType              NVARCHAR(100)  NOT NULL,   -- 'clientpaidlist'
    FileCreatedDateTime   DATETIME       NULL,
    InsertedDateTime      DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

-- ── 1. ClientPaidListData (row-level detail from ClientPaidList CSV) ────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ClientPaidListData')
CREATE TABLE dbo.ClientPaidListData
(
    RecordId              INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    FileLogId             NVARCHAR(500)  NULL,
    RunId                 NVARCHAR(500)  NULL,
    WeekFolder            NVARCHAR(500)  NULL,
    SourceFullPath        NVARCHAR(1000) NULL,
    FileName              NVARCHAR(500)  NULL,
    FileType              NVARCHAR(100)  NULL,
    RowHash               NVARCHAR(64)   NULL,        -- SHA256 of hashed columns for change detection

    -- ── Mapped CSV columns ───────────────────────────────────────────────
    SpecimenID            NVARCHAR(500)  NULL,        -- Specimen ID
    VisitNum              NVARCHAR(500)  NULL,        -- VisitNum
    PanelGroup            NVARCHAR(500)  NULL,        -- Panel Group
    Carrier               NVARCHAR(500)  NULL,        -- Carrier
    FinancialClass        NVARCHAR(500)  NULL,        -- FinancialClass
    Provider              NVARCHAR(500)  NULL,        -- Provider
    ReferringProvider     NVARCHAR(500)  NULL,        -- ReferringProvider
    Facility              NVARCHAR(500)  NULL,        -- Facility
    ChartNum              NVARCHAR(500)  NULL,        -- ChartNum
    PatientName           NVARCHAR(1000) NULL,        -- PatientName
    ClinicName            NVARCHAR(500)  NULL,        -- Clinic Name
    DOB                   NVARCHAR(500)  NULL,        -- DOB
    BeginDOS              NVARCHAR(500)  NULL,        -- BeginDOS
    DOE                   NVARCHAR(500)  NULL,        -- DOE
    LastBillDate          NVARCHAR(500)  NULL,        -- LastBillDate
    BilledUnbilled        NVARCHAR(100)  NULL,        -- Billed/Unbilled
    POS                   NVARCHAR(500)  NULL,        -- POS
    TOS                   NVARCHAR(500)  NULL,        -- TOS
    ModifierField         NVARCHAR(500)  NULL,        -- Modifier
    PrimaryDiagnosis      NVARCHAR(500)  NULL,        -- PrimaryDiagnosis
    CPTs                  NVARCHAR(MAX)  NULL,        -- CPTs
    TotalCharge           NVARCHAR(500)  NULL,        -- TotalCharge
    TotalAllowed          NVARCHAR(500)  NULL,        -- TotalAllowed
    CarrierPayment        NVARCHAR(500)  NULL,        -- CarrierPayment
    PaymentPercent        NVARCHAR(100)  NULL,        -- Payment %
    CarrierWO             NVARCHAR(500)  NULL,        -- CarrierWO
    PatientPayment        NVARCHAR(500)  NULL,        -- PatientPayment
    PatientWO             NVARCHAR(500)  NULL,        -- PatientWO
    CarrierBalance        NVARCHAR(500)  NULL,        -- CarrierBalance
    PatientBalance        NVARCHAR(500)  NULL,        -- PatientBalance
    TotalBalance          NVARCHAR(500)  NULL,        -- TotalBalance
    PostedDate            NVARCHAR(500)  NULL,        -- Posted Date
    Aging                 NVARCHAR(100)  NULL,        -- Aging
    AgingBucket           NVARCHAR(200)  NULL,        -- Aging Bucket
    DenialCode            NVARCHAR(MAX)  NULL,        -- Denial Code
    PaymentStatus         NVARCHAR(500)  NULL,        -- Payment Status
    BilledWeek            NVARCHAR(500)  NULL,        -- Billed Week
    PostedWeek            NVARCHAR(500)  NULL,        -- Posted Week
    FullyPaidCount        NVARCHAR(500)  NULL,        -- Fully Paid Count
    FullyPaidAmount       NVARCHAR(500)  NULL,        -- Fully Paid $
    AdjudicatedCount      NVARCHAR(500)  NULL,        -- Adjudicated Count
    AdjudicatedAmount     NVARCHAR(500)  NULL,        -- Adjudicated $
    Bucket30Count         NVARCHAR(500)  NULL,        -- 30 Days Count
    Bucket30Amount        NVARCHAR(500)  NULL,        -- 30 Days $
    Bucket60Count         NVARCHAR(500)  NULL,        -- 60 Days Count
    Bucket60Amount        NVARCHAR(500)  NULL,        -- 60 Days $

    InsertedDateTime      DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_ClientPaidListData_SpecimenID' AND object_id=OBJECT_ID('dbo.ClientPaidListData'))
    CREATE NONCLUSTERED INDEX IX_ClientPaidListData_SpecimenID
        ON dbo.ClientPaidListData (SpecimenID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_ClientPaidListData_RunId' AND object_id=OBJECT_ID('dbo.ClientPaidListData'))
    CREATE NONCLUSTERED INDEX IX_ClientPaidListData_RunId
        ON dbo.ClientPaidListData (RunId);
GO

-- ── 2. ClientPaidListDataArchive (snapshot of rows replaced by a newer run) ─
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ClientPaidListDataArchive')
CREATE TABLE dbo.ClientPaidListDataArchive
(
    ArchiveId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    OriginalRecordId      INT            NULL,
    ArchiveRemark         NVARCHAR(500)  NULL,

    FileLogId             NVARCHAR(500)  NULL,
    RunId                 NVARCHAR(500)  NULL,
    WeekFolder            NVARCHAR(500)  NULL,
    SourceFullPath        NVARCHAR(1000) NULL,
    FileName              NVARCHAR(500)  NULL,
    FileType              NVARCHAR(100)  NULL,
    RowHash               NVARCHAR(64)   NULL,

    SpecimenID            NVARCHAR(500)  NULL,
    VisitNum              NVARCHAR(500)  NULL,
    PanelGroup            NVARCHAR(500)  NULL,
    Carrier               NVARCHAR(500)  NULL,
    FinancialClass        NVARCHAR(500)  NULL,
    Provider              NVARCHAR(500)  NULL,
    ReferringProvider     NVARCHAR(500)  NULL,
    Facility              NVARCHAR(500)  NULL,
    ChartNum              NVARCHAR(500)  NULL,
    PatientName           NVARCHAR(1000) NULL,
    ClinicName            NVARCHAR(500)  NULL,
    DOB                   NVARCHAR(500)  NULL,
    BeginDOS              NVARCHAR(500)  NULL,
    DOE                   NVARCHAR(500)  NULL,
    LastBillDate          NVARCHAR(500)  NULL,
    BilledUnbilled        NVARCHAR(100)  NULL,
    POS                   NVARCHAR(500)  NULL,
    TOS                   NVARCHAR(500)  NULL,
    ModifierField         NVARCHAR(500)  NULL,
    PrimaryDiagnosis      NVARCHAR(500)  NULL,
    CPTs                  NVARCHAR(MAX)  NULL,
    TotalCharge           NVARCHAR(500)  NULL,
    TotalAllowed          NVARCHAR(500)  NULL,
    CarrierPayment        NVARCHAR(500)  NULL,
    PaymentPercent        NVARCHAR(100)  NULL,
    CarrierWO             NVARCHAR(500)  NULL,
    PatientPayment        NVARCHAR(500)  NULL,
    PatientWO             NVARCHAR(500)  NULL,
    CarrierBalance        NVARCHAR(500)  NULL,
    PatientBalance        NVARCHAR(500)  NULL,
    TotalBalance          NVARCHAR(500)  NULL,
    PostedDate            NVARCHAR(500)  NULL,
    Aging                 NVARCHAR(100)  NULL,
    AgingBucket           NVARCHAR(200)  NULL,
    DenialCode            NVARCHAR(MAX)  NULL,
    PaymentStatus         NVARCHAR(500)  NULL,
    BilledWeek            NVARCHAR(500)  NULL,
    PostedWeek            NVARCHAR(500)  NULL,
    FullyPaidCount        NVARCHAR(500)  NULL,
    FullyPaidAmount       NVARCHAR(500)  NULL,
    AdjudicatedCount      NVARCHAR(500)  NULL,
    AdjudicatedAmount     NVARCHAR(500)  NULL,
    Bucket30Count         NVARCHAR(500)  NULL,
    Bucket30Amount        NVARCHAR(500)  NULL,
    Bucket60Count         NVARCHAR(500)  NULL,
    Bucket60Amount        NVARCHAR(500)  NULL,

    OriginalInsertedDateTime DATETIME    NULL,
    ArchivedDateTime      DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

PRINT '20_RisingTides_ClientPaidList_Tables.sql completed.';
GO
