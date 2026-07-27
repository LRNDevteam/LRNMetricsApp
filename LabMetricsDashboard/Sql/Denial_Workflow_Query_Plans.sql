/**************************************************************************************************
  Denial Workflow — Query plan / optimization harness
  --------------------------------------------------------------------------------------------
  The denial workflow queries are built dynamically in C# (SqlDenialWorkflowRepository.cs) with
  temp-table pipelines, so the exact text varies by lab/role/filters. The most reliable way to get
  the ACTUAL execution plans is to run the app action once, then harvest the plan from cache/Query
  Store (PART A). PART B has self-contained, directly-runnable versions of the key building blocks
  so you can get an actual plan by hand.

  HOW TO USE
  1. Point SSMS at the lab database (e.g. NWL_LRN). Set @LabId / @RoleUserName below.
  2. PART A: exercise the app (open Dashboard, My Worklist, a tab, a claim), then run the harvest
     queries — they return each denial query's text + plan XML + IO/CPU/duration. Click the plan
     XML to open the graphical actual plan.
  3. PART B: turn on "Include Actual Execution Plan" (Ctrl+M) and run a block directly.

  WHAT TO LOOK FOR IN THE PLANS (the known hot spots)
    - Table Scan / Clustered Index Scan on DenialLineItem or DenialTaskBoard = the heap/index issue
      (apply Denial_Performance_Optimization.sql — clustered indexes + AssignedToNormalized).
    - Nested Loops with a scan on the inner side against DenialLineItem/DenialTaskBoard = a
      non-sargable join (the API fixes made these seeks; confirm here).
    - "Columnstore"/hash spills to tempdb, or a fat Sort, on the #ClaimBase / #TaskClaimRaw steps.
**************************************************************************************************/

DECLARE @LabId            int          = 23;          -- <-- set your lab id
DECLARE @IncludeNorthWestPair bit      = CASE WHEN @LabId IN (20,23) THEN 1 ELSE 0 END;
DECLARE @RoleUserName     nvarchar(256)= N'Jameel_AR'; -- <-- reviewer user for the reviewer path
DECLARE @ClaimUid         nvarchar(150)= N'';          -- <-- a ClaimUID for the drilldown block
DECLARE @ClaimKey         nvarchar(150)= N'';          -- <-- same claim's normalized/visit key

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO


/*================================================================================================
  PART A — Harvest the ACTUAL denial queries + plans from the plan cache
  (run these AFTER exercising the app; they need no parameters)
================================================================================================*/

-- A1. Every cached denial-workflow statement, ranked by total CPU. The plan_handle -> query_plan
--     column is the clickable actual/estimated plan. Filters to the denial temp tables + base
--     tables so you only see the workflow queries.
SELECT TOP (40)
    avg_worker_ms   = qs.total_worker_time / NULLIF(qs.execution_count,0) / 1000,
    avg_elapsed_ms  = qs.total_elapsed_time / NULLIF(qs.execution_count,0) / 1000,
    avg_logical_rds = qs.total_logical_reads / NULLIF(qs.execution_count,0),
    qs.execution_count,
    total_worker_ms = qs.total_worker_time / 1000,
    query_text = SUBSTRING(st.text,
                    (qs.statement_start_offset/2)+1,
                    ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                      ELSE qs.statement_end_offset END - qs.statement_start_offset)/2)+1),
    qp.query_plan,
    qs.creation_time, qs.last_execution_time
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE st.text LIKE '%#ClaimBase%'
   OR st.text LIKE '%#TaskClaimRaw%'
   OR st.text LIKE '%#TaskBoardBase%'
   OR st.text LIKE '%#ReviewerScope%'
   OR st.text LIKE '%#ClaimPage%'
   OR st.text LIKE '%DenialTaskBoard%'
   OR st.text LIKE '%DenialLineItem%'
ORDER BY qs.total_worker_time DESC;
GO

-- A2. If Query Store is ON (recommended on the MI), this is more durable than the cache and keeps
--     per-plan history. Enable once:  ALTER DATABASE CURRENT SET QUERY_STORE = ON;
SELECT TOP (40)
    avg_ms   = rs.avg_duration/1000.0,
    avg_cpu_ms = rs.avg_cpu_time/1000.0,
    avg_logical_reads = rs.avg_logical_io_reads,
    rs.count_executions,
    qt.query_sql_text,
    p.query_plan,
    rs.last_execution_time
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_plan p        ON p.plan_id = rs.plan_id
JOIN sys.query_store_query q       ON q.query_id = p.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
WHERE qt.query_sql_text LIKE '%DenialTaskBoard%'
   OR qt.query_sql_text LIKE '%DenialLineItem%'
   OR qt.query_sql_text LIKE '%#ClaimBase%'
