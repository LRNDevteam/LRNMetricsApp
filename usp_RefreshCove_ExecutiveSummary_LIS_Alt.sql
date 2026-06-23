
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

    -- ───────────────────────────────────────────────────────────────────────
    --  Hierarchy:
    --    A   Total Samples
    --    B   Billable Samples
    --      B.<PanelType>  (by panel - label only, RoleID keeps name for B)
    --    C   Billed
    --    D   Not Billed
    --      D.1 … D.20  (fixed subcategories)
    --      D.5         Coding Exception
    --        D.5.1, D.5.2 …  PanelType sub-rows  ← sequential numbering
    --      D.6         CP Exception
    --        D.6.1, D.6.2 …  PanelType sub-rows  ← sequential numbering
    --    E   Other Samples
    --      E.1 … E.7
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

        -- D.5  Coding Exception  (subcategory of D = Not Billed)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.5', '  Coding Exception',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'Coding exception'
        GROUP BY p.ESYear, p.ESMonth

        -- D.5.1, D.5.2 …  Coding Exception by PanelType (sequential)
        -- RoleID  = D.5.{n}   where n = alphabetical rank of PanelType
        -- Description shows the actual panel name, indented under D.5
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'D.5.' + CAST(pt.PanelSeq AS NVARCHAR(10)),
               N'    ' + pt.PanelType,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        CROSS JOIN #PanelTypes pt
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed'
                         AND l.SubStatus = 'Coding exception' AND l.PanelType = pt.PanelType
        GROUP BY p.ESYear, p.ESMonth, pt.PanelType, pt.PanelSeq

        -- D.6  CP Exception
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.6', '  CP Exception',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' AND l.SubStatus = 'CP Exception'
        GROUP BY p.ESYear, p.ESMonth

        -- D.6.1, D.6.2 …  CP Exception by PanelType (sequential)
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'D.6.' + CAST(pt.PanelSeq AS NVARCHAR(10)),
               N'    ' + pt.PanelType,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods p
        CROSS JOIN #PanelTypes pt
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
                         AND l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed'
                         AND l.SubStatus = 'CP Exception' AND l.PanelType = pt.PanelType
        GROUP BY p.ESYear, p.ESMonth, pt.PanelType, pt.PanelSeq

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
