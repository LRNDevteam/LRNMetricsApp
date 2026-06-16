/*
Run this once in each lab database that uses Denial Workflow.
It is also applied defensively by the Reports API before import/review operations.
*/

IF OBJECT_ID('dbo.DenialCodeActionChangeBatch','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialCodeActionChangeBatch
    (
        BatchId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialCodeActionChangeBatch PRIMARY KEY,
        SourceFileName nvarchar(500) NOT NULL,
        UploadedBy nvarchar(100) NOT NULL,
        UploadedOn datetime2(0) NOT NULL CONSTRAINT DF_DCACB_UploadedOn DEFAULT SYSUTCDATETIME(),
        TotalAffectedClaims int NOT NULL CONSTRAINT DF_DCACB_TotalAffectedClaims DEFAULT 0,
        TotalAffectedTasks int NOT NULL CONSTRAINT DF_DCACB_TotalAffectedTasks DEFAULT 0,
        PendingCount int NOT NULL CONSTRAINT DF_DCACB_PendingCount DEFAULT 0,
        ConfirmedCount int NOT NULL CONSTRAINT DF_DCACB_ConfirmedCount DEFAULT 0,
        IgnoredCount int NOT NULL CONSTRAINT DF_DCACB_IgnoredCount DEFAULT 0,
        Status nvarchar(50) NOT NULL CONSTRAINT DF_DCACB_Status DEFAULT 'Pending'
    );
END;

IF OBJECT_ID('dbo.DenialCodeActionChangeVerification','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialCodeActionChangeVerification
    (
        VerificationId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialCodeActionChangeVerification PRIMARY KEY,
        BatchId bigint NOT NULL,
        ClaimID nvarchar(100) NOT NULL,
        TaskID nvarchar(100) NULL,
        PatientId nvarchar(100) NULL,
        CPTCode nvarchar(100) NULL,
        Units int NULL,
        Modifier nvarchar(100) NULL,
        PayerName nvarchar(255) NULL,
        AssignedTo nvarchar(100) NULL,
        ClaimStatus nvarchar(100) NULL,
        DenialCode nvarchar(100) NOT NULL,
        DenialDescription nvarchar(1000) NULL,
        DenialClassification nvarchar(255) NULL,
        ICDComplianceStatus nvarchar(255) NULL,
        CoverageStatus nvarchar(255) NULL,
        ActionCode nvarchar(100) NULL,
        ActionCategory nvarchar(500) NULL,
        RecommendedAction nvarchar(1000) NULL,
        Task nvarchar(500) NULL,
        Priority nvarchar(100) NULL,
        InsuranceBalance decimal(18,2) NULL,
        SLADays int NULL,
        Status nvarchar(100) NULL,
        DateOpened date NULL,
        DueDate date NULL,
        SLAStatus nvarchar(100) NULL,
        FirstBilledDate date NULL,
        ChargeEnteredDate date NULL,
        DenialValidity nvarchar(255) NULL,
        OldActionCode nvarchar(100) NULL,
        NewActionCode nvarchar(100) NULL,
        OldActionCategory nvarchar(500) NULL,
        NewActionCategory nvarchar(500) NULL,
        OldTask nvarchar(500) NULL,
        NewTask nvarchar(500) NULL,
        OldShortCategory nvarchar(255) NULL,
        NewShortCategory nvarchar(255) NULL,
        VerificationStatus nvarchar(50) NOT NULL CONSTRAINT DF_DCACV_VerificationStatus DEFAULT 'Pending',
        VerifiedBy nvarchar(100) NULL,
        VerifiedOn datetime2(0) NULL,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DCACV_CreatedOn DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_DCACV_Batch FOREIGN KEY (BatchId) REFERENCES dbo.DenialCodeActionChangeBatch(BatchId)
    );
END;

IF COL_LENGTH('dbo.DenialTaskBoard','ShortCategory') IS NULL
    ALTER TABLE dbo.DenialTaskBoard ADD ShortCategory nvarchar(255) NULL;

IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','CPTCode') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD CPTCode nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Units') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Units int NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Modifier') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Modifier nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DenialDescription') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DenialDescription nvarchar(1000) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DenialClassification') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DenialClassification nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','ActionCode') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD ActionCode nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','ActionCategory') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD ActionCategory nvarchar(500) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','RecommendedAction') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD RecommendedAction nvarchar(1000) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Task') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Task nvarchar(500) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Priority') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Priority nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','InsuranceBalance') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD InsuranceBalance decimal(18,2) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','SLADays') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD SLADays int NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Status') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Status nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DateOpened') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DateOpened date NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DueDate') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DueDate date NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','SLAStatus') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD SLAStatus nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','FirstBilledDate') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD FirstBilledDate date NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','ChargeEnteredDate') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD ChargeEnteredDate date NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DenialValidity') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DenialValidity nvarchar(255) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Batch_Status' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
    CREATE INDEX IX_DCACV_Batch_Status ON dbo.DenialCodeActionChangeVerification(BatchId, VerificationStatus);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Denial_Key' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
    CREATE INDEX IX_DCACV_Denial_Key ON dbo.DenialCodeActionChangeVerification(DenialCode, ICDComplianceStatus, CoverageStatus);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Claim_Task' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
    CREATE INDEX IX_DCACV_Claim_Task ON dbo.DenialCodeActionChangeVerification(ClaimID, TaskID);
