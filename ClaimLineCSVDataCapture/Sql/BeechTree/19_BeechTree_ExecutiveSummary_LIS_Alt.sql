-- ============================================================
-- BeechTree – Executive Summary LIS Aggregate Refresh SP
-- File : 19_BeechTree_ExecutiveSummary_LIS_Alt.sql
-- DB   : BeechTree_LRN
--
-- Mirrors Augustus\30_Augustus_ExecutiveSummary_LIS_NewStructure.sql.
-- This SP owns and TRUNCATEs BeechTree_ES_LIS.
-- Source: dbo.LIMSMaster, period bucket = RequestCollectDate.
--
-- Column auto-detection (LIMSMaster):
--   @AccCol          : AccessionNumber, VisitNumber, OrderID, Accession, AccessionNo
--   @DateCol         : RequestCollectDate (priority 0), ReqCollectDate, DateOfCollection, ...
--   @ResultedCol     : RessultedStatus, ResultedStatus, ResultedNot, Resulted_Not, IsResulted
--   @ClaimStatusCol  : ClaimStatus, ClaimStatusCode
--   @BilledorNotCol  : BilledorNot, BilledStatus, BilledUnbilled, BillOrNot
--   @ClientStatusCol : ClientStatus, ClientStatus1, ClientStatusCode
--   @SampleStatusCol : SampleStatus, Sample_Status, SampleStatusCode
--   @PaymentMethodCol: PaymentMethod, Payment_Method, PayMethod
--   @PanelTypeCol    : PanelType, PanelCategory, PanelName, Panelname, TestPanel, ...
--
-- RoleID hierarchy:
--   A            Total Samples (all accessions)
--   B            Billable Samples - Resulted (RessultedStatus = 'Resulted')
--     B1.<Panel>   Panel sub-rows (dynamic, RoleID = 'B1.' + PanelType)
--     B2           Billed to Insurance (Resulted AND ClaimStatus='Billed' AND BilledorNot='Billed' AND ClientStatus='')
--       B2.1         Billed In AMD (same filter)
--     B3           Not Entered in AMD (Resulted AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled')
--       B3.1         Received (+ SampleStatus='Received' AND ClientStatus IN ('','Billing Review Required'))
--       B3.2         Billing Review Required (+ SampleStatus='Received' AND ClientStatus='Billing Review Required')
--       B3.3         In Transit (+ SampleStatus='In Transit')
--       B3.4         Transferred (+ SampleStatus='Transferred')
--       B3.5         Collected (+ SampleStatus='Collected')
--     B4           Unbilled (Resulted AND ClaimStatus='Entered' AND BilledorNot='UnBilled' AND ClientStatus='')
--     B5           Client Bill (Resulted AND ClientStatus='Client Bill')
--       B5.1         Not Entered in AMD (+ ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled')
--       B5.2         Billed (+ BilledorNot='Billed')
--     B6           Self Pay (Resulted AND ClientStatus='Self Pay')
--       B6.1         Not Entered in AMD
--       B6.2         Billed
--       B6.3         Entered (ClaimStatus='Entered' AND BilledorNot='UnBilled')
--     B7           Test Entries (Resulted AND ClientStatus='Test Entries')
--       B7.1         Not Entered in AMD
--       B7.2         Billed
--     B8           Rejected Sample (Resulted AND ClientStatus='Rejected Sample')
--       B8.1         Not Entered in AMD
--       B8.2         Billed
--     B9           Payment Method No Bill (Resulted AND PaymentMethod='No Bill')
--   C            Not Resulted (RessultedStatus = 'Not Resulted')
--     C1           No Result date on LIS but Billed (Not Resulted AND ClaimStatus='Billed' AND BilledorNot='Billed' AND ClientStatus='')
--     C2           Not Entered in AMD (Not Resulted AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='')
--       C2.1         Received
--       C2.2         In Transit
--       C2.3         Collected
--       C2.4         Transferred
--     C3           Client Bill (Not Resulted AND ClientStatus='Client Bill')
--     C4           Self Pay (Not Resulted AND ClientStatus='Self Pay')
--       C4.1         Not Entered in AMD
--       C4.2         Billed
--   D            Test Entries (Not Resulted AND ClientStatus='Test Entries')
--   E            Rejected Sample (Not Resulted AND ClientStatus='Rejected Sample')
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshBT_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        PRINT 'usp_RefreshBT_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found – skipping LIS refresh.';
        RETURN;
    END

    -- ── Auto-detect columns ──────────────────────────────────────────────────
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','VisitNumber','OrderID','Accession','AccessionNo')
        ORDER BY CASE name
            WHEN 'AccessionNumber' THEN 0 WHEN 'VisitNumber' THEN 1
            WHEN 'OrderID' THEN 2 WHEN 'Accession' THEN 3 WHEN 'AccessionNo' THEN 4 ELSE 5 END);

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('RequestCollectDate','ReqCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'RequestCollectDate' THEN 0 WHEN 'ReqCollectDate' THEN 1
            WHEN 'DateOfCollection'   THEN 2 WHEN 'DateofService'  THEN 3
            WHEN 'CollectionDate'     THEN 4 WHEN 'ServiceDate'    THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

    DECLARE @ResultedCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('RessultedStatus','ResultedStatus','ResultedNot','Resulted_Not','IsResulted','Resulted')
        ORDER BY CASE name
            WHEN 'RessultedStatus' THEN 0 WHEN 'ResultedStatus' THEN 1
            WHEN 'ResultedNot'     THEN 2 WHEN 'Resulted_Not'   THEN 3
            WHEN 'IsResulted'      THEN 4 WHEN 'Resulted'       THEN 5 ELSE 6 END);

    DECLARE @ClaimStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClaimStatus','ClaimStatusCode','BillingClaimStatus')
        ORDER BY CASE name WHEN 'ClaimStatus' THEN 0 WHEN 'ClaimStatusCode' THEN 1 ELSE 2 END);

    DECLARE @BilledorNotCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BilledorNot','BilledStatus','BilledUnbilled','BillOrNot','BilledNotBilled')
        ORDER BY CASE name
            WHEN 'BilledorNot' THEN 0 WHEN 'BilledStatus' THEN 1
            WHEN 'BilledUnbilled' THEN 2 WHEN 'BillOrNot' THEN 3 ELSE 4 END);

    DECLARE @ClientStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClientStatus','ClientStatus1','ClientStatusCode','ClientFlag')
        ORDER BY CASE name
            WHEN 'ClientStatus' THEN 0 WHEN 'ClientStatus1' THEN 1
            WHEN 'ClientStatusCode' THEN 2 ELSE 3 END);

    DECLARE @SampleStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('SampleStatus','Sample_Status','SampleStatusCode','SpecimenStatus')
        ORDER BY CASE name
            WHEN 'SampleStatus' THEN 0 WHEN 'Sample_Status' THEN 1
            WHEN 'SampleStatusCode' THEN 2 ELSE 3 END);

    DECLARE @PaymentMethodCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PaymentMethod','Payment_Method','PayMethod','PayType')
        ORDER BY CASE name WHEN 'PaymentMethod' THEN 0 WHEN 'Payment_Method' THEN 1 ELSE 2 END);

    DECLARE @PanelTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelType','PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','TestName','Test_Panel')
        ORDER BY CASE name
            WHEN 'PanelType'      THEN 0 WHEN 'PanelCategory'  THEN 1 WHEN 'PanelName'     THEN 2
            WHEN 'Panelname'      THEN 3 WHEN 'TestPanel'       THEN 4 WHEN 'TestPanelName' THEN 5
            WHEN 'Panel'          THEN 6 WHEN 'TestName'        THEN 7 WHEN 'Test_Panel'    THEN 8 ELSE 9 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @ResultedCol IS NULL
    BEGIN
        PRINT 'usp_RefreshBT_ExecutiveSummary_LIS_Alt: Required LIMSMaster columns not found (AccCol/DateCol/ResultedCol). Skipping.';
        RETURN;
    END

    -- ── Build #Lis staging table ─────────────────────────────────────────────
    DECLARE @AccExpr          NVARCHAR(300) = N'LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N'])))';
    DECLARE @DateExpr         NVARCHAR(300) = N'TRY_CAST([' + @DateCol + N'] AS DATE)';
    DECLARE @ResultedExpr     NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ResultedCol + N']), '''')))';
    DECLARE @ClaimStatusExpr  NVARCHAR(300) = CASE WHEN @ClaimStatusCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClaimStatusCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @BilledorNotExpr  NVARCHAR(300) = CASE WHEN @BilledorNotCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BilledorNotCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClientStatusExpr NVARCHAR(300) = CASE WHEN @ClientStatusCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientStatusCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @SampleStatusExpr NVARCHAR(300) = CASE WHEN @SampleStatusCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SampleStatusCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @PaymentMethodExpr NVARCHAR(300) = CASE WHEN @PaymentMethodCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PaymentMethodCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @PanelExpr        NVARCHAR(400) = CASE WHEN @PanelTypeCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelTypeCol + N']), '''')))' ELSE N'''''' END;

    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession      NVARCHAR(100) NOT NULL,
        ESYear         INT           NOT NULL,
        ESMonth        INT           NOT NULL,
        Resulted       NVARCHAR(200) NOT NULL,
        ClaimStatus    NVARCHAR(200) NOT NULL,
        BilledorNot    NVARCHAR(200) NOT NULL,
        ClientStatus   NVARCHAR(200) NOT NULL,
        SampleStatus   NVARCHAR(200) NOT NULL,
        PaymentMethod  NVARCHAR(200) NOT NULL,
        PanelType      NVARCHAR(200) NOT NULL
    );

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #Lis
            (Accession, ESYear, ESMonth, Resulted, ClaimStatus, BilledorNot, ClientStatus, SampleStatus, PaymentMethod, PanelType)
        SELECT
            ' + @AccExpr          + N',
            YEAR (' + @DateExpr   + N'),
            MONTH(' + @DateExpr   + N'),
            ' + @ResultedExpr     + N',
            ' + @ClaimStatusExpr  + N',
            ' + @BilledorNotExpr  + N',
            ' + @ClientStatusExpr + N',
            ' + @SampleStatusExpr + N',
            ' + @PaymentMethodExpr + N',
            ' + @PanelExpr        + N'
        FROM dbo.LIMSMaster
        WHERE ' + @DateExpr + N' IS NOT NULL
          AND NULLIF(' + @AccExpr + N', '''') IS NOT NULL;';

    EXEC sp_executesql @LisSql;

    -- ── #LisPeriods : distinct (ESYear,ESMonth) + (0,0) grand-total sentinel ─
    DROP TABLE IF EXISTS #LisPeriods;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
    UNION ALL SELECT 0, 0;

    -- ── #PanelTypes : distinct panel names for B1.x sub-rows ─────────────────
    DROP TABLE IF EXISTS #PanelTypes;
    SELECT
        PanelType,
        ROW_NUMBER() OVER (ORDER BY PanelType) AS PanelSeq
    INTO #PanelTypes
    FROM (SELECT DISTINCT PanelType FROM #Lis WHERE Resulted = 'Resulted' AND PanelType <> '') pt;

    -- ── TRUNCATE and repopulate ───────────────────────────────────────────────
    TRUNCATE TABLE dbo.BeechTree_ES_LIS;

    INSERT INTO dbo.BeechTree_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- ── A: Total Samples (all accessions) ────────────────────────────────
        SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
               COUNT(DISTINCT CASE WHEN (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth)) THEN l.Accession END) AS ClaimCount
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B: Billable Samples – Resulted ───────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples - Resulted',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B2: Billed to Insurance ───────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B2', '  Billed to Insurance',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClaimStatus='Billed'
                                    AND l.BilledorNot='Billed' AND l.ClientStatus='' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B2.1: Billed In AMD ───────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B2.1', '    Billed In AMD',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClaimStatus='Billed'
                                    AND l.BilledorNot='Billed' AND l.ClientStatus='' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B3: Not Entered in AMD ────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B3', '  Not Entered in AMD',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled'
                                    AND l.ClientStatus IN ('','Billing Review Required') THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B3.1: Received ────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B3.1', '    Received',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled'
                                    AND l.ClientStatus IN ('','Billing Review Required')
                                    AND l.SampleStatus='Received' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B3.2: Billing Review Required ────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B3.2', '    Billing Review Required',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled'
                                    AND l.SampleStatus='Received'
                                    AND l.ClientStatus='Billing Review Required' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B3.3: In Transit ─────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B3.3', '    In Transit',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled'
                                    AND l.ClientStatus IN ('','Billing Review Required')
                                    AND l.SampleStatus='In Transit' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B3.4: Transferred ────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B3.4', '    Transferred',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled'
                                    AND l.ClientStatus IN ('','Billing Review Required')
                                    AND l.SampleStatus='Transferred' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B3.5: Collected ──────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B3.5', '    Collected',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled'
                                    AND l.ClientStatus IN ('','Billing Review Required')
                                    AND l.SampleStatus='Collected' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B4: Unbilled ─────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B4', '  Unbilled',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClaimStatus='Entered'
                                    AND l.BilledorNot='UnBilled' AND l.ClientStatus='' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B5: Client Bill ───────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B5', '  Client Bill',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Client Bill' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B5.1: Not Entered in AMD ──────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B5.1', '    Not Entered in AMD',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Client Bill'
                                    AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B5.2: Billed ──────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B5.2', '    Billed',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Client Bill'
                                    AND l.BilledorNot='Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B6: Self Pay ──────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B6', '  Self Pay',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Self Pay' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B6.1: Not Entered in AMD ──────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B6.1', '    Not Entered in AMD',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Self Pay'
                                    AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B6.2: Billed ──────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B6.2', '    Billed',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Self Pay'
                                    AND l.BilledorNot='Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B6.3: Entered ─────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B6.3', '    Entered',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Self Pay'
                                    AND l.ClaimStatus='Entered' AND l.BilledorNot='UnBilled' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B7: Test Entries ─────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B7', '  Test Entries',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Test Entries' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B7.1: Not Entered in AMD ──────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B7.1', '    Not Entered in AMD',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Test Entries'
                                    AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B7.2: Billed ──────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B7.2', '    Billed',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Test Entries'
                                    AND l.BilledorNot='Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B8: Rejected Sample ───────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B8', '  Rejected Sample',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Rejected Sample' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B8.1: Not Entered in AMD ──────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B8.1', '    Not Entered in AMD',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Rejected Sample'
                                    AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B8.2: Billed ──────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B8.2', '    Billed',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.ClientStatus='Rejected Sample'
                                    AND l.BilledorNot='Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── B9: Payment Method No Bill ────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B9', '  Payment Method No Bill',
               COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.PaymentMethod='No Bill' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C: Not Resulted ───────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C', 'Not Resulted',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C1: No Result date on LIS but Billed ─────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C1', '  No Result date on LIS but Billed',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClaimStatus='Billed'
                                    AND l.BilledorNot='Billed' AND l.ClientStatus='' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C2: Not Entered in AMD ────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C2', '  Not Entered in AMD',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled' AND l.ClientStatus='' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C2.1: Received ────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C2.1', '    Received',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled' AND l.ClientStatus=''
                                    AND l.SampleStatus='Received' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C2.2: In Transit ──────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C2.2', '    In Transit',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled' AND l.ClientStatus=''
                                    AND l.SampleStatus='In Transit' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C2.3: Collected ───────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C2.3', '    Collected',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled' AND l.ClientStatus=''
                                    AND l.SampleStatus='Collected' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C2.4: Transferred ─────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C2.4', '    Transferred',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD'
                                    AND l.BilledorNot='UnBilled' AND l.ClientStatus=''
                                    AND l.SampleStatus='Transferred' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C3: Client Bill ───────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C3', '  Client Bill',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClientStatus='Client Bill' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C4: Self Pay ──────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C4', '  Self Pay',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClientStatus='Self Pay' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C4.1: Not Entered in AMD ──────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C4.1', '    Not Entered in AMD',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClientStatus='Self Pay'
                                    AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── C4.2: Billed ──────────────────────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C4.2', '    Billed',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClientStatus='Self Pay'
                                    AND l.BilledorNot='Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── D: Test Entries (Not Resulted) ────────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D', 'Test Entries',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClientStatus='Test Entries' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- ── E: Rejected Sample (Not Resulted) ─────────────────────────────────
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E', 'Rejected Sample',
               COUNT(DISTINCT CASE WHEN l.Resulted='Not Resulted' AND l.ClientStatus='Rejected Sample' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) lis_rows;

    -- ── B1.<PanelType>: Panel sub-rows directly under B ──────────────────────
    -- RoleID = 'B1.' + PanelType  (sorts between B and B2 in string order)
    INSERT INTO dbo.BeechTree_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT
        'B1.' + pt.PanelType,
        '  ' + pt.PanelType,
        p.ESYear,
        p.ESMonth,
        COUNT(DISTINCT CASE WHEN l.Resulted='Resulted' AND l.PanelType=pt.PanelType THEN l.Accession END),
        0,
        GETDATE()
    FROM #PanelTypes pt
    CROSS JOIN #LisPeriods p
    LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
    GROUP BY pt.PanelType, pt.PanelSeq, p.ESYear, p.ESMonth;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #LisPeriods;
    DROP TABLE IF EXISTS #PanelTypes;

    PRINT 'usp_RefreshBT_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '19_BeechTree_ExecutiveSummary_LIS_Alt.sql completed.';
GO
