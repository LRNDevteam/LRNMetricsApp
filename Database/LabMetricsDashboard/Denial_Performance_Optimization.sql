/**************************************************************************************************
  Denial Workflow — Performance Optimization
  --------------------------------------------------------------------------------------------
  Run this ONCE per lab database (the same databases named in appsettings ConnectionStrings:
  NWLConnection, BeechTreeConnStr, etc.). It is idempotent — safe to re-run.

  WHY the denial pages are slow (found by comparing Denial_Scripts.sql to the API queries in
  SqlDenialWorkflowRepository.cs):

    1. dbo.DenialLineItem AND dbo.DenialTaskBoard are HEAPS (no clustered index / no PK).
       Every dashboard / claim-list / counts request builds temp tables (#ClaimBase from
       DenialLineItem, #TaskClaimRaw from DenialTaskBoard) with a full-table read of these
       heaps, and the frequent status/assignment UPDATEs leave forwarded records that make
       heap scans progressively slower. This is the single biggest cost.  -> Section 3.

    2. dbo.DenialTaskBoard has NO AssignedToNormalized column on this database, so the reviewer
       scope predicate LOWER(LTRIM(RTRIM(AssignedTo))) = @user is non-sargable and cannot seek
       IX_DenialTaskBoard_AssignedTo — it scans. The API already looks for this column and uses
       it when present.  -> Section 1.

    3. dbo.DenialTaskBoard.ClaimIDNormalized is defined as CONVERT(varchar(50),REPLACE(ClaimID,
       'CLM-','')) — no LTRIM/RTRIM/ISNULL and only varchar(50), vs the API's trim/varchar(150).
       Minimal real impact (ClaimID is the short visit key; the long composite lives in ClaimUID),
       and the column is referenced by 10+ indexes incl. the Section 3 clustered index, so
       redefining it is fragile. -> Section 2 intentionally LEAVES it as-is (no action).

    4. The #PageLineDetails fallback joins on l.VisitNumberNormalized but the only index on it
       (IX_DenialLineItem_VisitNumberNormalized) has no INCLUDE columns, forcing a RID lookup per
       row.  -> Section 4.

  The API-side query fixes (sargable joins, reviewer-scope temp table, sargable notes/document
  lookups) are already in SqlDenialWorkflowRepository.cs. This script fixes the schema/indexes.

  NOTE ON ONLINE=ON: valid on Azure SQL Managed Instance / Enterprise. If a target runs Standard
  edition (the ReportEngine\SQLEXPRESS labs), change ONLINE=ON to ONLINE=OFF in this file first.
**************************************************************************************************/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*================================================================================================
  SECTION 1 — AssignedToNormalized (fixes the reviewer scope non-sargable scan)
  Adds a persisted, normalized, lower-cased AssignedTo + a seek index used by #ReviewerScope.
================================================================================================*/
IF COL_LENGTH('dbo.DenialTaskBoard','AssignedToNormalized') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard
        ADD AssignedToNormalized AS (LOWER(LTRIM(RTRIM(ISNULL([AssignedTo],''))))) PERSISTED;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_AssignedToNorm' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_AssignedToNorm
        ON dbo.DenialTaskBoard (LabId, AssignedToNormalized)
        INCLUDE (ClaimUID, ClaimIDNormalized, ClaimID, Status, WorkFlowStatus)
        WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

