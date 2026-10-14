IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_DenialTaskBoard_LabId_UniqueTrackId_RunId'
      AND object_id = OBJECT_ID('dbo.DenialTaskBoard')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_LabId_UniqueTrackId_RunId
    ON dbo.DenialTaskBoard (LabId, UniqueTrackId, RunId)
    INCLUDE (TaskID, Status, AssignedTo, DateCompleted);
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_DenialTaskBoard_LabId_TaskID_RunId'
      AND object_id = OBJECT_ID('dbo.DenialTaskBoard')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_LabId_TaskID_RunId
    ON dbo.DenialTaskBoard (LabId, TaskID, RunId)
    INCLUDE (UniqueTrackId, Status, AssignedTo, DateCompleted);
END
GO