GO

IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
   AND OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
   AND OBJECT_ID('dbo.DenialCodeActionChangeVerification','U') IS NOT NULL
BEGIN
    UPDATE v
    SET CPTCode = COALESCE(NULLIF(v.CPTCode, ''), NULLIF(t.CPTCode, ''), NULLIF(line.CPTCode, '')),
        Units = COALESCE(v.Units, TRY_CONVERT(int, t.Units), TRY_CONVERT(int, line.Units)),
        Modifier = COALESCE(NULLIF(v.Modifier, ''), NULLIF(t.Modifier, ''), NULLIF(line.Modifier, '')),
        PayerName = COALESCE(NULLIF(v.PayerName, ''), NULLIF(t.PayerName, ''), NULLIF(line.PayerName, '')),
        DenialDescription = COALESCE(NULLIF(v.DenialDescription, ''), NULLIF(t.DenialDescription, ''), NULLIF(line.DenialDescription, '')),
        DenialClassification = COALESCE(NULLIF(v.DenialClassification, ''), NULLIF(t.DenialClassification, ''), NULLIF(line.DenialClassification, '')),
        ActionCode = COALESCE(NULLIF(v.ActionCode, ''), NULLIF(t.ActionCode, ''), NULLIF(line.ActionCode, '')),
        ActionCategory = COALESCE(NULLIF(v.ActionCategory, ''), NULLIF(t.ActionCategory, ''), NULLIF(line.ActionCategory, '')),
        RecommendedAction = COALESCE(NULLIF(v.RecommendedAction, ''), NULLIF(t.RecommendedAction, ''), NULLIF(line.RecommendedAction, '')),
        Task = COALESCE(NULLIF(v.Task, ''), NULLIF(t.Task, ''), NULLIF(line.TaskGuidance, '')),
        Priority = COALESCE(NULLIF(v.Priority, ''), NULLIF(t.Priority, ''), NULLIF(line.Priority, '')),
        InsuranceBalance = COALESCE(v.InsuranceBalance, TRY_CONVERT(decimal(18,2), t.InsuranceBalance), TRY_CONVERT(decimal(18,2), line.InsuranceBalance)),
        SLADays = COALESCE(v.SLADays, TRY_CONVERT(int, t.SLADays), TRY_CONVERT(int, line.SLADays)),
        Status = COALESCE(NULLIF(v.Status, ''), NULLIF(t.Status, ''), NULLIF(line.TaskStatus, '')),
        DateOpened = COALESCE(v.DateOpened, t.DateOpened, line.DateOfService),
        DueDate = COALESCE(v.DueDate, t.DueDate),
        SLAStatus = COALESCE(NULLIF(v.SLAStatus, ''), NULLIF(t.SLAStatus, '')),
        FirstBilledDate = COALESCE(v.FirstBilledDate, t.FirstBilledDate, line.FirstBilledDate),
        ChargeEnteredDate = COALESCE(v.ChargeEnteredDate, t.ChargeEnteredDate, line.ChargeEnteredDate),
        DenialValidity = COALESCE(NULLIF(v.DenialValidity, ''), NULLIF(t.DenialValidity, ''), NULLIF(line.DenialValidity, ''))
    FROM dbo.DenialCodeActionChangeVerification v
    LEFT JOIN dbo.DenialTaskBoard t
        ON t.TaskID = v.TaskID
       AND CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.ClaimID, ''))), 'CLM-', '')) =
           CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(v.ClaimID, ''))), 'CLM-', ''))
    OUTER APPLY
    (
        SELECT TOP (1)
            l.CPTCode, l.Units, l.Modifier, l.PayerName, l.DenialDescription, l.DenialClassification,
            l.ActionCode, l.ActionCategory, l.RecommendedAction, l.TaskGuidance, l.Priority,
            l.InsuranceBalance, l.SLADays, l.TaskStatus, l.DateOfService, l.FirstBilledDate,
            l.ChargeEnteredDate, l.DenialValidity
        FROM dbo.DenialLineItem l
        WHERE CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber, ''))), 'CLM-', '')) =
              CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(v.ClaimID, ''))), 'CLM-', ''))
          AND (
                UPPER(LTRIM(RTRIM(ISNULL(l.DenialCodeNormalized, '')))) = UPPER(v.DenialCode)
             OR UPPER(LTRIM(RTRIM(ISNULL(l.DenialCodeOriginal, '')))) = UPPER(v.DenialCode)
             OR NULLIF(LTRIM(RTRIM(ISNULL(l.DenialCodeNormalized, ''))), '') IS NULL
          )
        ORDER BY
            CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(l.DenialCodeNormalized, '')))) = UPPER(v.DenialCode)
                   OR UPPER(LTRIM(RTRIM(ISNULL(l.DenialCodeOriginal, '')))) = UPPER(v.DenialCode) THEN 0 ELSE 1 END,
            l.DateOfService DESC
    ) line
    WHERE v.CPTCode IS NULL
       OR v.Units IS NULL
       OR v.Modifier IS NULL
       OR v.DenialDescription IS NULL
       OR v.DenialClassification IS NULL
       OR v.ActionCode IS NULL
       OR v.ActionCategory IS NULL
       OR v.RecommendedAction IS NULL
       OR v.Task IS NULL
       OR v.Priority IS NULL
       OR v.InsuranceBalance IS NULL
       OR v.SLADays IS NULL
       OR v.Status IS NULL
       OR v.DateOpened IS NULL
       OR v.FirstBilledDate IS NULL
       OR v.ChargeEnteredDate IS NULL
       OR v.DenialValidity IS NULL;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DenialActionChange_RecountBatch
    @BatchId bigint
AS
BEGIN
    SET NOCOUNT ON;
    IF @BatchId IS NULL RETURN;

    UPDATE b
    SET PendingCount = counts.PendingCount,
        ConfirmedCount = counts.ConfirmedCount,
        IgnoredCount = counts.IgnoredCount,
        Status = CASE WHEN counts.PendingCount = 0 THEN 'Completed' ELSE 'Pending' END
    FROM dbo.DenialCodeActionChangeBatch b
    CROSS APPLY
    (
        SELECT
            SUM(CASE WHEN v.VerificationStatus = 'Pending' THEN 1 ELSE 0 END) AS PendingCount,
            SUM(CASE WHEN v.VerificationStatus = 'Confirmed' THEN 1 ELSE 0 END) AS ConfirmedCount,
            SUM(CASE WHEN v.VerificationStatus IN ('Ignored', 'Skipped') THEN 1 ELSE 0 END) AS IgnoredCount
        FROM dbo.DenialCodeActionChangeVerification v
        WHERE v.BatchId = b.BatchId
    ) counts
    WHERE b.BatchId = @BatchId;
END;
GO
