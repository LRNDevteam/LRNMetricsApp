-- =============================================================================
-- 02_AlterColumns_CPTCode_ToMax.sql
--
-- Widens ActualCPTCode and ExpectedCPTCode from NVARCHAR(500) to NVARCHAR(MAX)
-- in every object that defines them:
--
--   1. dbo.CodingValidation          (base table, live rows)
--   2. dbo.CodingValidationData      (archive table - if it exists)
--   3. dbo.CodingValidationTVP       (table-valued parameter type)
--   4. dbo.usp_BulkInsertCodingValidation (re-created after TVP change)
--
-- HOW TO RUN:
--   Open in SSMS ? connect to the target database ? Execute (F5).
--   No SQLCMD mode required.  No $(DbName) variable.
--
-- Safe to re-run: ALTER TABLE steps are guarded by current column length.
-- =============================================================================

-- ??? 1. dbo.CodingValidation (live table) ???????????????????????????????????

IF COL_LENGTH('dbo.CodingValidation', 'ActualCPTCode') <> -1
   OR COL_LENGTH('dbo.CodingValidation', 'ActualCPTCode') IS NULL
BEGIN
    ALTER TABLE dbo.CodingValidation
        ALTER COLUMN ActualCPTCode NVARCHAR(MAX) NULL;
    PRINT 'dbo.CodingValidation.ActualCPTCode  -> NVARCHAR(MAX)';
END
ELSE
    PRINT 'dbo.CodingValidation.ActualCPTCode  already NVARCHAR(MAX) - skipped.';

IF COL_LENGTH('dbo.CodingValidation', 'ExpectedCPTCode') <> -1
   OR COL_LENGTH('dbo.CodingValidation', 'ExpectedCPTCode') IS NULL
BEGIN
    ALTER TABLE dbo.CodingValidation
        ALTER COLUMN ExpectedCPTCode NVARCHAR(MAX) NULL;
    PRINT 'dbo.CodingValidation.ExpectedCPTCode -> NVARCHAR(MAX)';
END
ELSE
    PRINT 'dbo.CodingValidation.ExpectedCPTCode already NVARCHAR(MAX) - skipped.';
GO

-- ??? 2. dbo.CodingValidationData (archive table - only if it exists) ????????

