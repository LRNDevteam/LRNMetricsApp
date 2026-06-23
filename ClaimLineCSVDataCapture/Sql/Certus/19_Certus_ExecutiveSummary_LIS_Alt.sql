-- ============================================================
-- Certus – Executive Summary LIS Refresh SP
-- File : 19_Certus_ExecutiveSummary_LIS_Alt.sql
-- DB   : Certus_LRN
--
-- Mirrors Augustus\19_Augustus_ExecutiveSummary_LIS_Alt.sql.
-- Owns and TRUNCATEs dbo.Certus_ES_LIS.
-- Sources from dbo.LIMSMaster using ReqCollectDate as the date column.
--
-- Certus LIS column mapping:
--   BillTo        -> BillTo / BillCategory / Bill_Category / BilledorNot
--   BillingStatus -> BillingStatus / NewStatus / Status / BillStatus
--   FinalStatus   -> FinalStatus / SubStatus / Sub_Status / ClientStatus
--   PanelName     -> PanelName / Panelname / PanelType / PanelCategory / ...
--   ReqCollectDate -> ReqCollectDate (priority 0) / DateOfCollection / ...
--
-- Row hierarchy:
--   A     Total Samples (all records)
--   B     Billable Samples (BillTo = 'Insurance Bill')
--     B1.<PanelName>  One per DISTINCT PanelName in LIMSMaster where BillTo='Insurance Bill'
--     C     Billed     (BillTo='Insurance Bill', BillingStatus='Billed')
--     D     Unbilled   (BillTo='Insurance Bill', BillingStatus='Not Billed')
--       D.1   Claim Entered in Daqbilling
--       D.2   Resulted yet to be billed
--       D.3   D/L Isomer
--   E     Other Samples (BillTo <> 'Insurance Bill')
--     E.1   Duplicate
--     E.2   Client Bill
--     E.3   Yet to be Validated
--     E.4   Selfpay
--     E.5   Rejection
--     E.6   System Test
-- ============================================================
SET NOCOUNT ON;
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_RefreshCertus_ExecutiveSummary_LIS_Alt]
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.Certus_ES_LIS;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        PRINT 'usp_RefreshCertus_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
        RETURN;
    END

    -- ── Dynamic column detection ─────────────────────────────────────────────
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','Accession','AccessionNo')
        ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

    -- ReqCollectDate is priority 0 for Certus
    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ReqCollectDate','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'ReqCollectDate'      THEN 0 WHEN 'RequestCollectDate' THEN 1
            WHEN 'DateOfCollection'    THEN 2 WHEN 'DateofService'      THEN 3
            WHEN 'CollectionDate'      THEN 4 WHEN 'ServiceDate'        THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

    DECLARE @BillToCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillTo','BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
        ORDER BY CASE name WHEN 'BillTo' THEN 0 WHEN 'BillCategory' THEN 1 WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3 WHEN 'BilledorNot' THEN 4 WHEN 'BillStatus' THEN 5 ELSE 6 END);

    DECLARE @BillingStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillingStatus','NewStatus','Status','BillStatus')
        ORDER BY CASE name WHEN 'BillingStatus' THEN 0 WHEN 'NewStatus' THEN 1 WHEN 'Status' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

    DECLARE @FinalStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('FinalStatus','SubStatus','Sub_Status','ClientStatus')
        ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'SubStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);

    -- PanelName: Certus uses PanelName/Panelname as priority
    DECLARE @PanelNameCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelName','Panelname','PanelType','PanelCategory','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelName'       THEN 0 WHEN 'Panelname'       THEN 1 WHEN 'PanelType'       THEN 2
            WHEN 'PanelCategory'   THEN 3 WHEN 'TestPanel'        THEN 4 WHEN 'TestPanelName'   THEN 5
            WHEN 'Panel'           THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'        THEN 8
            WHEN 'Test_Panel'      THEN 9 WHEN 'TestPanelname'    THEN 10 ELSE 11 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @BillToCol IS NULL OR @BillingStatusCol IS NULL OR @FinalStatusCol IS NULL
    BEGIN
        PRINT 'usp_RefreshCertus_ExecutiveSummary_LIS_Alt: required columns not found on dbo.LIMSMaster - skipping.';
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
        PanelName     NVARCHAR(200) NOT NULL
    );

    DECLARE @PanelExpr NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol + N']), '''')))'
        ELSE N'''''' END;

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #Lis (Accession, ESYear, ESMonth, BillTo, BillingStatus, FinalStatus, PanelName)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
            YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
            MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
            ' + @PanelExpr + N'
        FROM dbo.LIMSMaster
        WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL;';
    EXEC sp_executesql @LisSql;

    -- LIS periods + grand-total sentinel
    DROP TABLE IF EXISTS #LisPeriods;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
    UNION ALL SELECT 0, 0;

    -- Distinct PanelName values present in LIMSMaster (where BillTo='Insurance Bill')
    -- Drives the B1.<PanelName> sub-row breakdowns dynamically.
    DROP TABLE IF EXISTS #PanelNames;
    SELECT DISTINCT PanelName
    INTO #PanelNames
    FROM #Lis
    WHERE NULLIF(PanelName, '') IS NOT NULL
      AND BillTo = 'Insurance Bill';

    -- ────────────────────────────────────────────────────────────────────────
    --  Insert all LIS rows into Certus_ES_LIS
    -- ────────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Certus_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- A  Total Samples
        SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
               COUNT(DISTINCT l.Accession) AS ClaimCount
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- B  Billable Samples (Insurance Bill)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- B1.<PanelName>  Billable Samples by Panel - dynamic
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'B1.' + pn.PanelName,
               N'  ' + pn.PanelName,
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.PanelName=pn.PanelName THEN l.Accession END)
        FROM #LisPeriods p
        CROSS JOIN #PanelNames pn
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, pn.PanelName

        -- C  Billed (sub of B)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C', '  Billed',
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.BillingStatus='Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D  Unbilled (sub of B)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D', '  Unbilled',
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.1  Claim Entered in Daqbilling
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.1', '    Claim Entered in Daqbilling',
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed'
                                   AND l.FinalStatus='Claim Entered in Daqbilling' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.2  Resulted yet to be billed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.2', '    Resulted yet to be billed',
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed'
                                   AND l.FinalStatus='Resulted yet to be billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.3  D/L Isomer
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.3', '    D/L Isomer',
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed'
                                   AND l.FinalStatus='D/L Isomer' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E  Other Samples (not Insurance Bill)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E', 'Other Samples',
               COUNT(DISTINCT CASE WHEN l.BillTo <> 'Insurance Bill' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.1  Duplicate
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.1', '  Duplicate',
               COUNT(DISTINCT CASE WHEN l.BillTo='Duplicate' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.2  Client Bill
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.2', '  Client Bill',
               COUNT(DISTINCT CASE WHEN l.BillTo='Client Bill' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.3  Yet to be Validated
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.3', '  Yet to be Validated',
               COUNT(DISTINCT CASE WHEN l.BillTo='Yet to be Validated' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.4  Selfpay
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.4', '  Selfpay',
               COUNT(DISTINCT CASE WHEN l.BillTo='Selfpay' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.5  Rejection
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.5', '  Rejection',
               COUNT(DISTINCT CASE WHEN l.BillTo='Rejection' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.6  System Test
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.6', '  System Test',
               COUNT(DISTINCT CASE WHEN l.BillTo='System Test' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) lis_rows;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #LisPeriods;
    DROP TABLE IF EXISTS #PanelNames;

    PRINT 'usp_RefreshCertus_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '19_Certus_ExecutiveSummary_LIS_Alt.sql completed.';
GO
