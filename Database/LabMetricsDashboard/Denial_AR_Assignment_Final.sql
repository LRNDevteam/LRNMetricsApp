-- Run this in EACH LAB database that uses Denial Dashboard (example: NWL_LRN, Augustus_LRN, Certus_LRN)
IF COL_LENGTH('dbo.DenialInsight', 'AssignedTo') IS NULL
BEGIN
    ALTER TABLE dbo.DenialInsight ADD AssignedTo nvarchar(255) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerComments') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ReviewerComments nvarchar(max) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerUpdatedOn') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedOn datetime2(0) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerUpdatedBy') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedBy nvarchar(255) NULL;
END;

-- Helpful indexes for assignment and reviewer task filtering
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_AssignedTo_RunId' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE INDEX IX_DenialTaskBoard_AssignedTo_RunId ON dbo.DenialTaskBoard (AssignedTo, RunId) INCLUDE (TaskID, Status, DueDate, DenialCode, PayerName, PayerNameNormalized);
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Assign_ByDenialPayer' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE INDEX IX_DenialTaskBoard_Assign_ByDenialPayer ON dbo.DenialTaskBoard (LabId, RunId, DenialCode, PayerNameNormalized) INCLUDE (PayerName, AssignedTo, Status);
END;
