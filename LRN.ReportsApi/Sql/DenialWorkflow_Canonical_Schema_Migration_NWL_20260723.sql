/* ============================================================================
   Denial Workflow — Canonical Schema Migration (NWL_LRN pilot)
   Date: 2026-07-23
   Run against: NWL_LRN  (repeat per lab once the client approves rollout)

   Goal of the canonical schema (agreed for NWL, then all labs):
     * ClaimUID is the permanent, non-null distinct key on BOTH
       DenialTaskBoard and DenialLineItem. All joins / distinct counts use it.
     * Data is clean (no 'CLM-' prefix, no leading/trailing whitespace), so the
       app can compare raw columns directly (no COALESCE/REPLACE/LTRIM/RTRIM)
       and every predicate stays SARGable.
     * Integer user-id columns exist for FILTERING; the denormalized username
       string is retained for DISPLAY so claim lists never need a cross-database
       join into LRNMaster.dbo.LabUsers.

   This script is idempotent — safe to re-run. It does NOT drop the existing
   AssignedTo / ReviewerUpdatedBy username columns (display + backward compat).

   NOTE: LabUsers lives in LRNMaster (a different database on the same instance).
   The backfill uses a 3-part cross-database name; run where LRNMaster is
   reachable from this lab DB (same Azure SQL MI / same SQL instance).
   ============================================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;
-- Required because DenialTaskBoard/DenialLineItem carry indexed computed columns
-- (ClaimIDNormalized / VisitNumberNormalized): any INSERT/UPDATE needs these ON.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

/* ---------------------------------------------------------------------------
   0. Guard: ClaimUID must be present and non-null before we rely on it.
   --------------------------------------------------------------------------- */
IF COL_LENGTH('dbo.DenialTaskBoard','ClaimUID') IS NULL
    THROW 50001, 'DenialTaskBoard.ClaimUID is missing — cannot apply canonical schema.', 1;
IF COL_LENGTH('dbo.DenialLineItem','ClaimUID') IS NULL
    THROW 50002, 'DenialLineItem.ClaimUID is missing — cannot apply canonical schema.', 1;

DECLARE @tbNullUid int = (SELECT COUNT(*) FROM dbo.DenialTaskBoard WHERE NULLIF(LTRIM(RTRIM(ClaimUID)),'') IS NULL);
DECLARE @liNullUid int = (SELECT COUNT(*) FROM dbo.DenialLineItem  WHERE NULLIF(LTRIM(RTRIM(ClaimUID)),'') IS NULL);
IF (@tbNullUid > 0 OR @liNullUid > 0)
    THROW 50003, 'ClaimUID has NULL/blank rows — backfill ClaimUID before removing the fallback code path.', 1;

PRINT 'ClaimUID present and fully populated on both tables. OK.';

/* ---------------------------------------------------------------------------
   1. Integer user-id columns (for FILTERING; username kept for DISPLAY).
   --------------------------------------------------------------------------- */
IF COL_LENGTH('dbo.DenialTaskBoard','AssignedToUserId') IS NULL
    ALTER TABLE dbo.DenialTaskBoard ADD AssignedToUserId int NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ReviewerUpdatedByUserId') IS NULL
    ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedByUserId int NULL;
IF COL_LENGTH('dbo.DenialLineItem','AssignedToUserId') IS NULL
    ALTER TABLE dbo.DenialLineItem ADD AssignedToUserId int NULL;
GO

/* ---------------------------------------------------------------------------
   2. Backfill the int ids from LRNMaster.dbo.LabUsers (match on UserName).
      Case-insensitive, whitespace-trimmed match. Unmatched assignees stay NULL
      (e.g. historical users no longer in LabUsers) — the app treats NULL id as
      "fall back to the username string" so nothing is lost.
   --------------------------------------------------------------------------- */
UPDATE t
   SET t.AssignedToUserId = lu.LabUserID
FROM dbo.DenialTaskBoard t
JOIN LRNMaster.dbo.LabUsers lu
  ON LOWER(LTRIM(RTRIM(lu.UserName))) = LOWER(LTRIM(RTRIM(t.AssignedTo)))
WHERE NULLIF(LTRIM(RTRIM(t.AssignedTo)),'') IS NOT NULL
  AND (t.AssignedToUserId IS NULL OR t.AssignedToUserId <> lu.LabUserID);

UPDATE t
   SET t.ReviewerUpdatedByUserId = lu.LabUserID
FROM dbo.DenialTaskBoard t
JOIN LRNMaster.dbo.LabUsers lu
  ON LOWER(LTRIM(RTRIM(lu.UserName))) = LOWER(LTRIM(RTRIM(t.ReviewerUpdatedBy)))
WHERE NULLIF(LTRIM(RTRIM(t.ReviewerUpdatedBy)),'') IS NOT NULL
  AND (t.ReviewerUpdatedByUserId IS NULL OR t.ReviewerUpdatedByUserId <> lu.LabUserID);

UPDATE l
   SET l.AssignedToUserId = lu.LabUserID
