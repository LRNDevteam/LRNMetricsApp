-- ============================================================
-- NorthWest – Executive Summary PMS / Cash / Avg Aggregate SP
-- File : 30_NW_ExecutiveSummary_Aggregate.sql
-- DB   : NorthWest_LRN
--
-- Owns and TRUNCATEs NW_ES_PMS, NW_ES_Cash, NW_ES_Avg.
-- NW_ES_LIS is owned by 33_NW_ExecutiveSummary_LIS_Alt.sql.
--
-- Source: dbo.ClaimLevelData, period bucket = DateofService.
-- NorthWest-specific columns in ClaimLevelData:
--   Billed      – 'Billed' | 'Unbilled' | 'Billed - Client' | ''
--   ClaimType   – 'Claim Submitted in Webpm' | 'Claim Submitted in Daqbilling'
--                 | 'Manually Pushed in Emedix' | 'ADCS - Invoice' | 'Test Patient Entries'
--   ActualPayment    – insurance actual payment (optional column)
--   DuplicatePayment – duplicate payment (optional column)
--
-- PMS rows: G, G.1-G.3, H, H.1-H.5, I (billed mismatch), J, K,
--           M, N, O, P, Q, R, S, S.1, S.1.A1/A2/AP, S.2, S.3, S.3.A1/A2/AP
-- Cash rows: T, T.1-T.3, U, U.1-U.4, V, W, X, X.1, X.2, Y, Z,
--            AA, AA.1, AA.2, AB, AC, AC.1, AC.1.A1/A2/AP, AC.2, AC.3, AC.3.A1/A2/AP
-- Avg rows : AD, AE, AF
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.NW_ES_PMS;
    TRUNCATE TABLE dbo.NW_ES_Cash;
    TRUNCATE TABLE dbo.NW_ES_Avg;

    -- ── Dynamic column detection ─────────────────────────────────────────────
    -- Detect 'Billed' column (NW) vs 'BillStatus' / 'BillingStatus' (other labs)
    DECLARE @BilledCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('Billed','BillStatus','BillingStatus','BilledStatus')
        ORDER BY CASE name WHEN 'Billed' THEN 0 WHEN 'BillStatus' THEN 1
                           WHEN 'BillingStatus' THEN 2 WHEN 'BilledStatus' THEN 3 ELSE 4 END);

    DECLARE @ClaimTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('ClaimType','ClaimCategory','ClaimTypeCode')
        ORDER BY CASE name WHEN 'ClaimType' THEN 0 WHEN 'ClaimCategory' THEN 1 WHEN 'ClaimTypeCode' THEN 2 ELSE 3 END);

    DECLARE @ActualPayCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('ActualPayment','ActualPay','Actual_Payment')
        ORDER BY CASE name WHEN 'ActualPayment' THEN 0 WHEN 'ActualPay' THEN 1 WHEN 'Actual_Payment' THEN 2 ELSE 3 END);

    DECLARE @DupPayCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('DuplicatePayment','DuplicatePay','Duplicate_Payment')
        ORDER BY CASE name WHEN 'DuplicatePayment' THEN 0 WHEN 'DuplicatePay' THEN 1 WHEN 'Duplicate_Payment' THEN 2 ELSE 3 END);

    IF @BilledCol IS NULL OR @ClaimTypeCol IS NULL
    BEGIN
        PRINT 'usp_RefreshNW_ExecutiveSummary: required columns (Billed/ClaimType) not found on dbo.ClaimLevelData – skipping.';
        RETURN;
    END

    -- ── #Base : ClaimLevelData with NW-specific columns ──────────────────────
    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        AccessionNumber   NVARCHAR(100)  NOT NULL,
        ESYear            INT            NOT NULL,
        ESMonth           INT            NOT NULL,
        Billed            NVARCHAR(50)   NOT NULL,
        ClaimType         NVARCHAR(200)  NOT NULL,
        ClaimStatus       NVARCHAR(200)  NOT NULL,
        ChargeAmount      DECIMAL(18,2)  NOT NULL,
        InsurancePayment  DECIMAL(18,2)  NOT NULL,
        ActualPayment     DECIMAL(18,2)  NOT NULL,
        DuplicatePayment  DECIMAL(18,2)  NOT NULL,
        PatientPayment    DECIMAL(18,2)  NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceBalance  DECIMAL(18,2)  NOT NULL,
        PatientBalance    DECIMAL(18,2)  NOT NULL
    );

    DECLARE @ActExpr NVARCHAR(300) = CASE WHEN @ActualPayCol IS NOT NULL
        THEN N'ISNULL(TRY_CAST([' + @ActualPayCol + N'] AS DECIMAL(18,2)),0)'
        ELSE N'0' END;
    DECLARE @DupExpr NVARCHAR(300) = CASE WHEN @DupPayCol IS NOT NULL
        THEN N'ISNULL(TRY_CAST([' + @DupPayCol + N'] AS DECIMAL(18,2)),0)'
        ELSE N'0' END;

    DECLARE @BaseSql NVARCHAR(MAX) = N'
        INSERT INTO #Base
        SELECT
            LTRIM(RTRIM(ISNULL(AccessionNumber,''''))) AS AccessionNumber,
            YEAR (TRY_CAST(DateofService AS DATE)),
            MONTH(TRY_CAST(DateofService AS DATE)),
            ISNULL(LTRIM(RTRIM([' + @BilledCol    + N'])),'''') AS Billed,
            ISNULL(LTRIM(RTRIM([' + @ClaimTypeCol + N'])),'''') AS ClaimType,
            ISNULL(LTRIM(RTRIM(ClaimStatus)),'''') AS ClaimStatus,
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)),0),
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)),0),
            ' + @ActExpr + N',
            ' + @DupExpr + N',
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)),0),
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)),0),
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)),0),
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)),0),
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)),0)
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(ISNULL(AccessionNumber,''''))),'''') IS NOT NULL;';
    EXEC sp_executesql @BaseSql;

    -- ── #Periods ─────────────────────────────────────────────────────────────
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
    UNION ALL SELECT 0, 0;

    -- ── #LisBilled : LIMSMaster billed count per period (for Row I) ──────────
    DROP TABLE IF EXISTS #LisBilled;
    CREATE TABLE #LisBilled (ESYear INT NOT NULL, ESMonth INT NOT NULL, BilledCount INT NOT NULL DEFAULT 0);

    IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
    BEGIN
        DECLARE @LisAccCol2 SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('OrderID','OrderId','AccessionNumber','Accession','AccessionNo')
            ORDER BY CASE name WHEN 'OrderID' THEN 0 WHEN 'OrderId' THEN 1 WHEN 'AccessionNumber' THEN 2 WHEN 'Accession' THEN 3 ELSE 4 END);

        DECLARE @LisDateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ReqCollectDate','Entry_DateCreated','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'ReqCollectDate' THEN 0 WHEN 'Entry_DateCreated' THEN 1 WHEN 'RequestCollectDate' THEN 2
                WHEN 'DateOfCollection' THEN 3 WHEN 'DateofService' THEN 4
                WHEN 'CollectionDate' THEN 5 WHEN 'ServiceDate' THEN 6 WHEN 'AccessionDate' THEN 7 ELSE 8 END);

        DECLARE @LisBillStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillStatus','BillingStatus','Bill_Status')
            ORDER BY CASE name WHEN 'BillStatus' THEN 0 WHEN 'BillingStatus' THEN 1 WHEN 'Bill_Status' THEN 2 ELSE 3 END);

        IF @LisAccCol2 IS NOT NULL AND @LisDateCol IS NOT NULL AND @LisBillStatusCol IS NOT NULL
        BEGIN
            DECLARE @LisSql2 NVARCHAR(MAX) = N'
                INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
                SELECT YEAR(TRY_CAST([' + @LisDateCol + N'] AS DATE)),
                       MONTH(TRY_CAST([' + @LisDateCol + N'] AS DATE)),
                       COUNT(DISTINCT [' + @LisAccCol2 + N'])
                FROM dbo.LIMSMaster
                WHERE [' + @LisBillStatusCol + N'] = ''Billed''
                  AND TRY_CAST([' + @LisDateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),[' + @LisAccCol2 + N']))),'''') IS NOT NULL
                GROUP BY YEAR(TRY_CAST([' + @LisDateCol + N'] AS DATE)),
                         MONTH(TRY_CAST([' + @LisDateCol + N'] AS DATE));

                INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
                SELECT 0, 0, COUNT(DISTINCT [' + @LisAccCol2 + N'])
                FROM dbo.LIMSMaster
                WHERE [' + @LisBillStatusCol + N'] = ''Billed''
                  AND TRY_CAST([' + @LisDateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),[' + @LisAccCol2 + N']))),'''') IS NOT NULL;';
            EXEC sp_executesql @LisSql2;
        END
    END

    -- helper: ADCS + Test Patient types to exclude from standard claim counts
    -- G, M-S, T, X, Y, Z, AA, AB, AC filter: ClaimType NOT IN these two values
    -- H filter: ISNULL(Billed,'') IN ('','Unbilled')

    -- ════════════════════════════════════════════════════════════════════════
    --  NW_ES_PMS
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO dbo.NW_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- G  No. of Billed Claims
        SELECT p.ESYear, p.ESMonth, 'G' AS RoleID, 'No. of Billed Claims' AS Description,
               COUNT(DISTINCT CASE WHEN b.Billed='Billed'
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- G.1  Claim Submitted in Webpm
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G.1', '  Claim Submitted in Webpm',
               COUNT(DISTINCT CASE WHEN b.Billed='Billed' AND b.ClaimType='Claim Submitted in Webpm'
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- G.2  Claim Submitted in Daqbilling
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G.2', '  Claim Submitted in Daqbilling',
               COUNT(DISTINCT CASE WHEN b.Billed='Billed' AND b.ClaimType='Claim Submitted in Daqbilling'
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- G.3  Manually Pushed in Emedix
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G.3', '  Manually Pushed in Emedix',
               COUNT(DISTINCT CASE WHEN b.Billed='Billed' AND b.ClaimType='Manually Pushed in Emedix'
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H  No. of Unbilled Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'No. of Unbilled Claims',
               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.1  Unbilled in Webpm PR
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.1', '  Unbilled in Webpm PR',
               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Unbilled in Webpm PR' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.2  Unbilled in Webpm
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.2', '  Unbilled in Webpm',
               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Unbilled in Webpm' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.3  Unbilled in Daq
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.3', '  Unbilled in Daq',
               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Unbilled in Daq' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.4  Unbilled in Daq - PR
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.4', '  Unbilled in Daq - PR',
               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Unbilled in Daq - PR' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.5  Billed amount 0
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.5', '  Billed amount 0',
               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Billed Amount 0' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- I  Billed Mismatches (G count - LIMSMaster billed count)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'Billed Mismatches - Other samples billed / LIS Accessions NA',
               COUNT(DISTINCT CASE WHEN b.Billed='Billed'
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
               - ISNULL((SELECT lb.BilledCount FROM #LisBilled lb WHERE lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- J  Test Patient Entries
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'Test Patient Entries',
               COUNT(DISTINCT CASE WHEN b.ClaimType='Test Patient Entries' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- K  ADCS Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'ADCS Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType='ADCS - Invoice' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- M  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Fully Paid Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Fully Paid' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Fully Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Fully Patient Responsibility Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Pat Responsibility' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- O  No. of Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Adjusted/Written Off Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Fully Adjusted' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P  No. of Partially Adjusted Claim
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P', 'No. of Partially Adjusted Claim',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Partially Adjusted' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q', 'No. of Partially Paid Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Partially Paid' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- R  No. of Patient Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'No. of Patient Paid Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Patient Paid' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S', 'No. of Insurance Balance Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response') THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S.1  No. of Fully Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S.1', '  No. of Fully Denied Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Fully Denied' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S.1.A1/A2/AP  ARIA placeholders
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.1.A1', '    Aria Submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.1.A2', '    Aria not submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.1.AP', '    % of the claim submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth

        -- S.2  No. of Partially Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S.2', '  No. of Partially Denied Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Partially Denied' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S.3  No. of No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S.3', '  No. of No Response from Payor',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='No Response' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S.3.A1/A2/AP  ARIA placeholders
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.3.A1', '    Claim filed by ARIA in the last 30 days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.3.A2', '    Claims not filed in the last 30 days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.3.AP', '    % of the claim submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
    ) pms;

    -- ════════════════════════════════════════════════════════════════════════
    --  NW_ES_Cash
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO dbo.NW_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, 0, Amount, GETDATE()
    FROM
    (
        -- T  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'T' AS RoleID, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END) AS Amount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T.1', '  Claim Submitted in Webpm',
               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType='Claim Submitted in Webpm'
                         AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T.2', '  Claim Submitted in Daqbilling',
               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType='Claim Submitted in Daqbilling'
                         AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T.3', '  Manually Pushed in Emedix',
               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType='Manually Pushed in Emedix'
                         AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U  Total Unbilled ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Total Unbilled ($)',
               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.1', '  Unbilled in Webpm PR',
               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Unbilled in Webpm PR' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.2', '  Unbilled in Webpm',
               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Unbilled in Webpm' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.3', '  Unbilled in Daq',
               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Unbilled in Daq' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.4', '  Unbilled in Daq - PR',
               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Unbilled in Daq - PR' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- V  Test Patients Entries ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Test Patients Entries ($)',
               SUM(CASE WHEN b.ClaimType='Test Patient Entries' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W  ADCS Claims ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'ADCS Claims ($)',
               SUM(CASE WHEN b.ClaimType='ADCS - Invoice' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X  Insurance Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X', 'Insurance Payment ($)',
               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Fully Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.1  Actual Payments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.1', '  Actual Payments ($)',
               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Fully Paid' THEN b.ActualPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.2  Duplicate Payments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.2', '  Duplicate Payments ($)',
               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Fully Paid' THEN b.DuplicatePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Y  Patient Responsibility ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Y', 'Patient Responsibility ($)',
               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z  Adjustments / Write Off ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z', 'Adjustments / Write Off ($)',
               SUM(CASE WHEN b.Billed='Billed'
                         AND b.ClaimType IN ('Claim Submitted in Webpm','Claim Submitted in Daqbilling')
                         THEN b.InsuranceAdjustments + b.PatientAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AA  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AA', 'Partially Paid ($)',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Partially Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AA.1  Actual Payments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AA.1', '  Actual Payments ($)',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Partially Paid' THEN b.ActualPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AA.2  Duplicate Payments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AA.2', '  Duplicate Payments ($)',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Partially Paid' THEN b.DuplicatePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AB  Patient Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AB', 'Patient Paid ($)',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         THEN b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AC  Insurance Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AC', 'Insurance Balance ($)',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AC.1  Denials
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AC.1', '  Denials',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='Fully Denied' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AC.1 ARIA placeholders
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.1.A1', '    Claim filed by ARIA in the last 30 days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.1.A2', '    Claims not filed in the last 30 days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.1.AP', '    % of the claim submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth

        -- AC.2  Partially Denied (placeholder - 0 per spec)
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.2', '  Partially Denied', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth

        -- AC.3  No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AC.3', '  No Response from Payor',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='No Response' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AC.3 ARIA placeholders
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.3.A1', '    Claim filed by ARIA in the last 30 days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.3.A2', '    Claims not filed in the last 30 days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.3.AP', '    % of the claim submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
    ) cash;

    -- ════════════════════════════════════════════════════════════════════════
    --  NW_ES_Avg  (AD, AE, AF)
    --  AD = Total Pay / Billed Claims
    --  AE = Total Pay / Paid Claims
    --  AF = Total Pay / Adjudicated Claims
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO dbo.NW_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    FROM
    (
        -- AD  Average Payment ($) - Total Pay/Billed Claims
        SELECT p.ESYear, p.ESMonth, 'AD' AS RoleID,
               'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               COUNT(DISTINCT CASE WHEN b.Billed='Billed'
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END) AS ClaimCount,
               SUM(CASE WHEN b.Billed='Billed'
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus<>'Billed Amount 0'
                         THEN b.InsurancePayment + b.PatientPayment ELSE 0 END) AS PayTotal
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AE  Average Payment Per Claim (Total Pay / Paid Claims)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AE',
               'Average Payment Per Claim',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Patient Paid') THEN b.AccessionNumber END),
               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Patient Paid')
                         THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AF  Average Payment ($) - Total Pay/Adjudicated Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AF',
               'Average Payment ($) - Total Pay/Adjudicated Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus IN ('Fully Paid','Fully Adjusted','Fully Denied','Partially Denied') THEN b.AccessionNumber END),
               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus IN ('Fully Paid','Partially Paid')
                         THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) avgrows;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;

    PRINT 'usp_RefreshNW_ExecutiveSummary completed.';
END;
GO

PRINT '30_NW_ExecutiveSummary_Aggregate.sql completed.';
GO
