-- ============================================================
-- Augustus – LIS Breakdown: New Role ID Structure
-- File : 30_Augustus_ExecutiveSummary_LIS_NewStructure.sql
-- DB   : Augustus_LRN
--
-- CHANGES FROM file 19:
--   A   Total Samples        (NEW – count of ALL accessions)
--   B   Billable Samples     (was A = Insurance Bills; BillTo LIKE '%Insurance%')
--     B1.1, B1.2, ...          PanelType sub-rows directly under B (NEW)
--     B2.1                     Billed (was A.1)
--       B2.1.1                   Claim Submitted in IRCM (was A.1.1)
--         B2.1.1.<PanelType>       Panel sub-rows (was A.1.1.<PanelType>)
--       B2.1.2                   Claim Submitted in Daqbilling (was A.1.2)
--         B2.1.2.<PanelType>       Panel sub-rows (was A.1.2.<PanelType>)
--     B2.2                     Unbilled (was A.2)
--       B2.2.1                   Resulted yet to be billed (was A.2.1)
--         B2.2.1*                  Ready to bill (was A.2.1*)
--         B2.2.1.<PanelType>       Panel sub-rows (was A.2.1.<PanelType>)
--       B2.2.2                   Insurance name not listed (was A.2.2)
--   C   Yet to be Validated  (was B)
--     C.1  Billed            (was B.1)
--   D   Client Bills         (was C)
--     D.1  Billed            (was C.1)
--   E   System Test          (was D)
--     E.1  Billed            (was D.1)
--   F   Self pay             (was E)
--     F.1  Billed            (was E.1)
--
-- Also updates usp_GetAug_ExecutiveSummary to ORDER BY RoleID
-- (string sort on the new scheme is correct: A < B < B1.x < B2.x < C < D < E < F).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_RefreshAug_ExecutiveSummary_LIS_Alt]
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.Augustus_ES_LIS;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        PRINT 'usp_RefreshAug_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
        RETURN;
    END

    -- ── Dynamic column detection ─────────────────────────────────────────────
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','Accession','AccessionNo')
        ORDER BY CASE name
            WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('RequestCollectDate','ReqCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'RequestCollectDate' THEN 0 WHEN 'ReqCollectDate' THEN 1
            WHEN 'DateOfCollection' THEN 2 WHEN 'DateofService' THEN 3
            WHEN 'CollectionDate' THEN 4 WHEN 'ServiceDate' THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

    DECLARE @BillToCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillTo','BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
        ORDER BY CASE name
            WHEN 'BillTo' THEN 0 WHEN 'BillCategory' THEN 1 WHEN 'Bill_Category' THEN 2
            WHEN 'BillingCategory' THEN 3 WHEN 'BilledorNot' THEN 4 WHEN 'BillStatus' THEN 5 ELSE 6 END);

    DECLARE @BillingStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillingStatus','NewStatus','Status','BillStatus')
        ORDER BY CASE name
            WHEN 'BillingStatus' THEN 0 WHEN 'NewStatus' THEN 1 WHEN 'Status' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

    DECLARE @FinalStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('FinalStatus','SubStatus','Sub_Status','ClientStatus')
        ORDER BY CASE name
            WHEN 'FinalStatus' THEN 0 WHEN 'SubStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);

    DECLARE @ClientStatus1Col SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClientStatus1','ClientStatus2','ClientFlag')
        ORDER BY CASE name
            WHEN 'ClientStatus1' THEN 0 WHEN 'ClientStatus2' THEN 1 WHEN 'ClientFlag' THEN 2 ELSE 3 END);

    DECLARE @PanelTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelType','PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelType'        THEN 0 WHEN 'PanelCategory'   THEN 1 WHEN 'PanelName'      THEN 2
            WHEN 'Panelname'        THEN 3 WHEN 'TestPanel'        THEN 4 WHEN 'TestPanelName'  THEN 5
            WHEN 'Panel'            THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'       THEN 8
            WHEN 'Test_Panel'       THEN 9 WHEN 'TestPanelname'    THEN 10 ELSE 11 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @BillToCol IS NULL OR @BillingStatusCol IS NULL OR @FinalStatusCol IS NULL
    BEGIN
        PRINT 'usp_RefreshAug_ExecutiveSummary_LIS_Alt: required columns not found on dbo.LIMSMaster - skipping.';
        RETURN;
    END

    -- ── Build #Lis ───────────────────────────────────────────────────────────
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession     NVARCHAR(100) NOT NULL,
        ESYear        INT           NOT NULL,
        ESMonth       INT           NOT NULL,
        BillTo        NVARCHAR(200) NOT NULL,
        BillingStatus NVARCHAR(200) NOT NULL,
        FinalStatus   NVARCHAR(200) NOT NULL,
        ClientStatus1 NVARCHAR(200) NOT NULL,
        PanelType     NVARCHAR(200) NOT NULL
    );

    DECLARE @CS1Expr NVARCHAR(400) = CASE WHEN @ClientStatus1Col IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientStatus1Col + N']), '''')))'
        ELSE N'''''' END;

    DECLARE @PanelExpr NVARCHAR(400) = CASE WHEN @PanelTypeCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelTypeCol + N']), '''')))'
        ELSE N'''''' END;

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #Lis (Accession, ESYear, ESMonth, BillTo, BillingStatus, FinalStatus, ClientStatus1, PanelType)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
            YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
            MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
            ' + @CS1Expr + N',
            ' + @PanelExpr + N'
        FROM dbo.LIMSMaster
        WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL;';
    EXEC sp_executesql @LisSql;

    -- LIS periods + grand-total sentinel
    DROP TABLE IF EXISTS #LisPeriods;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
    UNION ALL SELECT 0, 0;

    -- Distinct PanelType values among Insurance Bills samples.
    -- B1.x sub-rows: one per panel, sorted alphabetically, numbered 1, 2, 3...
    DROP TABLE IF EXISTS #PanelTypes;
    SELECT PanelType,
           CAST(ROW_NUMBER() OVER (ORDER BY PanelType) AS INT) AS PanelSeq
    INTO #PanelTypes
    FROM (
        SELECT DISTINCT PanelType
        FROM #Lis
        WHERE BillTo LIKE '%Insurance%'
          AND NULLIF(PanelType, '') IS NOT NULL
    ) dp;

    -- ────────────────────────────────────────────────────────────────────────
    --  Main LIS rows
    -- ────────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Augustus_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- ── A  Total Samples (ALL accessions, no BillTo filter) ──────────────
        SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
               COUNT(DISTINCT l.Accession) AS ClaimCount
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B  Billable Samples (BillTo = Insurance Bills) ───────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
               COUNT(DISTINCT CASE WHEN l.BillTo LIKE '%Insurance%' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B2.1  Billed (was A.1) ────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B2.1', '  Billed',
               COUNT(DISTINCT CASE WHEN l.BillTo LIKE '%Insurance%' AND l.BillingStatus = 'Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B2.1.1  Claim Submitted in IRCM (was A.1.1) ──────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B2.1.1', '    Claim Submitted in IRCM',
               COUNT(DISTINCT CASE WHEN l.BillTo LIKE '%Insurance%' AND l.BillingStatus = 'Billed'
                                    AND l.FinalStatus = 'Claim Submitted in IRCM' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B2.1.2  Claim Submitted in Daqbilling (was A.1.2) ────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B2.1.2', '    Claim Submitted in Daqbilling',
               COUNT(DISTINCT CASE WHEN l.BillTo LIKE '%Insurance%' AND l.BillingStatus = 'Billed'
                                    AND l.FinalStatus = 'Claim Submitted in Daqbilling' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B2.2  Unbilled (was A.2) ──────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B2.2', '  Unbilled',
               COUNT(DISTINCT CASE WHEN l.BillTo LIKE '%Insurance%' AND l.BillingStatus = 'Unbilled' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B2.2.1  Resulted yet to be billed (was A.2.1) ────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B2.2.1', '    Resulted yet to be billed',
               COUNT(DISTINCT CASE WHEN l.BillTo LIKE '%Insurance%' AND l.BillingStatus = 'Unbilled'
                                    AND l.FinalStatus = 'Resulted yet to be billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B2.2.1*  Ready to bill (was A.2.1*) ──────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B2.2.1*', '      Ready to bill',
               COUNT(DISTINCT CASE WHEN l.BillTo LIKE '%Insurance%' AND l.BillingStatus = 'Unbilled'
                                    AND l.FinalStatus = 'Resulted yet to be billed'
                                    AND l.ClientStatus1 = 'Ready to bill' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B2.2.2  Insurance name not listed (was A.2.2) ─────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B2.2.2', '    Insurance name not listed',
               COUNT(DISTINCT CASE WHEN l.BillTo LIKE '%Insurance%' AND l.BillingStatus = 'Unbilled'
                                    AND l.FinalStatus = 'Insurance Name Not Listed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C  Yet to be Validated (was B) ───────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C', 'Yet to be Validated',
               COUNT(DISTINCT CASE WHEN l.BillTo = 'Yet to be Validated' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C.1  Billed (was B.1) ─────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C.1', '  Billed',
               COUNT(DISTINCT CASE WHEN l.BillTo = 'Yet to be Validated' AND l.BillingStatus = 'Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── D  Client Bills (was C) ───────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D', 'Client Bills',
               COUNT(DISTINCT CASE WHEN l.BillTo = 'Client Bills' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── D.1  Billed (was C.1) ─────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.1', '  Billed',
               COUNT(DISTINCT CASE WHEN l.BillTo = 'Client Bills' AND l.BillingStatus = 'Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── E  System Test (was D) ────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E', 'System Test',
               COUNT(DISTINCT CASE WHEN l.BillTo = 'System Test' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── E.1  Billed (was D.1) ─────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.1', '  Billed',
               COUNT(DISTINCT CASE WHEN l.BillTo = 'System Test' AND l.BillingStatus = 'Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── F  Self pay (was E) ───────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'F', 'Self pay',
               COUNT(DISTINCT CASE WHEN l.BillTo = 'Self pay' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── F.1  Billed (was E.1) ─────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'F.1', '  Billed',
               COUNT(DISTINCT CASE WHEN l.BillTo = 'Self pay' AND l.BillingStatus = 'Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) lis_rows;

    -- ── B1.x  Panel sub-rows directly under B (Billable Samples) ─────────────
    -- RoleID format: 'B1.<seq>' where <seq> is alphabetical order of PanelType.
    -- These appear between B and B2.1 in string sort order: B < B1.x < B2.x.
    INSERT INTO dbo.Augustus_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT
        'B1.' + pt.PanelType,
        '  ' + pt.PanelType,
        p.ESYear,
        p.ESMonth,
        COUNT(DISTINCT CASE WHEN l.BillTo LIKE '%Insurance%' AND l.PanelType = pt.PanelType THEN l.Accession END),
        0,
        GETDATE()
    FROM #PanelTypes pt
    CROSS JOIN #LisPeriods p
    LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
    GROUP BY pt.PanelType, pt.PanelSeq, p.ESYear, p.ESMonth;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #LisPeriods;
    DROP TABLE IF EXISTS #PanelTypes;

    PRINT 'usp_RefreshAug_ExecutiveSummary_LIS_Alt completed (new structure: A=Total Samples, B=Billable Samples).';
END;
GO

PRINT '30_Augustus_ExecutiveSummary_LIS_NewStructure.sql completed.';
GO
