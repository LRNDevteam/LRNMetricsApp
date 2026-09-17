/* =====================================================================
   Cove — usp_RefreshCove_ExecutiveSummary
   FIX : Billed Mismatches (RoleID G) = LIS RoleID C − PMS F (No. of Billed Claims)

   DB  : CoveLRN

   After Cove_ES_PMS is loaded:
     G.ESMonthClaimCount = MAX(0, F.ESMonthClaimCount − Cove_ES_LIS.B.ESMonthClaimCount)

   Capture order is PMS refresh then LIS_Alt, so G is also recomputed at the
   end of usp_RefreshCove_ExecutiveSummary_LIS_Alt (same formula).

   Also includes the latest PMS/Cash/Avg business filters (ClaimID counts,
   BillStatus filters, S1 Patient Write Off, table-driven Avg V/W/X).
   ===================================================================== */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Cove_ES_PMS;
    TRUNCATE TABLE dbo.Cove_ES_Cash;
    TRUNCATE TABLE dbo.Cove_ES_Avg;

    -- ── #Base : one row per ClaimLevelData record with period bucket ───────
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        ClaimID,
        YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
        ISNULL(LTRIM(RTRIM(BillStatus)),  '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL;

    -- ── #Periods : distinct (ESYear, ESMonth) + (0,0) grand-total sentinel ──
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
    UNION ALL SELECT 0, 0;

    -- ────────────────────────────────────────────────────────────────────
    --  Cove_ES_PMS  -  F, G(placeholder), H, I, J, K, L, M, N, N.1, N.2, N.3
    --  G is recomputed after insert: Cove_ES_LIS RoleID C − PMS F
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Cove_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- F  No. of Billed Claims
        SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'No. of Billed Claims' AS Description,
               COUNT(b.ClaimID) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed','Billed-Client','Billed - Client')
        GROUP BY p.ESYear, p.ESMonth

        -- G  placeholder (updated below from LIS C − PMS F)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G', 'Billed Mismatches - Accessions NA / Other Sample',
               0
        FROM #Periods p

        -- H  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'No. of Fully Paid Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed','Billed-Client','Billed - Client')
                          AND b.ClaimStatus IN ('Fully Paid')
        GROUP BY p.ESYear, p.ESMonth

        -- I  No. of Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'No. of Patient Responsibility Claims',
               COUNT(b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed')
                          AND b.ClaimStatus = 'Patient Responsibility'
        GROUP BY p.ESYear, p.ESMonth

        -- J  No. of Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'No. of Adjusted/Written Off Claims',
               COUNT(b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed')
                          AND b.ClaimStatus = 'Fully Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- K  No. of Partially Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'No. of Partially Adjusted/Written Off Claims',
               COUNT(b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed')
                          AND b.ClaimStatus = 'Partially Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- L  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'L', 'No. of Partially Paid Claims',
               COUNT(b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed')
                          AND b.ClaimStatus = 'Partially Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- M  No. of Patient Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Patient Paid Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed','Billed-Client','Billed - Client')
                          AND b.ClaimStatus = 'Patient Payment'
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Insurance Balance Claims',
               COUNT(b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed')
                          AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response')
        GROUP BY p.ESYear, p.ESMonth

        -- N.1  No. of Fully Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N.1', '  No. of Fully Denied Claims',
               COUNT(b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- N.2  No. of Partially Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N.2', '  No. of Partially Denied Claims',
               COUNT(b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus IN ('Partially Denied')
        GROUP BY p.ESYear, p.ESMonth

        -- N.3  No. of No Response from Payor Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N.3', '  No. of No Response from Payor Claims',
               COUNT(b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus IN ('No Response','No Response-Client')
        GROUP BY p.ESYear, p.ESMonth
    ) pms;

    -- G = No. of Billed Claims (F) − Billable Samples (Cove_ES_LIS RoleID B)
    -- Uses whatever LIS snapshot is already present (prior refresh / same-day LIS).
    -- LIS_Alt re-runs this update after it refreshes Cove_ES_LIS.
    IF OBJECT_ID('dbo.Cove_ES_LIS', 'U') IS NOT NULL
    BEGIN
        UPDATE g
        SET g.ESMonthClaimCount =
                CASE
                    WHEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0) > 0
                    THEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0)
                    ELSE 0
                END,
            g.RefreshedAt = GETDATE()
        FROM dbo.Cove_ES_PMS AS g
        INNER JOIN dbo.Cove_ES_PMS AS f
            ON  f.ESYear  = g.ESYear
            AND f.ESMonth = g.ESMonth
            AND f.RoleID  = 'F'
        LEFT JOIN dbo.Cove_ES_LIS AS lis
            ON  lis.ESYear  = g.ESYear
            AND lis.ESMonth = g.ESMonth
            AND lis.RoleID  = 'B'   -- Billable Samples (not B.<PanelType>)
        WHERE g.RoleID = 'G';
    END

    -- ────────────────────────────────────────────────────────────────────
    --  Cove_ES_Cash  -  O, P, Q, R, S, S1, T, U, U.1, U.2, U.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Cove_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeAmount, GETDATE()
    FROM
    (
        -- O  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'O' AS RoleID, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN b.BillStatus IN ('Billed','Billed-Client','Billed - Client') THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P  Insurance Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P', 'Insurance Payment ($)',
               SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client') THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q  Patient Responsibility ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q', 'Patient Responsibility ($)',
               SUM(CASE WHEN b.BillStatus IN ('Billed') THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- R  Patient Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'Patient Payment ($)',
               SUM(CASE WHEN b.BillStatus IN ('Billed','Billed-Client','Billed - Client') THEN b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  Adjustments / Write Off ($)  — insurance adjustments
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S', 'Adjustments / Write Off ($)',
               SUM(CASE WHEN b.BillStatus IN ('Billed','Billed-Client','Billed - Client') THEN b.InsuranceAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S1 Patient Write Off ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S1', 'Patient Write Off ($)',
               SUM(CASE WHEN b.BillStatus IN ('Billed','Billed-Client','Billed - Client') THEN b.PatientAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- T  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T', 'Partially Paid ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Partially Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U  Insurance Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Insurance Balance ($)',
               SUM(CASE WHEN b.BillStatus IN ('Billed','Billed-Client','Billed - Client') THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.1  Denials
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.1', '  Denials',
               SUM(CASE WHEN b.ClaimStatus = 'Fully Denied' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.2  Partially Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.2', '  Partially Denied',
               SUM(CASE
                       WHEN b.BillStatus IN ('Billed','Billed-Client','Billed - Client')
                        AND b.ClaimStatus NOT IN ('Fully Denied','No Response')
                       THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.3  No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.3', '  No Response from Payor',
               SUM(CASE WHEN b.ClaimStatus IN ('No Response','No Response-Client') THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) cash;

    -- ────────────────────────────────────────────────────────────────────
    --  Cove_ES_Avg  -  V, W, X  (table-driven from PMS/Cash)
    -- ────────────────────────────────────────────────────────────────────
    ;WITH
    Num_Billed AS
    (
        -- V numerator = P + T
        SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
        FROM dbo.Cove_ES_Cash
        WHERE RoleID IN ('P','T')
        GROUP BY ESYear, ESMonth
    ),
    Den_Billed AS
    (
        -- V denominator = F
        SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS DenValue
        FROM dbo.Cove_ES_PMS
        WHERE RoleID = 'F'
        GROUP BY ESYear, ESMonth
    ),
    Num_Paid AS
    (
        -- W numerator = P
        SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
        FROM dbo.Cove_ES_Cash
        WHERE RoleID IN ('P')
        GROUP BY ESYear, ESMonth
    ),
    Den_Paid AS
    (
        -- W denominator = H
        SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS DenValue
        FROM dbo.Cove_ES_PMS
        WHERE RoleID IN ('H')
        GROUP BY ESYear, ESMonth
    ),
    Num_Adj AS
    (
        -- X numerator = P + T
        SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
        FROM dbo.Cove_ES_Cash
        WHERE RoleID IN ('P','T')
        GROUP BY ESYear, ESMonth
    ),
    Den_Adj AS
    (
        -- X denominator = H + J + L + N.1 + N.2
        SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS DenValue
        FROM dbo.Cove_ES_PMS
        WHERE RoleID IN ('H','J','L','N.1','N.2')
        GROUP BY ESYear, ESMonth
    )
    INSERT INTO dbo.Cove_ES_Avg
    (
        RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt
    )
    SELECT
        'V',
        'Average Payment ($) - Total Pay/Billed Claims',
        p.ESYear,
        p.ESMonth,
        ISNULL(d.DenValue,0),
        ISNULL(ROUND(ISNULL(n.NumValue,0) / NULLIF(d.DenValue,0), 2), 0),
        GETDATE()
    FROM #Periods p
    LEFT JOIN Num_Billed n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
    LEFT JOIN Den_Billed d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth

    UNION ALL

    SELECT
        'W',
        'Average Payment ($) - Total Pay/Paid Claims',
        p.ESYear,
        p.ESMonth,
        ISNULL(d.DenValue,0),
        ISNULL(ROUND(ISNULL(n.NumValue,0) / NULLIF(d.DenValue,0), 2), 0),
        GETDATE()
    FROM #Periods p
    LEFT JOIN Num_Paid n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
    LEFT JOIN Den_Paid d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth

    UNION ALL

    SELECT
        'X',
        'Average Payment ($) - Total Pay/Adjudicated Claims',
        p.ESYear,
        p.ESMonth,
        ISNULL(d.DenValue,0),
        ISNULL(ROUND(ISNULL(n.NumValue,0) / NULLIF(d.DenValue,0), 2), 0),
        GETDATE()
    FROM #Periods p
    LEFT JOIN Num_Adj n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
    LEFT JOIN Den_Adj d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;

    PRINT 'usp_RefreshCove_ExecutiveSummary completed.';
END;
GO

/* Recompute G after LIS refresh (Capture runs LIS_Alt after this SP). */
CREATE OR ALTER PROCEDURE dbo.usp_Cove_ES_UpdatePmsBilledMismatch
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.Cove_ES_PMS', 'U') IS NULL OR OBJECT_ID('dbo.Cove_ES_LIS', 'U') IS NULL
        RETURN;

    UPDATE g
    SET g.ESMonthClaimCount =
            CASE
                WHEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0) > 0
                THEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0)
                ELSE 0
            END,
        g.RefreshedAt = GETDATE()
    FROM dbo.Cove_ES_PMS AS g
    INNER JOIN dbo.Cove_ES_PMS AS f
        ON  f.ESYear  = g.ESYear
        AND f.ESMonth = g.ESMonth
        AND f.RoleID  = 'F'
    LEFT JOIN dbo.Cove_ES_LIS AS lis
        ON  lis.ESYear  = g.ESYear
        AND lis.ESMonth = g.ESMonth
        AND lis.RoleID  = 'C'
    WHERE g.RoleID = 'G';
END;
GO

PRINT 'FIX_Cove_ES_BilledMismatch_G_FromLisBillable.sql — usp_RefreshCove_ExecutiveSummary updated.';
GO
