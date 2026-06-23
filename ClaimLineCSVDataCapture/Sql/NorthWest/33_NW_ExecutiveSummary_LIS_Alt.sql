-- ============================================================
-- NorthWest – LIS Aggregate SP (populates NW_ES_LIS)
-- File : 33_NW_ExecutiveSummary_LIS_Alt.sql
-- DB   : NorthWest_LRN
--
-- usp_RefreshNW_ExecutiveSummary_LIS_Alt
--   Single-pass aggregation into #Counts, then bulk insert.
--   Avoids 25+ repeated scans of LIMSMaster.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;

    -- ════════════════════════════════════════════════════════════════════
    --  Dynamic column detection – LIMSMaster
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @OrderIDCol  SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('OrderID','OrderId','AccessionNumber','Accession')
        ORDER BY CASE name WHEN 'OrderID' THEN 0 WHEN 'OrderId' THEN 1 WHEN 'AccessionNumber' THEN 2 ELSE 3 END);
    DECLARE @DateCol     SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('ReqCollectDate','Entry_DateCreated','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name WHEN 'ReqCollectDate' THEN 0 WHEN 'Entry_DateCreated' THEN 1 WHEN 'RequestCollectDate' THEN 2
            WHEN 'DateOfCollection' THEN 3 WHEN 'DateofService' THEN 4 WHEN 'CollectionDate' THEN 5
            WHEN 'ServiceDate' THEN 6 WHEN 'AccessionDate' THEN 7 ELSE 8 END);
    DECLARE @IncorrectDOSCol  SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('IncorrectDOS','IncorrectDos','Incorrect_DOS','BadDOS')
        ORDER BY CASE name WHEN 'IncorrectDOS' THEN 0 WHEN 'IncorrectDos' THEN 1 WHEN 'Incorrect_DOS' THEN 2 ELSE 3 END);
    DECLARE @BilledToCol      SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('BilledTo','BillTo','Billed_To')
        ORDER BY CASE name WHEN 'BilledTo' THEN 0 WHEN 'BillTo' THEN 1 ELSE 2 END);
    DECLARE @BillStatusCol    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('BillStatus','BillingStatus','Bill_Status')
        ORDER BY CASE name WHEN 'BillStatus' THEN 0 WHEN 'BillingStatus' THEN 1 ELSE 2 END);
    DECLARE @FinalStatusCol   SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('FinalStatus','Final_Status','SubStatus','Status')
        ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'Final_Status' THEN 1 WHEN 'SubStatus' THEN 2 ELSE 3 END);
    DECLARE @SourceCol        SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('Source','ClaimSource','System_Source')
        ORDER BY CASE name WHEN 'Source' THEN 0 WHEN 'ClaimSource' THEN 1 ELSE 2 END);
    DECLARE @ChargesNotCol    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('ChargesNotEnteredStatus','ChargesNotEntered','NotEnteredStatus')
        ORDER BY CASE name WHEN 'ChargesNotEnteredStatus' THEN 0 WHEN 'ChargesNotEntered' THEN 1 ELSE 2 END);
    DECLARE @PanelNameCol     SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('LRNPanelName','PanelName','Panelname','PanelType','Panel','TestPanel')
        ORDER BY CASE name WHEN 'LRNPanelName' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2
            WHEN 'PanelType' THEN 3 WHEN 'Panel' THEN 4 ELSE 5 END);

    -- Required columns guard
    IF @OrderIDCol IS NULL OR @DateCol IS NULL OR @IncorrectDOSCol IS NULL OR @BilledToCol IS NULL
    BEGIN
        RAISERROR('LIMSMaster is missing required columns (OrderID, DateCol, IncorrectDOS, or BilledTo). Cannot refresh NW LIS.',16,1);
        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  Build #LisBase – ONE scan of LIMSMaster
    -- ════════════════════════════════════════════════════════════════════
    DROP TABLE IF EXISTS #LisBase;
    CREATE TABLE #LisBase
    (
        OrderID                 NVARCHAR(100) NOT NULL,
        ESYear                  INT           NOT NULL,
        ESMonth                 INT           NOT NULL,
        IncorrectDOS            NVARCHAR(50)  NOT NULL,
        BilledTo                NVARCHAR(200) NOT NULL,
        BillStatus              NVARCHAR(100) NOT NULL,
        FinalStatus             NVARCHAR(200) NOT NULL,
        Source                  NVARCHAR(100) NOT NULL,
        ChargesNotEnteredStatus NVARCHAR(200) NOT NULL,
        PanelName               NVARCHAR(200) NOT NULL
    );

    DECLARE @BsExpr  NVARCHAR(300) = CASE WHEN @BillStatusCol IS NOT NULL  THEN N'ISNULL(LTRIM(RTRIM([' + @BillStatusCol  + N'])),'''')' ELSE N'''''' END;
    DECLARE @FsExpr  NVARCHAR(300) = CASE WHEN @FinalStatusCol IS NOT NULL  THEN N'ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')' ELSE N'''''' END;
    DECLARE @SrcExpr NVARCHAR(300) = CASE WHEN @SourceCol IS NOT NULL       THEN N'ISNULL(LTRIM(RTRIM([' + @SourceCol     + N'])),'''')' ELSE N'''''' END;
    DECLARE @CnsExpr NVARCHAR(300) = CASE WHEN @ChargesNotCol IS NOT NULL   THEN N'ISNULL(LTRIM(RTRIM([' + @ChargesNotCol + N'])),'''')' ELSE N'''''' END;
    DECLARE @PnExpr  NVARCHAR(300) = CASE WHEN @PanelNameCol IS NOT NULL    THEN N'ISNULL(LTRIM(RTRIM([' + @PanelNameCol  + N'])),'''')' ELSE N'''''' END;

    DECLARE @BaseSql NVARCHAR(MAX) = N'
        INSERT INTO #LisBase
        SELECT
            LTRIM(RTRIM(ISNULL([' + @OrderIDCol + N'],''''))),
            YEAR(TRY_CAST([' + @DateCol + N'] AS DATE)),
            MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)),
            ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),''''),
            ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),''''),
            ' + @BsExpr + N',
            ' + @FsExpr + N',
            ' + @SrcExpr + N',
            ' + @CnsExpr + N',
            ' + @PnExpr + N'
        FROM dbo.LIMSMaster
        WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(ISNULL([' + @OrderIDCol + N'],''''))),'''') IS NOT NULL;';
    EXEC sp_executesql @BaseSql;

    -- Index #LisBase so aggregations are fast
    CREATE NONCLUSTERED INDEX IX_LisBase_Period
        ON #LisBase (ESYear, ESMonth)
        INCLUDE (OrderID, IncorrectDOS, BilledTo, BillStatus, FinalStatus, Source, ChargesNotEnteredStatus, PanelName);

    -- ════════════════════════════════════════════════════════════════════
    --  Single-pass aggregation: all fixed rows in ONE GROUP BY
    --  Each period produces one row in #Counts with all counts as columns.
    --  Grand total (ESYear=0, ESMonth=0) added via UNION ALL.
    -- ════════════════════════════════════════════════════════════════════
    DROP TABLE IF EXISTS #Counts;
    SELECT
        ESYear, ESMonth,
        -- Row A
        COUNT(DISTINCT CASE WHEN IncorrectDOS=''                                                                                                           THEN OrderID END) AS cnt_A,
        -- Row B
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill'                                                                             THEN OrderID END) AS cnt_B,
        -- Row C and sub-rows
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed'                                                     THEN OrderID END) AS cnt_C,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Claim Submitted in Webpm'          THEN OrderID END) AS cnt_C1,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Claim Submitted in Daqbilling'     THEN OrderID END) AS cnt_C2,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Claim Submitted in Daq & Webpm'    THEN OrderID END) AS cnt_C3,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Non Billable - Excluded Organizations' THEN OrderID END) AS cnt_C4,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Manually Pushed in Emedix'         THEN OrderID END) AS cnt_C5,
        -- Row D and sub-rows
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled'                                                   THEN OrderID END) AS cnt_D,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created'              THEN OrderID END) AS cnt_D1,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created' AND Source='Webpm'            THEN OrderID END) AS cnt_D1W,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created' AND ChargesNotEnteredStatus='No Charges found in Webpm'    THEN OrderID END) AS cnt_D1NC,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created' AND ChargesNotEnteredStatus='Unposted Charges in Webpm'    THEN OrderID END) AS cnt_D1UP,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created' AND Source='Daqbilling'       THEN OrderID END) AS cnt_D1DQ,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Non Billable - Excluded PAP Codes'               THEN OrderID END) AS cnt_D2,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Non Billable - Excluded Validity Codes'           THEN OrderID END) AS cnt_D3,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Non Billable - Excluded Organizations'            THEN OrderID END) AS cnt_D4,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charges Created and Not Submitted'                THEN OrderID END) AS cnt_D5,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charges Created and Not Submitted' AND Source='Webpm'      THEN OrderID END) AS cnt_D5W,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charges Created and Not Submitted' AND Source='Daqbilling' THEN OrderID END) AS cnt_D5DQ,
        -- Row E
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='ADCS Claims'                                                                               THEN OrderID END) AS cnt_E,
        -- Row F and sub-rows
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo NOT IN ('Insurance Bill','ADCS Claims')                                                      THEN OrderID END) AS cnt_F,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Yet to be validate'                                                                         THEN OrderID END) AS cnt_F1,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Self pay'                                                                                   THEN OrderID END) AS cnt_F2,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Client Bills'                                                                               THEN OrderID END) AS cnt_F3,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='System Test'                                                                                THEN OrderID END) AS cnt_F4,
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Rejections'                                                                                 THEN OrderID END) AS cnt_F5
    INTO #Counts
    FROM #LisBase
    GROUP BY ESYear, ESMonth

    UNION ALL

    -- Grand-total row (ESYear=0, ESMonth=0) – second pass but on the already-indexed #LisBase
    SELECT
        0, 0,
        COUNT(DISTINCT CASE WHEN IncorrectDOS=''                                                                                                           THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill'                                                                             THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed'                                                     THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Claim Submitted in Webpm'          THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Claim Submitted in Daqbilling'     THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Claim Submitted in Daq & Webpm'    THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Non Billable - Excluded Organizations' THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Billed' AND FinalStatus='Manually Pushed in Emedix'         THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled'                                                   THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created'              THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created' AND Source='Webpm'            THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created' AND ChargesNotEnteredStatus='No Charges found in Webpm'    THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created' AND ChargesNotEnteredStatus='Unposted Charges in Webpm'    THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charge Not Created' AND Source='Daqbilling'       THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Non Billable - Excluded PAP Codes'               THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Non Billable - Excluded Validity Codes'           THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Non Billable - Excluded Organizations'            THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charges Created and Not Submitted'                THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charges Created and Not Submitted' AND Source='Webpm'      THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Insurance Bill' AND BillStatus='Unbilled' AND FinalStatus='Charges Created and Not Submitted' AND Source='Daqbilling' THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='ADCS Claims'                                                                               THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo NOT IN ('Insurance Bill','ADCS Claims')                                                      THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Yet to be validate'                                                                         THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Self pay'                                                                                   THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Client Bills'                                                                               THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='System Test'                                                                                THEN OrderID END),
        COUNT(DISTINCT CASE WHEN IncorrectDOS='' AND BilledTo='Rejections'                                                                                 THEN OrderID END)
    FROM #LisBase;

    -- ════════════════════════════════════════════════════════════════════
    --  TRUNCATE and bulk-insert from #Counts (in-memory, very fast)
    -- ════════════════════════════════════════════════════════════════════
    TRUNCATE TABLE dbo.NW_ES_LIS;

    -- Description indentation drives UI row class:
    --   No spaces  → es-cat-row  (collapsible parent)
    --   2 spaces   → es-sub-row  (first-level child)
    --   4 spaces   → es-sub-sub-row (second-level child)
    INSERT INTO dbo.NW_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, RefreshedAt)
    SELECT 'A',     'Total No. of Samples',                                          ESYear, ESMonth, cnt_A,    GETDATE() FROM #Counts UNION ALL
    SELECT 'B',     'Billable Samples',                                               ESYear, ESMonth, cnt_B,    GETDATE() FROM #Counts UNION ALL
    SELECT 'C',     'No. of Billed Claims',                                          ESYear, ESMonth, cnt_C,    GETDATE() FROM #Counts UNION ALL
    SELECT 'C.1',   '  Claim Submitted in Webpm',                                     ESYear, ESMonth, cnt_C1,   GETDATE() FROM #Counts UNION ALL
    SELECT 'C.2',   '  Claim Submitted in Daqbilling',                               ESYear, ESMonth, cnt_C2,   GETDATE() FROM #Counts UNION ALL
    SELECT 'C.3',   '  Claim Submitted in Daq & Webpm',                              ESYear, ESMonth, cnt_C3,   GETDATE() FROM #Counts UNION ALL
    SELECT 'C.4',   '  Non Billable - Excluded Organizations',                        ESYear, ESMonth, cnt_C4,   GETDATE() FROM #Counts UNION ALL
    SELECT 'C.5',   '  Manually Pushed in Emedix',                                   ESYear, ESMonth, cnt_C5,   GETDATE() FROM #Counts UNION ALL
    SELECT 'D',     'No. of Unbilled Claims',                                        ESYear, ESMonth, cnt_D,    GETDATE() FROM #Counts UNION ALL
    SELECT 'D.1',   '  Unbilled - Charge Not Created',                               ESYear, ESMonth, cnt_D1,   GETDATE() FROM #Counts UNION ALL
    SELECT 'D.1.W', '    Charge Not Created - Webpm',                                ESYear, ESMonth, cnt_D1W,  GETDATE() FROM #Counts UNION ALL
    SELECT 'D.1.NC','    Charge Not Created - No Charges found in Webpm',            ESYear, ESMonth, cnt_D1NC, GETDATE() FROM #Counts UNION ALL
    SELECT 'D.1.UP','    Charge Not Created - Unposted Charges in Webpm',            ESYear, ESMonth, cnt_D1UP, GETDATE() FROM #Counts UNION ALL
    SELECT 'D.1.DQ','    Charge Not Created - Daqbilling',                           ESYear, ESMonth, cnt_D1DQ, GETDATE() FROM #Counts UNION ALL
    SELECT 'D.2',   '  Unbilled - Non Billable (Excluded PAP Codes)',                ESYear, ESMonth, cnt_D2,   GETDATE() FROM #Counts UNION ALL
    SELECT 'D.3',   '  Unbilled - Non Billable (Excluded Validity Codes)',           ESYear, ESMonth, cnt_D3,   GETDATE() FROM #Counts UNION ALL
    SELECT 'D.4',   '  Unbilled - Non Billable (Excluded Organizations)',            ESYear, ESMonth, cnt_D4,   GETDATE() FROM #Counts UNION ALL
    SELECT 'D.5',   '  Unbilled - Charges Created and Not Submitted',                ESYear, ESMonth, cnt_D5,   GETDATE() FROM #Counts UNION ALL
    SELECT 'D.5.W', '    Charges Not Submitted - Webpm',                             ESYear, ESMonth, cnt_D5W,  GETDATE() FROM #Counts UNION ALL
    SELECT 'D.5.DQ','    Charges Not Submitted - Daqbilling',                        ESYear, ESMonth, cnt_D5DQ, GETDATE() FROM #Counts UNION ALL
    SELECT 'E',     'No. of ADCS Claims',                                            ESYear, ESMonth, cnt_E,    GETDATE() FROM #Counts UNION ALL
    SELECT 'F',     'No. of Other Claims',                                           ESYear, ESMonth, cnt_F,    GETDATE() FROM #Counts UNION ALL
    SELECT 'F.1',   '  Other - Yet to be validate',                                  ESYear, ESMonth, cnt_F1,   GETDATE() FROM #Counts UNION ALL
    SELECT 'F.2',   '  Other - Self pay',                                            ESYear, ESMonth, cnt_F2,   GETDATE() FROM #Counts UNION ALL
    SELECT 'F.3',   '  Other - Client Bills',                                        ESYear, ESMonth, cnt_F3,   GETDATE() FROM #Counts UNION ALL
    SELECT 'F.4',   '  Other - System Test',                                         ESYear, ESMonth, cnt_F4,   GETDATE() FROM #Counts UNION ALL
    SELECT 'F.5',   '  Other - Rejections',                                          ESYear, ESMonth, cnt_F5,   GETDATE() FROM #Counts;

    -- ════════════════════════════════════════════════════════════════════
    --  Panel sub-rows (B.{PanelName}) – single grouped scan of #LisBase
    -- ════════════════════════════════════════════════════════════════════
    INSERT INTO dbo.NW_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, RefreshedAt)
    -- Per-period panel counts  (2-space prefix → es-sub-row, collapses under Row B)
    SELECT
        'B.' + PanelName,
        '  ' + PanelName,
        ESYear, ESMonth,
        COUNT(DISTINCT OrderID),
        GETDATE()
    FROM #LisBase
    WHERE IncorrectDOS='' AND BilledTo='Insurance Bill' AND PanelName<>''
    GROUP BY PanelName, ESYear, ESMonth

    UNION ALL

    -- Grand-total panel counts
    SELECT
        'B.' + PanelName,
        '  ' + PanelName,
        0, 0,
        COUNT(DISTINCT OrderID),
        GETDATE()
    FROM #LisBase
    WHERE IncorrectDOS='' AND BilledTo='Insurance Bill' AND PanelName<>''
    GROUP BY PanelName;

    -- Cleanup
    DROP TABLE IF EXISTS #LisBase;
    DROP TABLE IF EXISTS #Counts;

    PRINT 'NW_ES_LIS refreshed successfully.';
END;
GO

PRINT '33_NW_ExecutiveSummary_LIS_Alt.sql completed.';
GO
