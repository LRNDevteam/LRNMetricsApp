
/****** Object:  StoredProcedure [dbo].[usp_RefreshCove_ExecutiveSummary_LIS_Alt]    Script Date: 6/19/2026 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   PROCEDURE [dbo].[usp_RefreshCove_ExecutiveSummary_LIS_Alt]
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

    -- ── Build #Lis ───────────────────────────────────────────────────────────
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

    -- LIS periods + grand-total sentinel
    DROP TABLE IF EXISTS #LisPeriods;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
    UNION ALL SELECT 0, 0;

    -- ── #PanelTypes: distinct PanelType values with stable sequential number ─
    -- PanelSeq drives D.5.1 / D.5.2 ... and D.6.1 / D.6.2 ... RoleIDs.
    -- Ordered alphabetically so the numbering is deterministic across runs.
    DROP TABLE IF EXISTS #PanelTypes;
    SELECT
        PanelType,
        ROW_NUMBER() OVER (ORDER BY PanelType) AS PanelSeq
    INTO #PanelTypes
    FROM (
        SELECT DISTINCT PanelType
        FROM #Lis
        WHERE NULLIF(PanelType, '') IS NOT NULL
    ) src;

    -- ── #SubStatuses: distinct SubStatus values under D (Not Billed) ─────────
    -- SubSeq drives D.1 / D.2 … RoleIDs (replaces the old hardcoded D.1–D.20).
    -- Ordered alphabetically so the numbering is deterministic across runs.
    -- IsException flags the two SubStatuses that also get a per-panel breakdown
    -- (D.{n}.1, D.{n}.2 …): 'Coding exception' and 'CP Exception'.
    DROP TABLE IF EXISTS #SubStatuses;
    SELECT
        SubStatus,
        ROW_NUMBER() OVER (ORDER BY SubStatus) AS SubSeq,
        CASE WHEN SubStatus IN ('Coding exception', 'CP Exception') THEN 1 ELSE 0 END AS IsException
    INTO #SubStatuses
    FROM (
        SELECT DISTINCT SubStatus
        FROM #Lis
        WHERE NewStatus = 'Billable'
          AND BillCategory = 'Not Billed'
          AND NULLIF(SubStatus, '') IS NOT NULL
    ) src;

    -- ── #OtherStatuses: distinct NewStatus values under E (Other Samples) ────
    -- OtherSeq drives E.1 / E.2 … RoleIDs (replaces the old hardcoded E.1–E.7).
    -- Everything that is NOT 'Billable' (NewStatus <> 'Billable'), numbered
    -- alphabetically so the numbering is deterministic across runs.
    DROP TABLE IF EXISTS #OtherStatuses;
    SELECT
        NewStatus,
        ROW_NUMBER() OVER (ORDER BY NewStatus) AS OtherSeq
    INTO #OtherStatuses
    FROM (
        SELECT DISTINCT NewStatus
        FROM #Lis
        WHERE NewStatus <> 'Billable'
          AND NULLIF(NewStatus, '') IS NOT NULL
    ) src;

    -- ───────────────────────────────────────────────────────────────────────
    --  Hierarchy:
    --    A   Total Samples
    --    B   Billable Samples
    --      B.<PanelType>  (by panel - label only, RoleID keeps name for B)
    --    C   Billed
    --    D   Not Billed
    --      D.1 … D.{n}  (one row per distinct SubStatus, alphabetical = SubSeq)
    --      For SubStatus 'Coding exception' and 'CP Exception' (IsException=1):
    --        D.{n}.1, D.{n}.2 …  PanelType sub-rows  ← sequential PanelSeq
    --    E   Other Samples  (NewStatus <> 'Billable')
    --      E.1 … E.{n}  (one row per distinct NewStatus, alphabetical = OtherSeq)
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

        -- B.<PanelType>  Billable Samples by Panel (name-keyed, no change)
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'B.' + pt.PanelType,
               N'  ' + pt.PanelType,
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

        -- D.1, D.2 …  Not Billed by SubStatus (dynamic, one row per SubStatus)
        -- RoleID = D.{SubSeq}, SubSeq = alphabetical rank of the SubStatus value.
        -- Description shows the actual SubStatus, indented under D.
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'D.' + CAST(ss.SubSeq AS NVARCHAR(10)),
               N'  ' + ss.SubStatus,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        CROSS JOIN #SubStatuses ss
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed'
                         AND l.SubStatus = ss.SubStatus
        GROUP BY p.ESYear, p.ESMonth, ss.SubStatus, ss.SubSeq

        -- D.{n}.1, D.{n}.2 …  PanelType breakdown for exception SubStatuses only
        -- (IsException = 1 → 'Coding exception' and 'CP Exception')
        -- RoleID = D.{SubSeq}.{PanelSeq}; Description shows the panel name.
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'D.' + CAST(ss.SubSeq AS NVARCHAR(10)) + N'.' + CAST(pt.PanelSeq AS NVARCHAR(10)),
               N'    ' + pt.PanelType,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        CROSS JOIN #SubStatuses ss
        CROSS JOIN #PanelTypes pt
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed'
                         AND l.SubStatus = ss.SubStatus AND l.PanelType = pt.PanelType
        WHERE ss.IsException = 1
        GROUP BY p.ESYear, p.ESMonth, ss.SubStatus, ss.SubSeq, pt.PanelType, pt.PanelSeq

        -- E  Other Samples
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E', 'Other Samples',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus <> 'Billable'
        GROUP BY p.ESYear, p.ESMonth

        -- E.1, E.2 …  Other Samples by NewStatus (dynamic, one row per NewStatus)
        -- RoleID = E.{OtherSeq}, OtherSeq = alphabetical rank of the NewStatus value.
        -- Description shows the actual NewStatus, indented under E.
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'E.' + CAST(os.OtherSeq AS NVARCHAR(10)),
               N'  ' + os.NewStatus,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        CROSS JOIN #OtherStatuses os
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = os.NewStatus
        GROUP BY p.ESYear, p.ESMonth, os.NewStatus, os.OtherSeq
    ) lis;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #LisPeriods;
    DROP TABLE IF EXISTS #PanelTypes;
    DROP TABLE IF EXISTS #SubStatuses;
    DROP TABLE IF EXISTS #OtherStatuses;
    PRINT 'usp_RefreshCove_ExecutiveSummary_LIS_Alt completed.';
END;
