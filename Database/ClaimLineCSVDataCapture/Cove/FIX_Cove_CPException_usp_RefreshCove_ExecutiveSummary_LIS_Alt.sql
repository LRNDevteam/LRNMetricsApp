-- ============================================================
-- Cove — Executive Summary LIS refresh (single SP)
-- File : FIX_Cove_CPException_usp_RefreshCove_ExecutiveSummary_LIS_Alt.sql
-- Date : 2026-09-08
-- DB   : CoveLRN
--
-- Run on CoveLRN:
--   sqlcmd -S <server> -d CoveLRN -E -I -i this file
-- Then:
--   EXEC dbo.usp_RefreshCove_ExecutiveSummary_LIS_Alt;
--
-- CP Exception children = DISTINCT PanelType from LIMSMaster
-- WHERE SubStatus = 'CP Exception'
--   Fungus, GI, PGx, RPP, STI, Tox, Urinalysis, UTI, Women's Health, Wound
-- (not a CROSS JOIN of every PanelType).
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
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

    DROP TABLE IF EXISTS #LisPeriods;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
    UNION ALL SELECT 0, 0;

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

    -- CP Exception children: DISTINCT PanelType WHERE SubStatus = 'CP Exception'
    DROP TABLE IF EXISTS #CpExceptionPanels;
    SELECT pt.PanelType, pt.PanelSeq
    INTO #CpExceptionPanels
    FROM #PanelTypes pt
    WHERE pt.PanelType IN (
        SELECT DISTINCT PanelType
        FROM #Lis
        WHERE SubStatus = N'CP Exception'
          AND NULLIF(PanelType, '') IS NOT NULL
    );

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

    INSERT INTO dbo.Cove_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
               COUNT(DISTINCT l.Accession) AS ClaimCount
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable'
        GROUP BY p.ESYear, p.ESMonth

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

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C', 'Billed',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D', 'Not Billed',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed'
        GROUP BY p.ESYear, p.ESMonth

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

        -- Coding exception by Panel — every distinct LIMSMaster PanelType
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
        WHERE ss.SubStatus = N'Coding exception'
        GROUP BY p.ESYear, p.ESMonth, ss.SubStatus, ss.SubSeq, pt.PanelType, pt.PanelSeq

        -- CP Exception by Panel — DISTINCT PanelType WHERE SubStatus = 'CP Exception'
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'D.' + CAST(ss.SubSeq AS NVARCHAR(10)) + N'.' + CAST(pt.PanelSeq AS NVARCHAR(10)),
               N'    ' + pt.PanelType,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        CROSS JOIN #SubStatuses ss
        CROSS JOIN #CpExceptionPanels pt
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed'
                         AND l.SubStatus = ss.SubStatus AND l.PanelType = pt.PanelType
        WHERE ss.SubStatus = N'CP Exception'
        GROUP BY p.ESYear, p.ESMonth, ss.SubStatus, ss.SubSeq, pt.PanelType, pt.PanelSeq

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E', 'Other Samples',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus <> 'Billable'
        GROUP BY p.ESYear, p.ESMonth

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
    DROP TABLE IF EXISTS #CpExceptionPanels;
    DROP TABLE IF EXISTS #SubStatuses;
    DROP TABLE IF EXISTS #OtherStatuses;
    PRINT 'usp_RefreshCove_ExecutiveSummary_LIS_Alt completed.';
END;
GO
