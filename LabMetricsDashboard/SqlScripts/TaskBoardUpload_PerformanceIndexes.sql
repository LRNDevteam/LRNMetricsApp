IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_DenialTaskBoard_LabId_UniqueTrackId'
      AND object_id = OBJECT_ID('dbo.DenialTaskBoard')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_LabId_UniqueTrackId
    ON dbo.DenialTaskBoard (LabId, UniqueTrackId)
    INCLUDE (TaskID, Status, AssignedTo, DateCompleted);
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_DenialTaskBoard_LabId_TaskID'
      AND object_id = OBJECT_ID('dbo.DenialTaskBoard')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_LabId_TaskID
    ON dbo.DenialTaskBoard (LabId, TaskID)
    INCLUDE (UniqueTrackId, Status, AssignedTo, DateCompleted);
END
GO
