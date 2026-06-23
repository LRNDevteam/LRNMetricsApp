-- ============================================================
-- Inhealth – Executive Summary LIS Refresh SP
-- File : 26_Inhealth_ExecutiveSummary_LIS_Alt.sql
-- DB   : Inhealth_LRN
--
-- Mirrors Augustus\19_Augustus_ExecutiveSummary_LIS_Alt.sql.
-- Owns and TRUNCATEs dbo.Inhealth_ES_LIS.
-- Sources from dbo.LIMSMaster using ReqCollectDate as the date column.
--
-- Inhealth LIMSMaster column mapping (dynamic detection, priority order):
--   OrderID       -> OrderID, OrderId, AccessionNumber, Accession, AccessionNo
--   NA            -> NA, IsNA, NotApplicable, NA_Flag, NAStatus
--   SampleStatus  -> SampleStatus, BillTo, Sample_Status, SampleType
--   BillCategory  -> BillCategory, BillingStatus, Bill_Category, BillingCategory
--   SubStatus     -> SubStatus, FinalStatus, Sub_Status, ClientStatus
--   LRNPanelName  -> LRNPanelName, LRN_PanelName, LRNPanel, PanelName, PanelType, ...
--   ReqCollectDate -> ReqCollectDate (priority 0), RequestCollectDate, DateOfCollection, ...
--
-- Row hierarchy:
--   A    Total Samples          (NA is not blank)
--   B    Billable Samples       (NA=blank AND SampleStatus='Billable')
--     B1.{LRNPanelName}         (one per DISTINCT LRNPanelName in Billable rows)
--   C    Billed                 (Billable AND BillCategory='Billed')
--     C.1  Billed Via AMD       (+ SubStatus='Billed Via AMD')
--   D    Unbilled               (Billable AND BillCategory='Not Billed')
--     D.1  Nexum_Claim_scrubber_Eligibility
--     D.2  Requires Review
--     D.3  Entered in AMD but not billed
--     D.4  Nexum Pre Processing Queue
--     D.5  Nexum_Claim_scrubber_AMD Output
--     D.6  Nexum_Claim_scrubber_Diagnosis Validity
--   E    Other Samples          (NA=blank AND SampleStatus='Other Samples')
--     E.1  Billed               (BillCategory='Billed')
--     E.2  Unbilled             (BillCategory='Not Billed')
--     E.3  Other Samples (LIS Table provides Breakdown) - label row
--     E.4  Self Pay             (SampleStatus='Self Pay')
--     E.5  Deleted/Rejected     (SampleStatus='Deleted/Rejected')
--     E.6  Duplicate            (SampleStatus='Duplicate')
--     E.7  System Test          (SampleStatus='System Test')
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshInh_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.Inhealth_ES_LIS;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        PRINT 'usp_RefreshInh_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
        RETURN;
    END

    -- ── Dynamic column detection ─────────────────────────────────────────────
    DECLARE @OrderIDCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('OrderID','OrderId','AccessionNumber','Accession','AccessionNo')
        ORDER BY CASE name WHEN 'OrderID' THEN 0 WHEN 'OrderId' THEN 1
                           WHEN 'AccessionNumber' THEN 2 WHEN 'Accession' THEN 3 WHEN 'AccessionNo' THEN 4 ELSE 5 END);

    DECLARE @NACol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('NA','IsNA','NotApplicable','NA_Flag','NAStatus')
        ORDER BY CASE name WHEN 'NA' THEN 0 WHEN 'IsNA' THEN 1 WHEN 'NotApplicable' THEN 2
                           WHEN 'NA_Flag' THEN 3 WHEN 'NAStatus' THEN 4 ELSE 5 END);

    -- ReqCollectDate is priority 0 for Inhealth
    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ReqCollectDate','Entry_DateCreated','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'ReqCollectDate' THEN 0 WHEN 'Entry_DateCreated' THEN 1 WHEN 'RequestCollectDate' THEN 2
            WHEN 'DateOfCollection' THEN 3 WHEN 'DateofService' THEN 4
            WHEN 'CollectionDate' THEN 5 WHEN 'ServiceDate' THEN 6 WHEN 'AccessionDate' THEN 7 ELSE 8 END);

    DECLARE @SampleStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('SampleStatus','BillTo','Sample_Status','SampleType')
        ORDER BY CASE name WHEN 'SampleStatus' THEN 0 WHEN 'BillTo' THEN 1 WHEN 'Sample_Status' THEN 2 WHEN 'SampleType' THEN 3 ELSE 4 END);

    DECLARE @BillCategoryCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillCategory','BillingStatus','Bill_Category','BillingCategory','BillStatus')
        ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'BillingStatus' THEN 1 WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3 WHEN 'BillStatus' THEN 4 ELSE 5 END);

    DECLARE @SubStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('SubStatus','FinalStatus','Sub_Status','ClientStatus')
        ORDER BY CASE name WHEN 'SubStatus' THEN 0 WHEN 'FinalStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);

    DECLARE @PanelNameCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('LRNPanelName','LRN_PanelName','LRNPanel','PanelName','Panelname','PanelType','PanelCategory','TestPanel','TestPanelName')
        ORDER BY CASE name
            WHEN 'LRNPanelName'  THEN 0 WHEN 'LRN_PanelName' THEN 1 WHEN 'LRNPanel'      THEN 2
            WHEN 'PanelName'     THEN 3 WHEN 'Panelname'     THEN 4 WHEN 'PanelType'     THEN 5
            WHEN 'PanelCategory' THEN 6 WHEN 'TestPanel'     THEN 7 WHEN 'TestPanelName' THEN 8 ELSE 9 END);

    IF @OrderIDCol IS NULL OR @DateCol IS NULL OR @SampleStatusCol IS NULL
       OR @BillCategoryCol IS NULL OR @SubStatusCol IS NULL
    BEGIN
        PRINT 'usp_RefreshInh_ExecutiveSummary_LIS_Alt: required columns not found on dbo.LIMSMaster - skipping.';
        RETURN;
    END

    -- ── Build #Lis ───────────────────────────────────────────────────────────
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        OrderID       NVARCHAR(100) NOT NULL,
        ESYear        INT           NOT NULL,
        ESMonth       INT           NOT NULL,
        NAFlag        NVARCHAR(50)  NOT NULL,
        SampleStatus  NVARCHAR(200) NOT NULL,
        BillCategory  NVARCHAR(200) NOT NULL,
        SubStatus     NVARCHAR(200) NOT NULL,
        LRNPanelName  NVARCHAR(200) NOT NULL
    );

    DECLARE @NAExpr    NVARCHAR(300) = CASE WHEN @NACol IS NOT NULL
        THEN N'ISNULL(CONVERT(NVARCHAR(50), [' + @NACol + N']), '''')'
        ELSE N'''''' END;
    DECLARE @PanelExpr NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol + N']), '''')))'
        ELSE N'''''' END;

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #Lis (OrderID, ESYear, ESMonth, NAFlag, SampleStatus, BillCategory, SubStatus, LRNPanelName)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @OrderIDCol + N']))),
            YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
            MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)),
            ' + @NAExpr + N',
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SampleStatusCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol    + N']), ''''))),
            ' + @PanelExpr + N'
        FROM dbo.LIMSMaster
        WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @OrderIDCol + N']))), '''') IS NOT NULL;';
    EXEC sp_executesql @LisSql;

    -- LIS periods + grand-total sentinel
    DROP TABLE IF EXISTS #LisPeriods;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
    UNION ALL SELECT 0, 0;

    -- Distinct LRNPanelName values for Billable rows - drives B1.{PanelName} sub-rows
    DROP TABLE IF EXISTS #PanelNames;
    SELECT DISTINCT LRNPanelName
    INTO #PanelNames
    FROM #Lis
    WHERE NULLIF(LRNPanelName, '') IS NOT NULL
      AND ISNULL(NAFlag,'') = ''
      AND SampleStatus = 'Billable';

    -- ────────────────────────────────────────────────────────────────────────
    --  Insert all LIS rows into Inhealth_ES_LIS
    -- ────────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Inhealth_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- A  Total Samples (NA not blank)
        SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
               COUNT(DISTINCT CASE WHEN NULLIF(l.NAFlag,'') IS NOT NULL THEN l.OrderID END) AS ClaimCount
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- B  Billable Samples (NA=blank AND SampleStatus='Billable')
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- B1.{LRNPanelName}  Billable by Panel - dynamic
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'B1.' + pn.LRNPanelName,
               N'    ' + pn.LRNPanelName,
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                   AND l.LRNPanelName = pn.LRNPanelName THEN l.OrderID END)
        FROM #LisPeriods p
        CROSS JOIN #PanelNames pn
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, pn.LRNPanelName

        -- C  Billed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C', '  Billed',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Billed' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- C.1  Billed Via AMD
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C.1', '    Billed Via AMD',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                   AND l.BillCategory='Billed' AND l.SubStatus='Billed Via AMD' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D  Unbilled
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D', '  Unbilled',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.1  Nexum_Claim_scrubber_Eligibility
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.1', '    Nexum_Claim_scrubber_Eligibility',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                   AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum_Claim_scrubber_Eligibility' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.2  Requires Review
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.2', '    Requires Review',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                   AND l.BillCategory='Not Billed' AND l.SubStatus='Requires Review' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.3  Entered in AMD but not billed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.3', '    Entered in AMD but not billed',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                   AND l.BillCategory='Not Billed' AND l.SubStatus='Entered in AMD but not billed' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.4  Nexum Pre Processing Queue
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.4', '    Nexum Pre Processing Queue',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                   AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum Pre Processing Queue' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.5  Nexum_Claim_scrubber_AMD Output
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.5', '    Nexum_Claim_scrubber_AMD Output',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                   AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum_Claim_scrubber_AMD Output' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.6  Nexum_Claim_scrubber_Diagnosis Validity
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.6', '    Nexum_Claim_scrubber_Diagnosis Validity',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                   AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum_Claim_scrubber_Diagnosis Validity' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E  Other Samples
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E', 'Other Samples',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.1  Billed (Other Samples + BillCategory=Billed)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.1', '  Billed',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples' AND l.BillCategory='Billed' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.2  Unbilled (Other Samples + BillCategory=Not Billed)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.2', '  Unbilled',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples' AND l.BillCategory='Not Billed' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.3  Other Samples (LIS Table provides Breakdown) - label row, count = 0
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.3', '  Other Samples (LIS Table provides Breakdown)', 0
        FROM #LisPeriods p
        GROUP BY p.ESYear, p.ESMonth

        -- E.4  Self Pay
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.4', '  Self Pay',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Self Pay' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.5  Deleted/Rejected
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.5', '  Deleted/Rejected',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Deleted/Rejected' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.6  Duplicate
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.6', '  Duplicate',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Duplicate' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.7  System Test
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.7', '  System Test',
               COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='System Test' THEN l.OrderID END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) lis_rows;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #LisPeriods;
    DROP TABLE IF EXISTS #PanelNames;

    PRINT 'usp_RefreshInh_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '26_Inhealth_ExecutiveSummary_LIS_Alt.sql completed.';
GO
