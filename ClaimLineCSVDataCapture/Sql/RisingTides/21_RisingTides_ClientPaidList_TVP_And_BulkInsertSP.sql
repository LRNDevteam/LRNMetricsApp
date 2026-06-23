-- ============================================================
-- RisingTides – ClientPaidList TVP type + bulk-insert SP
-- File : 21_RisingTides_ClientPaidList_TVP_And_BulkInsertSP.sql
-- DB   : Rising_Tides
-- Depends on : 20_RisingTides_ClientPaidList_Tables.sql
--
-- Mirrors the ClaimLevel / LineLevel bulk-insert pattern:
--   1. Skip if this RunId + FileType ('clientpaidlist') was already processed
--   2. Log the file in ClientPaidListFileLogs
--   3. Snapshot all current rows into ClientPaidListDataArchive
--      (ClientPaidList is a "Master" file – the whole table is replaced
--       on every run, so the prior snapshot is archived wholesale
--       rather than diffed column-by-column)
--   4. Delete all current rows from ClientPaidListData
--   5. Chunked re-insert from the @Rows TVP
-- ============================================================
SET NOCOUNT ON;
GO

-- ── TVP type for bulk-inserting ClientPaidListData rows ─────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.types WHERE name = 'ClientPaidListDataTVP')
CREATE TYPE dbo.ClientPaidListDataTVP AS TABLE
(
    FileLogId             NVARCHAR(500),
    RunId                 NVARCHAR(500),
    WeekFolder            NVARCHAR(500),
    SourceFullPath        NVARCHAR(1000),
    FileName              NVARCHAR(500),
    FileType              NVARCHAR(100),
    RowHash               NVARCHAR(64),

    SpecimenID            NVARCHAR(500),
    VisitNum              NVARCHAR(500),
    PanelGroup            NVARCHAR(500),
    Carrier               NVARCHAR(500),
    FinancialClass        NVARCHAR(500),
    Provider              NVARCHAR(500),
    ReferringProvider     NVARCHAR(500),
    Facility              NVARCHAR(500),
    ChartNum              NVARCHAR(500),
    PatientName           NVARCHAR(1000),
    ClinicName            NVARCHAR(500),
    DOB                   NVARCHAR(500),
    BeginDOS              NVARCHAR(500),
    DOE                   NVARCHAR(500),
    LastBillDate          NVARCHAR(500),
    BilledUnbilled        NVARCHAR(100),
    POS                   NVARCHAR(500),
    TOS                   NVARCHAR(500),
    ModifierField         NVARCHAR(500),
    PrimaryDiagnosis      NVARCHAR(500),
    CPTs                  NVARCHAR(MAX),
    TotalCharge           NVARCHAR(500),
    TotalAllowed          NVARCHAR(500),
    CarrierPayment        NVARCHAR(500),
    PaymentPercent        NVARCHAR(100),
    CarrierWO             NVARCHAR(500),
    PatientPayment        NVARCHAR(500),
    PatientWO             NVARCHAR(500),
    CarrierBalance        NVARCHAR(500),
    PatientBalance        NVARCHAR(500),
    TotalBalance          NVARCHAR(500),
    PostedDate            NVARCHAR(500),
    Aging                 NVARCHAR(100),
    AgingBucket           NVARCHAR(200),
    DenialCode            NVARCHAR(MAX),
    PaymentStatus         NVARCHAR(500),
    BilledWeek            NVARCHAR(500),
    PostedWeek            NVARCHAR(500),
    FullyPaidCount        NVARCHAR(500),
    FullyPaidAmount       NVARCHAR(500),
    AdjudicatedCount      NVARCHAR(500),
    AdjudicatedAmount     NVARCHAR(500),
    Bucket30Count         NVARCHAR(500),
    Bucket30Amount        NVARCHAR(500),
    Bucket60Count         NVARCHAR(500),
    Bucket60Amount        NVARCHAR(500)
);
GO

