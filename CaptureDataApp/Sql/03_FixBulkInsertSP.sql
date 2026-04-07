-- ============================================================
-- 03_FixBulkInsertSP.sql
--
-- Logic (no lab-specific conditions in archive/delete/insert):
--
--   SKIP    – @SourceFilePath already exists in CodingValidation
--             → already loaded, return 0, done.
--
--   ARCHIVE – move ALL rows from CodingValidation where
--             SourceFilePath = the OLD path into CodingValidationData.
--
--   DELETE  – remove those archived rows from CodingValidation.
--
--   INSERT  – load the incoming @Rows into CodingValidation.
--
-- One-time cleanup (Steps 1 + 2) fixes existing stale rows
-- before the SP is deployed.
-- Run once against every affected lab database.
-- ============================================================

-- ── Step 1 (one-time): archive every row whose SourceFilePath is NOT
--    the most-recently inserted file for its lab ─────────────────────
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
    cv.ReportId, cv.FileLogId, cv.WeekFolder, cv.SourceFilePath, cv.RunNumber,
    cv.AccessionNo, cv.VisitNumber, cv.PayerName_Raw, cv.Carrier,
    cv.Payer_Code, cv.PayerCommonCode, cv.Payer_Group_Code, cv.Global_Payer_ID, cv.PayerType,
    cv.BillingProvider, cv.ReferringProvider, cv.ClinicName, cv.SalesRepname,
    cv.PatientID, cv.PatientDOB, cv.DateofService, cv.ChargeEnteredDate, cv.FirstBillDate,
    cv.PanelName, cv.POS, cv.TOS,
    cv.TotalCharge, cv.AllowedAmount, cv.InsurancePayment, cv.PatientPayment, cv.TotalPayments,
    cv.InsuranceAdjustments, cv.PatientAdjustments, cv.TotalAdjustments,
    cv.InsuranceBalance, cv.PatientBalance, cv.TotalBalance,
    cv.CheckDate, cv.ClaimStatus, cv.DenialCode, cv.ICDCode,
    cv.DaystoDOS, cv.RollingDays, cv.DaystoBill, cv.DaystoPost, cv.ICDPointer,
    cv.ActualCPTCode, cv.ExpectedCPTCode, cv.MissingCPTCodes, cv.AdditionalCPTCodes,
    cv.MissingCPT_Charges, cv.MissingCPT_ChargeSource,
    cv.AdditionalCPT_Charges, cv.AdditionalCPT_ChargeSource, cv.ExpectedCharges,
    cv.ValidationStatus, cv.Remarks,
    cv.MissingCPT_AvgAllowedAmount, cv.MissingCPT_AvgPaidAmount,
    cv.MissingCPT_AvgPatientResponsibilityAmount,
    cv.AdditionalCPT_AvgAllowedAmount, cv.AdditionalCPT_AvgPaidAmount,
    cv.AdditionalCPT_AvgPatientResponsibilityAmount,
    cv.LabID, cv.LabName, cv.InsertedDateTime
FROM dbo.CodingValidation cv
WHERE cv.SourceFilePath <> (
    SELECT TOP 1 SourceFilePath
    FROM   dbo.CodingValidation
    WHERE  LabName = cv.LabName
    ORDER  BY InsertedDateTime DESC
);
GO

-- ── Step 2 (one-time): delete those stale rows ───────────────────────
DELETE cv
FROM dbo.CodingValidation cv
WHERE cv.SourceFilePath <> (
    SELECT TOP 1 SourceFilePath
    FROM   dbo.CodingValidation
    WHERE  LabName = cv.LabName
    ORDER  BY InsertedDateTime DESC
);
GO

-- ── Step 3: deploy the stored procedure ──────────────────────────────
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
GO

-- ── Step 4: verify – every lab should show DistinctFiles = 1 ─────────
SELECT
    LabName,
    COUNT(DISTINCT SourceFilePath) AS DistinctFiles,
    COUNT(*)                       AS TotalRows,
    MAX(InsertedDateTime)          AS LatestInsert,
    MAX(SourceFilePath)            AS CurrentSourceFilePath
FROM  dbo.CodingValidation
GROUP BY LabName
ORDER BY LabName;
GO