IF OBJECT_ID('dbo.CodingValidationData', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.CodingValidationData', 'ActualCPTCode') <> -1
       OR COL_LENGTH('dbo.CodingValidationData', 'ActualCPTCode') IS NULL
    BEGIN
        ALTER TABLE dbo.CodingValidationData
            ALTER COLUMN ActualCPTCode NVARCHAR(MAX) NULL;
        PRINT 'dbo.CodingValidationData.ActualCPTCode  -> NVARCHAR(MAX)';
    END
    ELSE
        PRINT 'dbo.CodingValidationData.ActualCPTCode  already NVARCHAR(MAX) - skipped.';

    IF COL_LENGTH('dbo.CodingValidationData', 'ExpectedCPTCode') <> -1
       OR COL_LENGTH('dbo.CodingValidationData', 'ExpectedCPTCode') IS NULL
    BEGIN
        ALTER TABLE dbo.CodingValidationData
            ALTER COLUMN ExpectedCPTCode NVARCHAR(MAX) NULL;
        PRINT 'dbo.CodingValidationData.ExpectedCPTCode -> NVARCHAR(MAX)';
    END
    ELSE
        PRINT 'dbo.CodingValidationData.ExpectedCPTCode already NVARCHAR(MAX) - skipped.';
END
ELSE
    PRINT 'dbo.CodingValidationData does not exist - skipped.';
GO

-- ??? 3. dbo.CodingValidationTVP ?????????????????????????????????????????????
--
--  TVP types cannot be altered in place.
--  Steps:  drop the procedure that owns the type ? drop type ? re-create type
--          ? re-create procedure.

IF OBJECT_ID('dbo.usp_BulkInsertCodingValidation', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_BulkInsertCodingValidation;
GO

IF EXISTS (SELECT 1 FROM sys.types WHERE name = 'CodingValidationTVP' AND is_user_defined = 1)
    DROP TYPE dbo.CodingValidationTVP;
GO

-- Re-create TVP with exact column list from 01_CreateTables.sql
-- (PatientDOB, ChargeEnteredDate, FirstBillDate, POS, TOS,
--  AllowedAmount, InsurancePayment, PatientPayment  are present here)
CREATE TYPE dbo.CodingValidationTVP AS TABLE
(
    FileLogId                                    NVARCHAR(500),
    WeekFolder                                   NVARCHAR(500),
    SourceFilePath                               NVARCHAR(500),
    RunNumber                                    NVARCHAR(500),
    AccessionNo                                  NVARCHAR(500),
    VisitNumber                                  NVARCHAR(500),
    PayerName_Raw                                NVARCHAR(500),
    Carrier                                      NVARCHAR(500),
    Payer_Code                                   NVARCHAR(500),
    PayerCommonCode                              NVARCHAR(500),
    Payer_Group_Code                             NVARCHAR(500),
    Global_Payer_ID                              NVARCHAR(500),
    PayerType                                    NVARCHAR(500),
    BillingProvider                              NVARCHAR(500),
    ReferringProvider                            NVARCHAR(500),
    ClinicName                                   NVARCHAR(500),
    SalesRepname                                 NVARCHAR(500),
    PatientID                                    NVARCHAR(500),
    PatientDOB                                   NVARCHAR(500),
    DateofService                                NVARCHAR(500),
    ChargeEnteredDate                            NVARCHAR(500),
    FirstBillDate                                NVARCHAR(500),
    PanelName                                    NVARCHAR(500),
    POS                                          NVARCHAR(500),
    TOS                                          NVARCHAR(500),
    TotalCharge                                  NVARCHAR(500),
    AllowedAmount                                NVARCHAR(500),
    InsurancePayment                             NVARCHAR(500),
    PatientPayment                               NVARCHAR(500),
    TotalPayments                                NVARCHAR(500),
    InsuranceAdjustments                         NVARCHAR(500),
    PatientAdjustments                           NVARCHAR(500),
    TotalAdjustments                             NVARCHAR(500),
    InsuranceBalance                             NVARCHAR(500),
    PatientBalance                               NVARCHAR(500),
    TotalBalance                                 NVARCHAR(500),
    CheckDate                                    NVARCHAR(500),
    ClaimStatus                                  NVARCHAR(500),
    DenialCode                                   NVARCHAR(MAX),
    ICDCode                                      NVARCHAR(500),
    DaystoDOS                                    NVARCHAR(500),
    RollingDays                                  NVARCHAR(500),
    DaystoBill                                   NVARCHAR(500),
    DaystoPost                                   NVARCHAR(500),
    ICDPointer                                   NVARCHAR(500),
    ActualCPTCode                                NVARCHAR(MAX),   -- widened
    ExpectedCPTCode                              NVARCHAR(MAX),   -- widened
    MissingCPTCodes                              NVARCHAR(MAX),
    AdditionalCPTCodes                           NVARCHAR(MAX),
    MissingCPT_Charges                           NVARCHAR(500),
    MissingCPT_ChargeSource                      NVARCHAR(500),
    AdditionalCPT_Charges                        NVARCHAR(500),
    AdditionalCPT_ChargeSource                   NVARCHAR(500),
    ExpectedCharges                              NVARCHAR(500),
    ValidationStatus                             NVARCHAR(MAX),
    Remarks                                      NVARCHAR(MAX),
    MissingCPT_AvgAllowedAmount                  NVARCHAR(500),
    MissingCPT_AvgPaidAmount                     NVARCHAR(500),
    MissingCPT_AvgPatientResponsibilityAmount     NVARCHAR(500),
    AdditionalCPT_AvgAllowedAmount               NVARCHAR(500),
    AdditionalCPT_AvgPaidAmount                  NVARCHAR(500),
    AdditionalCPT_AvgPatientResponsibilityAmount  NVARCHAR(500),
    LabID                                        NVARCHAR(500),
    LabName                                      NVARCHAR(500)
);
GO

PRINT 'dbo.CodingValidationTVP re-created with NVARCHAR(MAX) for ActualCPTCode / ExpectedCPTCode';
GO

-- ??? 4. Re-create dbo.usp_BulkInsertCodingValidation ????????????????????????
--  Exact body from 01_CreateTables.sql — column names match the real table.

CREATE OR ALTER PROCEDURE dbo.usp_BulkInsertCodingValidation
    @Rows                NVARCHAR(500)  = NULL,   -- placeholder; actual param below
    @RowsTVP             dbo.CodingValidationTVP READONLY,
    @LabName             NVARCHAR(500),
    @WeekFolder          NVARCHAR(500),
    @SourceFilePath      NVARCHAR(500),
    @RunId               NVARCHAR(500),
    @FileName            NVARCHAR(500),
    @FileCreatedDateTime DATETIME = NULL,
    @ChunkSize           INT = 1000
AS
BEGIN
    RAISERROR('Use the parameter name @RowsTVP, not @Rows', 16, 1);
END;
GO

-- Drop the placeholder and re-create with the correct signature:
DROP PROCEDURE dbo.usp_BulkInsertCodingValidation;
GO

CREATE OR ALTER PROCEDURE dbo.usp_BulkInsertCodingValidation
    @Rows                dbo.CodingValidationTVP READONLY,
    @LabName             NVARCHAR(500),
    @WeekFolder          NVARCHAR(500),
    @SourceFilePath      NVARCHAR(500),
    @RunId               NVARCHAR(500),
    @FileName            NVARCHAR(500),
    @FileCreatedDateTime DATETIME = NULL,
    @ChunkSize           INT = 1000
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Skip if this RunId was already processed
    IF EXISTS (SELECT 1 FROM dbo.CodingValidationFileLog WHERE RunId = @RunId)
    BEGIN
        PRINT 'RunId already in FileLog — skipping: ' + @RunId;
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    -- 2. Log this file run
    DECLARE @FileLogId INT;

    INSERT INTO dbo.CodingValidationFileLog
        (RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
    VALUES
        (@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'codingmaster', @FileCreatedDateTime);

    SET @FileLogId = SCOPE_IDENTITY();

    -- 3. Archive existing rows for this lab/week into CodingValidationData
    IF EXISTS (
        SELECT 1 FROM dbo.CodingValidation
        WHERE LabName = @LabName AND WeekFolder = @WeekFolder
    )
    BEGIN
        DECLARE @ArchiveOffset INT = 0;
        DECLARE @ArchiveBatch  INT = 1;

        WHILE @ArchiveBatch > 0
        BEGIN
            INSERT INTO dbo.CodingValidationData
            (
                OriginalReportId, FileLogId, WeekFolder, SourceFilePath, RunNumber,
                AccessionNo, VisitNumber, PayerName_Raw, Carrier,
                Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
                BillingProvider, ReferringProvider, ClinicName, SalesRepname,
                PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
                PanelName, POS, TOS,
                TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
                InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
                InsuranceBalance, PatientBalance, TotalBalance,
                CheckDate, ClaimStatus, DenialCode, ICDCode,
                DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
                ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
                MissingCPT_Charges, MissingCPT_ChargeSource,
                AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
                ValidationStatus, Remarks,
                MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount,
                MissingCPT_AvgPatientResponsibilityAmount,
                AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount,
                AdditionalCPT_AvgPatientResponsibilityAmount,
                LabID, LabName, OriginalInsertedDateTime
            )
            SELECT
                ReportId, FileLogId, WeekFolder, SourceFilePath, RunNumber,
                AccessionNo, VisitNumber, PayerName_Raw, Carrier,
                Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
                BillingProvider, ReferringProvider, ClinicName, SalesRepname,
                PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
                PanelName, POS, TOS,
                TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
                InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
                InsuranceBalance, PatientBalance, TotalBalance,
                CheckDate, ClaimStatus, DenialCode, ICDCode,
                DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
                ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
                MissingCPT_Charges, MissingCPT_ChargeSource,
                AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
                ValidationStatus, Remarks,
                MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount,
                MissingCPT_AvgPatientResponsibilityAmount,
                AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount,
                AdditionalCPT_AvgPatientResponsibilityAmount,
                LabID, LabName, InsertedDateTime
            FROM dbo.CodingValidation
            WHERE LabName = @LabName AND WeekFolder = @WeekFolder
            ORDER BY ReportId
            OFFSET @ArchiveOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

            SET @ArchiveBatch  = @@ROWCOUNT;
            SET @ArchiveOffset = @ArchiveOffset + @ChunkSize;
        END

        DELETE FROM dbo.CodingValidation
        WHERE LabName = @LabName AND WeekFolder = @WeekFolder;

        PRINT 'Archived and deleted existing rows for ' + @LabName + ' / ' + @WeekFolder;
    END

    -- 4. Insert new rows from TVP
    DECLARE @InsertOffset INT = 0;
    DECLARE @InsertBatch  INT = 1;

    WHILE @InsertBatch > 0
    BEGIN
        INSERT INTO dbo.CodingValidation
        (
            FileLogId, WeekFolder, SourceFilePath, RunNumber,
            AccessionNo, VisitNumber, PayerName_Raw, Carrier,
            Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
            PanelName, POS, TOS,
            TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
            MissingCPT_Charges, MissingCPT_ChargeSource,
            AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
            ValidationStatus, Remarks,
            MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount,
            MissingCPT_AvgPatientResponsibilityAmount,
            AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount,
            AdditionalCPT_AvgPatientResponsibilityAmount,
            LabID, LabName
        )
        SELECT
            CAST(@FileLogId AS NVARCHAR(500)),
            WeekFolder, SourceFilePath, RunNumber,
            AccessionNo, VisitNumber, PayerName_Raw, Carrier,
            Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
            PanelName, POS, TOS,
            TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
            MissingCPT_Charges, MissingCPT_ChargeSource,
            AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
            ValidationStatus, Remarks,
            MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount,
            MissingCPT_AvgPatientResponsibilityAmount,
            AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount,
            AdditionalCPT_AvgPatientResponsibilityAmount,
            LabID, LabName
        FROM @Rows
        ORDER BY (SELECT NULL)
        OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

        SET @InsertBatch  = @@ROWCOUNT;
        SET @InsertOffset = @InsertOffset + @ChunkSize;
    END

    PRINT 'Inserted ' + CAST(@InsertOffset AS NVARCHAR) + ' rows for '
          + @LabName + ' / ' + @WeekFolder
          + ' (FileLogId=' + CAST(@FileLogId AS NVARCHAR) + ')';

    SELECT @InsertOffset AS InsertedCount;
END;
GO

PRINT 'dbo.usp_BulkInsertCodingValidation re-created successfully.';
GO

-- =============================================================================
-- Verification  (uncomment and run after executing the script above)
-- =============================================================================
/*
-- Should show CHARACTER_MAXIMUM_LENGTH = -1 for both columns in both tables
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM   INFORMATION_SCHEMA.COLUMNS
WHERE  TABLE_NAME  IN ('CodingValidation', 'CodingValidationData')
  AND  COLUMN_NAME IN ('ActualCPTCode', 'ExpectedCPTCode')
ORDER  BY TABLE_NAME, COLUMN_NAME;

-- Should show max_length = -1 for both columns in the TVP
SELECT c.name, TYPE_NAME(c.system_type_id) AS base_type, c.max_length
FROM   sys.table_types tt
JOIN   sys.columns     c  ON c.object_id = tt.type_table_object_id
WHERE  tt.name = 'CodingValidationTVP'
  AND  c.name IN ('ActualCPTCode', 'ExpectedCPTCode');
*/
CREATE OR ALTER PROCEDURE dbo.usp_BulkInsertCodingValidation
    @Rows                dbo.CodingValidationTVP READONLY,
    @LabName             NVARCHAR(500),
    @WeekFolder          NVARCHAR(500),
    @SourceFilePath      NVARCHAR(500),
    @RunId               NVARCHAR(500),
    @FileName            NVARCHAR(500),
    @FileCreatedDateTime DATETIME = NULL,
    @ChunkSize           INT      = 1000
AS
BEGIN
    SET NOCOUNT ON;

    -- ── SKIP: file already recorded in FileLog (SourceFullPath + FileName + FileType) ──
    IF EXISTS (
        SELECT 1 FROM dbo.CodingValidationFileLog
        WHERE  SourceFullPath = @SourceFilePath
          AND  FileName       = @FileName
          AND  FileType       = 'codingmaster'
    )
    BEGIN
        PRINT 'Already loaded – skipping: ' + @SourceFilePath;
        SELECT 0 AS InsertedCount;
        RETURN;
    END

    -- ── LOG the incoming file ─────────────────────────────────────────
    DECLARE @FileLogId INT;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.CodingValidationFileLog
        WHERE  SourceFullPath = @SourceFilePath
          AND  FileName       = @FileName
          AND  FileType       = 'codingmaster'
    )
    BEGIN
        INSERT INTO dbo.CodingValidationFileLog
            (RunId, WeekFolder, SourceFullPath, FileName, FileType)
        VALUES
            (@RunId, @WeekFolder, @SourceFilePath, @FileName, 'codingmaster');

        SET @FileLogId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        SELECT @FileLogId = FileLogId
        FROM   dbo.CodingValidationFileLog
        WHERE  SourceFullPath = @SourceFilePath
          AND  FileName       = @FileName
          AND  FileType       = 'codingmaster';
    END

    -- ── ARCHIVE: move all existing rows with the old SourceFilePath ───
    --    No LabName filter – SourceFilePath alone identifies the dataset.
    DECLARE @OldSourceFilePath NVARCHAR(500);

    SELECT TOP 1 @OldSourceFilePath = SourceFilePath
    FROM   dbo.CodingValidation
    ORDER  BY InsertedDateTime DESC;

    IF @OldSourceFilePath IS NOT NULL
    BEGIN
        DECLARE @ArchiveOffset INT = 0;
        DECLARE @ArchiveBatch  INT = 1;

        WHILE @ArchiveBatch > 0
        BEGIN
            INSERT INTO dbo.CodingValidationData
            (
                OriginalReportId, FileLogId, WeekFolder, SourceFilePath, RunNumber,
                AccessionNo, VisitNumber, PayerName_Raw, Carrier,
                Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
                BillingProvider, ReferringProvider, ClinicName, SalesRepname,
                PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
                PanelName, POS, TOS,
                TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
                InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
                InsuranceBalance, PatientBalance, TotalBalance,
                CheckDate, ClaimStatus, DenialCode, ICDCode,
                DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
                ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
                MissingCPT_Charges, MissingCPT_ChargeSource,
                AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
                ValidationStatus, Remarks,
                MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount,
                MissingCPT_AvgPatientResponsibilityAmount,
                AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount,
                AdditionalCPT_AvgPatientResponsibilityAmount,
                LabID, LabName, OriginalInsertedDateTime
            )
            SELECT
                ReportId, FileLogId, WeekFolder, SourceFilePath, RunNumber,
                AccessionNo, VisitNumber, PayerName_Raw, Carrier,
                Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
                BillingProvider, ReferringProvider, ClinicName, SalesRepname,
                PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
                PanelName, POS, TOS,
                TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
                InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
                InsuranceBalance, PatientBalance, TotalBalance,
                CheckDate, ClaimStatus, DenialCode, ICDCode,
                DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
                ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
                MissingCPT_Charges, MissingCPT_ChargeSource,
                AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
                ValidationStatus, Remarks,
                MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount,
                MissingCPT_AvgPatientResponsibilityAmount,
                AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount,
                AdditionalCPT_AvgPatientResponsibilityAmount,
                LabID, LabName, InsertedDateTime
            FROM dbo.CodingValidation
            WHERE SourceFilePath = @OldSourceFilePath
            ORDER BY ReportId
            OFFSET @ArchiveOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

            SET @ArchiveBatch  = @@ROWCOUNT;
            SET @ArchiveOffset = @ArchiveOffset + @ChunkSize;
        END

        -- ── DELETE the archived rows ──────────────────────────────────
        DELETE FROM dbo.CodingValidation
        WHERE  SourceFilePath = @OldSourceFilePath;

        PRINT 'Archived and deleted: ' + @OldSourceFilePath;
    END

    -- ── INSERT: load new file rows into CodingValidation ─────────────
    DECLARE @InsertOffset INT = 0;
    DECLARE @InsertBatch  INT = 1;

    WHILE @InsertBatch > 0
    BEGIN
        INSERT INTO dbo.CodingValidation
        (
            FileLogId, WeekFolder, SourceFilePath, RunNumber,
            AccessionNo, VisitNumber, PayerName_Raw, Carrier,
            Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
            PanelName, POS, TOS,
            TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
            MissingCPT_Charges, MissingCPT_ChargeSource,
            AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
            ValidationStatus, Remarks,
            MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount,
            MissingCPT_AvgPatientResponsibilityAmount,
            AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount,
            AdditionalCPT_AvgPatientResponsibilityAmount,
            LabID, LabName
        )
        SELECT
            CAST(@FileLogId AS NVARCHAR(500)),
            WeekFolder, SourceFilePath, RunNumber,
            AccessionNo, VisitNumber, PayerName_Raw, Carrier,
            Payer_Code, PayerCommonCode, Payer_Group_Code, Global_Payer_ID, PayerType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepname,
            PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBillDate,
            PanelName, POS, TOS,
            TotalCharge, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance,
            CheckDate, ClaimStatus, DenialCode, ICDCode,
            DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
            ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes,
            MissingCPT_Charges, MissingCPT_ChargeSource,
            AdditionalCPT_Charges, AdditionalCPT_ChargeSource, ExpectedCharges,
            ValidationStatus, Remarks,
            MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount,
            MissingCPT_AvgPatientResponsibilityAmount,
            AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount,
            AdditionalCPT_AvgPatientResponsibilityAmount,
            LabID, LabName
        FROM @Rows
        ORDER BY (SELECT NULL)
        OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

        SET @InsertBatch  = @@ROWCOUNT;
        SET @InsertOffset = @InsertOffset + @ChunkSize;
    END

    PRINT 'Inserted '   + CAST(@InsertOffset     AS NVARCHAR(20)) + ' rows'
        + ' | Lab: '    + @LabName
        + ' | Week: '   + @WeekFolder
        + ' | File: '   + @FileName
        + ' | LogId: '  + CAST(@FileLogId AS NVARCHAR(20));

    SELECT @InsertOffset AS InsertedCount;
END;