ORDER BY rs.avg_cpu_time DESC;
GO

-- A3. Missing-index suggestions the optimizer recorded for the denial tables (sanity check against
--     Denial_Performance_Optimization.sql — do NOT blindly create all of these; they overlap).
SELECT
    improvement = ROUND(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans),0),
    d.statement AS table_name,
    equality = d.equality_columns,
    inequality = d.inequality_columns,
    included = d.included_columns,
    s.user_seeks, s.user_scans, s.last_user_seek
FROM sys.dm_db_missing_index_group_stats s
JOIN sys.dm_db_missing_index_groups g ON s.group_handle = g.index_group_handle
JOIN sys.dm_db_missing_index_details d ON d.index_handle = g.index_handle
WHERE d.statement LIKE '%DenialTaskBoard%' OR d.statement LIKE '%DenialLineItem%'
ORDER BY improvement DESC;
GO

-- A4. Confirm the two hot tables are no longer HEAPS and that AssignedToNormalized exists.
SELECT t.name AS table_name,
       heap_or_clustered = CASE WHEN i.index_id = 0 THEN 'HEAP (bad)' WHEN i.index_id = 1 THEN 'CLUSTERED' END,
       i.name AS clustered_index,
       row_count = SUM(p.rows)
FROM sys.tables t
JOIN sys.indexes i ON i.object_id = t.object_id AND i.index_id IN (0,1)
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id = i.index_id
WHERE t.name IN ('DenialTaskBoard','DenialLineItem')
GROUP BY t.name, i.index_id, i.name;

SELECT 'DenialTaskBoard.AssignedToNormalized' AS col,
       present = CASE WHEN COL_LENGTH('dbo.DenialTaskBoard','AssignedToNormalized') IS NULL THEN 'MISSING' ELSE 'OK' END;
GO


/*================================================================================================
  PART B — Self-contained runnable building blocks (Ctrl+M then run a block for an actual plan)
  These are the reviewer path — the slow one. Re-declare the vars if you ran GO above.
================================================================================================*/
DECLARE @LabId int = 23, @IncludeNorthWestPair bit = 0, @RoleUserName nvarchar(256) = N'Jameel_AR';
DECLARE @ClaimUid nvarchar(150) = N'', @ClaimKey nvarchar(150) = N'';
SET @IncludeNorthWestPair = CASE WHEN @LabId IN (20,23) THEN 1 ELSE 0 END;

-- B1. #ReviewerScope seed — the reviewer's assigned claims. Should be an INDEX SEEK on
--     IX_DWF_TaskBoard_Lab_AssignedToNorm (LabId, AssignedToNormalized). If it SCANS, the
--     AssignedToNormalized column/index from Denial_Performance_Optimization.sql is missing.
IF OBJECT_ID('tempdb..#ReviewerScope') IS NOT NULL DROP TABLE #ReviewerScope;
SELECT DISTINCT
    ClaimUid = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimUID,''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))), ''), CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.ClaimID,''))), 'CLM-', ''))),
    ClaimIDNormalized = NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))), '')
INTO #ReviewerScope
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE (t.LabId = @LabId OR (@IncludeNorthWestPair = 1 AND t.LabId IN (20,23)))
  AND t.AssignedToNormalized = LOWER(LTRIM(RTRIM(@RoleUserName)));   -- seek target
CREATE CLUSTERED INDEX IX_ReviewerScope_ClaimUid ON #ReviewerScope(ClaimUid);
SELECT ReviewerScopeRows = COUNT(*) FROM #ReviewerScope;

-- B2. #ClaimBase — the reviewer's claims from DenialLineItem. Look for: scan of DenialLineItem
--     probing #ReviewerScope. With the clustered index this is a range/seek; on the heap it is a
--     full scan. This is the step that most often dominates.
IF OBJECT_ID('tempdb..#ClaimBase') IS NOT NULL DROP TABLE #ClaimBase;
SELECT
    ClaimUid = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(l.ClaimUID,''))), ''), CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))),
    ClaimId  = MAX(LTRIM(RTRIM(ISNULL(l.VisitNumber,'')))),
    ClaimKey = MAX(CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))),
    DateOfService = MAX(l.DateOfService)