FROM dbo.DenialLineItem l
JOIN LRNMaster.dbo.LabUsers lu
  ON LOWER(LTRIM(RTRIM(lu.UserName))) = LOWER(LTRIM(RTRIM(l.AssignedTo)))
WHERE NULLIF(LTRIM(RTRIM(l.AssignedTo)),'') IS NOT NULL
  AND (l.AssignedToUserId IS NULL OR l.AssignedToUserId <> lu.LabUserID);
GO

/* ---------------------------------------------------------------------------
   3. CreatedUserId on the user-AUTHORED tables (these have CreatedBy/ActionBy).
      The ETL-loaded DenialTaskBoard/DenialLineItem have no created-by source,
      so no CreatedUserId there.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialClaimNotes','U') IS NOT NULL AND COL_LENGTH('dbo.DenialClaimNotes','CreatedUserId') IS NULL
    ALTER TABLE dbo.DenialClaimNotes ADD CreatedUserId int NULL;
IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL AND COL_LENGTH('dbo.DenialClaimEscalations','CreatedUserId') IS NULL
    ALTER TABLE dbo.DenialClaimEscalations ADD CreatedUserId int NULL;
IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL AND COL_LENGTH('dbo.DenialTaskHistory','ActionByUserId') IS NULL
    ALTER TABLE dbo.DenialTaskHistory ADD ActionByUserId int NULL;
GO

IF OBJECT_ID('dbo.DenialClaimNotes','U') IS NOT NULL
    UPDATE n SET n.CreatedUserId = lu.LabUserID
    FROM dbo.DenialClaimNotes n
    JOIN LRNMaster.dbo.LabUsers lu ON LOWER(LTRIM(RTRIM(lu.UserName))) = LOWER(LTRIM(RTRIM(n.CreatedBy)))
    WHERE NULLIF(LTRIM(RTRIM(n.CreatedBy)),'') IS NOT NULL AND (n.CreatedUserId IS NULL OR n.CreatedUserId <> lu.LabUserID);

IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL
    UPDATE e SET e.CreatedUserId = lu.LabUserID
    FROM dbo.DenialClaimEscalations e
    JOIN LRNMaster.dbo.LabUsers lu ON LOWER(LTRIM(RTRIM(lu.UserName))) = LOWER(LTRIM(RTRIM(e.CreatedBy)))
    WHERE NULLIF(LTRIM(RTRIM(e.CreatedBy)),'') IS NOT NULL AND (e.CreatedUserId IS NULL OR e.CreatedUserId <> lu.LabUserID);

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL
    UPDATE h SET h.ActionByUserId = lu.LabUserID
    FROM dbo.DenialTaskHistory h
    JOIN LRNMaster.dbo.LabUsers lu ON LOWER(LTRIM(RTRIM(lu.UserName))) = LOWER(LTRIM(RTRIM(h.ActionBy)))
    WHERE NULLIF(LTRIM(RTRIM(h.ActionBy)),'') IS NOT NULL AND (h.ActionByUserId IS NULL OR h.ActionByUserId <> lu.LabUserID);
GO

/* ---------------------------------------------------------------------------
   4. Covering indexes for the canonical predicates.
      - ClaimUID join/distinct (Lab + ClaimUID) on both tables.
      - AssignedToUserId filter (Lab + AssignedToUserId) on the task board.
   --------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DWF_TaskBoard_Lab_ClaimUID_Status' AND object_id=OBJECT_ID('dbo.DenialTaskBoard'))
    CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_ClaimUID_Status
        ON dbo.DenialTaskBoard(LabId, ClaimUID, Status, AssignedTo, CreatedOn);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DWF_LineItem_Lab_ClaimUID_DOS' AND object_id=OBJECT_ID('dbo.DenialLineItem'))
    CREATE NONCLUSTERED INDEX IX_DWF_LineItem_Lab_ClaimUID_DOS
        ON dbo.DenialLineItem(LabId, ClaimUID, DateOfService);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DWF_TaskBoard_Lab_AssignedToUserId' AND object_id=OBJECT_ID('dbo.DenialTaskBoard'))
    CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_AssignedToUserId
        ON dbo.DenialTaskBoard(LabId, AssignedToUserId, Status)
        INCLUDE (ClaimUID, CreatedOn);
GO

/* ---------------------------------------------------------------------------
   5. Verification — review before flipping the app to the canonical code path.
   --------------------------------------------------------------------------- */
SELECT 'DenialTaskBoard' AS tbl,
       COUNT(*) AS rows_total,
       SUM(CASE WHEN AssignedTo IS NOT NULL AND AssignedTo<>'' AND AssignedToUserId IS NULL THEN 1 ELSE 0 END) AS assigned_unmatched
FROM dbo.DenialTaskBoard
UNION ALL
SELECT 'DenialLineItem',
       COUNT(*),
       SUM(CASE WHEN AssignedTo IS NOT NULL AND AssignedTo<>'' AND AssignedToUserId IS NULL THEN 1 ELSE 0 END)
FROM dbo.DenialLineItem;
GO
