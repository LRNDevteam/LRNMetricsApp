-- ============================================================
-- RisingTides – LIS Breakdown row ordering fix
-- File : 28_RisingTides_ExecutiveSummary_LIS_SortOrder.sql
-- DB   : Rising_Tides
--
-- PROBLEM:
--   usp_GetRT_ExecutiveSummary orders all rows with
--   "ORDER BY BillYear, BillMonth, RowCode" where RowCode = RoleID.
--   The new "L_0 / L_A / L_A1.. / L_B / L_B1.." scheme from file 27
--   relies on RoleID STRING-SORT to get:
--     Total Samples (L_0) first, then Billable Samples - Resulted
--     (L_A) + its A1-A7 children, then Not Resulted (L_B) + B1-B2.
--   In the live SQL Server collation, '0' does NOT sort before 'A'/'B'
--   the way plain ASCII would — the deployed output actually came back
--   as: L_A, L_B, L_0, L_A1, L_A1a, L_A2, ... i.e. Total Samples landed
--   3rd instead of 1st, and Not Resulted landed right after the
--   "Billable Samples - Resulted" header instead of after L_A7.
--
-- FIX:
--   Stop relying on RoleID string-sort for the LIS section. Add an
--   explicit SortOrder INT column to RT_ES_LIS / RT_ES_LIS_Panel and
--   have usp_GetRT_ExecutiveSummary order LIS rows by that integer
--   (PMS/Cash/Avg keep their existing RoleID-based order — unchanged
--   and unaffected).
--
-- SortOrder MAP (RT_ES_LIS / RT_ES_LIS_Panel):
--   100  L_0    Total Samples
--   200  L_A    Billable Samples - Resulted
--   211+ L_A.<PanelName>  (panel sub-rows, one slot per distinct panel,
--                          assigned 211, 212, 213 ... in PanelName order)
--   300  L_A1     Billed to Insurance
--   301  L_A1a      Billed In AMD
--   310  L_A2     Not Entered in AMD
--   311  L_A2a      Received
--   312  L_A2b      Billing Review Required
--   320  L_A3     Unbilled
--   330  L_A4     Client Bill
--   331  L_A4a      Not Entered in AMD
--   332  L_A4b      Billed
--   340  L_A5     Self Pay
--   341  L_A5a      Billed
--   342  L_A5b      Not Entered in AMD
--   343  L_A5c      Entered
--   350  L_A6     Test Entries
--   351  L_A6a      Not Entered in AMD
--   360  L_A7     Billing Status - No Bill
--   400  L_B    Not Resulted
--   410  L_B1     Not Entered in AMD
--   411  L_B1a      Collected
--   412  L_B1b      Received
--   420  L_B2     Rejected Sample
--
-- Resulting display order: Total Samples, Billable Samples - Resulted
-- (+ panel sub-rows), A1..A7 (+ their sub-rows), Not Resulted, B1..B2
-- (+ their sub-rows) — i.e. "Not Resulted" immediately follows
-- "Billing Status - No Bill" with nothing in between, exactly as
-- requested.
--
-- All logic/branches are otherwise identical to
-- 27_RisingTides_ExecutiveSummary_LIS_Alt_NewLogicScheme.sql — only the
-- SortOrder column and the read SP's ORDER BY are new.
-- ============================================================
SET NOCOUNT ON;
GO

-- ── 1. Add SortOrder column ──────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.RT_ES_LIS') AND name = 'SortOrder')
    ALTER TABLE dbo.RT_ES_LIS ADD SortOrder INT NOT NULL CONSTRAINT DF_RT_ES_LIS_SortOrder DEFAULT 0;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.RT_ES_LIS_Panel') AND name = 'SortOrder')
    ALTER TABLE dbo.RT_ES_LIS_Panel ADD SortOrder INT NOT NULL CONSTRAINT DF_RT_ES_LIS_Panel_SortOrder DEFAULT 0;
GO

-- ── 2. usp_RefreshRT_ExecutiveSummary_LIS_Alt — adds SortOrder per row ──
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
        -- L_A7  Billing Status - No Bill  (SortOrder 360 — last item of section A)
        SELECT p.ESYear, p.ESMonth, 'L_A7', 'Billing Status - No Bill', 360,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B  Not Resulted  (SortOrder 400 — immediately follows L_A7/360)
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

