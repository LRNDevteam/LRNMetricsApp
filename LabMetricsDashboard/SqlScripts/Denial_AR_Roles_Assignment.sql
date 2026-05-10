/* Denial Database AR Manager / AR Reviewer patch */
IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = 'AR Manager')
BEGIN
    INSERT INTO dbo.Roles (RoleName, IsActive, CreatedBy) VALUES ('AR Manager', 1, 'system');
END;

IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = 'AR Reviewer')
BEGIN
    INSERT INTO dbo.Roles (RoleName, IsActive, CreatedBy) VALUES ('AR Reviewer', 1, 'system');
END;

/* Run this in every lab database that has DenialTaskBoard */
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerComments') IS NULL
        ALTER TABLE dbo.DenialTaskBoard ADD ReviewerComments nvarchar(max) NULL;

    IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerUpdatedOn') IS NULL
        ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedOn datetime2(0) NULL;

    IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerUpdatedBy') IS NULL
        ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedBy nvarchar(255) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_AssignedTo_RunId' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE INDEX IX_DenialTaskBoard_AssignedTo_RunId ON dbo.DenialTaskBoard (AssignedTo, RunId) INCLUDE (TaskID, Status, DenialCode, PayerName, PayerNameNormalized);
END;
