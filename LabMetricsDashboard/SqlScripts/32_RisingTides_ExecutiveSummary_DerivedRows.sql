/*
    Rising Tides Executive Summary - rows that depend on other sections
    (same pattern as Cove: FIX_Cove_ExecutiveSummary_BilledMismatch_F_Minus_LisBilled.sql)

    1. dbo.usp_RT_ES_UpdatePmsBilledMismatch
         PMS P  "Billed Mismatches - Non Diagnose LIS Samples"
           = MAX( PMS O [Billed - Includes all Claims Billed in AMD]
                  - ( LIS L_A1  [Billed to Insurance]
                    + LIS L_A4b [Client Bill - Billed]
                    + LIS L_A5a [Self Pay - Billed] ), 0 )
         Needs RT_ES_PMS and RT_ES_LIS to be complete.

    2. dbo.usp_RT_ES_RefreshAvgPaymentPerClaim   (RT_ES_Avg, "Average Payment Per Claim")
         Total Pay = Cash Z [Insurance Payment (fully paid)] + AA [Partially Paid] + AB [Patient Payment]
         AH  = Total Pay / PMS O                                  (Billed claims)
         AI1 = Total Pay / PMS S + V + W                          (Paid claims)
         AJ  = Total Pay / PMS S + T + U + V + W + X1 + X3        (Adjudicated claims)
         Monthly rows, a (Year, 0) row per year and the (0, 0) Grand Total.
         Year / Grand Total = SUM of the monthly numerators / SUM of the monthly denominators.
         Needs RT_ES_PMS and RT_ES_Cash to be complete.

    3. dbo.usp_RT_ES_RefreshDerivedRows  - runs 1 then 2.

    The capture flow runs usp_RefreshRT_ExecutiveSummary (PMS + Cash) and then
    usp_RefreshRT_ExecutiveSummary_LIS_Alt (LIS). A call to usp_RT_ES_RefreshDerivedRows
    is appended to the end of BOTH procedures (currently deployed code is preserved),
    so the derived rows are recalculated once LIS, PMS and Cash are all complete.
    No application change is required.
*/
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RT_ES_UpdatePmsBilledMismatch
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.RT_ES_PMS', 'U') IS NULL
       OR OBJECT_ID('dbo.RT_ES_LIS', 'U') IS NULL
        RETURN;

    ;WITH LisBilledM AS
    (
        SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS Cnt
        FROM dbo.RT_ES_LIS
        WHERE RoleID IN ('L_A1', 'L_A4b', 'L_A5a')
          AND ESYear <> 0
        GROUP BY ESYear, ESMonth
    ),
    LisBilled AS
    (
        SELECT ESYear, ESMonth, Cnt FROM LisBilledM
        UNION ALL
        SELECT 0, 0, ISNULL(SUM(Cnt), 0) FROM LisBilledM
    )
    UPDATE p
    SET p.ESMonthClaimCount =
            CASE WHEN ISNULL(o.ESMonthClaimCount, 0) - ISNULL(lb.Cnt, 0) > 0
                 THEN ISNULL(o.ESMonthClaimCount, 0) - ISNULL(lb.Cnt, 0)
                 ELSE 0 END,
        p.Description = 'Billed Mismatches - Non Diagnose LIS Samples',
        p.RefreshedAt = GETDATE()
    FROM dbo.RT_ES_PMS AS p
    INNER JOIN dbo.RT_ES_PMS AS o
        ON  o.ESYear  = p.ESYear
        AND o.ESMonth = p.ESMonth
        AND o.RoleID  = 'O'
    LEFT JOIN LisBilled AS lb
        ON  lb.ESYear  = p.ESYear
        AND lb.ESMonth = p.ESMonth
    WHERE p.RoleID = 'P';
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RT_ES_RefreshAvgPaymentPerClaim
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.RT_ES_Avg', 'U') IS NULL
       OR OBJECT_ID('dbo.RT_ES_PMS', 'U') IS NULL
       OR OBJECT_ID('dbo.RT_ES_Cash', 'U') IS NULL
        RETURN;

    DROP TABLE IF EXISTS #AvgMonth;

    SELECT m.ESYear, m.ESMonth,
           ISNULL(pay.TotalPay, 0)   AS TotalPay,
           ISNULL(cnt.BilledCnt, 0)  AS BilledCnt,
           ISNULL(cnt.PaidCnt, 0)    AS PaidCnt,
           ISNULL(cnt.AdjCnt, 0)     AS AdjCnt
    INTO #AvgMonth
    FROM
    (
        SELECT DISTINCT ESYear, ESMonth FROM dbo.RT_ES_PMS WHERE ESYear <> 0 AND ESMonth <> 0
        UNION
        SELECT DISTINCT ESYear, ESMonth FROM dbo.RT_ES_Cash WHERE ESYear <> 0 AND ESMonth <> 0
    ) AS m
    LEFT JOIN
    (
        SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS TotalPay
        FROM dbo.RT_ES_Cash
        WHERE RoleID IN ('Z', 'AA', 'AB') AND ESYear <> 0 AND ESMonth <> 0
        GROUP BY ESYear, ESMonth
    ) AS pay ON pay.ESYear = m.ESYear AND pay.ESMonth = m.ESMonth
    LEFT JOIN
    (
        SELECT ESYear, ESMonth,
               SUM(CASE WHEN RoleID = 'O' THEN ESMonthClaimCount ELSE 0 END)                                     AS BilledCnt,
               SUM(CASE WHEN RoleID IN ('S', 'V', 'W') THEN ESMonthClaimCount ELSE 0 END)                         AS PaidCnt,
               SUM(CASE WHEN RoleID IN ('S', 'T', 'U', 'V', 'W', 'X1', 'X3') THEN ESMonthClaimCount ELSE 0 END)   AS AdjCnt
        FROM dbo.RT_ES_PMS
        WHERE ESYear <> 0 AND ESMonth <> 0
        GROUP BY ESYear, ESMonth
    ) AS cnt ON cnt.ESYear = m.ESYear AND cnt.ESMonth = m.ESMonth;

    DROP TABLE IF EXISTS #AvgPeriod;

    SELECT ESYear, ESMonth, TotalPay, BilledCnt, PaidCnt, AdjCnt
    INTO #AvgPeriod
    FROM #AvgMonth
    UNION ALL
    SELECT ESYear, 0, SUM(TotalPay), SUM(BilledCnt), SUM(PaidCnt), SUM(AdjCnt)
    FROM #AvgMonth
    GROUP BY ESYear
    UNION ALL
    SELECT 0, 0, ISNULL(SUM(TotalPay), 0), ISNULL(SUM(BilledCnt), 0), ISNULL(SUM(PaidCnt), 0), ISNULL(SUM(AdjCnt), 0)
    FROM #AvgMonth;

    BEGIN TRAN;

    DELETE FROM dbo.RT_ES_Avg;

    INSERT INTO dbo.RT_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT 'AH', 'Average Payment ($) - Total Pay/Billed Claims', ESYear, ESMonth, BilledCnt,
           CASE WHEN BilledCnt = 0 THEN 0 ELSE TotalPay / BilledCnt END, GETDATE()
    FROM #AvgPeriod
    UNION ALL
    SELECT 'AI1', 'Average Payment ($) - Total Pay/Paid Claims', ESYear, ESMonth, PaidCnt,
           CASE WHEN PaidCnt = 0 THEN 0 ELSE TotalPay / PaidCnt END, GETDATE()
    FROM #AvgPeriod
    UNION ALL
    SELECT 'AJ', 'Average Payment ($) - Total Pay/Adjudicated Claims', ESYear, ESMonth, AdjCnt,
           CASE WHEN AdjCnt = 0 THEN 0 ELSE TotalPay / AdjCnt END, GETDATE()
    FROM #AvgPeriod;

    COMMIT;

    DROP TABLE IF EXISTS #AvgMonth;
    DROP TABLE IF EXISTS #AvgPeriod;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RT_ES_RefreshDerivedRows
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.usp_RT_ES_UpdatePmsBilledMismatch;
    EXEC dbo.usp_RT_ES_RefreshAvgPaymentPerClaim;
