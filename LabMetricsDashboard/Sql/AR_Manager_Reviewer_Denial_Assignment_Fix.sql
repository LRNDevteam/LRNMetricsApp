/* Run this on LRNMaster */
USE [LRNMaster];
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE REPLACE(RoleName, ' ', '') = 'ARManager')
BEGIN
    INSERT INTO dbo.Roles (RoleName, IsActive, CreatedDate, CreatedBy)
    VALUES ('AR Manager', 1, SYSUTCDATETIME(), 'System');
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE REPLACE(RoleName, ' ', '') = 'ARReviewer')
BEGIN
    INSERT INTO dbo.Roles (RoleName, IsActive, CreatedDate, CreatedBy)
    VALUES ('AR Reviewer', 1, SYSUTCDATETIME(), 'System');
END
GO

/* Run this on every lab database used by Denial Database, for example NWL_LRN, Augustus_LRN, Certus_LRN */
-- USE [NWL_LRN];
-- GO

IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerComments') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ReviewerComments nvarchar(max) NULL;
END
GO

IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerUpdatedOn') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedOn datetime2(0) NULL;
END
GO

IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerUpdatedBy') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedBy nvarchar(255) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Assignment' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE INDEX IX_DenialTaskBoard_Assignment
    ON dbo.DenialTaskBoard (LabId, RunId, DenialCode, PayerNameNormalized, AssignedTo)
    INCLUDE (TaskID, Status, PayerName);
END
GO
