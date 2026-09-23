/*
    Cove Executive Summary - weighted Average Payment year totals
    Date: 2026-09-23
    Database: CoveLRN

    Problem
    -------
    dbo.Cove_ES_Avg contains monthly rows and a (0,0) Grand Total row, but no
    (year,0) rows. The UI therefore has no weighted year result and can fall
    back to adding monthly averages, which is mathematically incorrect.

    Fix
    ---
    Keep the application-facing procedure name unchanged:
        dbo.usp_RefreshCove_ExecutiveSummary

    The existing implementation is retained as an internal core procedure.
    The public procedure calls it and then inserts one weighted-average row
    per year for V/W/X, using the same formulas as the existing (0,0) Grand
    Total:

      V = (P + T) / F
      W = P / H
      X = (P + T) / (H + J + L + N.1 + N.2)

    This file is idempotent. It also repairs the current snapshot immediately,
    without requiring an application deployment.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.usp_RefreshCove_ExecutiveSummary', N'P') IS NULL
    THROW 50001, 'dbo.usp_RefreshCove_ExecutiveSummary was not found.', 1;
GO

/*
    Preserve the current implementation once. On later executions, the core
    already exists and only the public wrapper is refreshed.
*/
IF OBJECT_ID(N'dbo.usp_RefreshCove_ExecutiveSummary_AvgYearTotals_Core', N'P') IS NULL
BEGIN
    EXEC sys.sp_rename
        @objname = N'dbo.usp_RefreshCove_ExecutiveSummary',
        @newname = N'usp_RefreshCove_ExecutiveSummary_AvgYearTotals_Core',
        @objtype = N'OBJECT';
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    EXEC dbo.usp_RefreshCove_ExecutiveSummary_AvgYearTotals_Core;

    /*
        The core refresh truncates and reloads Cove_ES_Avg. Recreate annual
        sentinel rows after every refresh. Exclude ESMonth=0 source rows so
        Grand Total and any prior annual rows are never folded into a year.
    */
    DELETE FROM dbo.Cove_ES_Avg
    WHERE ESYear > 0
      AND ESMonth = 0
      AND RoleID IN (N'V', N'W', N'X');

    ;WITH CashYear AS
    (
        SELECT
            ESYear,
            SUM(CASE WHEN RoleID IN (N'P', N'T')
                     THEN ESMonthChargeAmount ELSE 0 END) AS PayPlusPartial,
            SUM(CASE WHEN RoleID = N'P'
                     THEN ESMonthChargeAmount ELSE 0 END) AS FullyPaidPayment
        FROM dbo.Cove_ES_Cash
        WHERE ESYear > 0
          AND ESMonth BETWEEN 1 AND 12
        GROUP BY ESYear
    ),
    PmsYear AS
    (
        SELECT
            ESYear,
            SUM(CASE WHEN RoleID = N'F'
                     THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS BilledClaims,
            SUM(CASE WHEN RoleID = N'H'
                     THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS PaidClaims,
            SUM(CASE WHEN RoleID IN (N'H', N'J', N'L', N'N.1', N'N.2')
                     THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS AdjudicatedClaims
        FROM dbo.Cove_ES_PMS
        WHERE ESYear > 0
          AND ESMonth BETWEEN 1 AND 12
        GROUP BY ESYear
    ),
    Annual AS
    (
        SELECT
            COALESCE(c.ESYear, p.ESYear) AS ESYear,
            ISNULL(c.PayPlusPartial, 0) AS PayPlusPartial,
            ISNULL(c.FullyPaidPayment, 0) AS FullyPaidPayment,
            ISNULL(p.BilledClaims, 0) AS BilledClaims,
            ISNULL(p.PaidClaims, 0) AS PaidClaims,
            ISNULL(p.AdjudicatedClaims, 0) AS AdjudicatedClaims
        FROM CashYear c
        FULL OUTER JOIN PmsYear p ON p.ESYear = c.ESYear
    )
    INSERT INTO dbo.Cove_ES_Avg
    (
        RoleID,
        Description,
        ESYear,
        ESMonth,
        ESMonthClaimCount,
        ESMonthChargeAmount,
        RefreshedAt
    )
    SELECT
        v.RoleID,
        v.Description,
        a.ESYear,
        0,
        CONVERT(INT, v.Denominator),
        CONVERT(DECIMAL(18,2),
            CASE WHEN v.Denominator = 0 THEN 0
                 ELSE ROUND(v.Numerator / v.Denominator, 2) END),
        GETDATE()
    FROM Annual a
    CROSS APPLY
    (
        VALUES
        (
            N'V',
            N'Average Payment ($) - Total Pay/Billed Claims',
            CONVERT(DECIMAL(38,6), a.PayPlusPartial),
            CONVERT(DECIMAL(38,6), a.BilledClaims)
        ),
        (
            N'W',
            N'Average Payment ($) - Total Pay/Paid Claims',
            CONVERT(DECIMAL(38,6), a.FullyPaidPayment),
            CONVERT(DECIMAL(38,6), a.PaidClaims)
        ),
        (
            N'X',
            N'Average Payment ($) - Total Pay/Adjudicated Claims',
            CONVERT(DECIMAL(38,6), a.PayPlusPartial),
            CONVERT(DECIMAL(38,6), a.AdjudicatedClaims)
        )
    ) v(RoleID, Description, Numerator, Denominator);
END;
GO

/*
    Apply the fix to the current snapshot now. This runs the normal refresh,
    followed by the new annual weighted-average step.
*/
EXEC dbo.usp_RefreshCove_ExecutiveSummary;
GO

/*
    Verification: each year must return exactly one V/W/X row at ESMonth=0.
    These are the values used by the 2025 Total / 2026 Total columns.
*/
SELECT
    RoleID,
    Description,
    ESYear,
    ESMonth,
    ESMonthClaimCount AS DenominatorClaimCount,
    ESMonthChargeAmount AS WeightedAverage
FROM dbo.Cove_ES_Avg
WHERE ESYear > 0
  AND ESMonth = 0
  AND RoleID IN (N'V', N'W', N'X')
ORDER BY ESYear, RoleID;
GO
