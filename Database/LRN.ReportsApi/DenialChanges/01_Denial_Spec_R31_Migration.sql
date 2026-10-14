/*
    Denial Database — Architecture Spec Rev 3.1 migration (the unblocked subset).

    Run against EACH LAB database, not LRNMaster. Idempotent: safe to re-run.

    Covers MG-01 (renamed, see below), MG-02 (partial), MG-03, MG-04, MG-05, MG-06, MG-08 and the
    supporting indexes from MG-07 that the shipped code actually needs.

    MG-01 NAMING DEVIATION — the archive is dbo.DenialClosureLog, NOT dbo.DenialClosedClaims.
    A table of the spec's name ALREADY EXISTS, created by LRN.ReportsApi
    (Sql/Denial_Lab_Database_Setup_Merged.sql). It is CLAIM-grain, carries UNIQUE(LabId, ClaimId),
    and backs the reviewer close-claim feature together with dbo.DenialClosedClaimsHistory. The
    spec's archive is DENIAL-EVENT-grain and explicitly append-only (AR-05: several rows per
    UniqueTrackId over its life), which that unique index forbids. The two answer different
    questions and cannot share a name, so the new one was renamed and the existing one left alone.
    Spec §3.3 and MG-01 need an erratum to match.
*/

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   MG-01 — the denial closure archive (spec §3.3), under a non-colliding name.

   The worker creates this itself on first use, so this block exists so a DBA can
   pre-create it and size the indexes during the same maintenance window.
   Append-only: nothing updates or deletes a row here (DD-06).
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialClosureLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClosureLog
    (
        DenialClosureLogId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClosureLog PRIMARY KEY,
        LabId               INT            NOT NULL,
        LabName             NVARCHAR(255)  NULL,
        RunId               NVARCHAR(100)  NULL,
        OriginRunId         NVARCHAR(100)  NULL,
        ClaimUID            NVARCHAR(600)  NULL,
        UniqueTrackId       NVARCHAR(450)  NULL,
        ClaimID             NVARCHAR(150)  NULL,
        CPTCode             NVARCHAR(50)   NULL,
        DenialCode          NVARCHAR(100)  NULL,
        DateOfService       DATE           NULL,
        PayerName           NVARCHAR(256)  NULL,
        InsuranceBalance    DECIMAL(18,2)  NULL,
        ClosureReason       VARCHAR(40)    NOT NULL,
        SourcePayStatus     VARCHAR(60)    NULL,
        FinalWorkFlowStatus NVARCHAR(100)  NULL,
        AssignedTo          NVARCHAR(255)  NULL,
        ReviewerComments    NVARCHAR(MAX)  NULL,
        DateOpened          DATE           NULL,
        DateCompleted       DATE           NULL,
        ArchivedOn          DATETIME2(3)   NOT NULL CONSTRAINT DF_DenialClosureLog_ArchivedOn DEFAULT SYSUTCDATETIME(),
        TaskSnapshot        NVARCHAR(MAX)  NULL
    );

    CREATE INDEX IX_DenialClosureLog_Lab_Run_Reason ON dbo.DenialClosureLog (LabId, RunId, ClosureReason);
    CREATE INDEX IX_DenialClosureLog_Lab_UID_Reason ON dbo.DenialClosureLog (LabId, UniqueTrackId, ClosureReason);
END;
GO