-- ── Stored procedure – bulk insert ClientPaidListData rows ──────────────────
CREATE OR ALTER PROCEDURE dbo.usp_BulkInsertClientPaidListData
    @Rows               dbo.ClientPaidListDataTVP READONLY,
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

    -- 1. Skip only if the RunId is unchanged from the last processed run.
    --    ClientPaidList is a recurring "Master" file (often reused/regenerated
    --    weekly under the same naming), so we compare against the most recent
    --    RunId on file rather than checking for any historical match — if the
    --    incoming RunId differs from the last one, the data is (re)inserted.
    DECLARE @LastRunId NVARCHAR(500);

    SELECT TOP (1) @LastRunId = RunId
    FROM dbo.ClientPaidListFileLogs
    WHERE FileType = 'clientpaidlist'
    ORDER BY FileLogId DESC;

    IF @LastRunId IS NOT NULL AND @LastRunId = @RunId
    BEGIN
        PRINT 'RunId unchanged since last run for clientpaidlist – skipping: ' + @RunId;
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    -- 2. Log this file run
    DECLARE @FileLogId INT;

    INSERT INTO dbo.ClientPaidListFileLogs
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'clientpaidlist', @FileCreatedDateTime);

    SET @FileLogId = SCOPE_IDENTITY();

    -- 3. Snapshot all current rows into ClientPaidListDataArchive before replacing them.
    --    ClientPaidList is a "Master" file: the whole table is refreshed on every run,
    --    so prior rows are archived wholesale (no per-column diff) for traceability.
    IF EXISTS (SELECT 1 FROM dbo.ClientPaidListData)
    BEGIN
        INSERT INTO dbo.ClientPaidListDataArchive
        (
            OriginalRecordId, ArchiveRemark,
            FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
            SpecimenID, VisitNum, PanelGroup, Carrier, FinancialClass, Provider, ReferringProvider,
            Facility, ChartNum, PatientName, ClinicName, DOB, BeginDOS, DOE, LastBillDate,
            BilledUnbilled, POS, TOS, ModifierField, PrimaryDiagnosis, CPTs,
            TotalCharge, TotalAllowed, CarrierPayment, PaymentPercent, CarrierWO,
            PatientPayment, PatientWO, CarrierBalance, PatientBalance, TotalBalance,
            PostedDate, Aging, AgingBucket, DenialCode, PaymentStatus,
            BilledWeek, PostedWeek, FullyPaidCount, FullyPaidAmount,
            AdjudicatedCount, AdjudicatedAmount, Bucket30Count, Bucket30Amount,
            Bucket60Count, Bucket60Amount,
            OriginalInsertedDateTime
        )
        SELECT
            d.RecordId,
            'replaced_by_run: ' + @RunId,
            d.FileLogId, d.RunId, d.WeekFolder, d.SourceFullPath, d.FileName, d.FileType, d.RowHash,
            d.SpecimenID, d.VisitNum, d.PanelGroup, d.Carrier, d.FinancialClass, d.Provider, d.ReferringProvider,
            d.Facility, d.ChartNum, d.PatientName, d.ClinicName, d.DOB, d.BeginDOS, d.DOE, d.LastBillDate,
            d.BilledUnbilled, d.POS, d.TOS, d.ModifierField, d.PrimaryDiagnosis, d.CPTs,
            d.TotalCharge, d.TotalAllowed, d.CarrierPayment, d.PaymentPercent, d.CarrierWO,
            d.PatientPayment, d.PatientWO, d.CarrierBalance, d.PatientBalance, d.TotalBalance,
            d.PostedDate, d.Aging, d.AgingBucket, d.DenialCode, d.PaymentStatus,
            d.BilledWeek, d.PostedWeek, d.FullyPaidCount, d.FullyPaidAmount,
            d.AdjudicatedCount, d.AdjudicatedAmount, d.Bucket30Count, d.Bucket30Amount,
            d.Bucket60Count, d.Bucket60Amount,
            d.InsertedDateTime
        FROM dbo.ClientPaidListData d;

        -- 4. Delete all current rows (full refresh)
        DELETE FROM dbo.ClientPaidListData;
    END

    -- 5. Chunked re-insert from the @Rows TVP
    DECLARE @Total INT = (SELECT COUNT(*) FROM @Rows);
    DECLARE @Offset INT = 0;
    DECLARE @Inserted INT = 0;

    IF @ChunkSize IS NULL OR @ChunkSize <= 0 SET @ChunkSize = 5000;

    WHILE @Offset < @Total
    BEGIN
        INSERT INTO dbo.ClientPaidListData
        (
            FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
            SpecimenID, VisitNum, PanelGroup, Carrier, FinancialClass, Provider, ReferringProvider,
            Facility, ChartNum, PatientName, ClinicName, DOB, BeginDOS, DOE, LastBillDate,
            BilledUnbilled, POS, TOS, ModifierField, PrimaryDiagnosis, CPTs,
            TotalCharge, TotalAllowed, CarrierPayment, PaymentPercent, CarrierWO,
            PatientPayment, PatientWO, CarrierBalance, PatientBalance, TotalBalance,
            PostedDate, Aging, AgingBucket, DenialCode, PaymentStatus,
            BilledWeek, PostedWeek, FullyPaidCount, FullyPaidAmount,
            AdjudicatedCount, AdjudicatedAmount, Bucket30Count, Bucket30Amount,
            Bucket60Count, Bucket60Amount
        )
        SELECT
            CAST(@FileLogId AS NVARCHAR(500)), RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
            SpecimenID, VisitNum, PanelGroup, Carrier, FinancialClass, Provider, ReferringProvider,
            Facility, ChartNum, PatientName, ClinicName, DOB, BeginDOS, DOE, LastBillDate,
            BilledUnbilled, POS, TOS, ModifierField, PrimaryDiagnosis, CPTs,
            TotalCharge, TotalAllowed, CarrierPayment, PaymentPercent, CarrierWO,
            PatientPayment, PatientWO, CarrierBalance, PatientBalance, TotalBalance,
            PostedDate, Aging, AgingBucket, DenialCode, PaymentStatus,
            BilledWeek, PostedWeek, FullyPaidCount, FullyPaidAmount,
            AdjudicatedCount, AdjudicatedAmount, Bucket30Count, Bucket30Amount,
            Bucket60Count, Bucket60Amount
        FROM @Rows
        ORDER BY (SELECT NULL)
        OFFSET @Offset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

        SET @Inserted = @Inserted + @@ROWCOUNT;
        SET @Offset = @Offset + @ChunkSize;
    END

    SELECT @Inserted AS InsertedCount;
END
GO

PRINT '21_RisingTides_ClientPaidList_TVP_And_BulkInsertSP.sql completed.';
GO
