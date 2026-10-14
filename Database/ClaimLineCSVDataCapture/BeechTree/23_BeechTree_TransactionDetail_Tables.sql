SET NOCOUNT ON;

-- ============================================================
-- 23_BeechTree_TransactionDetail_Tables.sql
--
-- Creates three tables for the BeechTree TransactionDetail
-- Adjustment supplemental file pipeline:
--
--   1. BTTransactionDetailFileLogs
--        Separate file-receipt log (one row per XLSX processed).
--
--   2. BTTransactionDetailData
--        Raw import table — all 29 XLSX columns plus system
--        tracking columns.
--        Mandatory fields (NOT NULL):
--          VisitNumber, TransactionCode, TransactionCodeDesc
--        Wide fields:
--          TransactionCodeDesc  NVARCHAR(MAX)  (>1000 chars)
--          PrimaryDxICD10       NVARCHAR(MAX)  (>2000 chars)
--
--   3. BTWOSummary
--        Aggregated summary rebuilt on every new file receipt.
--        11 user-facing columns; ClaimID / CdateofService /
--        UpdatedDateTime / ClaimFileSourcename are populated
--        by cross-matching with dbo.ClaimLevelData.
--
-- Safe to re-run: all CREATE TABLE statements are guarded by
-- IF NOT EXISTS (OBJECT_ID(...) IS NULL).
-- ============================================================

-- ── 1. BTTransactionDetailFileLogs ───────────────────────────

IF OBJECT_ID('dbo.BTTransactionDetailFileLogs', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BTTransactionDetailFileLogs
    (
        FileLogId            BIGINT        IDENTITY(1,1) NOT NULL
                             CONSTRAINT PK_BTTransDetailFileLogs PRIMARY KEY CLUSTERED,
        LabName              NVARCHAR(200) NULL,
        FileName             NVARCHAR(500) NULL,
        SourceFullPath       NVARCHAR(MAX) NULL,
        WeekFolder           NVARCHAR(500) NULL,
        RunId                NVARCHAR(500) NULL,
        FileCreatedDateTime  DATETIME      NULL,
        InsertedDateTime     DATETIME      NOT NULL DEFAULT GETDATE(),
        [RowCount]           INT           NULL
    );
    PRINT 'dbo.BTTransactionDetailFileLogs created.';
END
ELSE
    PRINT 'dbo.BTTransactionDetailFileLogs already exists — skipped.';

-- ── 2. BTTransactionDetailData ───────────────────────────────

IF OBJECT_ID('dbo.BTTransactionDetailData', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BTTransactionDetailData
    (
        -- System / tracking columns
        Id               BIGINT        IDENTITY(1,1) NOT NULL
                         CONSTRAINT PK_BTTransDetailData PRIMARY KEY CLUSTERED,
        FileLogId        NVARCHAR(100) NULL,
        RunId            NVARCHAR(500) NULL,
        WeekFolder       NVARCHAR(500) NULL,
        SourceFullPath   NVARCHAR(MAX) NULL,
        FileName         NVARCHAR(500) NULL,
        FileType         NVARCHAR(100) NULL,
        RowHash          NVARCHAR(MAX) NULL,

        -- Data columns (match XLSX field headings)
        OfficeKey            NVARCHAR(500) NULL,
        TransactionType      NVARCHAR(500) NULL,
        ChartNumber          NVARCHAR(500) NULL,
        PatientName          NVARCHAR(1000) NULL,
        FinancialClass       NVARCHAR(500) NULL,
        VisitNumber          NVARCHAR(500) NOT NULL,          -- mandatory
        FacilityName         NVARCHAR(1000) NULL,
        ProviderProfile      NVARCHAR(1000) NULL,
        ChargeCode           NVARCHAR(500) NULL,
        TransactionCode      NVARCHAR(500) NOT NULL,          -- mandatory
        TransactionCodeDesc  NVARCHAR(MAX) NOT NULL,          -- mandatory, >1000 chars
        Modifiers            NVARCHAR(500) NULL,
        VisitPrimaryCarrier  NVARCHAR(1000) NULL,
        VisitSecondaryCarrier NVARCHAR(1000) NULL,
        TransactionCarrier   NVARCHAR(1000) NULL,
        PrimaryDxICD9        NVARCHAR(500) NULL,
        PrimaryDxICD10       NVARCHAR(MAX) NULL,              -- may be >2000 chars
        PaymentMethod        NVARCHAR(500) NULL,
        CheckNumber          NVARCHAR(500) NULL,
        DateOfService        NVARCHAR(100) NULL,
        DateOfEntry          NVARCHAR(100) NULL,
        DateOfDeposit        NVARCHAR(100) NULL,
        Void                 NVARCHAR(100) NULL,
        Units                NVARCHAR(100) NULL,
        Charges              NVARCHAR(500) NULL,
        PatientPayments      NVARCHAR(500) NULL,
        InsurancePayments    NVARCHAR(500) NULL,
        TotalPayments        NVARCHAR(500) NULL,
        Adjustments          NVARCHAR(500) NULL,

        InsertedDateTime DATETIME NOT NULL DEFAULT GETDATE()
    );
    PRINT 'dbo.BTTransactionDetailData created.';
END
ELSE
    PRINT 'dbo.BTTransactionDetailData already exists — skipped.';

-- ── 3. BTWOSummary ───────────────────────────────────────────

IF OBJECT_ID('dbo.BTWOSummary', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BTWOSummary
    (
        Id                  BIGINT        IDENTITY(1,1) NOT NULL
                            CONSTRAINT PK_BTWOSummary PRIMARY KEY CLUSTERED,

        -- Populated from BTTransactionDetailData on every rebuild
        VisitNumber         NVARCHAR(500) NULL,
        TransactionCode     NVARCHAR(500) NULL,
        TransactionCodeDesc NVARCHAR(MAX) NULL,
        TransactionDetail   NVARCHAR(MAX) NULL,   -- derived: TransactionCode + ' - ' + TransactionCodeDesc
        TDateofService      NVARCHAR(100) NULL,   -- Date of Service from the XLSX
        CreatedDateTime     DATETIME      NULL,
        WOFileName          NVARCHAR(500) NULL,

        -- Populated by cross-match with dbo.ClaimLevelData
        ClaimID             NVARCHAR(500) NULL,
        CdateofService      NVARCHAR(100) NULL,
        UpdatedDateTime     DATETIME      NULL,
        ClaimFileSourcename NVARCHAR(MAX) NULL
    );
    PRINT 'dbo.BTWOSummary created.';
END
ELSE
    PRINT 'dbo.BTWOSummary already exists — skipped.';

GO

PRINT '23_BeechTree_TransactionDetail_Tables.sql completed successfully.';
GO