/* ---------------------------------------------------------------------------
   MG-03 / MG-02 — identity columns.
   UniqueTrackId and ClaimUID are the keys every reconciliation statement matches
   on. Sql_Add_DenialTaskBoard_NewColumns.sql adds ClaimUID; this adds
   UniqueTrackId and backfills both where they are null.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'UniqueTrackId') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD UniqueTrackId NVARCHAR(450) NULL;
END;
GO

-- Backfill UniqueTrackId from its three parts. Only where all three are present: a partial key
-- is worse than none, because it would match the wrong task.
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'UniqueTrackId') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'ClaimUID') IS NOT NULL
BEGIN
    UPDATE dbo.DenialTaskBoard
    SET    UniqueTrackId = CONCAT(
               LTRIM(RTRIM(ClaimUID)), '|',
               LTRIM(RTRIM(ISNULL(CPTCode, ''))), '|',
               LTRIM(RTRIM(ISNULL(DenialCode, ''))))
    WHERE  NULLIF(LTRIM(RTRIM(ISNULL(UniqueTrackId, ''))), '') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(ClaimUID,      ''))), '') IS NOT NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(CPTCode,       ''))), '') IS NOT NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(DenialCode,    ''))), '') IS NOT NULL;
END;
GO

/* ---------------------------------------------------------------------------
   MG-05 — canonical status vocabulary (DD-09).

   Only the two legacy spellings are rewritten. Everything else is left alone:
   DenialTaskBoard.WorkFlowStatus carries the workflow app's escalation vocabulary
   ("Internal Escalation", "Response Escalation", "Closed Claim", …), which is a
   DIFFERENT axis from Status and is not in scope for this normalization.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
BEGIN
    UPDATE dbo.DenialTaskBoard
    SET    Status = 'Pending Review'
    WHERE  LTRIM(RTRIM(ISNULL(Status, ''))) = 'Review';

    UPDATE dbo.DenialTaskBoard
    SET    Status = 'In-Progress'
    WHERE  LTRIM(RTRIM(ISNULL(Status, ''))) IN ('In Progress', 'InProgress');
END;
GO

/* ---------------------------------------------------------------------------
   DD-07 — register the three system-set statuses.

   dbo.DenialStatusMaster is seeded by LRN.ReportsApi with the seven human statuses.
   These three are set only by the worker and must never be offered to a user (DD-08),
   so they are marked IsClosedStatus = 1 (terminal) and sorted after the human ones.

   Skipped silently where the table does not exist: the workflow app has not been
   set up in that lab, so nothing reads the vocabulary yet.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialStatusMaster', 'U') IS NOT NULL
BEGIN
    MERGE dbo.DenialStatusMaster AS t
    USING (VALUES
        ('Re-Submitted', 1, 0, 80),
        ('Write Off',    1, 0, 90),
        ('Adjusted',     1, 0, 100)
    ) AS s(StatusName, IsClosedStatus, IsVerificationStatus, SortOrder)
        ON t.StatusName = s.StatusName
    WHEN MATCHED THEN
        UPDATE SET IsClosedStatus = s.IsClosedStatus,
                   IsVerificationStatus = s.IsVerificationStatus,
                   SortOrder = s.SortOrder,
                   IsActive = 1
    WHEN NOT MATCHED THEN
        INSERT (StatusName, IsClosedStatus, IsVerificationStatus, SortOrder)
        VALUES (s.StatusName, s.IsClosedStatus, s.IsVerificationStatus, s.SortOrder);
END;
GO

/* ---------------------------------------------------------------------------
   MG-06 — per-lab TaskID sequence.

   The worker creates and seeds this on first use, so this block only exists so a
   DBA can see the table and pre-seed it during the same maintenance window.
   Seeding is from the highest TSK- number already on the board, so no id is
   ever re-issued.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialTaskIdSequence', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialTaskIdSequence
    (
        LabId     INT    NOT NULL CONSTRAINT PK_DenialTaskIdSequence PRIMARY KEY,
        NextValue BIGINT NOT NULL
    );
END;
GO

IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
BEGIN
    INSERT INTO dbo.DenialTaskIdSequence (LabId, NextValue)
    SELECT tb.LabId,
           ISNULL(MAX(TRY_CONVERT(BIGINT, SUBSTRING(tb.TaskID, 5, 50))), 0) + 1
    FROM   dbo.DenialTaskBoard tb
    WHERE  tb.TaskID LIKE 'TSK-%'
      AND  TRY_CONVERT(BIGINT, SUBSTRING(tb.TaskID, 5, 50)) IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM dbo.DenialTaskIdSequence s WHERE s.LabId = tb.LabId)
    GROUP BY tb.LabId;
END;
GO

/* ---------------------------------------------------------------------------
   MG-04 — unify the verification queue (spec D-3 / VF-01).

   The worker wrote dbo.DenialVerification; LRN.ReportsApi reads and writes
   dbo.DenialVerificationTask. Nothing read the worker's table, so every
   verification the pipeline raised was invisible to the reviewer who owned the
   task — a denial that vanished between runs was silently dropped rather than
   decided. The worker now writes DenialVerificationTask; this moves the backlog
   that accumulated in the old table so those denials finally reach someone.

   The old table is NOT dropped here. Verify the row counts first, then drop it
   with the statement at the bottom of this file.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialVerification', 'U') IS NOT NULL
   AND OBJECT_ID('dbo.DenialVerificationTask', 'U') IS NOT NULL
BEGIN
    INSERT INTO dbo.DenialVerificationTask
    (
        TaskID, UniqueTrackId, ClaimID, LabId, LabName,
        OriginalRunId, MissingDetectedRunId, RunId,
        Status, AssignedTo, VerificationStatus, VerificationComments, MovedOn
    )
    SELECT DISTINCT
        ISNULL(dv.TaskID, ''),
        dv.UniqueTrackId,
        dv.ClaimID,
        dv.LabId,
        dv.LabName,
        dv.RunId,
        dv.RunId,
        dv.RunId,
        'Verification Pending',
        dv.AssignedTo,
        'Verification Pending',
        'Migrated from dbo.DenialVerification (spec MG-04).',
        ISNULL(dv.CreatedOn, SYSUTCDATETIME())
    FROM   dbo.DenialVerification dv
    WHERE  NULLIF(LTRIM(RTRIM(ISNULL(dv.UniqueTrackId, ''))), '') IS NOT NULL
      AND  NOT EXISTS
      (
          SELECT 1
          FROM   dbo.DenialVerificationTask t
          WHERE  t.UniqueTrackId = dv.UniqueTrackId
            AND  ISNULL(t.MissingDetectedRunId, '') = ISNULL(dv.RunId, '')
      );
END;
GO

/* ---------------------------------------------------------------------------
   MG-07 (the subset the shipped code needs).

   The reconcile path matches on LabId + UniqueTrackId and LabId + ClaimUID, and
   the new verification insert probes DenialVerificationTask by UniqueTrackId +
   MissingDetectedRunId on every orphan.

   Review before running: each index costs write throughput on the bulk copies.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'UniqueTrackId') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'IX_DenialTaskBoard_LabId_UniqueTrackId'
                     AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_LabId_UniqueTrackId
        ON dbo.DenialTaskBoard (LabId, UniqueTrackId);
END;
GO

IF OBJECT_ID('dbo.DenialVerificationTask', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerificationTask', 'MissingDetectedRunId') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'IX_DenialVerificationTask_UID_MissingRun'
                     AND object_id = OBJECT_ID('dbo.DenialVerificationTask'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialVerificationTask_UID_MissingRun
        ON dbo.DenialVerificationTask (UniqueTrackId, MissingDetectedRunId);
END;
GO

/* ---------------------------------------------------------------------------
   MG-08 — no separate step is needed, and the one-way door in MG-09 is gone.

   The spec called for archiving existing Closed tasks before the first reconciliation
   so that run would not delete history. The worker's B1 bucket now archives every
   closed task to dbo.DenialClosureLog immediately before deleting it, so the first
   run under these rules preserves that history by itself. Nothing has to be moved
   ahead of time, and nothing is irreversible.
   --------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
   Verification queries — run these before and after.
   --------------------------------------------------------------------------- */

