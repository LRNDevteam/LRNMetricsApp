/*
    Rising Tides Executive Summary - LIS Breakdown changes (2026-10-06)

    A) L_A1   Billed to Insurance (SortOrder 300) - logic changed
       B) L_A1a  Billed In AMD     (SortOrder 301) - logic changed (same as L_A1 per spec)
              Count [Order ID] WHERE Resulted / Not = [Resulted] AND Payment Method = [Insurance]
              AND Claim Status = [Billed] AND Client Status <> [Test Entries]
    C) Test Entries (L_A6) - two new sub-rows
       L_A6b  Billed   (NEW, SortOrder 352)
              Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Test Entries,
              Billing Status <> No Bill, Claim Status = Billed
       L_A6c  Entered  (NEW, SortOrder 353)
              same as L_A6b but Claim Status = Entered
    D) Not Entered in AMD (L_B1) - one new sub-row
       L_B1c  In Transit (NEW, SortOrder 413)
              Count [Order ID] WHERE Resulted / Not = Not Resulted, Claim Status = Not Entered in AMD,
              Client Status = Blank, Sample Status = In Transit

    This script re-creates, from the deployed versions (script 37), with only the changes above:
      1. dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt  - stored rows (no filter)
      2. dbo.usp_GetRT_ExecutiveSummary              - live rows (with filters)
    then updates the drill-down definitions and rebuilds the LIS rows.
    Rising Tides database only. Safe to run again.
*/
SET NOCOUNT ON;
GO
CREATE OR ALTER PROCEDURE [dbo].[usp_RefreshRT_ExecutiveSummary_LIS_Alt]
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
		OrderID	      NVARCHAR(100) NOT NULL,
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
        INSERT INTO #Lis2 (Accession,OrderID, ESYear, ESMonth, ResultedNot, ClientStatus, BilledNot, BillingStatus, ClaimStatus, OrderStatus, PaymentMethod, SampleStatus, PanelName)
        SELECT
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), Accession), ''''))),
			LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), OrderID), ''''))),
            YEAR (TRY_CAST(RequestCollectDate AS DATE)),
            MONTH(TRY_CAST(RequestCollectDate AS DATE)),
            LTRIM(RTRIM(ISNULL(RessultedStatus, ''''))),
            LTRIM(RTRIM(ISNULL(ClientStatus,    ''''))),
            --CASE WHEN LTRIM(RTRIM(ISNULL(BillingStatus, ''''))) = ''Billed'' THEN ''Billed'' ELSE ''Unbilled'' END,
            LTRIM(RTRIM(ISNULL(BilledorNot,   ''''))),
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
               COUNT(l.Accession) AS SampleCount
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A  Billable Samples - Resulted  (SortOrder 200)
        SELECT p.ESYear, p.ESMonth, 'L_A', 'Billable Samples - Resulted', 200,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1  Billed to Insurance  (SortOrder 300)
        -- Count [Order ID] WHERE Resulted / Not = Resulted, Payment Method = Insurance,
        -- Claim Status = Billed, Client Status <> Test Entries
        SELECT p.ESYear, p.ESMonth, 'L_A1', 'Billed to Insurance', 300,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.ClientStatus <> 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1a  Billed to Insurance - Billed In AMD  (SortOrder 301)
        -- Same logic as L_A1 (per spec)
        SELECT p.ESYear, p.ESMonth, 'L_A1a', '  Billed In AMD', 301,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.ClientStatus <> 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A2  Not Entered in AMD  (SortOrder 310)
        --SELECT p.ESYear, p.ESMonth, 'L_A2', 'Not Entered in AMD', 310,
        --       COUNT(l.OrderID)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        --      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
        --      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        --GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A2a  Not Entered in AMD - Received  (SortOrder 311)
        --SELECT p.ESYear, p.ESMonth, 'L_A2a', '    Received', 311,
        --       COUNT(l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        --      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
        --      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        --      AND l.SampleStatus = 'Received'
        --GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A2b  Not Entered in AMD - Billing Review Required  (identical to L_A2a per spec) (SortOrder 312)
        --SELECT p.ESYear, p.ESMonth, 'L_A2b', '    Billing Review Required', 312,
        --       COUNT(l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        --      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
        --      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        --      AND l.SampleStatus = 'Received'
        --GROUP BY p.ESYear, p.ESMonth

		UNION ALL
        -- L_A2  Not Entered in AMD  (SortOrder 310)
        -- Resulted, Payment Method = Insurance, Claim Status = Not Entered in AMD,
        -- Client Status = Billing Review Required or blank, Billing Status = Billed / Not Ready To Bill / Ready To Bill
        SELECT p.ESYear, p.ESMonth, 'L_A2', 'Not Entered in AMD', 310,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus IN ('Billing Review Required', '')
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2a  Not Entered in AMD - Received  (SortOrder 311)
        SELECT p.ESYear, p.ESMonth, 'L_A2a', '  Received', 311,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus IN ('Billing Review Required', '')
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2b  Not Entered in AMD - Billing Review Required  (identical to L_A2a per spec) (SortOrder 312)
        SELECT p.ESYear, p.ESMonth, 'L_A2b', '  Billing Review Required', 312,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              --AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2c  Not Entered in AMD - Transferred  (SortOrder 313)
        SELECT p.ESYear, p.ESMonth, 'L_A2c', '  Transferred', 313,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus IN ('Billing Review Required', '')
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Transferred'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2d  Not Entered in AMD - Collected  (SortOrder 314)
        SELECT p.ESYear, p.ESMonth, 'L_A2d', '  Collected', 314,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus IN ('Billing Review Required', '')
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Collected'
        GROUP BY p.ESYear, p.ESMonth


        --UNION ALL
        ---- L_A3  Unbilled  (SortOrder 320)
        --SELECT p.ESYear, p.ESMonth, 'L_A3', 'Unbilled', 320,
        --       COUNT(l.OrderID)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Entered'
        --      AND l.BilledNot = 'Unbilled'
        --GROUP BY p.ESYear, p.ESMonth

		   UNION ALL
        -- L_A3  Unbilled  (SortOrder 320)
        SELECT p.ESYear, p.ESMonth, 'L_A3', 'Unbilled', 320,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND (l.ClientStatus is NULL or ClientStatus='')
              AND l.BilledNot = 'Unbilled' AND l.ClaimStatus = 'Entered'
        GROUP BY p.ESYear, p.ESMonth


        --UNION ALL
        ---- L_A4  Client Bill  (SortOrder 330)
        --SELECT p.ESYear, p.ESMonth, 'L_A4', 'Client Bill', 330,
        --       COUNT(l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
        --      AND l.ClaimStatus IN ('Billed','Not Entered in AMD')
        --      AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
        --GROUP BY p.ESYear, p.ESMonth

		UNION ALL
        -- L_A4  Client Bill  (SortOrder 330)
        SELECT p.ESYear, p.ESMonth, 'L_A4', 'Client Bill', 330,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Client Bill' 
			  AND l.BillingStatus in ('Billed','Ready to Bill')
        GROUP BY p.ESYear, p.ESMonth


        UNION ALL
        -- L_A4a  Client Bill - Not Entered in AMD  (SortOrder 331)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Client Bill, 
		--Billing Status = Billed, Ready to Bill, Claim Status = Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_A4a', '  Not Entered in AMD', 331,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'  AND l.ClientStatus = 'Client Bill'   AND l.BillingStatus in ('Billed','Ready to Bill')
			  AND l.ClaimStatus = 'Not Entered in AMD' 
             
        GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A4b  Client Bill - Billed  (SortOrder 332)
        --SELECT p.ESYear, p.ESMonth, 'L_A4b', '    Billed', 332,
        --       COUNT(l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
        --      AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
        --      AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
        --GROUP BY p.ESYear, p.ESMonth
		
        UNION ALL
        -- L_A4b  Client Bill - Billed  (SortOrder 332)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Self Pay, 
		--Billing Status NOT Equal to No BILL,
		--Claim Status = Not Entered in AMD
		--Select Distinct BillingSTatus from LIMSMaster
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Client Bill, Billing Status NOT Equal to No BILL, Claim Status = Billed
        SELECT p.ESYear, p.ESMonth, 'L_A4b', '  Billed', 332,
               COUNT( l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
               AND l.ResultedNot = 'Resulted'  AND l.ClientStatus = 'Client Bill'   
			   AND l.BillingStatus <>'No Bill' and ClaimStatus='Billed'
			  
        GROUP BY p.ESYear, p.ESMonth
		
        UNION ALL
        -- L_A4c  Client Bill - Entered  (SortOrder 333)
        -- Resulted / Not = Resulted AND Claim Status = Entered AND Billed/Not = Unbilled
        -- AND Client Status = Client Bill
        SELECT p.ESYear, p.ESMonth, 'L_A4c', '  Entered', 333,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Entered'
              AND l.BilledNot = 'Unbilled' AND l.ClientStatus = 'Client Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5  Self Pay  (SortOrder 340)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Self Pay, Billing Status NOT Equal to No BILL
        SELECT p.ESYear, p.ESMonth, 'L_A5', 'Self Pay', 340,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'   AND l.ClientStatus = 'Self Pay' and l.BillingStatus <>'No Bill'
			
			  --AND l.PaymentMethod = 'Self Pay'
              --AND l.ClientStatus = 'Self Pay'
              --AND l.BillingStatus IN ('Billed','Not Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5a  Self Pay - Billed  (SortOrder 341)
        SELECT p.ESYear, p.ESMonth, 'L_A5a', '  Billed', 341,
               COUNT(l.Accession)
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
		----Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Self Pay, 
		--Billing Status NOT Equal to No BILL, Claim Status = Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_A5b', '  Not Entered in AMD', 342,
               COUNT( l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'   AND l.BillingStatus <>'No Bill' --AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Not Entered in AMD' --AND l.BilledNot = 'Unbilled'
              AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5c  Self Pay - Entered  (SortOrder 343)
       -- L_A4a above — implemented without BillingStatus='Billed'.
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Self Pay,
		--Billing Status NOT Equal to No BILL, Claim Status = Entered

		
        SELECT p.ESYear, p.ESMonth, 'L_A5c', '  Entered', 343,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'AND l.ClaimStatus = 'Entered' 
			  AND l.BillingStatus <>'No Bill'
              AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6  Test Entries  (SortOrder 350)
        -- Count [Order ID] WHERE Resulted / Not = Resulted,
		-- Client Status = Test Entries, Billing Status NOT Equal to No BILL
       
        SELECT p.ESYear, p.ESMonth, 'L_A6', 'Test Entries', 350,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND   l.BillingStatus <>'No Bill'
              AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6a  Test Entries - Not Entered in AMD  (identical to L_A6 per spec) (SortOrder 351)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Test Entries,
		--Billing Status NOT Equal to No BILL, Claim Status = Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_A6a', '  Not Entered in AMD', 351,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.BillingStatus <>'No Bill' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6b  Test Entries - Billed  (SortOrder 352)
        -- Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Test Entries,
        -- Billing Status <> No Bill, Claim Status = Billed
        SELECT p.ESYear, p.ESMonth, 'L_A6b', '  Billed', 352,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Test Entries'
              AND l.BillingStatus <> 'No Bill' AND l.ClaimStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6c  Test Entries - Entered  (SortOrder 353)
        -- Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Test Entries,
        -- Billing Status <> No Bill, Claim Status = Entered
        SELECT p.ESYear, p.ESMonth, 'L_A6c', '  Entered', 353,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Test Entries'
              AND l.BillingStatus <> 'No Bill' AND l.ClaimStatus = 'Entered'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7  Billing Status - No Bill  (SortOrder 360)
        SELECT p.ESYear, p.ESMonth, 'L_A7', 'Billing Status - No Bill', 360,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7a  Billing Status - No Bill - Rejected  (SortOrder 361, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7a', '  Rejected', 361,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Rejected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7b  Billing Status - No Bill - Completed  (SortOrder 362, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7b', '  Completed', 362,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Completed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7c  Billing Status - No Bill - Recollect Required  (SortOrder 363, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7c', '  Recollect Required', 363,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Recollect Required'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B  Not Resulted  (SortOrder 400 — immediately follows L_A7c/363)
        SELECT p.ESYear, p.ESMonth, 'L_B', 'Not Resulted', 400,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1  Not Resulted - Not Entered in AMD  (SortOrder 410)
		--Count [Order ID] WHERE Resulted / Not = Not Resulted, Claim Status = Not Entered in AMD, 
		--Client Status = Blank
        SELECT p.ESYear, p.ESMonth, 'L_B1', 'Not Entered in AMD', 410,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			  and (ClientStatus is null or ClientStatus='')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1a  Not Entered in AMD - Collected  (SortOrder 411)
		--Count [Order ID] WHERE Resulted / Not = Not Resulted, Claim Status = Not Entered in AMD, 
		--Client Status = Blank, Sample Status = Collected

        SELECT p.ESYear, p.ESMonth, 'L_B1a', '  Collected', 411,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Collected'  and (ClientStatus is null or ClientStatus='')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1b  Not Entered in AMD - Received  (SortOrder 412)
        SELECT p.ESYear, p.ESMonth, 'L_B1b', '  Received', 412,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Received' AND (l.ClientStatus IS NULL OR l.ClientStatus = '')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1c  Not Entered in AMD - In Transit  (SortOrder 413)
        -- Count [Order ID] WHERE Resulted / Not = Not Resulted, Claim Status = Not Entered in AMD,
        -- Client Status = Blank, Sample Status = In Transit
        SELECT p.ESYear, p.ESMonth, 'L_B1c', '  In Transit', 413,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'In Transit' AND (l.ClientStatus IS NULL OR l.ClientStatus = '')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B2  Not Resulted - Rejected Sample  (SortOrder 420)
        SELECT p.ESYear, p.ESMonth, 'L_B2', 'Rejected Sample', 420,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Rejected'
        GROUP BY p.ESYear, p.ESMonth

		
        UNION ALL
        -- L_B3  Not Resulted - Test Entries  (SortOrder 430)
        -- Count [Accession] WHERE ResultedNot = 'Not Resulted', ClientStatus = 'Test Entries'
        SELECT p.ESYear, p.ESMonth, 'L_B3', 'Test Entries', 430,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B4  Not Resulted - Self Pay  (SortOrder 440)
        -- Count [Accession] WHERE ResultedNot = 'Not Resulted', ClientStatus = 'Self Pay'
        SELECT p.ESYear, p.ESMonth, 'L_B4', '  Self Pay', 440,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

    ) lis2;

    -- ── L_A.<PanelName> sub-rows (panel-wise breakdown of "Billable Samples - Resulted") ──
    DELETE FROM dbo.RT_ES_LIS_Panel WHERE RoleID LIKE 'L\_A.%' ESCAPE '\';
    -- Clean up legacy 'L_B.<PanelName>' rows from prior versions of this SP (file 19/25).
    DELETE FROM dbo.RT_ES_LIS_Panel WHERE RoleID LIKE 'L\_B.%' ESCAPE '\';

    INSERT INTO dbo.RT_ES_LIS_Panel (RoleID, PanelName, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt, SortOrder)
    SELECT 'L_A.' + pn.PanelName, pn.PanelName, '  ' + pn.PanelName,
           p.ESYear, p.ESMonth, COUNT(l.Accession), 0, GETDATE(), pn.PanelSortOrder
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

    -- Billed Mismatches (P) + Average Payment Per Claim, after LIS/PMS/Cash.
    IF OBJECT_ID('dbo.usp_RT_ES_RefreshDerivedRows', 'P') IS NOT NULL
        EXEC dbo.usp_RT_ES_RefreshDerivedRows;
END;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_GetRT_ExecutiveSummary]
(
	@YearFrom     INT           = NULL,
	@YearTo       INT           = NULL,
	@MonthFrom    INT           = NULL,
	@MonthTo      INT           = NULL,
	@DosFrom      DATE          = NULL,
	@DosTo        DATE          = NULL,
	@BilledFrom   DATE          = NULL,
	@BilledTo     DATE          = NULL,
	@Panels       NVARCHAR(MAX) = NULL,
	@Clinics      NVARCHAR(MAX) = NULL,
	@Providers    NVARCHAR(MAX) = NULL,
	@Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN @YearFrom     IS NOT NULL THEN 1
			WHEN @YearTo       IS NOT NULL THEN 1
			WHEN @MonthFrom    IS NOT NULL THEN 1
			WHEN @MonthTo      IS NOT NULL THEN 1
			WHEN @DosFrom      IS NOT NULL THEN 1
			WHEN @DosTo        IS NOT NULL THEN 1
			WHEN @BilledFrom   IS NOT NULL THEN 1
			WHEN @BilledTo     IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL THEN 1
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
			-- LIS header rows
			SELECT RoleID                              AS RowCode,
				   'LIS'                               AS Category,
				   Description,
				   ESYear                              AS BillYear,
				   ESMonth                             AS BillMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue
			FROM   dbo.RT_ES_LIS

			UNION ALL

			-- LIS panel sub-rows
			SELECT RoleID, 'LIS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.RT_ES_LIS_Panel

			UNION ALL

			-- PMS
			SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.RT_ES_PMS

			UNION ALL

			-- Cash (uses dollar amount)
			SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.RT_ES_Cash

			UNION ALL

			-- Avg (uses dollar amount)
			SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.RT_ES_Avg
		) all_rows
		ORDER BY BillYear, BillMonth, RowCode;
		RETURN;
	END;

	-- ───────────────────────────────────────────────────────────────────────
	--  FILTERED PATH – live re-aggregation for PMS + Cash.
	--  LIS rows are still served from the aggregate tables (filtered by Year/Month).
	-- ───────────────────────────────────────────────────────────────────────

	-- Dimension filter staging tables
	CREATE TABLE #FilterPanels   (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	CREATE TABLE #FilterClinics  (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	CREATE TABLE #FilterProviders(Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	CREATE TABLE #FilterReps     (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);

	IF NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL
		INSERT INTO #FilterPanels(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Panels, ',') WHERE LTRIM(RTRIM(value)) <> '';
	IF NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL
		INSERT INTO #FilterClinics(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Clinics, ',') WHERE LTRIM(RTRIM(value)) <> '';
	IF NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL
		INSERT INTO #FilterProviders(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Providers, ',') WHERE LTRIM(RTRIM(value)) <> '';
	IF NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL
		INSERT INTO #FilterReps(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Reps, ',') WHERE LTRIM(RTRIM(value)) <> '';

	DECLARE @HasPanelFilter    BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterPanels)    THEN 1 ELSE 0 END;
	DECLARE @HasClinicFilter   BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterClinics)   THEN 1 ELSE 0 END;
	DECLARE @HasProviderFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterProviders) THEN 1 ELSE 0 END;
	DECLARE @HasRepFilter      BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterReps)      THEN 1 ELSE 0 END;

	-- Date mode: DOS vs FirstBilledDate are mutually exclusive in the UI (same
	-- convention as Cove/Elixir). @UseBilledDate = 1 → FirstBilledDate filter is
	-- active (@BilledFrom/@BilledTo set, @DosFrom/@DosTo NULL) — LIS period basis
	-- switches from RequestCollectDate to AMDLBD. @UseBilledDate = 0 → DOS mode
	-- (or no date filter) — LIS period basis stays RequestCollectDate.
	DECLARE @UseBilledDate BIT = CASE
		WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
		 AND  @DosFrom IS NULL AND @DosTo IS NULL
		THEN 1 ELSE 0 END;

	-- ── LIS dimension filter via LIMSMaster ─────────────────────────────────────
	--    When Panel / Clinic / Provider filter is active, OR a DOS / FirstBilledDate
	--    range is set, re-aggregate LIS rows live from dbo.LIMSMaster (filtered)
	--    instead of the pre-built aggregate tables.
	--    DateofService   → LIMSMaster.RequestCollectDate
	--    FirstBilledDate → LIMSMaster.AMDLBD — mixed content: real dates, the
	--      literal text 'Not Entered in AMD', and blanks. TRY_CAST(... AS DATE)
	--      returns NULL for the latter two, so those rows are excluded from
	--      billed-date filtering/period bucketing automatically — no special-
	--      casing of the text value is needed.
	--    SalesRep is not available for RisingTides LIS — always skipped.
	-- ────────────────────────────────────────────────────────────────────────────
	DECLARE @HasLisFilter BIT = CASE
		WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
		  OR @DosFrom IS NOT NULL OR @DosTo IS NOT NULL
		  OR @UseBilledDate = 1
		THEN 1 ELSE 0 END;

	-- #LisBase: mirrors #Lis2 in usp_RefreshRT_ExecutiveSummary_LIS_Alt (file 29).
	-- Populated from LIMSMaster when @HasLisFilter = 1; empty otherwise.
	DROP TABLE IF EXISTS #LisBase;
	CREATE TABLE #LisBase
	(
		Accession     NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		ESYear        INT           NOT NULL,
		ESMonth       INT           NOT NULL,
		ResultedNot   NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
		ClientStatus  NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		BilledNot     NVARCHAR(20)  COLLATE DATABASE_DEFAULT NOT NULL,
		BillingStatus NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		ClaimStatus   NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		OrderStatus   NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		PaymentMethod NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		SampleStatus  NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		PanelName     NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL
	);

	DECLARE @LisMasterFiltered BIT = 0;   -- 1 when #LisBase was populated from LIMSMaster

	IF @HasLisFilter = 1 AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
	BEGIN
		-- Auto-detect dimension columns on dbo.LIMSMaster.
		-- Panel column: same candidate list / priority as usp_RefreshRT_ExecutiveSummary_LIS_Alt.
		DECLARE @LisPanelCatCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName',
			               'Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
			ORDER BY CASE name
				WHEN 'PanelCategory'   THEN 0 WHEN 'PanelName'      THEN 1 WHEN 'Panelname'      THEN 2
				WHEN 'TestPanelName'   THEN 3 WHEN 'TestPanelname'  THEN 4 WHEN 'TestPanel'      THEN 5
				WHEN 'Panel'           THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'      THEN 8 ELSE 9 END);

		DECLARE @LisFacilityCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('Facility','FacilityName','ClinicName','Clinic','FacilityID')
			ORDER BY CASE name
				WHEN 'Facility'     THEN 0 WHEN 'FacilityName' THEN 1
				WHEN 'ClinicName'   THEN 2 WHEN 'Clinic'       THEN 3 WHEN 'FacilityID' THEN 4 ELSE 5 END);

		DECLARE @LisProviderCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('Provider','PhysicianName','ProviderName','ReferringProvider','ReferringPhysician')
			ORDER BY CASE name
				WHEN 'Provider'           THEN 0 WHEN 'PhysicianName'     THEN 1
				WHEN 'ProviderName'       THEN 2 WHEN 'ReferringProvider' THEN 3
				WHEN 'ReferringPhysician' THEN 4 ELSE 5 END);

		-- FirstBilledDate: RisingTides' LIMSMaster billed-date column is AMDLBD
		-- (fixed name, confirmed present) — mixed date/text/blank content, handled
		-- via TRY_CAST at point of use (see @LisPeriodExpr below).
		DECLARE @LisBilledDateCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'AMDLBD');

		-- Only proceed when each active filter dimension has a matching column.
		IF (@HasPanelFilter    = 0 OR @LisPanelCatCol  IS NOT NULL)
		   AND (@HasClinicFilter   = 0 OR @LisFacilityCol  IS NOT NULL)
		   AND (@HasProviderFilter = 0 OR @LisProviderCol  IS NOT NULL)
		BEGIN
			DECLARE @LisPanelExpr NVARCHAR(400) = ISNULL(
				'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisPanelCatCol + ']), '''')))', '''''');

			-- LIS period basis:
			--   DOS mode (default)   → TRY_CAST(RequestCollectDate AS DATE)
			--   FirstBilledDate mode → TRY_CAST([AMDLBD] AS DATE) — TRY_CAST returns NULL
			--     for the non-date content ('Not Entered in AMD' text, blanks), and the
			--     WHERE clause below requires the period expression to be NOT NULL, so
			--     those rows are naturally excluded rather than mis-parsed.
			DECLARE @LisPeriodExpr NVARCHAR(200) =
				CASE WHEN @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
					 THEN N'TRY_CAST([' + @LisBilledDateCol + N'] AS DATE)'
					 ELSE N'TRY_CAST(RequestCollectDate AS DATE)' END;

			-- Build base SELECT from LIMSMaster.
			DECLARE @LisBaseSql NVARCHAR(MAX) = N'
			INSERT INTO #LisBase
			       (Accession, ESYear, ESMonth, ResultedNot, ClientStatus, BilledNot,
			        BillingStatus, ClaimStatus, OrderStatus, PaymentMethod, SampleStatus, PanelName)
			SELECT
			    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), Accession), ''''))),
			    YEAR (' + @LisPeriodExpr + N'),
			    MONTH(' + @LisPeriodExpr + N'),
			    LTRIM(RTRIM(ISNULL(RessultedStatus, ''''))),
			    LTRIM(RTRIM(ISNULL(ClientStatus,    ''''))),
			    LEFT(LTRIM(RTRIM(ISNULL(BilledorNot, ''''))), 20),
			    LTRIM(RTRIM(ISNULL(BillingStatus,   ''''))),
			    LTRIM(RTRIM(ISNULL(ClaimStatus,     ''''))),
			    LTRIM(RTRIM(ISNULL(OrderStatus,     ''''))),
			    LTRIM(RTRIM(ISNULL(PaymentMethod,   ''''))),
			    LTRIM(RTRIM(ISNULL(SampleStatus,    ''''))),
			    ' + @LisPanelExpr + N'
			FROM dbo.LIMSMaster
			WHERE ' + @LisPeriodExpr + N' IS NOT NULL
			  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '''') IS NOT NULL';

			-- Date predicates: DOS mode filters/bounds on RequestCollectDate;
			-- FirstBilledDate mode filters/bounds on AMDLBD (TRY_CAST — invalid/blank
			-- values already excluded by the period-basis WHERE clause above).
			IF @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
				SET @LisBaseSql += N'
			  AND (@iBilledFrom IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) >= @iBilledFrom)
			  AND (@iBilledTo   IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) <= @iBilledTo)';
			ELSE
				SET @LisBaseSql += N'
			  AND (@iDosFrom IS NULL OR TRY_CAST(RequestCollectDate AS DATE) >= @iDosFrom)
			  AND (@iDosTo   IS NULL OR TRY_CAST(RequestCollectDate AS DATE) <= @iDosTo)';

			-- Append dimension predicates (COLLATE DATABASE_DEFAULT prevents collation conflicts).
			IF @HasPanelFilter = 1 AND @LisPanelCatCol IS NOT NULL
				SET @LisBaseSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisPanelCatCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iPanels + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasClinicFilter = 1 AND @LisFacilityCol IS NOT NULL
				SET @LisBaseSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisFacilityCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iClinics + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasProviderFilter = 1 AND @LisProviderCol IS NOT NULL
				SET @LisBaseSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @LisProviderCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iProviders + '','') COLLATE DATABASE_DEFAULT) > 0';

			SET @LisBaseSql += N';';

			EXEC sp_executesql @LisBaseSql,
				N'@iPanels NVARCHAR(MAX), @iClinics NVARCHAR(MAX), @iProviders NVARCHAR(MAX),
				  @iDosFrom DATE, @iDosTo DATE, @iBilledFrom DATE, @iBilledTo DATE',
				@iPanels = @Panels, @iClinics = @Clinics, @iProviders = @Providers,
				@iDosFrom = @DosFrom, @iDosTo = @DosTo, @iBilledFrom = @BilledFrom, @iBilledTo = @BilledTo;

			SET @LisMasterFiltered = 1;
		END
	END

	-- #LisPeriods: distinct (ESYear,ESMonth) from filtered LIMSMaster + (0,0) sentinel.
	-- Only meaningful when @LisMasterFiltered = 1; left empty otherwise.
	DROP TABLE IF EXISTS #LisPeriods;
	CREATE TABLE #LisPeriods (ESYear INT NOT NULL, ESMonth INT NOT NULL);

	-- #LisPanels: distinct panel names for L_A.<PanelName> sub-rows.
	DROP TABLE IF EXISTS #LisPanels;
	CREATE TABLE #LisPanels (PanelName NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);

	IF @LisMasterFiltered = 1
	BEGIN
		INSERT INTO #LisPeriods (ESYear, ESMonth)
		SELECT DISTINCT ESYear, ESMonth FROM #LisBase
		UNION ALL SELECT 0, 0;

		INSERT INTO #LisPanels (PanelName)
		SELECT DISTINCT PanelName FROM #LisBase WHERE ResultedNot = 'Resulted' AND PanelName <> '';
	END

	-- #LisOut: final LIS rows (RowCode / Description / period / MetricValue).
	-- Populated either from live #LisBase aggregation (filtered) or aggregate tables (unfiltered).
	DROP TABLE IF EXISTS #LisOut;
	CREATE TABLE #LisOut
	(
		RowCode     NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,  -- widened: panel sub-rows = 'L_A.' + PanelName (up to 300 chars)
		Description NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
		ESYear      INT           NOT NULL,
		ESMonth     INT           NOT NULL,
		MetricValue DECIMAL(18,2) NOT NULL
	);

	IF @LisMasterFiltered = 1
	BEGIN
		-- Live aggregation from #LisBase - same row logic as
		-- usp_RefreshRT_ExecutiveSummary_LIS_Alt (script 38, the authoritative source).
		;WITH LisCounts AS
		(
			SELECT p.ESYear, p.ESMonth,
			       SUM(CASE WHEN l.Accession IS NOT NULL THEN 1 ELSE 0 END) AS L_0,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' THEN 1 ELSE 0 END) AS L_A,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
			                 AND l.ClientStatus <> 'Test Entries' THEN 1 ELSE 0 END) AS L_A1,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
			                 AND l.ClientStatus <> 'Test Entries' THEN 1 ELSE 0 END) AS L_A1a,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.ClientStatus IN ('Billing Review Required', '')
			                 AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill') THEN 1 ELSE 0 END) AS L_A2,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.ClientStatus IN ('Billing Review Required', '')
			                 AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
			                 AND l.SampleStatus = 'Received' THEN 1 ELSE 0 END) AS L_A2a,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.ClientStatus = 'Billing Review Required'
			                 AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill') THEN 1 ELSE 0 END) AS L_A2b,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.ClientStatus IN ('Billing Review Required', '')
			                 AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
			                 AND l.SampleStatus = 'Transferred' THEN 1 ELSE 0 END) AS L_A2c,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.ClientStatus IN ('Billing Review Required', '')
			                 AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
			                 AND l.SampleStatus = 'Collected' THEN 1 ELSE 0 END) AS L_A2d,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClientStatus = '' AND l.BilledNot = 'Unbilled'
			                 AND l.ClaimStatus = 'Entered' THEN 1 ELSE 0 END) AS L_A3,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Client Bill'
			                 AND l.BillingStatus IN ('Billed','Ready to Bill') THEN 1 ELSE 0 END) AS L_A4,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Client Bill'
			                 AND l.BillingStatus IN ('Billed','Ready to Bill')
			                 AND l.ClaimStatus = 'Not Entered in AMD' THEN 1 ELSE 0 END) AS L_A4a,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Client Bill'
			                 AND l.BillingStatus <> 'No Bill' AND l.ClaimStatus = 'Billed' THEN 1 ELSE 0 END) AS L_A4b,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Entered'
			                 AND l.BilledNot = 'Unbilled' AND l.ClientStatus = 'Client Bill' THEN 1 ELSE 0 END) AS L_A4c,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Self Pay'
			                 AND l.BillingStatus <> 'No Bill' THEN 1 ELSE 0 END) AS L_A5,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
			                 AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
			                 AND l.ClientStatus = 'Self Pay' AND l.BillingStatus IN ('Billed','Not Ready To Bill') THEN 1 ELSE 0 END) AS L_A5a,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.BillingStatus <> 'No Bill'
			                 AND l.ClaimStatus = 'Not Entered in AMD' AND l.ClientStatus = 'Self Pay' THEN 1 ELSE 0 END) AS L_A5b,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Entered'
			                 AND l.BillingStatus <> 'No Bill' AND l.ClientStatus = 'Self Pay' THEN 1 ELSE 0 END) AS L_A5c,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.BillingStatus <> 'No Bill'
			                 AND l.ClientStatus = 'Test Entries' THEN 1 ELSE 0 END) AS L_A6,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.BillingStatus <> 'No Bill' AND l.ClientStatus = 'Test Entries' THEN 1 ELSE 0 END) AS L_A6a,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Test Entries'
			                 AND l.BillingStatus <> 'No Bill' AND l.ClaimStatus = 'Billed' THEN 1 ELSE 0 END) AS L_A6b,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Test Entries'
			                 AND l.BillingStatus <> 'No Bill' AND l.ClaimStatus = 'Entered' THEN 1 ELSE 0 END) AS L_A6c,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill' THEN 1 ELSE 0 END) AS L_A7,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
			                 AND l.OrderStatus = 'Rejected' THEN 1 ELSE 0 END) AS L_A7a,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
			                 AND l.OrderStatus = 'Completed' THEN 1 ELSE 0 END) AS L_A7b,
			       SUM(CASE WHEN l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
			                 AND l.OrderStatus = 'Recollect Required' THEN 1 ELSE 0 END) AS L_A7c,
			       SUM(CASE WHEN l.ResultedNot = 'Not Resulted' THEN 1 ELSE 0 END) AS L_B,
			       SUM(CASE WHEN l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.ClientStatus = '' THEN 1 ELSE 0 END) AS L_B1,
			       SUM(CASE WHEN l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.ClientStatus = '' AND l.SampleStatus = 'Collected' THEN 1 ELSE 0 END) AS L_B1a,
			       SUM(CASE WHEN l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.ClientStatus = '' AND l.SampleStatus = 'Received' THEN 1 ELSE 0 END) AS L_B1b,
			       SUM(CASE WHEN l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.ClientStatus = '' AND l.SampleStatus = 'In Transit' THEN 1 ELSE 0 END) AS L_B1c,
			       SUM(CASE WHEN l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			                 AND l.SampleStatus = 'Rejected' THEN 1 ELSE 0 END) AS L_B2,
			       SUM(CASE WHEN l.ResultedNot = 'Not Resulted' AND l.ClientStatus = 'Test Entries' THEN 1 ELSE 0 END) AS L_B3,
			       SUM(CASE WHEN l.ResultedNot = 'Not Resulted' AND l.ClientStatus = 'Self Pay' THEN 1 ELSE 0 END) AS L_B4
			FROM #LisPeriods p
			LEFT JOIN #LisBase l
			       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
			GROUP BY p.ESYear, p.ESMonth
		)
		INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
		SELECT v.RowCode, v.Description, c.ESYear, c.ESMonth, CAST(v.SampleCount AS DECIMAL(18,2))
		FROM LisCounts c
		CROSS APPLY (VALUES
			('L_0',   'Total Samples',                 c.L_0),
			('L_A',   'Billable Samples - Resulted',   c.L_A),
			('L_A1',  'Billed to Insurance',           c.L_A1),
			('L_A1a', '  Billed In AMD',               c.L_A1a),
			('L_A2',  'Not Entered in AMD',            c.L_A2),
			('L_A2a', '  Received',                    c.L_A2a),
			('L_A2b', '  Billing Review Required',     c.L_A2b),
			('L_A2c', '  Transferred',                 c.L_A2c),
			('L_A2d', '  Collected',                   c.L_A2d),
			('L_A3',  'Unbilled',                      c.L_A3),
			('L_A4',  'Client Bill',                   c.L_A4),
			('L_A4a', '  Not Entered in AMD',          c.L_A4a),
			('L_A4b', '  Billed',                      c.L_A4b),
			('L_A4c', '  Entered',                     c.L_A4c),
			('L_A5',  'Self Pay',                      c.L_A5),
			('L_A5a', '  Billed',                      c.L_A5a),
			('L_A5b', '  Not Entered in AMD',          c.L_A5b),
			('L_A5c', '  Entered',                     c.L_A5c),
			('L_A6',  'Test Entries',                  c.L_A6),
			('L_A6a', '  Not Entered in AMD',          c.L_A6a),
			('L_A6b', '  Billed',                      c.L_A6b),
			('L_A6c', '  Entered',                     c.L_A6c),
			('L_A7',  'Billing Status - No Bill',      c.L_A7),
			('L_A7a', '  Rejected',                    c.L_A7a),
			('L_A7b', '  Completed',                   c.L_A7b),
			('L_A7c', '  Recollect Required',          c.L_A7c),
			('L_B',   'Not Resulted',                  c.L_B),
			('L_B1',  'Not Entered in AMD',            c.L_B1),
			('L_B1a', '  Collected',                   c.L_B1a),
			('L_B1b', '  Received',                    c.L_B1b),
			('L_B1c', '  In Transit',                  c.L_B1c),
			('L_B2',  'Rejected Sample',               c.L_B2),
			('L_B3',  'Test Entries',                  c.L_B3),
			('L_B4',  '  Self Pay',                    c.L_B4)
		) AS v (RowCode, Description, SampleCount);

		-- L_A.<PanelName> sub-rows (panel-wise breakdown of "Billable Samples - Resulted").
		INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
		SELECT 'L_A.' + pn.PanelName, '    ' + pn.PanelName,
		       p.ESYear, p.ESMonth, CAST(COUNT(DISTINCT l.Accession) AS DECIMAL(18,2))
		FROM #LisPanels pn
		CROSS JOIN #LisPeriods p
		LEFT JOIN #LisBase l
		       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
		      AND l.ResultedNot = 'Resulted'
		      AND l.PanelName COLLATE DATABASE_DEFAULT = pn.PanelName COLLATE DATABASE_DEFAULT
		GROUP BY pn.PanelName, p.ESYear, p.ESMonth;
	END
	ELSE
	BEGIN
		-- No LIS dimension filter: serve from pre-built aggregate tables filtered by period.
		INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
		SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
		FROM dbo.RT_ES_LIS
		WHERE (ESYear=0 AND ESMonth=0)
		   OR ( (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
			AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
			AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
			AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo))

		UNION ALL
		SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
		FROM dbo.RT_ES_LIS_Panel
		WHERE (ESYear=0 AND ESMonth=0)
		   OR ( (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
			AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
			AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
			AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo));
	END

	DROP TABLE IF EXISTS #Base;
	CREATE TABLE #Base
	(
		VisitNumber          NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		ESYear               INT           NOT NULL,
		ESMonth              INT           NOT NULL,
		BilledUnbilled       NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
		ClaimStatus          NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		ChargeAmount         DECIMAL(18,2) NOT NULL,
		InsurancePayment     DECIMAL(18,2) NOT NULL,
		PatientPayment       DECIMAL(18,2) NOT NULL,
		InsuranceAdjustments DECIMAL(18,2) NOT NULL,
		PatientAdjustments   DECIMAL(18,2) NOT NULL,
		InsuranceBalance     DECIMAL(18,2) NOT NULL,
		PatientBalance       DECIMAL(18,2) NOT NULL
	);

	-- PMS/Cash/Avg period basis now follows the same DOS vs FirstBilledDate mode as
	-- LIS (@UseBilledDate, declared earlier). Previously ESYear/ESMonth were ALWAYS
	-- derived from DateofService even when filtering by FirstBilledDate — rows that
	-- matched the FirstBilledDate WHERE bound still got bucketed under their
	-- (unrelated) DOS year/month, so a Billed-mode filter could show prior-year
	-- columns under a "DATA BASED ON BILLED DATE" header. Fixed by branching the
	-- period expression (and the date WHERE bound) on @UseBilledDate, same as Cove/
	-- Elixir's #Base construction.
	IF @UseBilledDate = 0
	BEGIN
		INSERT INTO #Base (VisitNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
		                    ChargeAmount, InsurancePayment, PatientPayment,
		                    InsuranceAdjustments, PatientAdjustments,
		                    InsuranceBalance, PatientBalance)
		SELECT
			LTRIM(RTRIM(ISNULL(ClaimID, ''))),
			YEAR (TRY_CAST(DateofService AS DATE)),
			MONTH(TRY_CAST(DateofService AS DATE)),
			LTRIM(RTRIM(ISNULL(BilledUnbilled, ''))),
			LTRIM(RTRIM(ISNULL(ClaimStatus,    ''))),
			ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0)
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
		  AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
		  AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
		  AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
		  AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
		  AND (@DosFrom   IS NULL OR TRY_CAST(DateofService AS DATE) >= @DosFrom)
		  AND (@DosTo     IS NULL OR TRY_CAST(DateofService AS DATE) <= @DosTo)
		  AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(PanelName,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps + ',') COLLATE DATABASE_DEFAULT) > 0);
	END
	ELSE  -- @UseBilledDate = 1 : period + filter on FirstBilledDate
	BEGIN
		INSERT INTO #Base (VisitNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
		                    ChargeAmount, InsurancePayment, PatientPayment,
		                    InsuranceAdjustments, PatientAdjustments,
		                    InsuranceBalance, PatientBalance)
		SELECT
			LTRIM(RTRIM(ISNULL(ClaimID, ''))),
			YEAR (TRY_CAST(FirstBilledDate AS DATE)),
			MONTH(TRY_CAST(FirstBilledDate AS DATE)),
			LTRIM(RTRIM(ISNULL(BilledUnbilled, ''))),
			LTRIM(RTRIM(ISNULL(ClaimStatus,    ''))),
			ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0)
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
		  AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
		  AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
		  AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(PanelName,         ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
		  AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps + ',') COLLATE DATABASE_DEFAULT) > 0)
		OPTION (RECOMPILE);
	END

	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	DROP TABLE IF EXISTS #EsOut;
	CREATE TABLE #EsOut
	(
		Category    NVARCHAR(10)  COLLATE DATABASE_DEFAULT NOT NULL,
		RowCode     NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
		Description NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
		ESYear      INT           NOT NULL,
		ESMonth     INT           NOT NULL,
		MetricValue DECIMAL(18,2) NOT NULL
	);

	;WITH PMS AS
	(
		SELECT p.ESYear,p.ESMonth,'O' AS RowCode,'Billed - Includes all Claims Billed in AMD' AS Description,
			   COUNT(DISTINCT b.VisitNumber) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b
		  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		 AND b.BilledUnbilled='Billed'
		GROUP BY p.ESYear,p.ESMonth

		-- P is calculated in the "Derived rows" section below, once LIS / PMS / Cash are complete.
		UNION ALL SELECT p.ESYear,p.ESMonth,'P','Billed Mismatches - Non Diagnose LIS Samples', 0
			FROM #Periods p

		UNION ALL SELECT p.ESYear,p.ESMonth,'Q','Unbilled - Entered in AMD - Yet to be released to Payer',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Unbilled'
			GROUP BY p.ESYear,p.ESMonth

		--UNION ALL SELECT p.ESYear,p.ESMonth,'R','Paid - Client',
		--	COUNT(DISTINCT b.VisitNumber)
		--	FROM #Periods p LEFT JOIN #Base b
		--	  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		--	 AND b.ClaimStatus='Client Paid'
		--	GROUP BY p.ESYear,p.ESMonth

		-- R = ClientPaidListData SpecimenID count, matched on BeginDOS year/month
		UNION ALL SELECT p.ESYear,p.ESMonth,'R','Paid - Client',
			COUNT(DISTINCT LTRIM(RTRIM(c.SpecimenID)))
			FROM #Periods p LEFT JOIN dbo.ClientPaidListData c
			  ON NULLIF(LTRIM(RTRIM(c.SpecimenID)), '') IS NOT NULL
			 AND (p.ESYear=0 OR (YEAR (TRY_CAST(c.BeginDOS AS DATE))=p.ESYear
							 AND MONTH(TRY_CAST(c.BeginDOS AS DATE))=p.ESMonth))
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

		UNION ALL SELECT p.ESYear,p.ESMonth,'W','Patient Payment',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Patient Payment'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'X','Insurance Balance',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied','Partially Adjusted')
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'X1','  Fully Denied',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Denied'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'X2','  No Response',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus='No Response'
			GROUP BY p.ESYear,p.ESMonth

		UNION ALL SELECT p.ESYear,p.ESMonth,'X3','  Partially Denied',
			COUNT(DISTINCT b.VisitNumber)
			FROM #Periods p LEFT JOIN #Base b
			  ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Partially Denied','Partially Adjusted')
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
			 AND b.BilledUnbilled='Billed' GROUP BY p.ESYear,p.ESMonth

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
			 AND b.BilledUnbilled='Billed' AND b.ClaimStatus NOT IN ('Fully Denied','No Response') GROUP BY p.ESYear,p.ESMonth
	)
	INSERT INTO #EsOut (Category, RowCode, Description, ESYear, ESMonth, MetricValue)
	SELECT 'PMS', RowCode, Description, ESYear, ESMonth, CAST(MetricValue AS DECIMAL(18,2)) FROM PMS
	UNION ALL
	SELECT 'Cash', RowCode, Description, ESYear, ESMonth, CAST(MetricValue AS DECIMAL(18,2)) FROM Cash;

	-- ───────────────────────────────────────────────────────────────────────
	--  Derived rows – calculated after LIS (#LisOut), PMS and Cash (#EsOut) are
	--  complete. Same rules as dbo.usp_RT_ES_RefreshDerivedRows (stored path).
	-- ───────────────────────────────────────────────────────────────────────

	-- P  Billed Mismatches - Non Diagnose LIS Samples
	--    = MAX(PMS O - (LIS L_A1 Billed to Insurance + L_A4b Client Bill Billed
	--                   + L_A5a Self Pay Billed), 0)
	;WITH LisBilledM AS
	(
		SELECT ESYear, ESMonth, SUM(MetricValue) AS Cnt
		FROM #LisOut
		WHERE RowCode IN ('L_A1','L_A4b','L_A5a') AND ESYear <> 0 AND ESMonth <> 0
		GROUP BY ESYear, ESMonth
	),
	LisBilled AS
	(
		SELECT ESYear, ESMonth, Cnt FROM LisBilledM
		UNION ALL SELECT 0, 0, ISNULL(SUM(Cnt), 0) FROM LisBilledM
	)
	UPDATE p
	SET p.MetricValue = CASE WHEN o.MetricValue - ISNULL(lb.Cnt, 0) > 0
	                         THEN o.MetricValue - ISNULL(lb.Cnt, 0) ELSE 0 END
	FROM #EsOut p
	INNER JOIN #EsOut o
		ON o.Category = 'PMS' AND o.RowCode = 'O'
	   AND o.ESYear = p.ESYear AND o.ESMonth = p.ESMonth
	LEFT JOIN LisBilled lb
		ON lb.ESYear = p.ESYear AND lb.ESMonth = p.ESMonth
	WHERE p.Category = 'PMS' AND p.RowCode = 'P';

	-- Average Payment Per Claim
	--   Total Pay = Cash Z + AA + AB
	--   AH  = Total Pay / PMS O                           (Billed claims)
	--   AI1 = Total Pay / PMS S + V + W                   (Paid claims)
	--   AJ  = Total Pay / PMS S + T + U + V + W + X1 + X3 (Adjudicated claims)
	--   Year (Y,0) and Grand Total (0,0) = SUM(monthly numerator) / SUM(monthly denominator).
	;WITH AvgMonth AS
	(
		SELECT ESYear, ESMonth,
			SUM(CASE WHEN Category = 'Cash' AND RowCode IN ('Z','AA','AB') THEN MetricValue ELSE 0 END) AS TotalPay,
			SUM(CASE WHEN Category = 'PMS'  AND RowCode = 'O' THEN MetricValue ELSE 0 END)             AS BilledCnt,
			SUM(CASE WHEN Category = 'PMS'  AND RowCode IN ('S','V','W') THEN MetricValue ELSE 0 END)   AS PaidCnt,
			SUM(CASE WHEN Category = 'PMS'  AND RowCode IN ('S','T','U','V','W','X1','X3') THEN MetricValue ELSE 0 END) AS AdjCnt
		FROM #EsOut
		WHERE ESYear <> 0 AND ESMonth <> 0
		GROUP BY ESYear, ESMonth
	),
	AvgPeriod AS
	(
		SELECT ESYear, ESMonth, TotalPay, BilledCnt, PaidCnt, AdjCnt FROM AvgMonth
		UNION ALL
		SELECT ESYear, 0, SUM(TotalPay), SUM(BilledCnt), SUM(PaidCnt), SUM(AdjCnt) FROM AvgMonth GROUP BY ESYear
		UNION ALL
		SELECT 0, 0, ISNULL(SUM(TotalPay), 0), ISNULL(SUM(BilledCnt), 0), ISNULL(SUM(PaidCnt), 0), ISNULL(SUM(AdjCnt), 0) FROM AvgMonth
	)
	INSERT INTO #EsOut (Category, RowCode, Description, ESYear, ESMonth, MetricValue)
	SELECT 'Avg', 'AH', 'Average Payment ($) - Total Pay/Billed Claims', ESYear, ESMonth,
		   CASE WHEN BilledCnt = 0 THEN 0 ELSE TotalPay / BilledCnt END
	FROM AvgPeriod
	UNION ALL
	SELECT 'Avg', 'AI1', 'Average Payment ($) - Total Pay/Paid Claims', ESYear, ESMonth,
		   CASE WHEN PaidCnt = 0 THEN 0 ELSE TotalPay / PaidCnt END
	FROM AvgPeriod
	UNION ALL
	SELECT 'Avg', 'AJ', 'Average Payment ($) - Total Pay/Adjudicated Claims', ESYear, ESMonth,
		   CASE WHEN AdjCnt = 0 THEN 0 ELSE TotalPay / AdjCnt END
	FROM AvgPeriod;

	SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
	FROM
	(
		-- LIS rows — populated from #LisOut (either live #LisBase aggregation when
		-- a dimension filter is active, or pre-built aggregate tables otherwise).
		SELECT RowCode, 'LIS' AS Category, Description,
			   ESYear AS BillYear, ESMonth AS BillMonth, MetricValue
		FROM #LisOut

		UNION ALL
		SELECT RowCode, Category, Description, ESYear, ESMonth, MetricValue
		FROM #EsOut
	) all_rows
	ORDER BY BillYear, BillMonth, RowCode;

	DROP TABLE IF EXISTS #EsOut;

	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #LisBase;
	DROP TABLE IF EXISTS #LisPeriods;
	DROP TABLE IF EXISTS #LisPanels;
	DROP TABLE IF EXISTS #LisOut;
END;
GO

/* Drill-down definitions (Year / Grand Total links) for the changed and new rows.
   The drill compares LTRIM(RTRIM(ISNULL(col,''))), so Val = N'' means "blank". */
DELETE FROM dbo.LisDrillRowDef
WHERE LabPrefix = N'RT' AND ISNULL(Source, N'LIS') = N'LIS'
  AND RowCode IN (N'L_A1', N'L_A1a', N'L_A6b', N'L_A6c', N'L_B1c');

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4)
VALUES
 (N'RT', N'L_A1', N'Billed to Insurance', N'RequestCollectDate', N'LIS',
     N'RessultedStatus',N'=',N'Resulted', N'PaymentMethod',N'=',N'Insurance',
     N'ClaimStatus',N'=',N'Billed', N'ClientStatus',N'<>',N'Test Entries'),
 (N'RT', N'L_A1a', N'Billed In AMD', N'RequestCollectDate', N'LIS',
     N'RessultedStatus',N'=',N'Resulted', N'PaymentMethod',N'=',N'Insurance',
     N'ClaimStatus',N'=',N'Billed', N'ClientStatus',N'<>',N'Test Entries'),
 (N'RT', N'L_A6b', N'Test Entries - Billed', N'RequestCollectDate', N'LIS',
     N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Test Entries',
     N'BillingStatus',N'<>',N'No Bill', N'ClaimStatus',N'=',N'Billed'),
 (N'RT', N'L_A6c', N'Test Entries - Entered', N'RequestCollectDate', N'LIS',
     N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Test Entries',
     N'BillingStatus',N'<>',N'No Bill', N'ClaimStatus',N'=',N'Entered'),
 (N'RT', N'L_B1c', N'Not Entered in AMD - In Transit', N'RequestCollectDate', N'LIS',
     N'RessultedStatus',N'=',N'Not Resulted', N'ClaimStatus',N'=',N'Not Entered in AMD',
     N'ClientStatus',N'=',N'', N'SampleStatus',N'=',N'In Transit');
GO

-- Rebuild the stored LIS rows now (also refreshes the derived row P, which uses L_A1).
EXEC dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt;
GO

-- Check: changed / new rows, Grand Total column
SELECT RoleID, Description, SortOrder, ESMonthClaimCount
FROM dbo.RT_ES_LIS
WHERE ESYear = 0 AND ESMonth = 0
  AND RoleID IN ('L_A1','L_A1a','L_A6','L_A6a','L_A6b','L_A6c','L_B1','L_B1a','L_B1b','L_B1c')
ORDER BY SortOrder;
GO