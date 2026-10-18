SET NOCOUNT ON;

-- ============================================================
-- 24_BeechTree_TransactionDetail_TVP_And_SP.sql
--
-- Creates the TVP type and bulk-insert stored procedure for
-- the BeechTree TransactionDetail Adjustment supplemental file.
--
-- Run AFTER 23_BeechTree_TransactionDetail_Tables.sql.
--
-- Steps:
--   1. Drop dbo.usp_BulkInsertBTTransactionDetailData (if any)
--      — must precede TVP drop due to reference dependency.
--   2. Drop and recreate dbo.BTTransactionDetailDataTVP.
--   3. Create dbo.usp_BulkInsertBTTransactionDetailData.
--
-- SP behaviour:
--   - Logs the file to dbo.BTTransactionDetailFileLogs.
--   - Inserts all TVP rows into dbo.BTTransactionDetailData.
--   - No RunId dedup / skip logic (file is always processed).
--   - Returns @@ROWCOUNT (rows inserted) as scalar.
-- ============================================================

-- ── Step 1: Drop the SP first (references the TVP type) ──────

IF OBJECT_ID('dbo.usp_BulkInsertBTTransactionDetailData', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_BulkInsertBTTransactionDetailData;
GO

-- ── Step 2: Drop and recreate the TVP type ───────────────────

IF TYPE_ID(N'dbo.BTTransactionDetailDataTVP') IS NOT NULL
    DROP TYPE dbo.BTTransactionDetailDataTVP;
GO

CREATE TYPE dbo.BTTransactionDetailDataTVP AS TABLE
(
    -- System columns (always present — matches ClaimLineDbService.CreateTvpSchema)
    FileLogId        NVARCHAR(100)  NULL,
    RunId            NVARCHAR(500)  NULL,
    WeekFolder       NVARCHAR(500)  NULL,
    SourceFullPath   NVARCHAR(MAX)  NULL,
    FileName         NVARCHAR(500)  NULL,
    FileType         NVARCHAR(100)  NULL,
    RowHash          NVARCHAR(MAX)  NULL,

    -- Data columns (29 XLSX field headings — must match FieldMappings JSON order)
    OfficeKey             NVARCHAR(500)  NULL,
    TransactionType       NVARCHAR(500)  NULL,
    ChartNumber           NVARCHAR(500)  NULL,
    PatientName           NVARCHAR(1000) NULL,
    FinancialClass        NVARCHAR(500)  NULL,
    VisitNumber           NVARCHAR(500)  NULL,
    FacilityName          NVARCHAR(1000) NULL,
    ProviderProfile       NVARCHAR(1000) NULL,
    ChargeCode            NVARCHAR(500)  NULL,
    TransactionCode       NVARCHAR(500)  NULL,
    TransactionCodeDesc   NVARCHAR(MAX)  NULL,
    Modifiers             NVARCHAR(500)  NULL,
    VisitPrimaryCarrier   NVARCHAR(1000) NULL,
    VisitSecondaryCarrier NVARCHAR(1000) NULL,
    TransactionCarrier    NVARCHAR(1000) NULL,
    PrimaryDxICD9         NVARCHAR(500)  NULL,
    PrimaryDxICD10        NVARCHAR(MAX)  NULL,
    PaymentMethod         NVARCHAR(500)  NULL,
    CheckNumber           NVARCHAR(500)  NULL,
    DateOfService         NVARCHAR(100)  NULL,
    DateOfEntry           NVARCHAR(100)  NULL,
    DateOfDeposit         NVARCHAR(100)  NULL,
    Void                  NVARCHAR(100)  NULL,
    Units                 NVARCHAR(100)  NULL,
    Charges               NVARCHAR(500)  NULL,
    PatientPayments       NVARCHAR(500)  NULL,
    InsurancePayments     NVARCHAR(500)  NULL,
    TotalPayments         NVARCHAR(500)  NULL,
    Adjustments           NVARCHAR(500)  NULL
);
GO

PRINT 'dbo.BTTransactionDetailDataTVP created.';
GO

-- ── Step 3: Create the bulk-insert SP ────────────────────────

CREATE PROCEDURE dbo.usp_BulkInsertBTTransactionDetailData
    @Rows                dbo.BTTransactionDetailDataTVP READONLY,
    @LabName             NVARCHAR(200) = NULL,
    @WeekFolder          NVARCHAR(500) = NULL,
    @SourceFilePath      NVARCHAR(MAX) = NULL,
    @RunId               NVARCHAR(500) = NULL,
    @FileName            NVARCHAR(500) = NULL,
    @FileCreatedDateTime DATETIME      = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- ── 0. Skip if this exact file was already processed ─────
    --    Uses FileName as the unique key (e.g. "TransactionDetail Adjustment_05.22.2026-05.28.2026.xlsx").
    --    A new file with a different date range in the name will always pass through.
    IF EXISTS (SELECT 1 FROM dbo.BTTransactionDetailFileLogs WHERE FileName = @FileName)
    BEGIN
        SELECT 0 AS InsertedCount;   -- already loaded, caller sees 0 → no BTWOSummary rebuild
        RETURN;
    END

    -- ── 1. Log the file receipt ───────────────────────────────
    DECLARE @RowCount INT = (SELECT COUNT(*) FROM @Rows);

    INSERT INTO dbo.BTTransactionDetailFileLogs
        (LabName, FileName, SourceFullPath, WeekFolder, RunId,
         FileCreatedDateTime, InsertedDateTime, [RowCount])
    VALUES
        (@LabName, @FileName, @SourceFilePath, @WeekFolder, @RunId,
         @FileCreatedDateTime, GETDATE(), @RowCount);

    -- ── 2. Insert all rows into the raw data table ────────────
    INSERT INTO dbo.BTTransactionDetailData
    (
        FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
        OfficeKey, TransactionType, ChartNumber, PatientName, FinancialClass,
        VisitNumber, FacilityName, ProviderProfile, ChargeCode,
        TransactionCode, TransactionCodeDesc, Modifiers,
        VisitPrimaryCarrier, VisitSecondaryCarrier, TransactionCarrier,
        PrimaryDxICD9, PrimaryDxICD10, PaymentMethod, CheckNumber,
        DateOfService, DateOfEntry, DateOfDeposit,
        Void, Units, Charges, PatientPayments, InsurancePayments,
        TotalPayments, Adjustments
    )
    SELECT
        FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
        OfficeKey, TransactionType, ChartNumber, PatientName, FinancialClass,
        VisitNumber, FacilityName, ProviderProfile, ChargeCode,
        TransactionCode, TransactionCodeDesc, Modifiers,
        VisitPrimaryCarrier, VisitSecondaryCarrier, TransactionCarrier,
        PrimaryDxICD9, PrimaryDxICD10, PaymentMethod, CheckNumber,
        DateOfService, DateOfEntry, DateOfDeposit,
        Void, Units, Charges, PatientPayments, InsurancePayments,
        TotalPayments, Adjustments
    FROM @Rows;

    -- ── 3. Return inserted row count ──────────────────────────
    SELECT @@ROWCOUNT AS InsertedCount;
END
GO

PRINT 'dbo.usp_BulkInsertBTTransactionDetailData created.';
GO

PRINT '24_BeechTree_TransactionDetail_TVP_And_SP.sql completed successfully.';
GO
