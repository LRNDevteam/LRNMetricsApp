/* =============================================================================
DenialWorkflow_Performance_Optimization_20260722.sql

Purpose
-------
Round 2 of the SARGability work started in DenialWorkflow_Performance_Indexes_
And_Backfill_20260701.sql. That script normalized ClaimID / VisitNumber /
AssignedTo. The remaining hot-path cost is the CLAIM KEY expression used by the
claim grids, tab counts, and dashboard:

    COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(ClaimUID,''))), ''),
             REPLACE(LTRIM(RTRIM(ISNULL(VisitNumber,''))), 'CLM-', ''))

Today this is recomputed per row per request and GROUPed BY / JOINed ON, which
is non-SARGable: every claims page load scans DenialLineItem and DenialTaskBoard
and recomputes string functions for every row (CPU + full-scan logical reads).

This script materializes that expression once as a PERSISTED computed column
(ClaimKeyNormalized) on both tables, indexes it, and adds the equivalent for
DenialClaimEscalations.ClaimIdNormalized. The application (build 2026-07-22+)
detects these columns at runtime and switches its queries to them; without the
columns it keeps the old inline expressions, so deploy order does not matter.

Idempotent — safe to re-run. Run once per lab database, in a maintenance
window (index builds on ~300k+ row tables).
============================================================================= */

SET NOCOUNT ON;

