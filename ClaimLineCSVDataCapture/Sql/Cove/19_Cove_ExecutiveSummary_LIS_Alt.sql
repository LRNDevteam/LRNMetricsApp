-- ============================================================
-- Cove – LIS Breakdown Refresh ("Alt") SP
-- File : 19_Cove_ExecutiveSummary_LIS_Alt.sql
-- DB   : Cove_LRN
--
-- Run order: AFTER ingestion of LIMSMaster (independent of
-- usp_RefreshCove_ExecutiveSummary / ClaimLevelData, which only populates
-- the PMS/Cash/Avg breakdowns in 16_Cove_ExecutiveSummary_Aggregate.sql).
-- Wired into ClaimLineCSVDataCapture's generic prefix-driven Executive
-- Summary refresh (RefreshExecutiveSummaryByPrefix), same as
-- PhiLife/Elixir/RisingTides' *_LIS_Alt procs.
--
-- This SP fully owns dbo.Cove_ES_LIS and TRUNCATEs it at the start of
-- every run. There is no separate LIS_Panel table for Cove - see
-- 15_Cove_ExecutiveSummary_Tables.sql.
--
-- DYNAMIC PanelType sub-rows: B.<PanelType>, D.5.<PanelType> and
-- D.6.<PanelType> are NOT a fixed/enumerated list. They are generated
-- at refresh time, one row per DISTINCT PanelType value actually present
-- in dbo.LIMSMaster (via #PanelTypes, CROSS JOINed against #LisPeriods).
-- If LIMSMaster gains/loses a panel type, these rows automatically
-- appear/disappear on the next refresh - no SQL changes needed.
--
-- RoleID scheme (from the Cove "LIS Breakdown" spec image):
--   A      Total Samples            -> COUNT(DISTINCT Accession)
--   B      Billable Samples         -> NewStatus = 'Billable'
--     B.<PanelType>  (one per distinct LIMSMaster.PanelType, e.g. 'B.UTI',
--                     'B.Wound', 'B.RPP', ...) -> B + PanelType = <PanelType>
--   C      Billed                   -> B + BillCategory = 'Billed'
--   D      Not Billed                -> B + BillCategory = 'Not Billed'
--     D.1    Billed Insurance In Covedx     -> D + SubStatus = 'Billed Insurance In Covedx'
--     D.2    Billed In Variantx Lab         -> D + SubStatus = 'Billed In Variantx Lab'
--     D.3    Billed In Elixir Dx            -> D + SubStatus = 'Billed In Elixir Dx'
--     D.4    Ignored - Duplicate Accession  -> D + SubStatus = 'Ignored - Duplicate Accession'
--     D.5    Coding exception               -> D + SubStatus = 'Coding exception'
--       D.5.<PanelType>  (one per distinct LIMSMaster.PanelType, e.g.
--                         'D.5.Wound', 'D.5.GI', ...) -> D.5 + PanelType = <PanelType>
--     D.6    CP Exception                   -> D + SubStatus = 'CP Exception'
--       D.6.<PanelType>  (one per distinct LIMSMaster.PanelType, e.g.
--                         'D.6.UTI', 'D.6.Wound', ...) -> D.6 + PanelType = <PanelType>
--     D.7    In process                              -> D + SubStatus = 'In process'
--     D.8    Ignored - Client Response Non Billiable -> D + SubStatus = 'Ignored - Client Response Non Billiable'
--     D.9    Ready To Bill                           -> D + SubStatus = 'Ready To Bill'
--     D.10   Ignored - NGS & PGX in Cove             -> D + SubStatus = 'Ignored - NGS & PGX in Cove'
--     D.11   CP Exception -In Review                 -> D + SubStatus = 'CP Exception -In Review'
--     D.12   Medicaid Credentialling In Process      -> D + SubStatus = 'Medicaid Credentialling In Process'
--     D.13   Ignored - Reported in Elixir Truemed    -> D + SubStatus = 'Ignored - Reported in Elixir Truemed'
--     D.14   Ignored - CP Exception                  -> D + SubStatus = 'Ignored - CP Exception'
--     D.15   Client Bill Cases                       -> D + SubStatus = 'Client Bill Cases'
--     D.16   Ignored - Client Response Pure Selfpay  -> D + SubStatus = 'Ignored - Client Response Pure Selfpay'
--     D.17   Selfpay                                 -> D + SubStatus = 'Selfpay'
--     D.18   Ignored - Rejected Accession            -> D + SubStatus = 'Ignored - Rejected Accession'
--     D.19   Hold-Amerihealth Lousiana                -> D + SubStatus = 'Hold-Amerihealth Lousiana'
--     D.20   Ignored - Test Cases                    -> D + SubStatus = 'Ignored - Test Cases'
--   E      Other Samples            -> NewStatus <> 'Billable'
--     E.1    Self Pay                 -> NewStatus = 'Self Pay'
--     E.2    Client Bill              -> NewStatus = 'Client Bill'
--     E.3    Deleted / Rejected       -> NewStatus = 'Deleted / Rejected'
--     E.4    System Test              -> NewStatus = 'System Test'
--     E.5    Ref Lab - Bill Patient   -> NewStatus = 'Ref Lab - Bill Patient'
--     E.6    Missing Accession        -> NewStatus = 'Missing Accession'
--     E.7    Yet To Be Validated      -> NewStatus = 'Yet To Be Validated'
--
-- NOTE on spec source numbering: the source spec image lists a "16" row
-- twice (once as "Ignored - Client Response Pure Selfpay" and again,
-- separately, as "Selfpay"). To keep RoleIDs unique they are renumbered
-- here as D.16 (Ignored - Client Response Pure Selfpay) and D.17
-- (Selfpay), shifting the remaining rows so D.18/D.19/D.20 = Ignored -
-- Rejected Accession / Hold-Amerihealth Lousiana / Ignored - Test Cases.
--
-- Period bucket: LIMSMaster's own date column, auto-detected with
-- DateOfCollection given top priority (per user direction: "DateOfCollection
-- - for Dates - use this in LIMSMaster"), independent of the
-- DateofService-based #Periods used by PMS/Cash/Avg.
--
-- Column auto-detection (sys.columns / OBJECT_ID('dbo.LIMSMaster')):
--   @AccCol          : AccessionNumber, Accession, AccessionNo
--   @DateCol         : DateOfCollection, RequestCollectDate, DateofService, CollectionDate, ServiceDate, AccessionDate
--   @NewStatusCol    : NewStatus, Status
--   @PanelTypeCol    : PanelType, PanelCategory, PanelName, Panelname, TestPanel, TestPanelName, Panel, PanelDescription, TestName, Test_Panel, TestPanelname
--   @BillCategoryCol : BillCategory, Bill_Category, BillingCategory, BilledorNot, BillStatus
--   @SubStatusCol    : SubStatus, Sub_Status, ClientStatus, FinalStatus
--
-- If dbo.LIMSMaster does not exist, or any required column cannot be
-- located, the SP TRUNCATEs Cove_ES_LIS, prints a diagnostic, and RETURNs
-- (graceful no-op - same pattern as Elixir's 19 / RisingTides' 27).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Cove_ES_LIS;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        PRINT 'usp_RefreshCove_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
        RETURN;
    END

    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','Accession','AccessionNo')
        ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('DateOfCollection','RequestCollectDate','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'DateOfCollection' THEN 0 WHEN 'RequestCollectDate' THEN 1
            WHEN 'DateofService' THEN 2 WHEN 'CollectionDate' THEN 3
            WHEN 'ServiceDate' THEN 4 WHEN 'AccessionDate' THEN 5 ELSE 6 END);

    DECLARE @NewStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('NewStatus','Status')
        ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 ELSE 2 END);

    DECLARE @PanelTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelType','PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelType' THEN 0 WHEN 'PanelCategory' THEN 1 WHEN 'PanelName' THEN 2
            WHEN 'Panelname' THEN 3 WHEN 'TestPanel' THEN 4 WHEN 'TestPanelName' THEN 5
            WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8
            WHEN 'Test_Panel' THEN 9 WHEN 'TestPanelname' THEN 10 ELSE 11 END);

    DECLARE @BillCategoryCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
        ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BilledorNot' THEN 3 WHEN 'BillStatus' THEN 4 ELSE 5 END);

    DECLARE @SubStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('SubStatus','Sub_Status','ClientStatus','FinalStatus')
        ORDER BY CASE name WHEN 'SubStatus' THEN 0 WHEN 'Sub_Status' THEN 1 WHEN 'ClientStatus' THEN 2 WHEN 'FinalStatus' THEN 3 ELSE 4 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @NewStatusCol IS NULL OR @PanelTypeCol IS NULL OR @BillCategoryCol IS NULL OR @SubStatusCol IS NULL
    BEGIN
        PRINT 'usp_RefreshCove_ExecutiveSummary_LIS_Alt: could not locate Accession/Date/NewStatus/PanelType/BillCategory/SubStatus columns on dbo.LIMSMaster - skipping.';
        RETURN;
    END

    -- ── Build #Lis (real table - must survive past sp_executesql) ───────────
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession    NVARCHAR(100) NOT NULL,
        ESYear       INT           NOT NULL,
        ESMonth      INT           NOT NULL,
        NewStatus    NVARCHAR(200) NOT NULL,
        PanelType    NVARCHAR(200) NOT NULL,
        BillCategory NVARCHAR(200) NOT NULL,
        SubStatus    NVARCHAR(200) NOT NULL
    );

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #Lis (Accession, ESYear, ESMonth, NewStatus, PanelType, BillCategory, SubStatus)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
            YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
            MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @NewStatusCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelTypeCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol + N']), '''')))
        FROM dbo.LIMSMaster
        WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL;';

    EXEC sp_executesql @LisSql;

    -- LIS-specific periods (LIMSMaster date-based) PLUS grand-total sentinel.
    DROP TABLE IF EXISTS #LisPeriods;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
    UNION ALL SELECT 0, 0;

    -- Distinct PanelType values actually present in LIMSMaster - drives the
    -- B.<PanelType> / D.5.<PanelType> / D.6.<PanelType> sub-row breakdowns
    -- dynamically (no fixed/hardcoded panel list).
    DROP TABLE IF EXISTS #PanelTypes;
    SELECT DISTINCT PanelType
    INTO #PanelTypes
    FROM #Lis
    WHERE NULLIF(PanelType, '') IS NOT NULL;

    -- ───────────────────────────────────────────────────────────────────────
    --  Cove_ES_LIS - A, B (+ dynamic PanelType subs per distinct LIMSMaster
    --  PanelType), C, D (+20 subs incl D.5/D.6 dynamic PanelType subs),
    --  E (+7 subs)
    -- ───────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Cove_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- A  Total Samples
        SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
               COUNT(DISTINCT l.Accession) AS ClaimCount
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- B  Billable Samples
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable'
        GROUP BY p.ESYear, p.ESMonth

        -- B.<PanelType>  Billable Samples by Panel - one row per DISTINCT
        -- PanelType found in LIMSMaster (dynamic, not a fixed list)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, N'B.' + pt.PanelType, N'  ' + pt.PanelType,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        CROSS JOIN #PanelTypes pt
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.PanelType = pt.PanelType
        GROUP BY p.ESYear, p.ESMonth, pt.PanelType

        -- C  Billed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C', 'Billed',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        -- D  Not Billed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D', 'Not Billed',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed'
        GROUP BY p.ESYear, p.ESMonth

        -- D.1  Billed Insurance In Covedx
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.1', '  Billed Insurance In Covedx',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Billed Insurance In Covedx'
        GROUP BY p.ESYear, p.ESMonth

        -- D.2  Billed In Variantx Lab
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.2', '  Billed In Variantx Lab',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Billed In Variantx Lab'
        GROUP BY p.ESYear, p.ESMonth

        -- D.3  Billed In Elixir Dx
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.3', '  Billed In Elixir Dx',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Billed In Elixir Dx'
        GROUP BY p.ESYear, p.ESMonth

        -- D.4  Ignored - Duplicate Accession
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.4', '  Ignored - Duplicate Accession',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Ignored - Duplicate Accession'
        GROUP BY p.ESYear, p.ESMonth

        -- D.5  Coding exception
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.5', '  Coding exception',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Coding exception'
        GROUP BY p.ESYear, p.ESMonth

        -- D.5.<PanelType>  Coding exception by Panel - one row per DISTINCT
        -- PanelType found in LIMSMaster (dynamic, not a fixed list)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, N'D.5.' + pt.PanelType, N'    ' + pt.PanelType,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        CROSS JOIN #PanelTypes pt
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Coding exception' AND l.PanelType = pt.PanelType
        GROUP BY p.ESYear, p.ESMonth, pt.PanelType

        -- D.6  CP Exception
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.6', '  CP Exception',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'CP Exception'
        GROUP BY p.ESYear, p.ESMonth

        -- D.6.<PanelType>  CP Exception by Panel - one row per DISTINCT
        -- PanelType found in LIMSMaster (dynamic, not a fixed list)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, N'D.6.' + pt.PanelType, N'    ' + pt.PanelType,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        CROSS JOIN #PanelTypes pt
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'CP Exception' AND l.PanelType = pt.PanelType
        GROUP BY p.ESYear, p.ESMonth, pt.PanelType

        -- D.7  In process
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.7', '  In process',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'In process'
        GROUP BY p.ESYear, p.ESMonth

        -- D.8  Ignored - Client Response Non Billiable
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.8', '  Ignored - Client Response Non Billiable',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Ignored - Client Response Non Billiable'
        GROUP BY p.ESYear, p.ESMonth

        -- D.9  Ready To Bill
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.9', '  Ready To Bill',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Ready To Bill'
        GROUP BY p.ESYear, p.ESMonth

        -- D.10  Ignored - NGS & PGX in Cove
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.10', '  Ignored - NGS & PGX in Cove',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Ignored - NGS & PGX in Cove'
        GROUP BY p.ESYear, p.ESMonth

        -- D.11  CP Exception -In Review
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.11', '  CP Exception -In Review',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'CP Exception -In Review'
        GROUP BY p.ESYear, p.ESMonth

        -- D.12  Medicaid Credentialling In Process
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.12', '  Medicaid Credentialling In Process',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Medicaid Credentialling In Process'
        GROUP BY p.ESYear, p.ESMonth

        -- D.13  Ignored - Reported in Elixir Truemed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.13', '  Ignored - Reported in Elixir Truemed',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Ignored - Reported in Elixir Truemed'
        GROUP BY p.ESYear, p.ESMonth

        -- D.14  Ignored - CP Exception
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.14', '  Ignored - CP Exception',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Ignored - CP Exception'
        GROUP BY p.ESYear, p.ESMonth

        -- D.15  Client Bill Cases
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.15', '  Client Bill Cases',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Client Bill Cases'
        GROUP BY p.ESYear, p.ESMonth

        -- D.16  Ignored - Client Response Pure Selfpay
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.16', '  Ignored - Client Response Pure Selfpay',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Ignored - Client Response Pure Selfpay'
        GROUP BY p.ESYear, p.ESMonth

        -- D.17  Selfpay
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.17', '  Selfpay',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Selfpay'
        GROUP BY p.ESYear, p.ESMonth

        -- D.18  Ignored - Rejected Accession
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.18', '  Ignored - Rejected Accession',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Ignored - Rejected Accession'
        GROUP BY p.ESYear, p.ESMonth

        -- D.19  Hold-Amerihealth Lousiana
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.19', '  Hold-Amerihealth Lousiana',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Hold-Amerihealth Lousiana'
        GROUP BY p.ESYear, p.ESMonth

        -- D.20  Ignored - Test Cases
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.20', '  Ignored - Test Cases',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Ignored - Test Cases'
        GROUP BY p.ESYear, p.ESMonth

        -- E  Other Samples
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E', 'Other Samples',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus <> 'Billable'
        GROUP BY p.ESYear, p.ESMonth

        -- E.1  Self Pay
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.1', '  Self Pay',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        -- E.2  Client Bill
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.2', '  Client Bill',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Client Bill'
        GROUP BY p.ESYear, p.ESMonth

        -- E.3  Deleted / Rejected
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.3', '  Deleted / Rejected',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Deleted / Rejected'
        GROUP BY p.ESYear, p.ESMonth

        -- E.4  System Test
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.4', '  System Test',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'System Test'
        GROUP BY p.ESYear, p.ESMonth

        -- E.5  Ref Lab - Bill Patient
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.5', '  Ref Lab - Bill Patient',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Ref Lab - Bill Patient'
        GROUP BY p.ESYear, p.ESMonth

        -- E.6  Missing Accession
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.6', '  Missing Accession',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Missing Accession'
        GROUP BY p.ESYear, p.ESMonth

        -- E.7  Yet To Be Validated
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.7', '  Yet To Be Validated',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Yet To Be Validated'
        GROUP BY p.ESYear, p.ESMonth
    ) lis;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #LisPeriods;
    DROP TABLE IF EXISTS #PanelTypes;

    PRINT 'usp_RefreshCove_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '19_Cove_ExecutiveSummary_LIS_Alt.sql completed.';
GO