INTO #ClaimBase
FROM dbo.DenialLineItem l WITH (NOLOCK)
WHERE (l.LabId = @LabId OR (@IncludeNorthWestPair = 1 AND l.LabId IN (20,23)))
  AND NULLIF(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))),'') IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM #ReviewerScope rs
      WHERE rs.ClaimUid = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(l.ClaimUID,''))), ''), CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', '')))
         OR (NULLIF(LTRIM(RTRIM(ISNULL(l.ClaimUID,''))),'') IS NULL
             AND rs.ClaimIDNormalized <> '' AND rs.ClaimIDNormalized = l.VisitNumberNormalized)
  )
GROUP BY COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(l.ClaimUID,''))), ''), CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', '')));
SELECT ClaimBaseRows = COUNT(*) FROM #ClaimBase;

-- B3. The task-side join (the #TaskClaimRaw step joins #ClaimBase to DenialTaskBoard). This is the
--     sargable form the API now uses. Look for INDEX SEEK on IX_DWF_TaskBoard_ClaimUID_StatusAgg
--     (ClaimUID) and IX_DWF_TaskBoard_ClaimIDNormalized_StatusAgg (ClaimIDNormalized), NOT a scan.
SELECT cb.ClaimUid, TaskCount = COUNT(t.TaskID),
       AssignedCount = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'') IS NOT NULL THEN 1 ELSE 0 END)
FROM #ClaimBase cb
LEFT JOIN dbo.DenialTaskBoard t WITH (NOLOCK)
  ON (t.ClaimUID = cb.ClaimUid OR t.ClaimIDNormalized = cb.ClaimKey)
 AND (t.LabId = @LabId OR (@IncludeNorthWestPair = 1 AND t.LabId IN (20,23)))
GROUP BY cb.ClaimUid;

-- B4. The page-detail join (#PageLineDetails). Sargable form: seek DenialLineItem on ClaimUID /
--     VisitNumberNormalized. Uses the top page of #ClaimBase as the driver.
;WITH pg AS (SELECT TOP (100) ClaimUid, ClaimId AS VisitNumber FROM #ClaimBase ORDER BY DateOfService DESC, ClaimId)
SELECT p.ClaimUid,
       PayerName = MAX(LTRIM(RTRIM(ISNULL(l.PayerName,'')))),
       InsuranceBalance = CAST(SUM(ISNULL(l.InsuranceBalance,0)) AS decimal(18,2))
FROM pg p
JOIN dbo.DenialLineItem l WITH (NOLOCK)
  ON (l.ClaimUID = p.ClaimUid OR l.VisitNumberNormalized = CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(p.VisitNumber,''))), 'CLM-', '')))
 AND (l.LabId = @LabId OR (@IncludeNorthWestPair = 1 AND l.LabId IN (20,23)))
GROUP BY p.ClaimUid;

IF OBJECT_ID('tempdb..#ReviewerScope') IS NOT NULL DROP TABLE #ReviewerScope;
IF OBJECT_ID('tempdb..#ClaimBase') IS NOT NULL DROP TABLE #ClaimBase;
GO

-- B5. Claim drill-down (GetTasksByClaimAsync). Set @ClaimUid/@ClaimKey above. Should seek
--     IX_DWF_TaskBoard_ClaimUID_Drill / ClaimIDNormalized, then OUTER APPLY the line items.
--     (Previously this scanned DenialTaskBoard because of a leading-wildcard LIKE — now sargable.)
SELECT t.TaskID, t.ClaimID, t.CPTCode, t.Status, t.AssignedTo, t.DueDate, t.SLAStatus
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE (t.LabId = @LabId OR (@IncludeNorthWestPair = 1 AND t.LabId IN (20,23)))
  AND (t.ClaimUID = @ClaimUid OR t.ClaimIDNormalized = @ClaimKey OR t.ClaimID = @ClaimUid)
ORDER BY t.CPTCode, t.TaskID;
GO

-- B6. Notes / documents lookups (Claim Notes tab, History). Sargable prefix match on ClaimIDNormalized.
SELECT TOP (200) NoteId, ClaimId, NoteLevel, Status, CreatedOn
FROM dbo.DenialClaimNotes WITH (NOLOCK)
WHERE IsDeleted=0 AND LabId=@LabId AND NoteLevel='Claim'
  AND (ClaimIdNormalized=@ClaimKey
       OR ClaimIdNormalized LIKE @ClaimKey + '\_%' ESCAPE '\'
       OR @ClaimKey LIKE ClaimIdNormalized + '\_%' ESCAPE '\')
ORDER BY CreatedOn DESC, NoteId DESC;
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