------------------------------------------------------------------------------
-- 1. DenialLineItem.ClaimKeyNormalized — the canonical claim key used by
--    GetClaimsAsync / GetClaimSubMenuCountsAsync / dashboard aggregations.
--    NOTE: a computed column cannot reference another computed column, so the
--    VisitNumber normalization formula is inlined rather than referencing
--    VisitNumberNormalized.
------------------------------------------------------------------------------
IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialLineItem','ClaimKeyNormalized') IS NULL
BEGIN
    IF COL_LENGTH('dbo.DenialLineItem','ClaimUID') IS NOT NULL
        EXEC sp_executesql N'
            ALTER TABLE dbo.DenialLineItem ADD ClaimKeyNormalized AS
                CONVERT(varchar(150), COALESCE(
                    NULLIF(LTRIM(RTRIM(ISNULL(ClaimUID,''''))), ''''),
                    REPLACE(LTRIM(RTRIM(ISNULL(VisitNumber,''''))), ''CLM-'', ''''))) PERSISTED;';
    ELSE
        EXEC sp_executesql N'
            ALTER TABLE dbo.DenialLineItem ADD ClaimKeyNormalized AS
                CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(VisitNumber,''''))), ''CLM-'', '''')) PERSISTED;';
    PRINT 'DenialLineItem.ClaimKeyNormalized added.';
END
GO

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialLineItem','ClaimKeyNormalized') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialLineItem_ClaimKeyNormalized' AND object_id=OBJECT_ID('dbo.DenialLineItem'))
BEGIN
    -- Key order (LabId, ClaimKeyNormalized): every caller filters by LabId, then
    -- groups/joins on the claim key. INCLUDE covers the claim-grid page SELECT so the
    -- #ClaimBase build is an index-only range scan instead of a clustered scan.
    CREATE NONCLUSTERED INDEX IX_DenialLineItem_ClaimKeyNormalized
        ON dbo.DenialLineItem (LabId, ClaimKeyNormalized)
        INCLUDE (VisitNumber, DateOfService, PayerName, PanelName, InsuranceBalance, AssignedTo, DenialClassification, ActionCategory);
    PRINT 'IX_DenialLineItem_ClaimKeyNormalized created.';
END
GO

------------------------------------------------------------------------------
-- 2. DenialTaskBoard.ClaimKeyNormalized — same canonical key on the task side,
--    replacing COALESCE(ClaimUID, ClaimIDNormalized, REPLACE(ClaimID)) at
--    query time. (ClaimIDNormalized ≡ REPLACE(TRIM(ClaimID)),'CLM-'), so the
--    inlined 2-way COALESCE is equivalent to the old 3-way expression.)
------------------------------------------------------------------------------
IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard','ClaimKeyNormalized') IS NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskBoard','ClaimUID') IS NOT NULL
        EXEC sp_executesql N'
            ALTER TABLE dbo.DenialTaskBoard ADD ClaimKeyNormalized AS
                CONVERT(varchar(150), COALESCE(
                    NULLIF(LTRIM(RTRIM(ISNULL(ClaimUID,''''))), ''''),
                    REPLACE(LTRIM(RTRIM(ISNULL(ClaimID,''''))), ''CLM-'', ''''))) PERSISTED;';
    ELSE
        EXEC sp_executesql N'
            ALTER TABLE dbo.DenialTaskBoard ADD ClaimKeyNormalized AS
                CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(ClaimID,''''))), ''CLM-'', '''')) PERSISTED;';
    PRINT 'DenialTaskBoard.ClaimKeyNormalized added.';
END
GO

IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard','ClaimKeyNormalized') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialTaskBoard_ClaimKeyNormalized' AND object_id=OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    -- Serves the per-claim task aggregation (status counts per claim) as a seek/range
    -- scan; INCLUDE covers the status/assignment columns those aggregates read.
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimKeyNormalized
        ON dbo.DenialTaskBoard (LabId, ClaimKeyNormalized)
        INCLUDE (TaskID, Status, WorkFlowStatus, AssignedTo, SLAStatus, CreatedOn, InsuranceBalance);
    PRINT 'IX_DenialTaskBoard_ClaimKeyNormalized created.';
END
GO

------------------------------------------------------------------------------
-- 3. DenialClaimEscalations.ClaimIdNormalized — escalation lookups currently
--    wrap ClaimId in REPLACE(LTRIM(RTRIM(...))) per row (non-SARGable).
--    DenialClaimNotes already has this exact column; mirror it here.
------------------------------------------------------------------------------
IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimEscalations','ClaimIdNormalized') IS NULL
BEGIN
    EXEC sp_executesql N'
        ALTER TABLE dbo.DenialClaimEscalations ADD ClaimIdNormalized AS
            CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''''))), ''CLM-'', '''')) PERSISTED;';
    PRINT 'DenialClaimEscalations.ClaimIdNormalized added.';
END
GO

IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimEscalations','ClaimIdNormalized') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DWF_Escalations_Lab_ClaimIdNormalized' AND object_id=OBJECT_ID('dbo.DenialClaimEscalations'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DWF_Escalations_Lab_ClaimIdNormalized
        ON dbo.DenialClaimEscalations (LabId, ClaimIdNormalized, IsDeleted)
        INCLUDE (EscalationLevel, Status, EscalatedTo, EscalatedToRole, CreatedOn);
    PRINT 'IX_DWF_Escalations_Lab_ClaimIdNormalized created.';
END
GO

------------------------------------------------------------------------------
-- 4. REVIEW-FIRST helper: missing indexes suggested by the DMVs for THIS
--    database. Do NOT create these blindly — check overlap with existing
--    indexes (section 5) and the write cost. Run, review, then decide.
------------------------------------------------------------------------------
PRINT '--- Missing-index suggestions (review before creating) ---';
SELECT TOP (20)
    improvement = CONVERT(decimal(18,1), gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans)),
    tbl = OBJECT_NAME(d.object_id),
    d.equality_columns, d.inequality_columns, d.included_columns,
    gs.user_seeks, gs.user_scans, gs.last_user_seek
FROM sys.dm_db_missing_index_details d
JOIN sys.dm_db_missing_index_groups g  ON g.index_handle = d.index_handle
JOIN sys.dm_db_missing_index_group_stats gs ON gs.group_handle = g.index_group_handle
WHERE d.database_id = DB_ID()
  AND OBJECT_NAME(d.object_id) LIKE 'Denial%'
ORDER BY improvement DESC;
GO

------------------------------------------------------------------------------
-- 5. Duplicate / overlapping index detection: two indexes where one's key list
--    is a leading prefix of the other's are candidates to consolidate (keep
--    the wider one; drop the narrower unless it is unique/constraint-backed).
------------------------------------------------------------------------------
PRINT '--- Overlapping index candidates (leading-prefix duplicates) ---';
;WITH IndexCols AS
(
    SELECT i.object_id, i.index_id, i.name,
           key_cols = STRING_AGG(c.name, ',') WITHIN GROUP (ORDER BY ic.key_ordinal)
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=0
    JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
    WHERE i.type > 0 AND OBJECT_NAME(i.object_id) LIKE 'Denial%'
    GROUP BY i.object_id, i.index_id, i.name
)
SELECT tbl = OBJECT_NAME(a.object_id),
       narrower = a.name, narrower_keys = a.key_cols,
       wider = b.name,   wider_keys   = b.key_cols
FROM IndexCols a
JOIN IndexCols b
  ON a.object_id=b.object_id AND a.index_id<>b.index_id
 AND b.key_cols LIKE a.key_cols + ',%'
ORDER BY tbl, narrower;
GO

------------------------------------------------------------------------------
-- 6. Measurement protocol (run BEFORE deploying the app build and again AFTER,
--    with the same filters, to get the before/after numbers):
--
--    SET STATISTICS IO, TIME ON;
--    EXEC sp_executesql N'<paste the claims/menu-counts batch from the app log>';
--
--    Or from Query Store (aggregate, no repro needed):
--    SELECT TOP 20 qt.query_sql_text,
--           rs.avg_cpu_time, rs.avg_logical_io_reads, rs.count_executions
--    FROM sys.query_store_query_text qt
--    JOIN sys.query_store_query q ON q.query_text_id = qt.query_text_id
--    JOIN sys.query_store_plan p ON p.query_id = q.query_id
--    JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
--    WHERE qt.query_sql_text LIKE '%DenialLineItem%'
--    ORDER BY rs.avg_logical_io_reads DESC;
------------------------------------------------------------------------------
PRINT 'DenialWorkflow_Performance_Optimization_20260722.sql complete.';
GO
