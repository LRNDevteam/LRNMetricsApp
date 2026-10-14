-- ============================================================
-- RisingTides – LIS Breakdown: "Billing Status - No Bill" (L_A7) sub-rows
-- File : 29_RisingTides_ExecutiveSummary_LIS_A7_SubRows.sql
-- DB   : Rising_Tides
--
-- Adds 3 new sub-rows under L_A7 "Billing Status - No Bill", per spec:
--   L_A7a  Rejected            ResultedStatus=Resulted AND BillingStatus=No Bill AND OrderStatus=Rejected
--   L_A7b  Completed           ResultedStatus=Resulted AND BillingStatus=No Bill AND OrderStatus=Completed
--   L_A7c  Recollect Required  ResultedStatus=Resulted AND BillingStatus=No Bill AND OrderStatus=Recollect Required
--
-- SortOrder: 361/362/363 — sit immediately after L_A7 (360) and before
-- L_B "Not Resulted" (400), so they render as sub-rows of A7.
--
-- This file only re-creates usp_RefreshRT_ExecutiveSummary_LIS_Alt
-- (identical to file 28's version, plus these 3 new UNION ALL branches).
-- usp_GetRT_ExecutiveSummary is unchanged — it already orders generically
-- by SortOrder so the new rows slot in automatically.
--
-- Also requires a matching update to SqlPhiExecutiveSummaryRepository.cs's
-- RowOrder list (C# side), inserting "L_A7a","L_A7b","L_A7c" right after
-- "L_A7" — done alongside this file.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;

    -- Remove any previously-generated 'L_*' rows from this alternate breakdown
    -- (leaves the existing A..I rows from usp_RefreshRT_ExecutiveSummary alone).
    DELETE FROM dbo.RT_ES_LIS WHERE RoleID LIKE 'L\_%' ESCAPE '\';

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        PRINT 'usp_RefreshRT_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found – nothing to do.';
        RETURN;
    END

    DROP TABLE IF EXISTS #Lis2;
    CREATE TABLE #Lis2
    (
        Accession     NVARCHAR(100) NOT NULL,
        ESYear        INT           NOT NULL,
        ESMonth       INT           NOT NULL,
        ResultedNot   NVARCHAR(50)  NOT NULL,
        ClientStatus  NVARCHAR(100) NOT NULL,
        BilledNot     NVARCHAR(20)  NOT NULL,
        BillingStatus NVARCHAR(100) NOT NULL,  -- raw BillingStatus value
        ClaimStatus   NVARCHAR(100) NOT NULL,  -- raw ClaimStatus value
        OrderStatus   NVARCHAR(100) NOT NULL,
        PaymentMethod NVARCHAR(100) NOT NULL,  -- raw PaymentMethod value
        SampleStatus  NVARCHAR(100) NOT NULL,  -- raw SampleStatus value
        PanelName     NVARCHAR(300) NOT NULL
    );

    -- Auto-detect the panel-name column on dbo.LIMSMaster (same candidate list /
    -- priority order as 18_RisingTides_ExecutiveSummary_Detail.sql's @PanelCol).
    DECLARE @PanelCol2 SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2
            WHEN 'TestPanelName' THEN 3 WHEN 'TestPanelname' THEN 4 WHEN 'TestPanel' THEN 5
            WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8 ELSE 9 END);

    DECLARE @PanelExpr2 NVARCHAR(400) = ISNULL(
        'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol2 + N']), '''')))', '''''');

    DECLARE @Lis2Sql NVARCHAR(MAX) = N'
        INSERT INTO #Lis2 (Accession, ESYear, ESMonth, ResultedNot, ClientStatus, BilledNot, BillingStatus, ClaimStatus, OrderStatus, PaymentMethod, SampleStatus, PanelName)
        SELECT
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), Accession), ''''))),
            YEAR (TRY_CAST(RequestCollectDate AS DATE)),
            MONTH(TRY_CAST(RequestCollectDate AS DATE)),
            LTRIM(RTRIM(ISNULL(RessultedStatus, ''''))),
            LTRIM(RTRIM(ISNULL(ClientStatus,    ''''))),
            CASE WHEN LTRIM(RTRIM(ISNULL(BillingStatus, ''''))) = ''Billed'' THEN ''Billed'' ELSE ''Unbilled'' END,
            LTRIM(RTRIM(ISNULL(BillingStatus,   ''''))),
            LTRIM(RTRIM(ISNULL(ClaimStatus,     ''''))),
            LTRIM(RTRIM(ISNULL(OrderStatus,     ''''))),
            LTRIM(RTRIM(ISNULL(PaymentMethod,   ''''))),
            LTRIM(RTRIM(ISNULL(SampleStatus,    ''''))),
            ' + @PanelExpr2 + N'
        FROM dbo.LIMSMaster
        WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '''') IS NOT NULL;';

    EXEC sp_executesql @Lis2Sql;

    -- Periods: every (Year,Month) present in #Lis2 PLUS a (0,0) grand-total sentinel.
    DROP TABLE IF EXISTS #LisPeriods2;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods2 FROM #Lis2
    UNION ALL SELECT 0, 0;

    -- Distinct panel names among Resulted samples, for the L_A.<PanelName> sub-rows.
    -- Each distinct panel gets its own SortOrder slot (211, 212, 213, ...) so the
    -- panel breakdown sits right under the "Billable Samples - Resulted" header
    -- (SortOrder 200) and before A1 (SortOrder 300).
    DROP TABLE IF EXISTS #LisPanels2;
    SELECT PanelName, 210 + CAST(ROW_NUMBER() OVER (ORDER BY PanelName) AS INT) AS PanelSortOrder
    INTO #LisPanels2
    FROM (SELECT DISTINCT PanelName FROM #Lis2 WHERE ResultedNot = 'Resulted' AND PanelName <> '') AS dp;

    INSERT INTO dbo.RT_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt, SortOrder)
    SELECT lis2.RoleID, lis2.Description, lis2.ESYear, lis2.ESMonth, lis2.SampleCount, 0, GETDATE(), lis2.SortOrder
    FROM
    (
        -- L_0  Total Samples  (SortOrder 100 — always first)
        SELECT p.ESYear, p.ESMonth, 'L_0' AS RoleID, 'Total Samples' AS Description, 100 AS SortOrder,
               COUNT(DISTINCT l.Accession) AS SampleCount
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A  Billable Samples - Resulted  (SortOrder 200)
        SELECT p.ESYear, p.ESMonth, 'L_A', 'Billable Samples - Resulted', 200,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1  Billed to Insurance  (SortOrder 300)
        SELECT p.ESYear, p.ESMonth, 'L_A1', 'Billed to Insurance', 300,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1a  Billed to Insurance - Billed In AMD  (SortOrder 301)
        SELECT p.ESYear, p.ESMonth, 'L_A1a', '    Billed In AMD', 301,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2  Not Entered in AMD  (SortOrder 310)
        SELECT p.ESYear, p.ESMonth, 'L_A2', 'Not Entered in AMD', 310,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2a  Not Entered in AMD - Received  (SortOrder 311)
        SELECT p.ESYear, p.ESMonth, 'L_A2a', '    Received', 311,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2b  Not Entered in AMD - Billing Review Required  (identical to L_A2a per spec) (SortOrder 312)
        SELECT p.ESYear, p.ESMonth, 'L_A2b', '    Billing Review Required', 312,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A3  Unbilled  (SortOrder 320)
        SELECT p.ESYear, p.ESMonth, 'L_A3', 'Unbilled', 320,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Entered'
              AND l.BilledNot = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A4  Client Bill  (SortOrder 330)
        SELECT p.ESYear, p.ESMonth, 'L_A4', 'Client Bill', 330,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
              AND l.ClaimStatus IN ('Billed','Not Entered in AMD')
              AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A4a  Client Bill - Not Entered in AMD  (SortOrder 331)
        -- NOTE: spec also lists BillingStatus='Billed' here, which conflicts with
        -- BilledorNot='Unbilled' (BilledNot is derived FROM BillingStatus='Billed').
        -- Implemented WITHOUT the BillingStatus='Billed' clause so this branch is
        -- not permanently 0; flag if BillingStatus='Billed' should be kept/changed.
        SELECT p.ESYear, p.ESMonth, 'L_A4a', '    Not Entered in AMD', 331,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
              AND l.ClaimStatus = 'Not Entered in AMD' AND l.BilledNot = 'Unbilled'
              AND l.ClientStatus = 'Client Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A4b  Client Bill - Billed  (SortOrder 332)
        SELECT p.ESYear, p.ESMonth, 'L_A4b', '    Billed', 332,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
              AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
              AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5  Self Pay  (SortOrder 340)
        SELECT p.ESYear, p.ESMonth, 'L_A5', 'Self Pay', 340,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClientStatus = 'Self Pay'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5a  Self Pay - Billed  (SortOrder 341)
        SELECT p.ESYear, p.ESMonth, 'L_A5a', '    Billed', 341,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
              AND l.ClientStatus = 'Self Pay' AND l.BillingStatus IN ('Billed','Not Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5b  Self Pay - Not Entered in AMD  (SortOrder 342)
        -- NOTE: same BillingStatus='Billed' vs BilledorNot='Unbilled' conflict as
        -- L_A4a above — implemented without BillingStatus='Billed'.
        SELECT p.ESYear, p.ESMonth, 'L_A5b', '    Not Entered in AMD', 342,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Not Entered in AMD' AND l.BilledNot = 'Unbilled'
              AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5c  Self Pay - Entered  (SortOrder 343)
        -- NOTE: same BillingStatus='Billed' vs BilledorNot='Unbilled' conflict as
        -- L_A4a above — implemented without BillingStatus='Billed'.
        SELECT p.ESYear, p.ESMonth, 'L_A5c', '    Entered', 343,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Entered' AND l.BilledNot = 'Unbilled'
              AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6  Test Entries  (SortOrder 350)
        -- NOTE: spec's Test Entries logic also conflicts on BillingStatus='Billed'
        -- vs BilledorNot='Unbilled' (see file 27 header note 2) — implemented
        -- without BillingStatus='Billed'.
        SELECT p.ESYear, p.ESMonth, 'L_A6', 'Test Entries', 350,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.BilledNot = 'Unbilled' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6a  Test Entries - Not Entered in AMD  (identical to L_A6 per spec) (SortOrder 351)
        SELECT p.ESYear, p.ESMonth, 'L_A6a', '    Not Entered in AMD', 351,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.BilledNot = 'Unbilled' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7  Billing Status - No Bill  (SortOrder 360)
        SELECT p.ESYear, p.ESMonth, 'L_A7', 'Billing Status - No Bill', 360,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7a  Billing Status - No Bill - Rejected  (SortOrder 361, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7a', '    Rejected', 361,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Rejected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7b  Billing Status - No Bill - Completed  (SortOrder 362, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7b', '    Completed', 362,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Completed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7c  Billing Status - No Bill - Recollect Required  (SortOrder 363, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7c', '    Recollect Required', 363,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Recollect Required'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B  Not Resulted  (SortOrder 400 — immediately follows L_A7c/363)
        SELECT p.ESYear, p.ESMonth, 'L_B', 'Not Resulted', 400,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1  Not Resulted - Not Entered in AMD  (SortOrder 410)
        SELECT p.ESYear, p.ESMonth, 'L_B1', 'Not Entered in AMD', 410,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1a  Not Entered in AMD - Collected  (SortOrder 411)
        SELECT p.ESYear, p.ESMonth, 'L_B1a', '    Collected', 411,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Collected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1b  Not Entered in AMD - Received  (identical to L_B1a per spec) (SortOrder 412)
        SELECT p.ESYear, p.ESMonth, 'L_B1b', '    Received', 412,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Collected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B2  Not Resulted - Rejected Sample  (SortOrder 420)
        SELECT p.ESYear, p.ESMonth, 'L_B2', 'Rejected Sample', 420,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Rejected'
        GROUP BY p.ESYear, p.ESMonth
    ) lis2;

    -- ── L_A.<PanelName> sub-rows (panel-wise breakdown of "Billable Samples - Resulted") ──
    DELETE FROM dbo.RT_ES_LIS_Panel WHERE RoleID LIKE 'L\_A.%' ESCAPE '\';
    -- Clean up legacy 'L_B.<PanelName>' rows from prior versions of this SP (file 19/25).
    DELETE FROM dbo.RT_ES_LIS_Panel WHERE RoleID LIKE 'L\_B.%' ESCAPE '\';

    INSERT INTO dbo.RT_ES_LIS_Panel (RoleID, PanelName, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt, SortOrder)
    SELECT 'L_A.' + pn.PanelName, pn.PanelName, '    ' + pn.PanelName,
           p.ESYear, p.ESMonth, COUNT(DISTINCT l.Accession), 0, GETDATE(), pn.PanelSortOrder
    FROM #LisPanels2 pn
    CROSS JOIN #LisPeriods2 p
    LEFT JOIN #Lis2 l
           ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
          AND l.ResultedNot = 'Resulted'
          AND l.PanelName = pn.PanelName
    GROUP BY pn.PanelName, pn.PanelSortOrder, p.ESYear, p.ESMonth;

    DROP TABLE IF EXISTS #Lis2;
    DROP TABLE IF EXISTS #LisPeriods2;
    DROP TABLE IF EXISTS #LisPanels2;

    PRINT 'usp_RefreshRT_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '29_RisingTides_ExecutiveSummary_LIS_A7_SubRows.sql completed.';
GO
