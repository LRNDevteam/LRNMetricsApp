USE [BeechTree_LRN]
GO
/****** Object:  StoredProcedure [dbo].[usp_RefreshBT_ExecutiveSummary]    Script Date: 7/8/2026 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   PROCEDURE [dbo].[usp_RefreshBT_ExecutiveSummary]
    -- Period filters (NULL = no restriction)
    @YearFrom   INT            = NULL,
    @YearTo     INT            = NULL,
    @MonthFrom  INT            = NULL,
    @MonthTo    INT            = NULL,
    -- Dimension filters — comma-separated values, NULL = all
    @Panels     NVARCHAR(MAX)  = NULL,
    @Clinics    NVARCHAR(MAX)  = NULL,
    @Providers  NVARCHAR(MAX)  = NULL,
    @Reps       NVARCHAR(MAX)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.BeechTree_ES_PMS;
    TRUNCATE TABLE dbo.BeechTree_ES_Cash;
    TRUNCATE TABLE dbo.BeechTree_ES_Avg;
    -- ── #Base : one row per ClaimLevelData record with period bucket ───────
    DROP TABLE IF EXISTS #Base;
    SELECT
        ClaimID,
        YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
        ISNULL(LTRIM(RTRIM(BilledUnbilled)),    '')  AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)),       '')  AS ClaimStatus,
        ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance,
        -- Dimension columns (used for filter matching)
        ISNULL(LTRIM(RTRIM(Panelname)),         '')  AS Panelname,
        ISNULL(LTRIM(RTRIM(ClinicName)),        '')  AS ClinicName,
        ISNULL(LTRIM(RTRIM(ReferringProvider)), '')  AS ReferringProvider,
        ISNULL(LTRIM(RTRIM(SalesRepname)),      '')  AS SalesRepname
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(CONVERT(NVARCHAR(50), ClaimID), '') IS NOT NULL
      -- ── Year / Month filters ────────────────────────────────────────────
      AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
      -- ── Dimension filters (comma-separated; NULL = no restriction) ──────
      AND (@Panels    IS NULL OR EXISTS (
              SELECT 1 FROM STRING_SPLIT(@Panels,    ',') s
              WHERE LTRIM(RTRIM(s.value)) = LTRIM(RTRIM(Panelname))))
      AND (@Clinics   IS NULL OR EXISTS (
              SELECT 1 FROM STRING_SPLIT(@Clinics,   ',') s
              WHERE LTRIM(RTRIM(s.value)) = LTRIM(RTRIM(ClinicName))))
      AND (@Providers IS NULL OR EXISTS (
              SELECT 1 FROM STRING_SPLIT(@Providers, ',') s
              WHERE LTRIM(RTRIM(s.value)) = LTRIM(RTRIM(ReferringProvider))))
      AND (@Reps      IS NULL OR EXISTS (
              SELECT 1 FROM STRING_SPLIT(@Reps,      ',') s
              WHERE LTRIM(RTRIM(s.value)) = LTRIM(RTRIM(SalesRepname))));
    -- ── #Periods : distinct (ESYear, ESMonth) + (0,0) grand-total sentinel ──
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
    UNION ALL SELECT 0, 0;
    -- ── #LisBilled : LIMSMaster BilledorNot='Billed' counts per
    --    RequestCollectDate period. Used for row S (Billed Mismatches):
    --    S = PMS Billed Claims (R) - LIS Billed Samples (this table).
    DROP TABLE IF EXISTS #LisBilled;
    CREATE TABLE #LisBilled (ESYear INT NOT NULL, ESMonth INT NOT NULL, BilledCount INT NOT NULL);
    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        -- Detect accession and date columns dynamically (mirrors file 19)
        DECLARE @LbAccCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('AccessionNumber','VisitNumber','OrderID','Accession','AccessionNo')
            ORDER BY CASE name
                WHEN 'AccessionNumber' THEN 0 WHEN 'VisitNumber' THEN 1
                WHEN 'OrderID' THEN 2 WHEN 'Accession' THEN 3 WHEN 'AccessionNo' THEN 4 ELSE 5 END);
        DECLARE @LbDateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('RequestCollectDate','ReqCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'RequestCollectDate' THEN 0 WHEN 'ReqCollectDate' THEN 1
                WHEN 'DateOfCollection'   THEN 2 WHEN 'DateofService'  THEN 3
                WHEN 'CollectionDate'     THEN 4 WHEN 'ServiceDate'    THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);
        IF @LbAccCol IS NOT NULL AND @LbDateCol IS NOT NULL
        BEGIN
            DECLARE @LbSql NVARCHAR(MAX) = N'
                INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
                SELECT
                    YEAR (TRY_CAST([' + @LbDateCol + N'] AS DATE)),
                    MONTH(TRY_CAST([' + @LbDateCol + N'] AS DATE)),
                    COUNT(DISTINCT LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LbAccCol + N']))))
                FROM dbo.LIMSMaster
                WHERE BilledorNot = ''Billed''
                  AND TRY_CAST([' + @LbDateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LbAccCol + N']))), '''') IS NOT NULL
                GROUP BY
                    YEAR (TRY_CAST([' + @LbDateCol + N'] AS DATE)),
                    MONTH(TRY_CAST([' + @LbDateCol + N'] AS DATE));
                INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
                SELECT 0, 0, COUNT(DISTINCT LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LbAccCol + N']))))
                FROM dbo.LIMSMaster
                WHERE BilledorNot = ''Billed''
                  AND TRY_CAST([' + @LbDateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LbAccCol + N']))), '''') IS NOT NULL;';
            EXEC sp_executesql @LbSql;
        END
    END
    -- ────────────────────────────────────────────────────────────────────
    --  BeechTree_ES_PMS  -  R, S, T, U, V, V.1..Vn (BTWOSummary), W, X, Y, Z, Z.1, Z.2, Z.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.BeechTree_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- R  Billed – Includes all Claims Billed in AMD
        SELECT p.ESYear, p.ESMonth, 'R' AS RoleID,
               'Billed - Includes all Claims Billed in AMD' AS Description,
               COUNT(DISTINCT CASE WHEN b.BillStatus = 'Billed' THEN b.ClaimID END) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- S  Billed Mismatches – Non Diagnose LIS Samples
        --    = PMS Billed Claims (R) - LIS Billed Samples (LIMSMaster BilledorNot='Billed')
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S',
               'Billed Mismatches - Non Diagnose LIS Samples',
               COUNT(DISTINCT CASE WHEN b.BillStatus='Billed' THEN b.ClaimID END)
               - ISNULL(MAX(lb.BilledCount), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        LEFT JOIN #LisBilled lb ON lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth
        GROUP BY p.ESYear, p.ESMonth
        -- T  Unbilled – Entered to AMD – Yet to be released to Payer
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T',
               'Unbilled - Entered to AMD - Yet to be released to Payer',
               COUNT(DISTINCT CASE WHEN b.BillStatus = 'UnBilled' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- U  Fully Paid – Insurance Pay
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Fully Paid - Insurance Pay',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- V  Fully Adjusted – parent count comes DIRECTLY from ClaimLevelData
        --    (#Base): write-off claims where BillStatus='Billed' AND
        --    ClaimStatus='Complete W/O'. (The V.n sub-rows below come from
        --    BTWOSummary; the parent may exceed SUM(V.n) because some write-off
        --    claims have no matching transaction-detail rows.)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Fully Adjusted',
               COUNT(DISTINCT CASE WHEN b.BillStatus = 'Billed'
                                    AND b.ClaimStatus = 'Complete W/O'
                                   THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- W  Patient Responsibility
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Patient Responsibility',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus in ('Pat Responsibility','Patient Responsibility') THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- X  Partially Paid
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X', 'Partially Paid',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus in ('Partial Paid','Partially Paid') THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Y  Patient Payment
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Y', 'Patient Payment',
               --COUNT(DISTINCT CASE WHEN b.PatientPayment > 0 THEN b.ClaimID END)
			    COUNT(DISTINCT CASE WHEN b.ClaimStatus in ('Patient Payment','Pat Payment') THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Z  Insurance Balance
		--Filter Billed / Unbilled = Billed  Distinct Count (Visit Number)
		--WHERE ClaimStatus =  FullyDenied, No Response,Partially Adjusted,Partially Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z', 'Insurance Balance',
               COUNT(DISTINCT CASE WHEN b.BillStatus='Billed' and  b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied','Partially Adjusted') THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Z.1  Fully Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z.1', '  Fully Denied',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Denied' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Z.2  No Response
		--Filter Billed / Unbilled = Billed Distinct Count (Visit Number) WHERE ClaimStatus =  No Response
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z.2', '  No Response',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'No Response'  and b.BillStatus='Billed' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Z.3  Partially Denied
		--Filter Billed / Unbilled = Billed Distinct Count (Visit Number)
		--WHERE ClaimStatus =  Partially Adjusted + Partially Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z.3', '  Partially Denied',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus in ('Partially Denied','Partially Adjusted') and b.BillStatus='Billed'
			   THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) pms;
    -- ────────────────────────────────────────────────────────────────────
    --  BeechTree_ES_PMS  -  V.n  Write-off reason sub-rows (BTWOSummary v6)
    --  One row per TransactionCodeCombined per period (incl. 'No reason'),
    --  ordered by count desc. BTWOSummary v6 is driven by the Complete W/O
    --  claims, so SUM(V.n) = parent V for each month.
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.BeechTree_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT
        'V.' + CAST(ROW_NUMBER() OVER (PARTITION BY agg.ESYear, agg.ESMonth
                                       ORDER BY agg.MatchingCount DESC, agg.TransactionCodeCombined
                                      ) AS NVARCHAR(10)) AS RoleID,
        '  ' + agg.TransactionCodeCombined              AS Description,
        agg.ESYear,
        agg.ESMonth,
        agg.MatchingCount                               AS ESMonthClaimCount,
        0                                               AS ESMonthChargeAmount,
        GETDATE()                                       AS RefreshedAt
    FROM (
        SELECT
            p.ESYear,
            p.ESMonth,
            ws.TransactionCodeCombined,
            SUM(ws.MatchingCount) AS MatchingCount
        FROM #Periods p
        JOIN (
            SELECT
                ws2.TransactionCodeCombined,
                ws2.MatchingCount,
                YEAR (TRY_CAST(ws2.DateofService AS DATE)) AS WOYear,
                MONTH(TRY_CAST(ws2.DateofService AS DATE)) AS WOMonth
            FROM   dbo.BTWOSummary ws2
            WHERE  ws2.TransactionCodeCombined IS NOT NULL
              AND  TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
              AND  EXISTS (
                    SELECT 1
                    FROM   #Base b
                    WHERE  LTRIM(RTRIM(CAST(b.ClaimID   AS NVARCHAR(50))))
                         = LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50))))
                      AND  b.BillStatus  = 'Billed'
                      AND  b.ClaimStatus = 'Complete W/O'
              )
        ) ws ON (p.ESYear = 0 OR (ws.WOYear = p.ESYear AND ws.WOMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, ws.TransactionCodeCombined
    ) agg;
    -- ────────────────────────────────────────────────────────────────────
    --  BeechTree_ES_Cash  -  AA through AJ
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.BeechTree_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeAmount, GETDATE()
    FROM
    (
        -- AA  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'AA' AS RoleID, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN b.BillStatus = 'Billed' THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- AB  Unbilled ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AB', 'Unbilled ($)',
               SUM(CASE WHEN b.BillStatus = 'UnBilled' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- AC  Insurance Payment (fully paid) ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AC', 'Insurance Payment (fully paid) ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' AND b.InsurancePayment > 0 THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- AD  Partially Paid ($)
		--Sum (InsurancePayment) WHERE Billed/Unbilled = Billed AND ClaimStatus = Partially Paid
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AD', 'Partially Paid ($)',
               SUM(CASE WHEN b.ClaimStatus in ('Partial Paid','Partially Paid') and b.BillStatus='Billed' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- AE  Patient Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AE', 'Patient Payment ($)',
		--SUM(CASE WHEN b.ClaimStatus in ('Patient Payment','Pat Payment')  THEN b.PatientPayment ELSE 0 END)
         SUM(CASE WHEN b.PatientPayment > 0 THEN b.PatientPayment ELSE 0 END)
		FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- AF  Fully Adjusted (Complete W/O)
		--Sum (InsuranceAdjustments) WHERE Billed/Unbilled = Billed AND ClaimStatus = Complete W/O
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AF', 'Fully Adjusted (Complete W/O)',
               SUM(CASE WHEN b.ClaimStatus in ('Complete W/O') and b.BillStatus='Billed'
                        THEN b.InsuranceAdjustments  ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- AG  Contractual Obligation W/O
		--Sum (InsuranceAdjustments) WHERE Billed/Unbilled = Billed AND ClaimStatus is not Equal to Complete W/O
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AG', 'Contractual Obligation W/O',
               SUM(CASE WHEN b.BillStatus='Billed' and ClaimStatus<>'Complete W/O'
			   THEN b.InsuranceAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- AH  Patient Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AH', 'Patient Balance ($)',
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- AI  Patient WO
		--Sum (PatientAdjustments) WHERE Billed/Unbilled = Billed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AJ', 'Patient WO',
				SUM(CASE WHEN b.BillStatus = 'Billed' THEN b.PatientAdjustments ELSE 0 END)
               --SUM(CASE WHEN b.PatientAdjustments > 0 THEN b.PatientAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- AJ  Insurance Balance ($)
		--Sum (InsuranceBalance) WHERE Billed/Unbilled = Billed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AK', 'Insurance Balance ($)',
               SUM(CASE WHEN b.BillStatus='Billed' --b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied')
                        THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

		--Sum (InsuranceBalance) WHERE Billed/Unbilled = Billed AND Claim Status = Fully Denied
		UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AK1', '  Fully Denied',
               SUM(CASE WHEN b.BillStatus='Billed' and b.ClaimStatus IN ('Fully Denied')--b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied')
                        THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
		--Sum (InsuranceBalance) WHERE Billed/Unbilled = Billed AND Claim Status = No Response
		UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AK2', '  No Response',
               SUM(CASE WHEN b.BillStatus='Billed' and b.ClaimStatus IN ('No Response')--b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied')
                        THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
		--Partially Denied
		--Sum (InsuranceBalance) WHERE Billed/Unbilled = Billed AND Claim Status =Not Equal to  No Response , Fully Denied

		UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AK3', '  Partially Denied',
               SUM(CASE WHEN b.BillStatus='Billed' and b.ClaimStatus NOT IN ('No Response','Fully Denied')--b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied')
                        THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) cash;
    -- ────────────────────────────────────────────────────────────────────
    --  BeechTree_ES_Avg  -  AL, AM, AN
    --  CHANGED: averages are now derived from the ALREADY-CALCULATED rows in
    --  BeechTree_ES_Cash (AC, AD, AE = Total Pay) and BeechTree_ES_PMS
    --  (claim-count denominators), instead of recomputing from #Base.
    --    AL = (AC + AD + AE) / R
    --    AM = (AC + AD + AE) / (U + X + Y)
    --    AN = (AC + AD + AE) / (U + V + W + X + Y + Z.1 + Z.3)
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.BeechTree_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    FROM
    (
        -- AL  Average Payment ($) - Total Pay / Billed Claims
        --     Sum(AC, AD, AE) / R (Billed - Includes all Claims Billed in AMD)
        SELECT cnt.ESYear, cnt.ESMonth, 'AL' AS RoleID,
               'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               cnt.BilledClaims                               AS ClaimCount,
               ISNULL(pay.TotalPay, 0)                        AS PayTotal
        FROM
        (
            SELECT ESYear, ESMonth,
                   SUM(CASE WHEN RoleID = 'R' THEN ESMonthClaimCount ELSE 0 END) AS BilledClaims
            FROM dbo.BeechTree_ES_PMS
            WHERE RoleID = 'R'
            GROUP BY ESYear, ESMonth
        ) cnt
        LEFT JOIN
        (
            SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS TotalPay
            FROM dbo.BeechTree_ES_Cash
            WHERE RoleID IN ('AC','AD','AE')
            GROUP BY ESYear, ESMonth
        ) pay ON pay.ESYear = cnt.ESYear AND pay.ESMonth = cnt.ESMonth
        -- AM  Average Payment ($) - Total Pay / Paid Claims
        --     Sum(AC, AD, AE) / Sum(U, X, Y)
        UNION ALL
        SELECT cnt.ESYear, cnt.ESMonth, 'AM',
               'Average Payment ($) - Total Pay/Paid Claims',
               cnt.PaidClaims,
               ISNULL(pay.TotalPay, 0)
        FROM
        (
            SELECT ESYear, ESMonth,
                   SUM(ESMonthClaimCount) AS PaidClaims
            FROM dbo.BeechTree_ES_PMS
            WHERE RoleID IN ('U','X','Y')
            GROUP BY ESYear, ESMonth
        ) cnt
        LEFT JOIN
        (
            SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS TotalPay
            FROM dbo.BeechTree_ES_Cash
            WHERE RoleID IN ('AC','AD','AE')
            GROUP BY ESYear, ESMonth
        ) pay ON pay.ESYear = cnt.ESYear AND pay.ESMonth = cnt.ESMonth
        -- AN  Average Payment ($) - Total Pay / Adjudicated Claims
        --     Sum(AC, AD, AE) / Sum(U, V, W, X, Y, Z.1, Z.3)
        UNION ALL
        SELECT cnt.ESYear, cnt.ESMonth, 'AN',
               'Average Payment ($) - Total Pay/Adjudicated Claims',
               cnt.AdjudicatedClaims,
               ISNULL(pay.TotalPay, 0)
        FROM
        (
            SELECT ESYear, ESMonth,
                   SUM(ESMonthClaimCount) AS AdjudicatedClaims
            FROM dbo.BeechTree_ES_PMS
            WHERE RoleID IN ('U','V','W','X','Y','Z.1','Z.3')
            GROUP BY ESYear, ESMonth
        ) cnt
        LEFT JOIN
        (
            SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS TotalPay
            FROM dbo.BeechTree_ES_Cash
            WHERE RoleID IN ('AC','AD','AE')
            GROUP BY ESYear, ESMonth
        ) pay ON pay.ESYear = cnt.ESYear AND pay.ESMonth = cnt.ESMonth
    ) avgrows;
    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;
    PRINT 'usp_RefreshBT_ExecutiveSummary completed.';
END;