END;
GO

/*
    Append "EXEC dbo.usp_RT_ES_RefreshDerivedRows;" to the end of the deployed
    PMS/Cash refresh procedure (standalone refresh uses the latest LIS snapshot).
*/
DECLARE @pmsProcedureId INT = OBJECT_ID('dbo.usp_RefreshRT_ExecutiveSummary', 'P');

IF @pmsProcedureId IS NULL
    THROW 51103, 'dbo.usp_RefreshRT_ExecutiveSummary was not found.', 1;

DECLARE @pmsDefinition NVARCHAR(MAX) = OBJECT_DEFINITION(@pmsProcedureId);

IF @pmsDefinition IS NULL
    THROW 51104, 'Unable to read dbo.usp_RefreshRT_ExecutiveSummary definition.', 1;

IF @pmsDefinition NOT LIKE '%EXEC dbo.usp_RT_ES_RefreshDerivedRows%'
BEGIN
    DECLARE @pmsProcedureKeyword INT = PATINDEX('%PROCEDURE%', UPPER(@pmsDefinition));
    DECLARE @pmsLastEnd INT =
        LEN(@pmsDefinition) - CHARINDEX('DNE', REVERSE(UPPER(@pmsDefinition))) - 1;

    IF @pmsProcedureKeyword = 0
       OR @pmsLastEnd <= 0
       OR LTRIM(RTRIM(REPLACE(REPLACE(
            SUBSTRING(@pmsDefinition, @pmsLastEnd, LEN(@pmsDefinition)),
            CHAR(13), ''), CHAR(10), '')))
            NOT IN ('END', 'END;')
        THROW 51105, 'Unable to safely patch dbo.usp_RefreshRT_ExecutiveSummary.', 1;

    SET @pmsDefinition =
        N'ALTER ' + SUBSTRING(@pmsDefinition, @pmsProcedureKeyword, @pmsLastEnd - @pmsProcedureKeyword)
        + N'    -- Billed Mismatches (P) + Average Payment Per Claim, after LIS/PMS/Cash.'
        + CHAR(13) + CHAR(10)
        + N'    EXEC dbo.usp_RT_ES_RefreshDerivedRows;'
        + CHAR(13) + CHAR(10)
        + SUBSTRING(@pmsDefinition, @pmsLastEnd, LEN(@pmsDefinition));

    EXEC sys.sp_executesql @pmsDefinition;
