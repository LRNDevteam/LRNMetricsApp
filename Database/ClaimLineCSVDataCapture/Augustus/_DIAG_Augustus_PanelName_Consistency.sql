/* =====================================================================
   DIAGNOSTIC — Augustus: does Collection Summary use the same panel
   name as Production Report?

   Run on Augustus_LRN. Read-only: no CREATE / ALTER / INSERT anywhere.

   Background
   ----------
   dbo.ClaimLevelData carries three panel columns:
       Panelname      raw value from the CSV
       PanelNew       the cleaned / mapped panel  <-- Production Report uses this
       PanelCategory  category grouping           <-- feeds the panel filter dropdown

   Production Report (14_ / 07_ / 08_) groups by PanelNew everywhere.
   Collection Summary READ SPs (15_) also use PanelNew everywhere, but they
   only aggregate live WHEN A FILTER IS APPLIED - with no filter they serve
   the Aug_CS_* snapshot tables, and two of the refresh SPs that build those
   snapshots group by the raw Panelname instead:

       usp_RefreshAug_CS_WeeklyClaimVolume   -> Panelname   (13_ line 546)
       usp_RefreshAug_CS_PanelVsPayment      -> Panelname   (13_ line 834)

   Also: usp_RefreshAug_CS_PanelAverages is declared TWICE in 13_
       line  98  -> Panelname   (raw)
       line 648  -> PanelNew    (correct; wins when the whole script runs)
   so whichever body is actually deployed decides what Panel Averages shows.
   Query 4 below tells you which one is live.
   ===================================================================== */
SET NOCOUNT ON;

PRINT '=== 1. How often do the three panel columns disagree? ===';
SELECT
    TotalRows            = COUNT(*),
    PanelNew_Blank       = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(PanelNew,      ''))), '') IS NULL THEN 1 ELSE 0 END),
    Panelname_Blank      = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(Panelname,     ''))), '') IS NULL THEN 1 ELSE 0 END),
    PanelCategory_Blank  = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(PanelCategory, ''))), '') IS NULL THEN 1 ELSE 0 END),
    Raw_vs_New_Differ    = SUM(CASE WHEN LTRIM(RTRIM(ISNULL(Panelname, ''))) <> LTRIM(RTRIM(ISNULL(PanelNew, ''))) THEN 1 ELSE 0 END),
    Cat_vs_New_Differ    = SUM(CASE WHEN LTRIM(RTRIM(ISNULL(PanelCategory, ''))) <> LTRIM(RTRIM(ISNULL(PanelNew, ''))) THEN 1 ELSE 0 END)
FROM dbo.ClaimLevelData;

PRINT '=== 2. Side-by-side distinct mapping (raw -> new -> category) ===';
SELECT TOP (100)
    Panelname     = LTRIM(RTRIM(ISNULL(Panelname,     '(blank)'))),
    PanelNew      = LTRIM(RTRIM(ISNULL(PanelNew,      '(blank)'))),
    PanelCategory = LTRIM(RTRIM(ISNULL(PanelCategory, '(blank)'))),
    Claims        = COUNT(*)
FROM dbo.ClaimLevelData
GROUP BY LTRIM(RTRIM(ISNULL(Panelname, '(blank)'))),
         LTRIM(RTRIM(ISNULL(PanelNew, '(blank)'))),
         LTRIM(RTRIM(ISNULL(PanelCategory, '(blank)')))
ORDER BY Claims DESC;

PRINT '=== 3. Snapshot panel names that are NOT valid PanelNew values ===';
PRINT '     (anything listed here is a tab showing the wrong panel name)';
;WITH validPanel AS (
    SELECT DISTINCT PanelNew = LTRIM(RTRIM(ISNULL(PanelNew, 'Unknown')))
    FROM dbo.ClaimLevelData
)
SELECT SnapshotTable = 'Aug_CS_PanelAverages',  PanelName FROM dbo.Aug_CS_PanelAverages
WHERE PanelName NOT IN (SELECT PanelNew FROM validPanel)
UNION
SELECT 'Aug_CS_AvgPayments',        PanelName FROM dbo.Aug_CS_AvgPayments
WHERE PanelName NOT IN (SELECT PanelNew FROM validPanel)
UNION
SELECT 'Aug_CS_WeeklyClaimVolume',  PanelName FROM dbo.Aug_CS_WeeklyClaimVolume
WHERE PanelName NOT IN (SELECT PanelNew FROM validPanel)
UNION
SELECT 'Aug_CS_MonthlyClaimVolume', PanelName FROM dbo.Aug_CS_MonthlyClaimVolume
WHERE PanelName NOT IN (SELECT PanelNew FROM validPanel)
UNION
SELECT 'Aug_CS_PanelVsPayment',     PanelName FROM dbo.Aug_CS_PanelVsPayment
WHERE PanelName NOT IN (SELECT PanelNew FROM validPanel)
UNION
SELECT 'Aug_CS_StatusSummary',      PanelName FROM dbo.Aug_CS_StatusSummary
WHERE PanelName NOT IN (SELECT PanelNew FROM validPanel)
ORDER BY 1, 2;

PRINT '=== 4. Which panel column does each DEPLOYED refresh SP actually use? ===';
SELECT
    ProcName    = o.name,
    UsesPanelNew   = CASE WHEN m.definition COLLATE Latin1_General_BIN2 LIKE '%PanelNew%'   THEN 'YES' ELSE 'no' END,
    UsesRawPanel   = CASE WHEN m.definition COLLATE Latin1_General_BIN2 LIKE '%Panelname%'  THEN 'YES' ELSE 'no' END,
    UsesPanelCat   = CASE WHEN m.definition COLLATE Latin1_General_BIN2 LIKE '%PanelCategory%' THEN 'YES' ELSE 'no' END,
    LastModified   = o.modify_date
FROM sys.sql_modules m
JOIN sys.objects o ON o.object_id = m.object_id
WHERE o.name LIKE 'usp_%Aug%CS%'
   OR o.name LIKE 'usp_GetAug_%ProductionSummary%'
ORDER BY o.name;
-- NOTE: 'UsesRawPanel = YES' can be a false positive when the SP merely
-- ALIASES its output column as PanelName. Confirm with query 3 (data) or by
-- reading the body:  EXEC sp_helptext 'dbo.usp_RefreshAug_CS_PanelAverages';

PRINT '=== 5. Panel filter dropdown values vs what the SPs filter on ===';
PRINT '     Dropdown is built from PanelCategory; every SP filters on PanelNew.';
SELECT
    DropdownValue = LTRIM(RTRIM(FilterValue)),
    MatchesAPanelNew = CASE WHEN EXISTS (
        SELECT 1 FROM dbo.ClaimLevelData c
        WHERE LTRIM(RTRIM(ISNULL(c.PanelNew, 'Unknown'))) = LTRIM(RTRIM(f.FilterValue))
    ) THEN 'yes' ELSE 'NO - filter will return nothing' END
FROM dbo.DashboardFilterOptions f
WHERE FilterType IN (N'PanelName', N'PanelType')
  AND NULLIF(LTRIM(RTRIM(FilterValue)), '') IS NOT NULL
ORDER BY 2 DESC, 1;