-- What left the board in a given run, and why.
-- SELECT ClosureReason, COUNT(1) AS Denials, SUM(InsuranceBalance) AS Balance
-- FROM   dbo.DenialClosureLog
-- WHERE  LabId = <LabId> AND RunId = '<RunId>'
-- GROUP BY ClosureReason ORDER BY Denials DESC;

-- Denials permanently retired (AR-03). These are the ones the worker will not re-create.
-- SELECT COUNT(DISTINCT UniqueTrackId) FROM dbo.DenialClosureLog
-- WHERE LabId = <LabId> AND ClosureReason IN ('Closed by Reviewer', 'Verified Invalid');

-- Did the backlog move? The first number should become 0 once you drop the old table.
-- SELECT OldQueue = (SELECT COUNT(1) FROM dbo.DenialVerification),
--        NewQueue = (SELECT COUNT(1) FROM dbo.DenialVerificationTask);

-- Any task still missing an identity key? These are invisible to reconciliation.
-- SELECT COUNT(1) FROM dbo.DenialTaskBoard
-- WHERE NULLIF(LTRIM(RTRIM(ISNULL(UniqueTrackId,''))),'') IS NULL;

-- Statuses actually in use, so a stray legacy value shows up before the next run.
-- SELECT Status, COUNT(1) AS Rows FROM dbo.DenialTaskBoard GROUP BY Status ORDER BY Rows DESC;

-- Only after confirming the counts above:
-- DROP TABLE dbo.DenialVerification;
