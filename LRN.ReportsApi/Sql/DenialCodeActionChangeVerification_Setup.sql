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
        PayerName nvarchar(255) NULL,
        AssignedTo nvarchar(100) NULL,
        ClaimStatus nvarchar(100) NULL,
        DenialCode nvarchar(100) NOT NULL,
        ICDComplianceStatus nvarchar(255) NULL,
        CoverageStatus nvarchar(255) NULL,
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Batch_Status' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
    CREATE INDEX IX_DCACV_Batch_Status ON dbo.DenialCodeActionChangeVerification(BatchId, VerificationStatus);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Denial_Key' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
    CREATE INDEX IX_DCACV_Denial_Key ON dbo.DenialCodeActionChangeVerification(DenialCode, ICDComplianceStatus, CoverageStatus);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Claim_Task' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
    CREATE INDEX IX_DCACV_Claim_Task ON dbo.DenialCodeActionChangeVerification(ClaimID, TaskID);
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
