/* ============================================================================================
   AR Workbench - 08 OPTIONAL: index on the source line table
   The only statement in the AR Workbench scripts that touches a dbo source table. It adds an
   index; it does not change any column or data. The sync ranks line files per ClaimID and joins
   on ClaimID; this index lets it do that without sorting the whole table on every run.
   dbo.ClaimLevelData already has IX_ClaimLevelData_ClaimID_Latest (DenialDashboard_Filter_Indexes.sql).
   Run it in a quiet window; skip it if the DBA prefers to own dbo indexes.
   Script 00 does not drop this index (it is on a source table), so the name is kept as it was.
   ============================================================================================ */
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
