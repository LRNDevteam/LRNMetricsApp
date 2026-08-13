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
    -- Detect 'Billed' column (NW) vs 'BillStatus' / 'BillingStatus' (other labs).
    -- If none found, BilledStatus is DERIVED from FirstBillDate / EmedixSubmissionDate:
    --   FirstBillDate is not blank  → 'Billed'
    --   EmedixSubmissionDate is not blank → 'Billed'
    --   both blank                  → 'Unbilled'
    DECLARE @BilledCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('Billed','BillStatus','BillingStatus','BilledStatus')
        ORDER BY CASE name WHEN 'Billed' THEN 0 WHEN 'BillStatus' THEN 1
                           WHEN 'BillingStatus' THEN 2 WHEN 'BilledStatus' THEN 3 ELSE 4 END);

    -- Fallback date columns used to derive Billed status when @BilledCol IS NULL
    DECLARE @FirstBillDateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('FirstBillDate','FirstBilledDate','First_Bill_Date','FirstBilled')
        ORDER BY CASE name WHEN 'FirstBillDate' THEN 0 WHEN 'FirstBilledDate' THEN 1
                           WHEN 'First_Bill_Date' THEN 2 ELSE 3 END);

    -- ARIA "last 30 days" uses Last Billed Date when present; else FirstBilledDate.
    DECLARE @LastBillDateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('LastBillDate','LastBilledDate','Last_Bill_Date','LastBilled','LastBill')
        ORDER BY CASE name
            WHEN 'LastBillDate' THEN 0 WHEN 'LastBilledDate' THEN 1
            WHEN 'Last_Bill_Date' THEN 2 WHEN 'LastBilled' THEN 3 ELSE 4 END);

    DECLARE @EmedixSubDateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('EmedixSubmissionDate','EmedixSubmitDate','Emedix_Submission_Date','EmedixDate')
        ORDER BY CASE name WHEN 'EmedixSubmissionDate' THEN 0 WHEN 'EmedixSubmitDate' THEN 1
                           WHEN 'Emedix_Submission_Date' THEN 2 ELSE 3 END);

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
          AND name IN ('DuplicatePaymentPosted','DuplicatePay','Duplicate_Payment')
        ORDER BY CASE name WHEN 'DuplicatePaymentPosted' THEN 0 WHEN 'DuplicatePay' THEN 1 WHEN 'Duplicate_Payment' THEN 2 ELSE 3 END);

    -- Build the Billed expression for @BaseSql.
    -- NW: BilledStatus column exists but is NOT populated — skip it.
    -- Derive 'Billed'/'Unbilled' from FirstBilledDate / EmedixSubmissionDate.
    --   FirstBilledDate non-empty  → 'Billed'
    --   EmedixSubmissionDate non-empty → 'Billed'
    --   both empty/null            → 'Unbilled'
    -- BilledStatus / BillStatus column kept only as last-resort fallback.
    -- Output values are always 'Billed' or 'Unbilled'.
    DECLARE @BilledExpr NVARCHAR(MAX) =
        CASE
            -- Priority 1: derive from date columns (BilledStatus is blank for NW)
            --WHEN @BilledCol IS NOT NULL
            --    THEN N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')'
            WHEN @FirstBillDateCol IS NOT NULL OR @EmedixSubDateCol IS NOT NULL
                THEN
                    N'CASE'
                    + CASE WHEN @FirstBillDateCol IS NOT NULL
                           THEN N' WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50),[' + @FirstBillDateCol + N']),''''))),'''') IS NOT NULL THEN ''Billed'''
                           ELSE N'' END
                    + CASE WHEN @EmedixSubDateCol IS NOT NULL
                           THEN N' WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50),[' + @EmedixSubDateCol + N']),''''))),'''') IS NOT NULL THEN ''Billed'''
                           ELSE N'' END
                    + N' ELSE ''Unbilled'' END'
            -- Priority 2: BilledStatus / Billed column (only if no date columns found)
            WHEN @BilledCol IS NOT NULL
                THEN N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')'
            ELSE NULL
        END;

    IF @BilledExpr IS NULL OR @ClaimTypeCol IS NULL
    BEGIN
        PRINT 'usp_RefreshNW_ExecutiveSummary: required columns (Billed/ClaimType or FirstBillDate/EmedixSubmissionDate) not found on dbo.ClaimLevelData – skipping.';
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
        FirstBilledDate   DATE           NULL,
        LastBilledDate    DATE           NULL,
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

    -- FirstBilledDate: used to derive Billed/Unbilled when needed.
    DECLARE @FBDExpr NVARCHAR(300) = CASE WHEN @FirstBillDateCol IS NOT NULL
        THEN N'TRY_CAST([' + @FirstBillDateCol + N'] AS DATE)'
        ELSE N'CAST(NULL AS DATE)' END;

    -- LastBilledDate: ARIA "submitted in last 30 days" age basis (spec).
    -- Falls back to FirstBilledDate when Last* column is not on ClaimLevelData.
    DECLARE @LBDExpr NVARCHAR(300) =
        CASE
            WHEN @LastBillDateCol IS NOT NULL
                THEN N'TRY_CAST([' + @LastBillDateCol + N'] AS DATE)'
            WHEN @FirstBillDateCol IS NOT NULL
                THEN N'TRY_CAST([' + @FirstBillDateCol + N'] AS DATE)'
            ELSE N'CAST(NULL AS DATE)'
        END;

    DECLARE @BaseSql NVARCHAR(MAX) = N'
        INSERT INTO #Base
        SELECT
            LTRIM(RTRIM(ISNULL(AccessionNumber,''''))) AS AccessionNumber,
            YEAR (TRY_CAST(DateofService AS DATE)),
            MONTH(TRY_CAST(DateofService AS DATE)),
            ' + @BilledExpr + N' AS Billed,
            ISNULL(LTRIM(RTRIM([' + @ClaimTypeCol + N'])),'''') AS ClaimType,
            ISNULL(LTRIM(RTRIM(ClaimStatus)),'''') AS ClaimStatus,
            ' + @FBDExpr + N' AS FirstBilledDate,
            ' + @LBDExpr + N' AS LastBilledDate,
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

    -- ── ARIA "submitted / not submitted in the last 30 days" ─────────────────
    -- Spec (DOS cohort + Max FirstBilledDate — do NOT invent calendar AsOf):
    --   1) Choose DateOfService month (column) → that DOS cohort only
    --      (missing DOS days are fine; filter by YEAR/MONTH, not a date range)
    --   2) AsOf = MAX(FirstBilledDate) within that cohort (status-specific)
    --      e.g. July DOS Fully Denied → Max FirstBill = 2026-07-06
    --   3) Submitted     = same cohort AND FirstBilledDate age 0..30 vs AsOf
    --   4) Not submitted = same cohort EXCLUDING the 30-day window
    --      (NULL FirstBilled OR age NOT BETWEEN 0 AND 30)
    --   5) Submitted + NotSubmitted = parent count (S.1 Fully Denied / S.3 No Response)
    --   % = Submitted / NotSubmitted (ratio)
    -- Cash: same window + Billed + SUM(InsuranceBalance).
    --
    -- Separate AsOf per status: Fully Denied vs No Response may differ.
    IF OBJECT_ID('tempdb..#AriaWindow_FD') IS NOT NULL DROP TABLE #AriaWindow_FD;
    IF OBJECT_ID('tempdb..#AriaWindow_NR') IS NOT NULL DROP TABLE #AriaWindow_NR;

    SELECT
        p.ESYear, p.ESMonth,
        AsOfDate = (
            SELECT MAX(b.FirstBilledDate)
            FROM #Base b
            WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
              AND b.ClaimStatus = 'Fully Denied'
              AND b.FirstBilledDate IS NOT NULL
              AND (p.ESYear = 0 OR (b.ESYear = p.ESYear AND (p.ESMonth = 0 OR b.ESMonth = p.ESMonth)))
        )
    INTO #AriaWindow_FD
    FROM #Periods p;

    SELECT
        p.ESYear, p.ESMonth,
        AsOfDate = (
            SELECT MAX(b.FirstBilledDate)
            FROM #Base b
            WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
              AND b.ClaimStatus = 'No Response'
              AND b.FirstBilledDate IS NOT NULL
              AND (p.ESYear = 0 OR (b.ESYear = p.ESYear AND (p.ESMonth = 0 OR b.ESMonth = p.ESMonth)))
        )
    INTO #AriaWindow_NR
    FROM #Periods p;

    -- Keep #PeriodWindow alias for print/diag (Fully Denied AsOf)
    IF OBJECT_ID('tempdb..#PeriodWindow') IS NOT NULL DROP TABLE #PeriodWindow;
    SELECT ESYear, ESMonth, AsOfDate INTO #PeriodWindow FROM #AriaWindow_FD;

    PRINT 'ARIA AsOf = MAX(FirstBilledDate) per DOS period (Fully Denied / No Response separate):';
    SELECT TOP 20
        fd.ESYear, fd.ESMonth,
        FullyDeniedAsOf = fd.AsOfDate,
        NoResponseAsOf  = nr.AsOfDate,
        WindowStart_FD  = CASE WHEN fd.AsOfDate IS NOT NULL THEN DATEADD(DAY, -30, fd.AsOfDate) END
    FROM #AriaWindow_FD fd
    JOIN #AriaWindow_NR nr ON nr.ESYear = fd.ESYear AND nr.ESMonth = fd.ESMonth
    ORDER BY fd.ESYear, fd.ESMonth;

    -- S.1/S.3 (PMS) and AC.1/AC.3 (Cash) A1/A2/AP rows are inserted as
    -- placeholder 0 below and filled by UPDATE blocks using #AriaWindow_FD / _NR
    -- (AsOf = MAX(FirstBilledDate) within each DOS-month status cohort).

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
               COUNT(CASE WHEN b.Billed='Billed'
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- G.1  Claim Submitted in Webpm
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G.1', '  Claim Submitted in Webpm',
               COUNT( CASE WHEN b.Billed='Billed' AND b.ClaimType='Claim Submitted in Webpm'
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- G.2  Claim Submitted in Daqbilling
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G.2', '  Claim Submitted in Daqbilling',
               COUNT( CASE WHEN b.Billed='Billed' AND b.ClaimType in ('Claim Submitted in Daqbilling','Claim submitted in Daq Billing')
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- G.3  Manually Pushed in Emedix
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G.3', '  Manually Pushed in Emedix',
               COUNT( CASE WHEN b.Billed='Billed' AND b.ClaimType='Manually Pushed in Emedix'
                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H  No. of Unbilled Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'No. of Unbilled Claims',
               COUNT( CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.1  Unbilled in Webpm PR
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.1', '  Unbilled in Webpm PR',
               COUNT( CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus in ('Unbilled in Webpm PR','Unbilled in Webpm - PR') THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.2  Unbilled in Webpm
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.2', '  Unbilled in Webpm',
               COUNT( CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Unbilled in Webpm'  THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.3  Unbilled in Daq
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.3', '  Unbilled in Daq',
               COUNT( CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Unbilled in Daq' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.4  Unbilled in Daq - PR
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.4', '  Unbilled in Daq - PR',
               COUNT( CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Unbilled in Daq - PR' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- H.5  Billed amount 0
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.5', '  Billed amount 0',
               COUNT( CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Billed Amount 0' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- I  Billed Mismatches (G count - LIMSMaster billed count)

		-- I  Billed Mismatches (G count - LIS "Total No. of Samples", NW_ES_LIS RoleID='A')
			
        -- I  Billed Mismatches (LIS "Total No. of Samples", NW_ES_LIS RoleID='A' - G count)
			UNION ALL
			SELECT p.ESYear, p.ESMonth, 'I', 'Billed Mismatches - Other samples billed / LIS Accessions NA',
				   ISNULL((SELECT lis.ESMonthClaimCount FROM dbo.NW_ES_LIS lis
							WHERE lis.RoleID='A' AND lis.ESYear=p.ESYear AND lis.ESMonth=p.ESMonth), 0)
				   - COUNT( CASE WHEN b.Billed='Billed'
									   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
									   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
			FROM #Periods p
			LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
			GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        --SELECT p.ESYear, p.ESMonth, 'I', 'Billed Mismatches - Other samples billed / LIS Accessions NA',
        --       COUNT( CASE WHEN b.Billed='Billed'
        --                           AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
        --                           AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
        --       - ISNULL((SELECT lb.BilledCount FROM #LisBilled lb WHERE lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth), 0)
        --FROM #Periods p
        --LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        --GROUP BY p.ESYear, p.ESMonth

        -- J  Test Patient Entries
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'Test Patient Entries',
               COUNT( CASE WHEN b.ClaimType='Test Patient Entries' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- K  ADCS Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'ADCS Claims',
               COUNT( CASE WHEN b.ClaimType='ADCS - Invoice' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- M  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Fully Paid Claims',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Fully Paid' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Fully Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Fully Patient Responsibility Claims',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Pat Responsibility' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- O  No. of Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Adjusted/Written Off Claims',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Fully Adjusted' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P  No. of Partially Adjusted Claim
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P', 'No. of Partially Adjusted Claim',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Partially Adjusted' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q', 'No. of Partially Paid Claims',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus in ('Partially Paid','Partial Paid','Partial Paid') THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- R  No. of Patient Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'No. of Patient Paid Claims',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Patient Paid' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S', 'No. of Insurance Balance Claims',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response') THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S.1  No. of Fully Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S.1', '  No. of Fully Denied Claims',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Fully Denied' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S.1.A1/A2/AP  ARIA — placeholder 0; computed per-period by the UPDATE
        -- block after this INSERT finishes (see #PeriodWindow above).
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.1.A1', '    Aria Submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.1.A2', '    Aria not submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.1.AP', '    % of the claim submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth

        -- S.2  No. of Partially Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S.2', '  No. of Partially Denied Claims',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='Partially Denied' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S.3  No. of No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S.3', '  No. of No Response from Payor',
               COUNT( CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                                   AND b.ClaimStatus='No Response' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S.3.A1/A2/AP  ARIA — placeholder 0; computed per-period by the UPDATE
        -- block after this INSERT finishes (see #PeriodWindow above).
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.3.A1', '    Claim filed by ARIA in the last 30 days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.3.A2', '    Claims not filed in the last 30 days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.3.AP', '    % of the claim submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
    ) pms;
	   -- Row I ("Billed Mismatches") is computed AFTER NW_ES_PMS is fully populated,
	   -- per spec: Row I = NW_ES_PMS.G (No. of Billed Claims) - NW_ES_LIS.A (Total
	   -- No. of Samples), matched per ESYear/ESMonth. A straight two-table UPDATE
	   -- here (rather than a correlated subquery inside the UNION ALL above) is
	   -- what was requested to fix the earlier wrong values.
	   UPDATE i
	   SET i.ESMonthClaimCount = ISNULL(g.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0)
	   FROM dbo.NW_ES_PMS i
	   INNER JOIN dbo.NW_ES_PMS g ON g.RoleID = 'G' AND g.ESYear = i.ESYear AND g.ESMonth = i.ESMonth
	   LEFT JOIN dbo.NW_ES_LIS lis ON lis.RoleID = 'C' AND lis.ESYear = i.ESYear AND lis.ESMonth = i.ESMonth
	   WHERE i.RoleID = 'I';

    -- ── S.1.A1/A2 — Fully Denied, DOS-month cohort, Max(FirstBilledDate) AsOf ──
    -- Submitted + NotSubmitted = S.1 (Fully Denied) for that DOS period.
    UPDATE t
    SET t.ESMonthClaimCount = (
        SELECT COUNT(b.AccessionNumber) FROM #Base b
        WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'Fully Denied'
          AND (t.ESYear = 0 OR (b.ESYear = t.ESYear AND (t.ESMonth = 0 OR b.ESMonth = t.ESMonth)))
          AND w.AsOfDate IS NOT NULL
          AND b.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30)
    FROM dbo.NW_ES_PMS t
    JOIN #AriaWindow_FD w ON w.ESYear = t.ESYear AND w.ESMonth = t.ESMonth
    WHERE t.RoleID = 'S.1.A1';

    UPDATE t
    SET t.ESMonthClaimCount = (
        SELECT COUNT(b.AccessionNumber) FROM #Base b
        WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'Fully Denied'
          AND (t.ESYear = 0 OR (b.ESYear = t.ESYear AND (t.ESMonth = 0 OR b.ESMonth = t.ESMonth)))
          AND (w.AsOfDate IS NULL
               OR b.FirstBilledDate IS NULL
               OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30))
    FROM dbo.NW_ES_PMS t
    JOIN #AriaWindow_FD w ON w.ESYear = t.ESYear AND w.ESMonth = t.ESMonth
    WHERE t.RoleID = 'S.1.A2';

    -- S.1.AP — Filed / NotFiled (ratio). Client UI shows e.g. 0.1409 = 13406/95147.
    UPDATE ap
    SET ap.ESMonthChargeAmount = CASE WHEN ISNULL(a2.ESMonthClaimCount,0) > 0
            THEN CAST(a1.ESMonthClaimCount AS DECIMAL(18,4)) / a2.ESMonthClaimCount ELSE 0 END
    FROM dbo.NW_ES_PMS ap
    JOIN dbo.NW_ES_PMS a1 ON a1.RoleID = 'S.1.A1' AND a1.ESYear = ap.ESYear AND a1.ESMonth = ap.ESMonth
    JOIN dbo.NW_ES_PMS a2 ON a2.RoleID = 'S.1.A2' AND a2.ESYear = ap.ESYear AND a2.ESMonth = ap.ESMonth
    WHERE ap.RoleID = 'S.1.AP';

    -- ── S.3.A1/A2 — No Response, same DOS-cohort + Max(FirstBilledDate) rule ──
    UPDATE t
    SET t.ESMonthClaimCount = (
        SELECT COUNT(b.AccessionNumber) FROM #Base b
        WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'No Response'
          AND (t.ESYear = 0 OR (b.ESYear = t.ESYear AND (t.ESMonth = 0 OR b.ESMonth = t.ESMonth)))
          AND w.AsOfDate IS NOT NULL
          AND b.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30)
    FROM dbo.NW_ES_PMS t
    JOIN #AriaWindow_NR w ON w.ESYear = t.ESYear AND w.ESMonth = t.ESMonth
    WHERE t.RoleID = 'S.3.A1';

    UPDATE t
    SET t.ESMonthClaimCount = (
        SELECT COUNT(b.AccessionNumber) FROM #Base b
        WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'No Response'
          AND (t.ESYear = 0 OR (b.ESYear = t.ESYear AND (t.ESMonth = 0 OR b.ESMonth = t.ESMonth)))
          AND (w.AsOfDate IS NULL
               OR b.FirstBilledDate IS NULL
               OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30))
    FROM dbo.NW_ES_PMS t
    JOIN #AriaWindow_NR w ON w.ESYear = t.ESYear AND w.ESMonth = t.ESMonth
    WHERE t.RoleID = 'S.3.A2';

    UPDATE ap
    SET ap.ESMonthChargeAmount = CASE WHEN ISNULL(a2.ESMonthClaimCount,0) > 0
            THEN CAST(a1.ESMonthClaimCount AS DECIMAL(18,4)) / a2.ESMonthClaimCount ELSE 0 END
    FROM dbo.NW_ES_PMS ap
    JOIN dbo.NW_ES_PMS a1 ON a1.RoleID = 'S.3.A1' AND a1.ESYear = ap.ESYear AND a1.ESMonth = ap.ESMonth
    JOIN dbo.NW_ES_PMS a2 ON a2.RoleID = 'S.3.A2' AND a2.ESYear = ap.ESYear AND a2.ESMonth = ap.ESMonth
    WHERE ap.RoleID = 'S.3.AP';

    -- ── Aria year sentinels (ESMonth=0) — DOS year cohort, Max FirstBilled in year ──
    IF OBJECT_ID('tempdb..#AriaYearWindow_FD') IS NOT NULL DROP TABLE #AriaYearWindow_FD;
    IF OBJECT_ID('tempdb..#AriaYearWindow_NR') IS NOT NULL DROP TABLE #AriaYearWindow_NR;

    SELECT DISTINCT
        b.ESYear,
        AsOfDate = (
            SELECT MAX(x.FirstBilledDate)
            FROM #Base x
            WHERE x.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
              AND x.ClaimStatus = 'Fully Denied'
              AND x.FirstBilledDate IS NOT NULL
              AND x.ESYear = b.ESYear
        )
    INTO #AriaYearWindow_FD
    FROM #Base b
    WHERE b.ESYear <> 0;

    SELECT DISTINCT
        b.ESYear,
        AsOfDate = (
            SELECT MAX(x.FirstBilledDate)
            FROM #Base x
            WHERE x.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
              AND x.ClaimStatus = 'No Response'
              AND x.FirstBilledDate IS NOT NULL
              AND x.ESYear = b.ESYear
        )
    INTO #AriaYearWindow_NR
    FROM #Base b
    WHERE b.ESYear <> 0;

    -- Compat alias used by Cash year block below
    IF OBJECT_ID('tempdb..#AriaYearWindow') IS NOT NULL DROP TABLE #AriaYearWindow;
    SELECT ESYear, AsOfDate INTO #AriaYearWindow FROM #AriaYearWindow_FD;

    INSERT INTO dbo.NW_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT v.RoleID, v.Description, y.ESYear, 0, 0, 0, GETDATE()
    FROM #AriaYearWindow_FD y
    CROSS JOIN (VALUES
        ('S.1.A1', N'    Aria Submitted in the last 30 Days'),
        ('S.1.A2', N'    Aria not submitted in the last 30 Days'),
        ('S.1.AP', N'    % of the claim submitted in the last 30 Days'),
        ('S.3.A1', N'    Claim filed by ARIA in the last 30 days'),
        ('S.3.A2', N'    Claims not filed in the last 30 days'),
        ('S.3.AP', N'    % of the claim submitted in the last 30 Days')
    ) v(RoleID, Description);

    UPDATE t
    SET t.ESMonthClaimCount = (
        SELECT COUNT(b.AccessionNumber) FROM #Base b
        WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'Fully Denied'
          AND b.ESYear = t.ESYear
          AND w.AsOfDate IS NOT NULL
          AND b.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30)
    FROM dbo.NW_ES_PMS t
    JOIN #AriaYearWindow_FD w ON w.ESYear = t.ESYear
    WHERE t.RoleID = 'S.1.A1' AND t.ESMonth = 0;

    UPDATE t
    SET t.ESMonthClaimCount = (
        SELECT COUNT(b.AccessionNumber) FROM #Base b
        WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'Fully Denied'
          AND b.ESYear = t.ESYear
          AND (w.AsOfDate IS NULL
               OR b.FirstBilledDate IS NULL
               OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30))
    FROM dbo.NW_ES_PMS t
    JOIN #AriaYearWindow_FD w ON w.ESYear = t.ESYear
    WHERE t.RoleID = 'S.1.A2' AND t.ESMonth = 0;

    UPDATE ap
    SET ap.ESMonthChargeAmount = CASE WHEN ISNULL(a2.ESMonthClaimCount,0) > 0
            THEN CAST(a1.ESMonthClaimCount AS DECIMAL(18,4)) / a2.ESMonthClaimCount ELSE 0 END
    FROM dbo.NW_ES_PMS ap
    JOIN dbo.NW_ES_PMS a1 ON a1.RoleID = 'S.1.A1' AND a1.ESYear = ap.ESYear AND a1.ESMonth = 0
    JOIN dbo.NW_ES_PMS a2 ON a2.RoleID = 'S.1.A2' AND a2.ESYear = ap.ESYear AND a2.ESMonth = 0
    WHERE ap.RoleID = 'S.1.AP' AND ap.ESMonth = 0;

    UPDATE t
    SET t.ESMonthClaimCount = (
        SELECT COUNT(b.AccessionNumber) FROM #Base b
        WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'No Response'
          AND b.ESYear = t.ESYear
          AND w.AsOfDate IS NOT NULL
          AND b.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30)
    FROM dbo.NW_ES_PMS t
    JOIN #AriaYearWindow_NR w ON w.ESYear = t.ESYear
    WHERE t.RoleID = 'S.3.A1' AND t.ESMonth = 0;

    UPDATE t
    SET t.ESMonthClaimCount = (
        SELECT COUNT(b.AccessionNumber) FROM #Base b
        WHERE b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'No Response'
          AND b.ESYear = t.ESYear
          AND (w.AsOfDate IS NULL
               OR b.FirstBilledDate IS NULL
               OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30))
    FROM dbo.NW_ES_PMS t
    JOIN #AriaYearWindow_NR w ON w.ESYear = t.ESYear
    WHERE t.RoleID = 'S.3.A2' AND t.ESMonth = 0;

    UPDATE ap
    SET ap.ESMonthChargeAmount = CASE WHEN ISNULL(a2.ESMonthClaimCount,0) > 0
            THEN CAST(a1.ESMonthClaimCount AS DECIMAL(18,4)) / a2.ESMonthClaimCount ELSE 0 END
    FROM dbo.NW_ES_PMS ap
    JOIN dbo.NW_ES_PMS a1 ON a1.RoleID = 'S.3.A1' AND a1.ESYear = ap.ESYear AND a1.ESMonth = 0
    JOIN dbo.NW_ES_PMS a2 ON a2.RoleID = 'S.3.A2' AND a2.ESYear = ap.ESYear AND a2.ESMonth = 0
    WHERE ap.RoleID = 'S.3.AP' AND ap.ESMonth = 0;

    PRINT 'ARIA #PeriodWindow sample (Fully Denied AsOf per DOS month):';
    SELECT TOP 20 ESYear, ESMonth, AsOfDate FROM #PeriodWindow ORDER BY ESYear, ESMonth;

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
               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType in ('Claim Submitted in Daqbilling','Claim submitted in Daq Billing')
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
                         AND b.ClaimStatus in ('Unbilled in Webpm PR','Unbilled in Webpm - PR') THEN b.ChargeAmount ELSE 0 END)
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
                         AND b.ClaimType IN ('Claim Submitted in Webpm','Claim Submitted in Daqbilling','Claim submitted in Daq Billing')
                         THEN b.InsuranceAdjustments + b.PatientAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AA  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AA', 'Partially Paid ($)',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus in ('Partially Paid','Partial Paid') THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AA.1  Actual Payments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AA.1', '  Actual Payments ($)',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus in ('Partially Paid','Partial Paid') THEN b.ActualPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AA.2  Duplicate Payments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AA.2', '  Duplicate Payments ($)',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus in ('Partially Paid','Partial Paid') THEN b.DuplicatePayment ELSE 0 END)
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

        -- AC.1 ARIA — SUM(InsuranceBalance), Fully Denied, LastBilled age <=/> 30 days
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.1.A1', '    Aria Submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.1.A2', '    Aria not submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.1.AP', '    % of the claim submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth

        -- AC.2  Partially Denied (placeholder - 0 per spec)
        --UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.2', '  Partially Denied', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth

		 UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.2', '  Partially Denied', 
			SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus in('Fully Denied','No Response') THEN b.InsuranceBalance ELSE 0 END)
						 FROM #Periods p
					LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
					GROUP BY p.ESYear, p.ESMonth
        -- AC.3  No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AC.3', '  No Response from Payor',
               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus='No Response' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AC.3 ARIA — SUM(InsuranceBalance), No Response, LastBilled age <=/> 30 days
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.3.A1', '    Aria Submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.3.A2', '    Aria not submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.3.AP', '    % of the claim submitted in the last 30 Days', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
    ) cash;

    -- ── AC.1.A1/A2 — Fully Denied Cash, DOS cohort + Max(FirstBilledDate) AsOf ──
    UPDATE t
    SET t.ESMonthChargeAmount = (
        SELECT ISNULL(SUM(b.InsuranceBalance),0) FROM #Base b
        WHERE b.Billed IN ('Billed','Billed - Client')
          AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'Fully Denied'
          AND (t.ESYear = 0 OR (b.ESYear = t.ESYear AND (t.ESMonth = 0 OR b.ESMonth = t.ESMonth)))
          AND w.AsOfDate IS NOT NULL
          AND b.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30)
    FROM dbo.NW_ES_Cash t
    JOIN #AriaWindow_FD w ON w.ESYear = t.ESYear AND w.ESMonth = t.ESMonth
    WHERE t.RoleID = 'AC.1.A1';

    UPDATE t
    SET t.ESMonthChargeAmount = (
        SELECT ISNULL(SUM(b.InsuranceBalance),0) FROM #Base b
        WHERE b.Billed IN ('Billed','Billed - Client')
          AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'Fully Denied'
          AND (t.ESYear = 0 OR (b.ESYear = t.ESYear AND (t.ESMonth = 0 OR b.ESMonth = t.ESMonth)))
          AND (w.AsOfDate IS NULL
               OR b.FirstBilledDate IS NULL
               OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30))
    FROM dbo.NW_ES_Cash t
    JOIN #AriaWindow_FD w ON w.ESYear = t.ESYear AND w.ESMonth = t.ESMonth
    WHERE t.RoleID = 'AC.1.A2';

    UPDATE ap
    SET ap.ESMonthChargeAmount = CASE WHEN ISNULL(a2.ESMonthChargeAmount,0) > 0
            THEN a1.ESMonthChargeAmount / a2.ESMonthChargeAmount ELSE 0 END
    FROM dbo.NW_ES_Cash ap
    JOIN dbo.NW_ES_Cash a1 ON a1.RoleID = 'AC.1.A1' AND a1.ESYear = ap.ESYear AND a1.ESMonth = ap.ESMonth
    JOIN dbo.NW_ES_Cash a2 ON a2.RoleID = 'AC.1.A2' AND a2.ESYear = ap.ESYear AND a2.ESMonth = ap.ESMonth
    WHERE ap.RoleID = 'AC.1.AP';

    -- ── AC.3.A1/A2 — No Response Cash, same DOS-cohort rule ──
    UPDATE t
    SET t.ESMonthChargeAmount = (
        SELECT ISNULL(SUM(b.InsuranceBalance),0) FROM #Base b
        WHERE b.Billed IN ('Billed','Billed - Client')
          AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'No Response'
          AND (t.ESYear = 0 OR (b.ESYear = t.ESYear AND (t.ESMonth = 0 OR b.ESMonth = t.ESMonth)))
          AND w.AsOfDate IS NOT NULL
          AND b.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30)
    FROM dbo.NW_ES_Cash t
    JOIN #AriaWindow_NR w ON w.ESYear = t.ESYear AND w.ESMonth = t.ESMonth
    WHERE t.RoleID = 'AC.3.A1';

    UPDATE t
    SET t.ESMonthChargeAmount = (
        SELECT ISNULL(SUM(b.InsuranceBalance),0) FROM #Base b
        WHERE b.Billed IN ('Billed','Billed - Client')
          AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'No Response'
          AND (t.ESYear = 0 OR (b.ESYear = t.ESYear AND (t.ESMonth = 0 OR b.ESMonth = t.ESMonth)))
          AND (w.AsOfDate IS NULL
               OR b.FirstBilledDate IS NULL
               OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30))
    FROM dbo.NW_ES_Cash t
    JOIN #AriaWindow_NR w ON w.ESYear = t.ESYear AND w.ESMonth = t.ESMonth
    WHERE t.RoleID = 'AC.3.A2';

    UPDATE ap
    SET ap.ESMonthChargeAmount = CASE WHEN ISNULL(a2.ESMonthChargeAmount,0) > 0
            THEN a1.ESMonthChargeAmount / a2.ESMonthChargeAmount ELSE 0 END
    FROM dbo.NW_ES_Cash ap
    JOIN dbo.NW_ES_Cash a1 ON a1.RoleID = 'AC.3.A1' AND a1.ESYear = ap.ESYear AND a1.ESMonth = ap.ESMonth
    JOIN dbo.NW_ES_Cash a2 ON a2.RoleID = 'AC.3.A2' AND a2.ESYear = ap.ESYear AND a2.ESMonth = ap.ESMonth
    WHERE ap.RoleID = 'AC.3.AP';

    -- Cash Aria year sentinels (ESMonth=0) — DOS year cohort
    INSERT INTO dbo.NW_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT v.RoleID, v.Description, y.ESYear, 0, 0, 0, GETDATE()
    FROM #AriaYearWindow_FD y
    CROSS JOIN (VALUES
        ('AC.1.A1', N'    Aria Submitted in the last 30 Days'),
        ('AC.1.A2', N'    Aria not submitted in the last 30 Days'),
        ('AC.1.AP', N'    % of the claim submitted in the last 30 Days'),
        ('AC.3.A1', N'    Aria Submitted in the last 30 Days'),
        ('AC.3.A2', N'    Aria not submitted in the last 30 Days'),
        ('AC.3.AP', N'    % of the claim submitted in the last 30 Days')
    ) v(RoleID, Description);

    UPDATE t
    SET t.ESMonthChargeAmount = (
        SELECT ISNULL(SUM(b.InsuranceBalance),0) FROM #Base b
        WHERE b.Billed IN ('Billed','Billed - Client')
          AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'Fully Denied'
          AND b.ESYear = t.ESYear
          AND w.AsOfDate IS NOT NULL
          AND b.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30)
    FROM dbo.NW_ES_Cash t
    JOIN #AriaYearWindow_FD w ON w.ESYear = t.ESYear
    WHERE t.RoleID = 'AC.1.A1' AND t.ESMonth = 0;

    UPDATE t
    SET t.ESMonthChargeAmount = (
        SELECT ISNULL(SUM(b.InsuranceBalance),0) FROM #Base b
        WHERE b.Billed IN ('Billed','Billed - Client')
          AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'Fully Denied'
          AND b.ESYear = t.ESYear
          AND (w.AsOfDate IS NULL
               OR b.FirstBilledDate IS NULL
               OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30))
    FROM dbo.NW_ES_Cash t
    JOIN #AriaYearWindow_FD w ON w.ESYear = t.ESYear
    WHERE t.RoleID = 'AC.1.A2' AND t.ESMonth = 0;

    UPDATE ap
    SET ap.ESMonthChargeAmount = CASE WHEN ISNULL(a2.ESMonthChargeAmount,0) > 0
            THEN a1.ESMonthChargeAmount / a2.ESMonthChargeAmount ELSE 0 END
    FROM dbo.NW_ES_Cash ap
    JOIN dbo.NW_ES_Cash a1 ON a1.RoleID = 'AC.1.A1' AND a1.ESYear = ap.ESYear AND a1.ESMonth = 0
    JOIN dbo.NW_ES_Cash a2 ON a2.RoleID = 'AC.1.A2' AND a2.ESYear = ap.ESYear AND a2.ESMonth = 0
    WHERE ap.RoleID = 'AC.1.AP' AND ap.ESMonth = 0;

    UPDATE t
    SET t.ESMonthChargeAmount = (
        SELECT ISNULL(SUM(b.InsuranceBalance),0) FROM #Base b
        WHERE b.Billed IN ('Billed','Billed - Client')
          AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'No Response'
          AND b.ESYear = t.ESYear
          AND w.AsOfDate IS NOT NULL
          AND b.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) BETWEEN 0 AND 30)
    FROM dbo.NW_ES_Cash t
    JOIN #AriaYearWindow_NR w ON w.ESYear = t.ESYear
    WHERE t.RoleID = 'AC.3.A1' AND t.ESMonth = 0;

    UPDATE t
    SET t.ESMonthChargeAmount = (
        SELECT ISNULL(SUM(b.InsuranceBalance),0) FROM #Base b
        WHERE b.Billed IN ('Billed','Billed - Client')
          AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
          AND b.ClaimStatus = 'No Response'
          AND b.ESYear = t.ESYear
          AND (w.AsOfDate IS NULL
               OR b.FirstBilledDate IS NULL
               OR DATEDIFF(DAY, b.FirstBilledDate, w.AsOfDate) NOT BETWEEN 0 AND 30))
    FROM dbo.NW_ES_Cash t
    JOIN #AriaYearWindow_NR w ON w.ESYear = t.ESYear
    WHERE t.RoleID = 'AC.3.A2' AND t.ESMonth = 0;

    UPDATE ap
    SET ap.ESMonthChargeAmount = CASE WHEN ISNULL(a2.ESMonthChargeAmount,0) > 0
            THEN a1.ESMonthChargeAmount / a2.ESMonthChargeAmount ELSE 0 END
    FROM dbo.NW_ES_Cash ap
    JOIN dbo.NW_ES_Cash a1 ON a1.RoleID = 'AC.3.A1' AND a1.ESYear = ap.ESYear AND a1.ESMonth = 0
    JOIN dbo.NW_ES_Cash a2 ON a2.RoleID = 'AC.3.A2' AND a2.ESYear = ap.ESYear AND a2.ESMonth = 0
    WHERE ap.RoleID = 'AC.3.AP' AND ap.ESMonth = 0;

    -- ════════════════════════════════════════════════════════════════════════
    --  NW_ES_Avg  (AD, AE, AF)
    --  AD = Total Pay / Billed Claims          (from #Base)
    --  AE = Total Pay / Paid Claims            (from #Base)
    --  AF = Total Pay / Adjudicated Claims
    --      Numerator   = Cash X (Fully Paid Ins $) + AA (Partially Paid $)
    --      Denominator = PMS K+M+O+S.1+S.2+Q+P+R+N
    --        ADCS, Fully Paid, Adjusted/Written off, Fully Denied,
    --        Partially Denied, Partially Paid, Partially Adjusted,
    --        Patient Paid, Fully Patient Responsibility
    --      Computed FROM already-generated NW_ES_Cash / NW_ES_PMS rows
    --      (not a separate #Base recount — keeps AF aligned with the grid).
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
                                   AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Partial Paid','Patient Paid') THEN b.AccessionNumber END),
               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
                         AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Partial Paid','Patient Paid')
                         THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AF placeholder — filled from NW_ES_Cash / NW_ES_PMS below
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AF',
               'Average Payment ($) - Total Pay/Adjudicated Claims',
               0, 0
        FROM #Periods p
        GROUP BY p.ESYear, p.ESMonth
    ) avgrows;

    -- AF = (X + AA) / (K + M + O + S.1 + S.2 + Q + P + R + N)
    ;WITH pay AS (
        SELECT ESYear, ESMonth,
               ISNULL(SUM(ESMonthChargeAmount), 0) AS PayTotal
        FROM dbo.NW_ES_Cash
        WHERE RoleID IN ('X', 'AA')
        GROUP BY ESYear, ESMonth
    ),
    denom AS (
        SELECT ESYear, ESMonth,
               ISNULL(SUM(ESMonthClaimCount), 0) AS ClaimCount
        FROM dbo.NW_ES_PMS
        WHERE RoleID IN ('K', 'M', 'O', 'S.1', 'S.2', 'Q', 'P', 'R', 'N')
        GROUP BY ESYear, ESMonth
    )
    UPDATE a
    SET a.ESMonthClaimCount   = ISNULL(d.ClaimCount, 0),
        a.ESMonthChargeAmount = CASE
            WHEN ISNULL(d.ClaimCount, 0) > 0
            THEN ISNULL(p.PayTotal, 0) / d.ClaimCount
            ELSE 0 END
    FROM dbo.NW_ES_Avg a
    LEFT JOIN pay   p ON p.ESYear = a.ESYear AND p.ESMonth = a.ESMonth
    LEFT JOIN denom d ON d.ESYear = a.ESYear AND d.ESMonth = a.ESMonth
    WHERE a.RoleID = 'AF';

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;
    DROP TABLE IF EXISTS #PeriodWindow;
    DROP TABLE IF EXISTS #AriaWindow_FD;
    DROP TABLE IF EXISTS #AriaWindow_NR;
    DROP TABLE IF EXISTS #AriaYearWindow;
    DROP TABLE IF EXISTS #AriaYearWindow_FD;
    DROP TABLE IF EXISTS #AriaYearWindow_NR;

    PRINT 'usp_RefreshNW_ExecutiveSummary completed.';
END;
GO

PRINT '30_NW_ExecutiveSummary_Aggregate.sql completed.';
GO


--------------


---- ============================================================
---- NorthWest – Executive Summary PMS / Cash / Avg Aggregate SP
---- File : 30_NW_ExecutiveSummary_Aggregate.sql
---- DB   : NorthWest_LRN
----
---- Owns and TRUNCATEs NW_ES_PMS, NW_ES_Cash, NW_ES_Avg.
---- NW_ES_LIS is owned by 33_NW_ExecutiveSummary_LIS_Alt.sql.
----
---- Source: dbo.ClaimLevelData, period bucket = DateofService.
---- NorthWest-specific columns in ClaimLevelData:
----   Billed      – 'Billed' | 'Unbilled' | 'Billed - Client' | ''
----   ClaimType   – 'Claim Submitted in Webpm' | 'Claim Submitted in Daqbilling'
----                 | 'Manually Pushed in Emedix' | 'ADCS - Invoice' | 'Test Patient Entries'
----   ActualPayment    – insurance actual payment (optional column)
----   DuplicatePayment – duplicate payment (optional column)
----
---- PMS rows: G, G.1-G.3, H, H.1-H.5, I (billed mismatch), J, K,
----           M, N, O, P, Q, R, S, S.1, S.1.A1/A2/AP, S.2, S.3, S.3.A1/A2/AP
---- Cash rows: T, T.1-T.3, U, U.1-U.4, V, W, X, X.1, X.2, Y, Z,
----            AA, AA.1, AA.2, AB, AC, AC.1, AC.1.A1/A2/AP, AC.2, AC.3, AC.3.A1/A2/AP
---- Avg rows : AD, AE, AF

---- ============================================================
--SET NOCOUNT ON;
--GO

--CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_ExecutiveSummary
--AS
--BEGIN
--    SET NOCOUNT ON;

--    TRUNCATE TABLE dbo.NW_ES_PMS;
--    TRUNCATE TABLE dbo.NW_ES_Cash;
--    TRUNCATE TABLE dbo.NW_ES_Avg;

--    -- ── Dynamic column detection ─────────────────────────────────────────────
--    -- Detect 'Billed' column (NW) vs 'BillStatus' / 'BillingStatus' (other labs).
--    -- If none found, BilledStatus is DERIVED from FirstBillDate / EmedixSubmissionDate:
--    --   FirstBillDate is not blank  → 'Billed'
--    --   EmedixSubmissionDate is not blank → 'Billed'
--    --   both blank                  → 'Unbilled'
--    DECLARE @BilledCol SYSNAME = (
--        SELECT TOP 1 name FROM sys.columns
--        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
--          AND name IN ('Billed','BillStatus','BillingStatus','BilledStatus')
--        ORDER BY CASE name WHEN 'Billed' THEN 0 WHEN 'BillStatus' THEN 1
--                           WHEN 'BillingStatus' THEN 2 WHEN 'BilledStatus' THEN 3 ELSE 4 END);

--    -- Fallback date columns used to derive Billed status when @BilledCol IS NULL
--    DECLARE @FirstBillDateCol SYSNAME = (
--        SELECT TOP 1 name FROM sys.columns
--        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
--          AND name IN ('FirstBillDate','FirstBilledDate','First_Bill_Date','FirstBilled')
--        ORDER BY CASE name WHEN 'FirstBillDate' THEN 0 WHEN 'FirstBilledDate' THEN 1
--                           WHEN 'First_Bill_Date' THEN 2 ELSE 3 END);

--    DECLARE @EmedixSubDateCol SYSNAME = (
--        SELECT TOP 1 name FROM sys.columns
--        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
--          AND name IN ('EmedixSubmissionDate','EmedixSubmitDate','Emedix_Submission_Date','EmedixDate')
--        ORDER BY CASE name WHEN 'EmedixSubmissionDate' THEN 0 WHEN 'EmedixSubmitDate' THEN 1
--                           WHEN 'Emedix_Submission_Date' THEN 2 ELSE 3 END);

--    DECLARE @ClaimTypeCol SYSNAME = (
--        SELECT TOP 1 name FROM sys.columns
--        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
--          AND name IN ('ClaimType','ClaimCategory','ClaimTypeCode')
--        ORDER BY CASE name WHEN 'ClaimType' THEN 0 WHEN 'ClaimCategory' THEN 1 WHEN 'ClaimTypeCode' THEN 2 ELSE 3 END);

--    DECLARE @ActualPayCol SYSNAME = (
--        SELECT TOP 1 name FROM sys.columns
--        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
--          AND name IN ('ActualPayment','ActualPay','Actual_Payment')
--        ORDER BY CASE name WHEN 'ActualPayment' THEN 0 WHEN 'ActualPay' THEN 1 WHEN 'Actual_Payment' THEN 2 ELSE 3 END);

--    DECLARE @DupPayCol SYSNAME = (
--        SELECT TOP 1 name FROM sys.columns
--        WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
--          AND name IN ('DuplicatePayment','DuplicatePay','Duplicate_Payment')
--        ORDER BY CASE name WHEN 'DuplicatePayment' THEN 0 WHEN 'DuplicatePay' THEN 1 WHEN 'Duplicate_Payment' THEN 2 ELSE 3 END);

--    -- Build the Billed expression for @BaseSql.
--    -- NW: BilledStatus column exists but is NOT populated — skip it.
--    -- Derive 'Billed'/'Unbilled' from FirstBilledDate / EmedixSubmissionDate.
--    --   FirstBilledDate non-empty  → 'Billed'
--    --   EmedixSubmissionDate non-empty → 'Billed'
--    --   both empty/null            → 'Unbilled'
--    -- BilledStatus / BillStatus column kept only as last-resort fallback.
--    -- Output values are always 'Billed' or 'Unbilled'.
--    DECLARE @BilledExpr NVARCHAR(MAX) =
--        CASE
--            -- Priority 1: derive from date columns (BilledStatus is blank for NW)
--            --WHEN @BilledCol IS NOT NULL
--            --    THEN N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')'
--            WHEN @FirstBillDateCol IS NOT NULL OR @EmedixSubDateCol IS NOT NULL
--                THEN
--                    N'CASE'
--                    + CASE WHEN @FirstBillDateCol IS NOT NULL
--                           THEN N' WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50),[' + @FirstBillDateCol + N']),''''))),'''') IS NOT NULL THEN ''Billed'''
--                           ELSE N'' END
--                    + CASE WHEN @EmedixSubDateCol IS NOT NULL
--                           THEN N' WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50),[' + @EmedixSubDateCol + N']),''''))),'''') IS NOT NULL THEN ''Billed'''
--                           ELSE N'' END
--                    + N' ELSE ''Unbilled'' END'
--            -- Priority 2: BilledStatus / Billed column (only if no date columns found)
--            WHEN @BilledCol IS NOT NULL
--                THEN N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')'
--            ELSE NULL
--        END;

--    IF @BilledExpr IS NULL OR @ClaimTypeCol IS NULL
--    BEGIN
--        PRINT 'usp_RefreshNW_ExecutiveSummary: required columns (Billed/ClaimType or FirstBillDate/EmedixSubmissionDate) not found on dbo.ClaimLevelData – skipping.';
--        RETURN;
--    END

--    -- ── #Base : ClaimLevelData with NW-specific columns ──────────────────────
--    DROP TABLE IF EXISTS #Base;
--    CREATE TABLE #Base
--    (
--        AccessionNumber   NVARCHAR(100)  NOT NULL,
--        ESYear            INT            NOT NULL,
--        ESMonth           INT            NOT NULL,
--        Billed            NVARCHAR(50)   NOT NULL,
--        ClaimType         NVARCHAR(200)  NOT NULL,
--        ClaimStatus       NVARCHAR(200)  NOT NULL,
--        FirstBilledDate   DATE           NULL,
--        ChargeAmount      DECIMAL(18,2)  NOT NULL,
--        InsurancePayment  DECIMAL(18,2)  NOT NULL,
--        ActualPayment     DECIMAL(18,2)  NOT NULL,
--        DuplicatePayment  DECIMAL(18,2)  NOT NULL,
--        PatientPayment    DECIMAL(18,2)  NOT NULL,
--        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
--        PatientAdjustments   DECIMAL(18,2) NOT NULL,
--        InsuranceBalance  DECIMAL(18,2)  NOT NULL,
--        PatientBalance    DECIMAL(18,2)  NOT NULL
--    );

--    DECLARE @ActExpr NVARCHAR(300) = CASE WHEN @ActualPayCol IS NOT NULL
--        THEN N'ISNULL(TRY_CAST([' + @ActualPayCol + N'] AS DECIMAL(18,2)),0)'
--        ELSE N'0' END;
--    DECLARE @DupExpr NVARCHAR(300) = CASE WHEN @DupPayCol IS NOT NULL
--        THEN N'ISNULL(TRY_CAST([' + @DupPayCol + N'] AS DECIMAL(18,2)),0)'
--        ELSE N'0' END;

--    -- FirstBilledDate: needed for the ARIA "submitted/not submitted in the last
--    -- 30 days" rows below. Reuses the already-detected @FirstBillDateCol (same
--    -- column used to derive the Billed/Unbilled status above).
--    DECLARE @FBDExpr NVARCHAR(300) = CASE WHEN @FirstBillDateCol IS NOT NULL
--        THEN N'TRY_CAST([' + @FirstBillDateCol + N'] AS DATE)'
--        ELSE N'CAST(NULL AS DATE)' END;

--    DECLARE @BaseSql NVARCHAR(MAX) = N'
--        INSERT INTO #Base
--        SELECT
--            LTRIM(RTRIM(ISNULL(AccessionNumber,''''))) AS AccessionNumber,
--            YEAR (TRY_CAST(DateofService AS DATE)),
--            MONTH(TRY_CAST(DateofService AS DATE)),
--            ' + @BilledExpr + N' AS Billed,
--            ISNULL(LTRIM(RTRIM([' + @ClaimTypeCol + N'])),'''') AS ClaimType,
--            ISNULL(LTRIM(RTRIM(ClaimStatus)),'''') AS ClaimStatus,
--            ' + @FBDExpr + N' AS FirstBilledDate,
--            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)),0),
--            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)),0),
--            ' + @ActExpr + N',
--            ' + @DupExpr + N',
--            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)),0),
--            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)),0),
--            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)),0),
--            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)),0),
--            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)),0)
--        FROM dbo.ClaimLevelData
--        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
--          AND NULLIF(LTRIM(RTRIM(ISNULL(AccessionNumber,''''))),'''') IS NOT NULL;';
--    EXEC sp_executesql @BaseSql;

--    -- ── #Periods ─────────────────────────────────────────────────────────────
--    DROP TABLE IF EXISTS #Periods;
--    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
--    UNION ALL SELECT 0, 0;

--    -- ── ARIA "submitted / not submitted in the last 30 days" scalars ─────────
--    -- These are point-in-time snapshots (not period-bucketed), so the same
--    -- computed value is broadcast to every ESYear/ESMonth row below, replacing
--    -- the previous hardcoded 0 placeholders. Anchor = the most recent
--    -- FirstBilledDate that is not in the future; window = that date minus one
--    -- calendar month (e.g. anchor 12-Jun-2026 → window start 12-May-2026).
--    -- Each group mirrors its own parent row's existing WHERE conditions
--    -- (ClaimType exclusion, ClaimStatus, and for the AC.1/AC.3 dollar rows the
--    -- same Billed IN ('Billed','Billed - Client') condition used by AC.1/AC.3
--    -- themselves) with the FirstBilledDate window layered on top to split into
--    -- "submitted" (A1, within the window) vs "not submitted" (A2, outside it or
--    -- never billed). AP = A1 / A2, per spec.
--    DECLARE @AriaAnchor      DATE = (SELECT MAX(FirstBilledDate) FROM #Base WHERE FirstBilledDate <= CAST(GETDATE() AS DATE));
--    DECLARE @AriaWindowStart DATE = DATEADD(MONTH, -1, @AriaAnchor);

--    -- S.1 (PMS, Count of AccessionNumber, ClaimStatus = 'Fully Denied')
--    DECLARE @S1_A1 DECIMAL(18,2) = (SELECT COUNT(DISTINCT AccessionNumber) FROM #Base
--        WHERE ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND ClaimStatus='Fully Denied'
--          AND @AriaAnchor IS NOT NULL AND FirstBilledDate BETWEEN @AriaWindowStart AND @AriaAnchor);
--    DECLARE @S1_A2 DECIMAL(18,2) = (SELECT COUNT(DISTINCT AccessionNumber) FROM #Base
--        WHERE ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND ClaimStatus='Fully Denied'
--          AND (@AriaAnchor IS NULL OR FirstBilledDate IS NULL OR FirstBilledDate < @AriaWindowStart OR FirstBilledDate > @AriaAnchor));
--    DECLARE @S1_AP DECIMAL(18,2) = CASE WHEN ISNULL(@S1_A2,0) > 0 THEN @S1_A1 / @S1_A2 ELSE 0 END;

--    -- S.3 (PMS, Count of AccessionNumber, ClaimStatus = 'No Response')
--    DECLARE @S3_A1 DECIMAL(18,2) = (SELECT COUNT(DISTINCT AccessionNumber) FROM #Base
--        WHERE ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND ClaimStatus='No Response'
--          AND @AriaAnchor IS NOT NULL AND FirstBilledDate BETWEEN @AriaWindowStart AND @AriaAnchor);
--    DECLARE @S3_A2 DECIMAL(18,2) = (SELECT COUNT(DISTINCT AccessionNumber) FROM #Base
--        WHERE ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND ClaimStatus='No Response'
--          AND (@AriaAnchor IS NULL OR FirstBilledDate IS NULL OR FirstBilledDate < @AriaWindowStart OR FirstBilledDate > @AriaAnchor));
--    DECLARE @S3_AP DECIMAL(18,2) = CASE WHEN ISNULL(@S3_A2,0) > 0 THEN @S3_A1 / @S3_A2 ELSE 0 END;

--    -- AC.1 (Cash, SUM of InsuranceBalance, ClaimStatus = 'Fully Denied', mirrors
--    -- AC.1's own Billed IN ('Billed','Billed - Client') condition)
--    DECLARE @AC1_A1 DECIMAL(18,2) = (SELECT ISNULL(SUM(InsuranceBalance),0) FROM #Base
--        WHERE Billed IN ('Billed','Billed - Client') AND ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND ClaimStatus='Fully Denied'
--          AND @AriaAnchor IS NOT NULL AND FirstBilledDate BETWEEN @AriaWindowStart AND @AriaAnchor);
--    DECLARE @AC1_A2 DECIMAL(18,2) = (SELECT ISNULL(SUM(InsuranceBalance),0) FROM #Base
--        WHERE Billed IN ('Billed','Billed - Client') AND ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND ClaimStatus='Fully Denied'
--          AND (@AriaAnchor IS NULL OR FirstBilledDate IS NULL OR FirstBilledDate < @AriaWindowStart OR FirstBilledDate > @AriaAnchor));
--    DECLARE @AC1_AP DECIMAL(18,2) = CASE WHEN ISNULL(@AC1_A2,0) > 0 THEN @AC1_A1 / @AC1_A2 ELSE 0 END;

--    -- AC.3 (Cash, SUM of InsuranceBalance, ClaimStatus = 'No Response', mirrors
--    -- AC.3's own Billed IN ('Billed','Billed - Client') condition)
--    DECLARE @AC3_A1 DECIMAL(18,2) = (SELECT ISNULL(SUM(InsuranceBalance),0) FROM #Base
--        WHERE Billed IN ('Billed','Billed - Client') AND ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND ClaimStatus='No Response'
--          AND @AriaAnchor IS NOT NULL AND FirstBilledDate BETWEEN @AriaWindowStart AND @AriaAnchor);
--    DECLARE @AC3_A2 DECIMAL(18,2) = (SELECT ISNULL(SUM(InsuranceBalance),0) FROM #Base
--        WHERE Billed IN ('Billed','Billed - Client') AND ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND ClaimStatus='No Response'
--          AND (@AriaAnchor IS NULL OR FirstBilledDate IS NULL OR FirstBilledDate < @AriaWindowStart OR FirstBilledDate > @AriaAnchor));
--    DECLARE @AC3_AP DECIMAL(18,2) = CASE WHEN ISNULL(@AC3_A2,0) > 0 THEN @AC3_A1 / @AC3_A2 ELSE 0 END;

--    -- ── #LisBilled : LIMSMaster billed count per period (for Row I) ──────────
--    DROP TABLE IF EXISTS #LisBilled;
--    CREATE TABLE #LisBilled (ESYear INT NOT NULL, ESMonth INT NOT NULL, BilledCount INT NOT NULL DEFAULT 0);

--    IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
--    BEGIN
--        DECLARE @LisAccCol2 SYSNAME = (
--            SELECT TOP 1 name FROM sys.columns
--            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
--              AND name IN ('OrderID','OrderId','AccessionNumber','Accession','AccessionNo')
--            ORDER BY CASE name WHEN 'OrderID' THEN 0 WHEN 'OrderId' THEN 1 WHEN 'AccessionNumber' THEN 2 WHEN 'Accession' THEN 3 ELSE 4 END);

--        DECLARE @LisDateCol SYSNAME = (
--            SELECT TOP 1 name FROM sys.columns
--            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
--              AND name IN ('ReqCollectDate','Entry_DateCreated','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
--            ORDER BY CASE name
--                WHEN 'ReqCollectDate' THEN 0 WHEN 'Entry_DateCreated' THEN 1 WHEN 'RequestCollectDate' THEN 2
--                WHEN 'DateOfCollection' THEN 3 WHEN 'DateofService' THEN 4
--                WHEN 'CollectionDate' THEN 5 WHEN 'ServiceDate' THEN 6 WHEN 'AccessionDate' THEN 7 ELSE 8 END);

--        DECLARE @LisBillStatusCol SYSNAME = (
--            SELECT TOP 1 name FROM sys.columns
--            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
--              AND name IN ('BillStatus','BillingStatus','Bill_Status')
--            ORDER BY CASE name WHEN 'BillStatus' THEN 0 WHEN 'BillingStatus' THEN 1 WHEN 'Bill_Status' THEN 2 ELSE 3 END);

--        IF @LisAccCol2 IS NOT NULL AND @LisDateCol IS NOT NULL AND @LisBillStatusCol IS NOT NULL
--        BEGIN
--            DECLARE @LisSql2 NVARCHAR(MAX) = N'
--                INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
--                SELECT YEAR(TRY_CAST([' + @LisDateCol + N'] AS DATE)),
--                       MONTH(TRY_CAST([' + @LisDateCol + N'] AS DATE)),
--                       COUNT(DISTINCT [' + @LisAccCol2 + N'])
--                FROM dbo.LIMSMaster
--                WHERE [' + @LisBillStatusCol + N'] = ''Billed''
--                  AND TRY_CAST([' + @LisDateCol + N'] AS DATE) IS NOT NULL
--                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),[' + @LisAccCol2 + N']))),'''') IS NOT NULL
--                GROUP BY YEAR(TRY_CAST([' + @LisDateCol + N'] AS DATE)),
--                         MONTH(TRY_CAST([' + @LisDateCol + N'] AS DATE));

--                INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
--                SELECT 0, 0, COUNT(DISTINCT [' + @LisAccCol2 + N'])
--                FROM dbo.LIMSMaster
--                WHERE [' + @LisBillStatusCol + N'] = ''Billed''
--                  AND TRY_CAST([' + @LisDateCol + N'] AS DATE) IS NOT NULL
--                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),[' + @LisAccCol2 + N']))),'''') IS NOT NULL;';
--            EXEC sp_executesql @LisSql2;
--        END
--    END

--    -- helper: ADCS + Test Patient types to exclude from standard claim counts
--    -- G, M-S, T, X, Y, Z, AA, AB, AC filter: ClaimType NOT IN these two values
--    -- H filter: ISNULL(Billed,'') IN ('','Unbilled')

--    -- ════════════════════════════════════════════════════════════════════════
--    --  NW_ES_PMS
--    -- ════════════════════════════════════════════════════════════════════════
--    INSERT INTO dbo.NW_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
--    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
--    FROM
--    (
--        -- G  No. of Billed Claims
--        SELECT p.ESYear, p.ESMonth, 'G' AS RoleID, 'No. of Billed Claims' AS Description,
--               COUNT(DISTINCT CASE WHEN b.Billed='Billed'
--                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END) AS ClaimCount
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- G.1  Claim Submitted in Webpm
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'G.1', '  Claim Submitted in Webpm',
--               COUNT(DISTINCT CASE WHEN b.Billed='Billed' AND b.ClaimType='Claim Submitted in Webpm'
--                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- G.2  Claim Submitted in Daqbilling
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'G.2', '  Claim Submitted in Daqbilling',
--               COUNT(DISTINCT CASE WHEN b.Billed='Billed' AND b.ClaimType='Claim Submitted in Daqbilling'
--                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- G.3  Manually Pushed in Emedix
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'G.3', '  Manually Pushed in Emedix',
--               COUNT(DISTINCT CASE WHEN b.Billed='Billed' AND b.ClaimType='Manually Pushed in Emedix'
--                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- H  No. of Unbilled Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'H', 'No. of Unbilled Claims',
--               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
--                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- H.1  Unbilled in Webpm PR
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'H.1', '  Unbilled in Webpm PR',
--               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
--                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Unbilled in Webpm PR' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- H.2  Unbilled in Webpm
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'H.2', '  Unbilled in Webpm',
--               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
--                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Unbilled in Webpm' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- H.3  Unbilled in Daq
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'H.3', '  Unbilled in Daq',
--               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
--                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Unbilled in Daq' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- H.4  Unbilled in Daq - PR
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'H.4', '  Unbilled in Daq - PR',
--               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
--                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Unbilled in Daq - PR' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- H.5  Billed amount 0
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'H.5', '  Billed amount 0',
--               COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled')
--                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Billed Amount 0' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- I  Billed Mismatches (G count - LIMSMaster billed count)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'I', 'Billed Mismatches - Other samples billed / LIS Accessions NA',
--               COUNT(DISTINCT CASE WHEN b.Billed='Billed'
--                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
--               - ISNULL((SELECT lb.BilledCount FROM #LisBilled lb WHERE lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth), 0)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- J  Test Patient Entries
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'J', 'Test Patient Entries',
--               COUNT(DISTINCT CASE WHEN b.ClaimType='Test Patient Entries' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- K  ADCS Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'K', 'ADCS Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType='ADCS - Invoice' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- M  No. of Fully Paid Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Fully Paid Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Fully Paid' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- N  No. of Fully Patient Responsibility Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Fully Patient Responsibility Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Pat Responsibility' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- O  No. of Adjusted/Written Off Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Adjusted/Written Off Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Fully Adjusted' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- P  No. of Partially Adjusted Claim
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'P', 'No. of Partially Adjusted Claim',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Partially Adjusted' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- Q  No. of Partially Paid Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'Q', 'No. of Partially Paid Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Partially Paid' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- R  No. of Patient Paid Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'R', 'No. of Patient Paid Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Patient Paid' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- S  No. of Insurance Balance Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'S', 'No. of Insurance Balance Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response') THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- S.1  No. of Fully Denied Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'S.1', '  No. of Fully Denied Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Fully Denied' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- S.1.A1/A2/AP  ARIA (Count of AccessionNumber, ClaimStatus='Fully Denied')
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.1.A1', '    Aria Submitted in the last 30 Days', @S1_A1 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.1.A2', '    Aria not submitted in the last 30 Days', @S1_A2 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.1.AP', '    % of the claim submitted in the last 30 Days', @S1_AP FROM #Periods p GROUP BY p.ESYear, p.ESMonth

--        -- S.2  No. of Partially Denied Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'S.2', '  No. of Partially Denied Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='Partially Denied' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- S.3  No. of No Response from Payor
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'S.3', '  No. of No Response from Payor',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus='No Response' THEN b.AccessionNumber END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- S.3.A1/A2/AP  ARIA (Count of AccessionNumber, ClaimStatus='No Response')
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.3.A1', '    Claim filed by ARIA in the last 30 days', @S3_A1 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.3.A2', '    Claims not filed in the last 30 days', @S3_A2 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'S.3.AP', '    % of the claim submitted in the last 30 Days', @S3_AP FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--    ) pms;

--    -- ════════════════════════════════════════════════════════════════════════
--    --  NW_ES_Cash
--    -- ════════════════════════════════════════════════════════════════════════
--    INSERT INTO dbo.NW_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
--    SELECT RoleID, Description, ESYear, ESMonth, 0, Amount, GETDATE()
--    FROM
--    (
--        -- T  Total Billed ($)
--        SELECT p.ESYear, p.ESMonth, 'T' AS RoleID, 'Total Billed ($)' AS Description,
--               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END) AS Amount
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'T.1', '  Claim Submitted in Webpm',
--               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType='Claim Submitted in Webpm'
--                         AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'T.2', '  Claim Submitted in Daqbilling',
--               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType='Claim Submitted in Daqbilling'
--                         AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'T.3', '  Manually Pushed in Emedix',
--               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType='Manually Pushed in Emedix'
--                         AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- U  Total Unbilled ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'U', 'Total Unbilled ($)',
--               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'U.1', '  Unbilled in Webpm PR',
--               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Unbilled in Webpm PR' THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'U.2', '  Unbilled in Webpm',
--               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Unbilled in Webpm' THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'U.3', '  Unbilled in Daq',
--               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Unbilled in Daq' THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'U.4', '  Unbilled in Daq - PR',
--               SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Unbilled in Daq - PR' THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- V  Test Patients Entries ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'V', 'Test Patients Entries ($)',
--               SUM(CASE WHEN b.ClaimType='Test Patient Entries' THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- W  ADCS Claims ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'W', 'ADCS Claims ($)',
--               SUM(CASE WHEN b.ClaimType='ADCS - Invoice' THEN b.ChargeAmount ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- X  Insurance Payment ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'X', 'Insurance Payment ($)',
--               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Fully Paid' THEN b.InsurancePayment ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- X.1  Actual Payments ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'X.1', '  Actual Payments ($)',
--               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Fully Paid' THEN b.ActualPayment ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- X.2  Duplicate Payments ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'X.2', '  Duplicate Payments ($)',
--               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Fully Paid' THEN b.DuplicatePayment ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- Y  Patient Responsibility ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'Y', 'Patient Responsibility ($)',
--               SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         THEN b.PatientBalance ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- Z  Adjustments / Write Off ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'Z', 'Adjustments / Write Off ($)',
--               SUM(CASE WHEN b.Billed='Billed'
--                         AND b.ClaimType IN ('Claim Submitted in Webpm','Claim Submitted in Daqbilling')
--                         THEN b.InsuranceAdjustments + b.PatientAdjustments ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AA  Partially Paid ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'AA', 'Partially Paid ($)',
--               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
--                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Partially Paid' THEN b.InsurancePayment ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AA.1  Actual Payments ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'AA.1', '  Actual Payments ($)',
--               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
--                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Partially Paid' THEN b.ActualPayment ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AA.2  Duplicate Payments ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'AA.2', '  Duplicate Payments ($)',
--               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
--                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Partially Paid' THEN b.DuplicatePayment ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AB  Patient Paid ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'AB', 'Patient Paid ($)',
--               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
--                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         THEN b.PatientPayment ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AC  Insurance Balance ($)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'AC', 'Insurance Balance ($)',
--               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
--                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         THEN b.InsuranceBalance ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AC.1  Denials
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'AC.1', '  Denials',
--               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
--                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='Fully Denied' THEN b.InsuranceBalance ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AC.1 ARIA (SUM of InsuranceBalance, ClaimStatus='Fully Denied', mirrors AC.1's own Billed filter)
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.1.A1', '    Claim filed by ARIA in the last 30 days', @AC1_A1 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.1.A2', '    Claims not filed in the last 30 days', @AC1_A2 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.1.AP', '    % of the claim submitted in the last 30 Days', @AC1_AP FROM #Periods p GROUP BY p.ESYear, p.ESMonth

--        -- AC.2  Partially Denied (placeholder - 0 per spec)
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.2', '  Partially Denied', 0 FROM #Periods p GROUP BY p.ESYear, p.ESMonth

--        -- AC.3  No Response from Payor
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'AC.3', '  No Response from Payor',
--               SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client')
--                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus='No Response' THEN b.InsuranceBalance ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AC.3 ARIA (SUM of InsuranceBalance, ClaimStatus='No Response', mirrors AC.3's own Billed filter)
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.3.A1', '    Claim filed by ARIA in the last 30 days', @AC3_A1 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.3.A2', '    Claims not filed in the last 30 days', @AC3_A2 FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--        UNION ALL SELECT p.ESYear, p.ESMonth, 'AC.3.AP', '    % of the claim submitted in the last 30 Days', @AC3_AP FROM #Periods p GROUP BY p.ESYear, p.ESMonth
--    ) cash;

--    -- ════════════════════════════════════════════════════════════════════════
--    --  NW_ES_Avg  (AD, AE, AF)
--    --  AD = Total Pay / Billed Claims
--    --  AE = Total Pay / Paid Claims
--    --  AF = Total Pay / Adjudicated Claims
--    -- ════════════════════════════════════════════════════════════════════════
--    INSERT INTO dbo.NW_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
--    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
--           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
--    FROM
--    (
--        -- AD  Average Payment ($) - Total Pay/Billed Claims
--        SELECT p.ESYear, p.ESMonth, 'AD' AS RoleID,
--               'Average Payment ($) - Total Pay/Billed Claims' AS Description,
--               COUNT(DISTINCT CASE WHEN b.Billed='Billed'
--                                   AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END) AS ClaimCount,
--               SUM(CASE WHEN b.Billed='Billed'
--                         AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus<>'Billed Amount 0'
--                         THEN b.InsurancePayment + b.PatientPayment ELSE 0 END) AS PayTotal
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AE  Average Payment Per Claim (Total Pay / Paid Claims)
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'AE',
--               'Average Payment Per Claim',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Patient Paid') THEN b.AccessionNumber END),
--               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus IN ('Fully Paid','Partially Paid','Patient Paid')
--                         THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth

--        -- AF  Average Payment ($) - Total Pay/Adjudicated Claims
--        UNION ALL
--        SELECT p.ESYear, p.ESMonth, 'AF',
--               'Average Payment ($) - Total Pay/Adjudicated Claims',
--               COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                                   AND b.ClaimStatus IN ('Fully Paid','Fully Adjusted','Fully Denied','Partially Denied') THEN b.AccessionNumber END),
--               SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries')
--                         AND b.ClaimStatus IN ('Fully Paid','Partially Paid')
--                         THEN b.InsurancePayment ELSE 0 END)
--        FROM #Periods p
--        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
--        GROUP BY p.ESYear, p.ESMonth
--    ) avgrows;

--    DROP TABLE IF EXISTS #Base;
--    DROP TABLE IF EXISTS #Periods;
--    DROP TABLE IF EXISTS #LisBilled;

--    PRINT 'usp_RefreshNW_ExecutiveSummary completed.';
--END;
--GO

--PRINT '30_NW_ExecutiveSummary_Aggregate.sql completed.';
--GO
