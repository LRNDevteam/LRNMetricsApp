/* ============================================================================================
   AR Workbench - 07 OPTIONAL: index on the source line table
   The only statement in the AR Workbench scripts that touches a dbo table. It adds an index; it
   does not change any column or data. dbo.LineLevelData has no ClaimID index today, and the loader
   joins on ClaimID - without this the line step scans the whole table on every refresh.
   dbo.ClaimLevelData already has IX_ClaimLevelData_ClaimID_Latest (DenialDashboard_Filter_Indexes.sql).
   Run it in a quiet window; skip it if the DBA prefers to own dbo indexes.
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.LineLevelData', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.LineLevelData') AND name = N'IX_LineLevelData_ClaimID_ArWorkbench')
BEGIN
    -- ClaimID is nvarchar(500) (1000 bytes) - within the 1700-byte nonclustered key limit.
    -- Deliberately NOT a filtered index: a filtered index makes every INSERT/UPDATE on the table fail
    -- for a session or procedure created with QUOTED_IDENTIFIER OFF, which would break the existing
    -- ingestion that writes dbo.LineLevelData.
    CREATE NONCLUSTERED INDEX IX_LineLevelData_ClaimID_ArWorkbench
        ON dbo.LineLevelData (ClaimID);
    PRINT 'Created IX_LineLevelData_ClaimID_ArWorkbench.';
END;
GO