END;
GO

/*
    Append the same call to the end of the deployed LIS refresh procedure, which the
    capture flow runs after the PMS/Cash procedure.
*/
DECLARE @lisProcedureId INT = OBJECT_ID('dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt', 'P');

IF @lisProcedureId IS NULL
    THROW 51100, 'dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt was not found.', 1;

DECLARE @definition NVARCHAR(MAX) = OBJECT_DEFINITION(@lisProcedureId);

IF @definition IS NULL
    THROW 51101, 'Unable to read dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt definition.', 1;

IF @definition NOT LIKE '%EXEC dbo.usp_RT_ES_RefreshDerivedRows%'
BEGIN
    DECLARE @procedureKeyword INT = PATINDEX('%PROCEDURE%', UPPER(@definition));
    DECLARE @lastEnd INT =
        LEN(@definition) - CHARINDEX('DNE', REVERSE(UPPER(@definition))) - 1;

    IF @procedureKeyword = 0
       OR @lastEnd <= 0
       OR LTRIM(RTRIM(REPLACE(REPLACE(
            SUBSTRING(@definition, @lastEnd, LEN(@definition)),
            CHAR(13), ''), CHAR(10), '')))
            NOT IN ('END', 'END;')
        THROW 51102, 'Unable to safely patch dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt.', 1;

    SET @definition =
        N'ALTER ' + SUBSTRING(@definition, @procedureKeyword, @lastEnd - @procedureKeyword)
        + N'    -- Billed Mismatches (P) + Average Payment Per Claim, after LIS/PMS/Cash.'
        + CHAR(13) + CHAR(10)
        + N'    EXEC dbo.usp_RT_ES_RefreshDerivedRows;'
        + CHAR(13) + CHAR(10)
        + SUBSTRING(@definition, @lastEnd, LEN(@definition));

    EXEC sys.sp_executesql @definition;
END;
GO

-- Recalculate the current snapshot now.
EXEC dbo.usp_RT_ES_RefreshDerivedRows;
GO

-- Verification 1: Billed Mismatches. Difference must be 0 on every row.
;WITH LisBilledM AS
(
    SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS Cnt
    FROM dbo.RT_ES_LIS
    WHERE RoleID IN ('L_A1', 'L_A4b', 'L_A5a') AND ESYear <> 0
    GROUP BY ESYear, ESMonth
),
LisBilled AS
(
    SELECT ESYear, ESMonth, Cnt FROM LisBilledM
    UNION ALL SELECT 0, 0, ISNULL(SUM(Cnt), 0) FROM LisBilledM
)
SELECT o.ESYear, o.ESMonth,
       o.ESMonthClaimCount       AS PmsBilled_O,
       ISNULL(lb.Cnt, 0)         AS LisBilled_A1_A4b_A5a,
       p.ESMonthClaimCount       AS StoredMismatch_P,
       CASE WHEN o.ESMonthClaimCount - ISNULL(lb.Cnt, 0) > 0 THEN o.ESMonthClaimCount - ISNULL(lb.Cnt, 0) ELSE 0 END
           - p.ESMonthClaimCount AS Difference
FROM dbo.RT_ES_PMS o
INNER JOIN dbo.RT_ES_PMS p ON p.ESYear = o.ESYear AND p.ESMonth = o.ESMonth AND p.RoleID = 'P'
LEFT JOIN LisBilled lb ON lb.ESYear = o.ESYear AND lb.ESMonth = o.ESMonth
WHERE o.RoleID = 'O'
ORDER BY CASE WHEN o.ESYear = 0 THEN 1 ELSE 0 END, o.ESYear, o.ESMonth;
GO

-- Verification 2: Average Payment Per Claim (year totals and Grand Total).
SELECT RoleID, Description, ESYear, ESMonth,
       ESMonthClaimCount   AS Denominator,
       ESMonthChargeAmount AS AveragePayment
FROM dbo.RT_ES_Avg
WHERE ESMonth = 0
ORDER BY RoleID, CASE WHEN ESYear = 0 THEN 1 ELSE 0 END, ESYear;
GO