-- DenialLineItem also stores AssignedTo (used when scoping a reviewer directly off the line
-- items). Add the same normalized column + seek index so that path can seek too.
IF COL_LENGTH('dbo.DenialLineItem','AssignedToNormalized') IS NULL
BEGIN
    ALTER TABLE dbo.DenialLineItem
        ADD AssignedToNormalized AS (LOWER(LTRIM(RTRIM(ISNULL([AssignedTo],''))))) PERSISTED;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_LineItem_Lab_AssignedToNorm' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
    CREATE NONCLUSTERED INDEX IX_DWF_LineItem_Lab_AssignedToNorm
        ON dbo.DenialLineItem (LabId, AssignedToNormalized)
        INCLUDE (ClaimUID, VisitNumberNormalized, VisitNumber)
        WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/*================================================================================================
  SECTION 2 — ClaimIDNormalized definition note (NO ACTION — intentionally left as-is).

  The base column is CONVERT(varchar(50), REPLACE([ClaimID],'CLM-','')) — no LTRIM/RTRIM/ISNULL and
  only varchar(50), whereas the API normalizes keys with trim/varchar(150). We DO NOT redefine it
  here: the column is a persisted computed column referenced by 10+ indexes (including the new
  clustered index in Section 3), so dropping/recreating it is heavy and fragile, while the practical
  impact is minimal — ClaimID holds the short visit-style key (the long composite lives in ClaimUID),
  so no truncation, and the API already compares against a trimmed @ClaimKey. Leaving it avoids a
  risky rebuild for negligible gain.

  Self-heal: a prior version of this script dropped four ClaimIDNormalized indexes before a
  DROP COLUMN that then failed. These IF NOT EXISTS creates put back any that went missing. If they
  already exist (the normal case) this section is a no-op.
================================================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialTaskBoard_ClaimIDNormalized' AND object_id=OBJECT_ID('dbo.DenialTaskBoard'))
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimIDNormalized
        ON dbo.DenialTaskBoard (ClaimIDNormalized) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialTaskBoard_ClaimAssignment_Status' AND object_id=OBJECT_ID('dbo.DenialTaskBoard'))
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimAssignment_Status
        ON dbo.DenialTaskBoard (ClaimIDNormalized)
        INCLUDE (TaskID, Status, AssignedTo, CreatedOn) WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialTaskBoard_TaskView_ClaimIDNormalized' AND object_id=OBJECT_ID('dbo.DenialTaskBoard'))
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_TaskView_ClaimIDNormalized
        ON dbo.DenialTaskBoard (Status, AssignedTo, ClaimIDNormalized)
        INCLUDE (TaskID, UniqueTrackId, CPTCode, SLAStatus, DueDate, InsuranceBalance, DenialCode, DenialClassification, ActionCategory)
        WITH (ONLINE = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DWF_TaskBoard_ClaimIDNormalized_StatusAgg' AND object_id=OBJECT_ID('dbo.DenialTaskBoard'))
    CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_ClaimIDNormalized_StatusAgg
        ON dbo.DenialTaskBoard (ClaimIDNormalized, Status, AssignedTo, CreatedOn)
        INCLUDE (ClaimID, ClaimUID, CPTCode, WorkFlowStatus, SLAStatus, DueDate, DateOpened,
                 InsuranceBalance, DenialClassification, ActionCategory, PayerName, DateOfService)
        WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/*================================================================================================
  SECTION 3 — Convert the HEAPS to clustered tables (the biggest win).
  Choose a clustered key that matches the dominant access (filter by LabId, then group/join by
  claim key). Creating a clustered index rebuilds the nonclustered indexes once; on MI it can run
  ONLINE. If either table is reloaded by TRUNCATE+BULK INSERT during import, keep the clustered
  index — the read benefit far outweighs the small insert-sort cost.
================================================================================================*/
-- DenialTaskBoard: lab-local, grouped by claim. TaskID is the natural per-task identity.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND index_id = 1)
    CREATE CLUSTERED INDEX CIX_DenialTaskBoard_Lab_ClaimIDNorm
        ON dbo.DenialTaskBoard (LabId, ClaimIDNormalized, TaskID)
        WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

-- DenialLineItem: lab-local, grouped by claim. VisitNumberNormalized is non-null (persisted).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialLineItem') AND index_id = 1)
    CREATE CLUSTERED INDEX CIX_DenialLineItem_Lab_VisitNorm
        ON dbo.DenialLineItem (LabId, VisitNumberNormalized, CPTCode)
        WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/*================================================================================================
  SECTION 4 — Cover the VisitNumberNormalized page-detail fallback (avoids per-row RID lookups).
================================================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_LineItem_Lab_VisitNorm_Page' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
    CREATE NONCLUSTERED INDEX IX_DWF_LineItem_Lab_VisitNorm_Page
        ON dbo.DenialLineItem (LabId, VisitNumberNormalized)
        INCLUDE (ClaimUID, VisitNumber, PayerName, PanelName, PatientName, PatientDOB, PatientID,
                 SubscriberId, ClinicName, ReferringProvider, SalesRepname, Source, AccessionNo,
                 InsuranceBalance, DateOfService)
        WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO


/*================================================================================================
  SECTION 5 — (OPTIONAL) Drop redundant / overlapping indexes to speed up imports and updates.
  DenialLineItem and DenialTaskBoard carry many near-duplicate indexes; each one is re-maintained
  on every insert/update (the workflow updates status constantly). These are safe supersets of
  other indexes. UNCOMMENT after confirming with sys.dm_db_index_usage_stats that they are unused.

  -- DenialLineItem: many single-column VisitNumber duplicates
  -- DROP INDEX IX_DLI_VisitNumber_Fast ON dbo.DenialLineItem;                  -- superset: IX_DLI_Filtered / IX_DenialLineItem_Lab_VisitNumber
  -- DROP INDEX IX_DenialLineItem_VisitNumber_ClaimView ON dbo.DenialLineItem;  -- covered by IX_DWF_LineItem_VisitNumber_ClaimView_Fallback
  -- DROP INDEX IX_DWF_LineItem_DOS_ClaimUID_Page ON dbo.DenialLineItem;        -- overlaps IX_DWF_LineItem_ClaimUID_ClaimView
  --
  -- DenialTaskBoard: duplicate ClaimIDNormalized / ClaimID indexes
  -- DROP INDEX IX_DenialTaskBoard_ClaimAssignment_Status ON dbo.DenialTaskBoard;  -- covered by IX_DWF_TaskBoard_ClaimIDNormalized_StatusAgg
  -- DROP INDEX IX_DenialTaskBoard_Lab_ClaimID ON dbo.DenialTaskBoard;            -- covered by IX_DWF_TaskBoard_Lab_Claim
================================================================================================*/


/*================================================================================================
  SECTION 6 — Refresh statistics so the optimizer picks the new indexes immediately.
================================================================================================*/
UPDATE STATISTICS dbo.DenialTaskBoard WITH FULLSCAN;
UPDATE STATISTICS dbo.DenialLineItem  WITH FULLSCAN;
UPDATE STATISTICS dbo.DenialClaimNotes WITH FULLSCAN;
UPDATE STATISTICS dbo.DenialClaimEscalations WITH FULLSCAN;
GO

PRINT 'Denial performance optimization complete.';
GO