-- ── 3. usp_GetRT_ExecutiveSummary — order LIS rows by SortOrder ─────────
CREATE OR ALTER PROCEDURE dbo.usp_GetRT_ExecutiveSummary
(
	@YearFrom  INT = NULL,
	@YearTo    INT = NULL,
	@MonthFrom INT = NULL,
	@MonthTo   INT = NULL
)
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN @YearFrom IS NOT NULL OR @YearTo IS NOT NULL
			  OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL THEN 1
			ELSE 0
		END;

	-- ───────────────────────────────────────────────────────────────────────
	--  NO-FILTER PATH – fast path; read straight from aggregate tables.
	-- ───────────────────────────────────────────────────────────────────────
	IF @HasFilter = 0
	BEGIN
		SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
		FROM
		(
			-- LIS header rows — ordered via SortOrder (see file 28), not RoleID.
			SELECT RoleID                              AS RowCode,
				   'LIS'                               AS Category,
				   Description,
				   ESYear                              AS BillYear,
				   ESMonth                             AS BillMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue,
				   SortOrder                           AS SortOrder,
				   CAST(NULL AS NVARCHAR(20))          AS AltSortCode
			FROM   dbo.RT_ES_LIS

			UNION ALL

			-- LIS panel sub-rows — same SortOrder scheme.
			SELECT RoleID, 'LIS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
				   SortOrder,
				   NULL
			FROM   dbo.RT_ES_LIS_Panel

			UNION ALL

			-- PMS — unchanged, ordered by RoleID as before.
			SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
				   NULL,
				   RoleID
			FROM   dbo.RT_ES_PMS

			UNION ALL

			-- Cash (uses dollar amount) — unchanged, ordered by RoleID as before.
			SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
				   ESMonthChargeAmount,
				   NULL,
				   RoleID
			FROM   dbo.RT_ES_Cash

			UNION ALL

			-- Avg (uses dollar amount) — unchanged, ordered by RoleID as before.
			SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
				   ESMonthChargeAmount,
				   NULL,
				   RoleID
			FROM   dbo.RT_ES_Avg
		) all_rows
		ORDER BY BillYear, BillMonth, Category, SortOrder, AltSortCode;
		RETURN;
	END;

	-- ───────────────────────────────────────────────────────────────────────
	--  FILTERED PATH – live re-aggregation for PMS + Cash.
	--  LIS rows are still served from the aggregate tables (filtered by Year/Month).
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #Base;

	SELECT
		LTRIM(RTRIM(ISNULL(ClaimID, '')))                                  AS VisitNumber,
		YEAR (TRY_CAST(DateofService AS DATE))                             AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE))                             AS ESMonth,
		LTRIM(RTRIM(ISNULL(BilledUnbilled, '')))                           AS BilledUnbilled,
		LTRIM(RTRIM(ISNULL(ClaimStatus,    '')))                           AS ClaimStatus,
		ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0)        AS ChargeAmount,
		ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0)        AS InsurancePayment,
		ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0)        AS PatientPayment,
		ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0)        AS InsuranceAdjustments,
		ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0)        AS PatientAdjustments,
		ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0)        AS InsuranceBalance,
		ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0)        AS PatientBalance
	INTO #Base
	FROM dbo.ClaimLevelData
	WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
	  AND NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
	  AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
	  AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
	  AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
	  AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo);

	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	;WITH PMS AS
	(
		SELECT p.ESYear,p.ESMonth,'O' AS RowCode,'Billed - Includes all Claims Billed in AMD' AS Description,
			   COUNT(DISTINCT b.VisitNumber) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b
		  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		 AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'P','Billed Mismatches - Non Diagnose US Samples',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Unbilled'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'Q','Unbilled - Entered in AMD - Yet to be released to Payer',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Unbilled'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'R','Paid - Client',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.ClaimStatus='Client Paid'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'S','Fully Paid - Insurance Pay',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Paid'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'T','Fully Adjusted',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Complete W/O'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'U','Patient Responsibility',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Patient Responsibility'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'V','Partially Paid',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Paid'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'X','Patient Payment',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Patient Payment'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'W','Insurance Balance',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied')
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'W1','  Fully Denied',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Denied'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'W2','  No Response',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='No Response'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'W3','  Partially Denied',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Denied'
			GROUP BY p.ESYear,p.ESMonth
	),
	Cash AS
	(
		SELECT p.ESYear,p.ESMonth,'X' AS RowCode,'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount),0) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b
		  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		 AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'Y','Unbilled ($)',ISNULL(SUM(b.ChargeAmount),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Unbilled' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'Z','Insurance Payment (fully paid) ($)',ISNULL(SUM(b.InsurancePayment),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Paid' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AA','Partially Paid ($)',ISNULL(SUM(b.InsurancePayment),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Paid' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AB','Patient Payment ($)',ISNULL(SUM(b.PatientPayment),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AC','Fully Adjusted (Complete W/O) ($)',ISNULL(SUM(b.InsuranceAdjustments),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Complete W/O' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AD','Contractual Obligation W/O ($)',ISNULL(SUM(b.InsuranceAdjustments),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus <> 'Complete W/O' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AE','Patient Balance ($)',ISNULL(SUM(b.PatientBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AF','Patient WO ($)',ISNULL(SUM(b.PatientAdjustments),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AG','Insurance Balance ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied') GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AG1','  No Response ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='No Response' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AG2','  Fully Denied ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Denied' GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'AG3','  Partially Denied ($)',ISNULL(SUM(b.InsuranceBalance),0)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Denied' GROUP BY p.ESYear,p.ESMonth
	),
	AvgBase AS
	(
		SELECT
			p.ESYear, p.ESMonth,
			ISNULL(SUM(CASE WHEN b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Fully Paid','Partially Paid')
							THEN b.InsurancePayment ELSE 0 END), 0)
			  + ISNULL(SUM(CASE WHEN b.BilledUnbilled='Billed' THEN b.PatientPayment ELSE 0 END), 0) AS TotalPay,
			COUNT(DISTINCT CASE WHEN b.BilledUnbilled='Billed'
								 THEN b.VisitNumber END) AS BilledClaims,
			COUNT(DISTINCT CASE WHEN b.BilledUnbilled='Billed'
								  AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Patient Payment')
								 THEN b.VisitNumber END) AS PaidClaims,
			COUNT(DISTINCT CASE WHEN b.BilledUnbilled='Billed'
								  AND b.ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
														 'Partially Paid','Patient Payment','Fully Denied','Partially Denied')
								 THEN b.VisitNumber END) AS AdjudicatedClaims
		FROM #Periods p LEFT JOIN #Base b
		  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth
	),
	AvgRows AS
	(
		SELECT ESYear, ESMonth, 'AH' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
			   CASE WHEN BilledClaims = 0 THEN 0 ELSE TotalPay / BilledClaims END AS MetricValue
		FROM AvgBase

		UNION ALL SELECT ESYear, ESMonth, 'AI1', 'Average Payment ($) - Total Pay/Paid Claims',
			   CASE WHEN PaidClaims = 0 THEN 0 ELSE TotalPay / PaidClaims END
		FROM AvgBase

		UNION ALL SELECT ESYear, ESMonth, 'AJ', 'Average Payment ($) - Total Pay/Adjudicated Claims',
			   CASE WHEN AdjudicatedClaims = 0 THEN 0 ELSE TotalPay / AdjudicatedClaims END
		FROM AvgBase
	)
	SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
	FROM
	(
		-- LIS rows from aggregate table (filtered by period) — ordered via SortOrder.
		SELECT RoleID AS RowCode,'LIS' AS Category, Description,
			   ESYear AS BillYear, ESMonth AS BillMonth,
			   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue,
			   SortOrder AS SortOrder, CAST(NULL AS NVARCHAR(20)) AS AltSortCode
		FROM dbo.RT_ES_LIS
		WHERE (ESYear=0 AND ESMonth=0)
		   OR ( (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
			AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
			AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
			AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo))

		UNION ALL
		SELECT RoleID,'LIS', Description, ESYear, ESMonth,
			   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
			   SortOrder, NULL
		FROM dbo.RT_ES_LIS_Panel
		WHERE (ESYear=0 AND ESMonth=0)
		   OR ( (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
			AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
			AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
			AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo))

		UNION ALL
		SELECT RowCode,'PMS', Description, ESYear, ESMonth,
			   CAST(MetricValue AS DECIMAL(18,2)),
			   NULL, RowCode
		FROM PMS

		UNION ALL
		SELECT RowCode,'Cash', Description, ESYear, ESMonth, MetricValue,
			   NULL, RowCode
		FROM Cash

		UNION ALL
		SELECT RowCode,'Avg', Description, ESYear, ESMonth, MetricValue,
			   NULL, RowCode
		FROM AvgRows
	) all_rows
	ORDER BY BillYear, BillMonth, Category, SortOrder, AltSortCode;

	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
END;
GO

PRINT '28_RisingTides_ExecutiveSummary_LIS_SortOrder.sql completed.';
GO
