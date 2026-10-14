/*
    Elixir client feedback fixes - 2026-09-23

    1. Unbilled x Aging: rows are PayerName_Raw; exclude blank payers.
    2. Panel vs Payment: include every valid CheckDate (remove 2026-04-01 exclusion).
    3. Insurance vs Payment: use every valid CheckDate.
    4. Executive Summary:
       - F/Q exclude Unbilled, Unbilled - PB and Billed Amount 0.
       - J/S include every Fully Paid claim, regardless of BillStatus.
       - I mismatch = MAX(PMS F - LIS C [Billed], 0), after LIS refresh.
       - Y/Z/AA annual totals are weighted ratios, not sums of monthly averages.

    Existing application-facing procedure names are retained.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(PayerName_Raw)) AS PanelName,
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown') AS AgingBucket,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        )) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown');

    TRUNCATE TABLE dbo.Elix_UnbilledAging;

    INSERT INTO dbo.Elix_UnbilledAging
        (PanelName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, AgingBucket, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw;

    DROP TABLE IF EXISTS #Raw;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetElix_UnbilledAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, AgingBucket, ClaimCount, TotalCharges
        FROM dbo.Elix_UnbilledAging
        ORDER BY PanelName, AgingBucket;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(PayerName_Raw)) AS PanelName,
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown') AS AgingBucket,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        )) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
      AND (@HasPayerFilter = 0
           OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0
           OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))
              IN (SELECT Value FROM @PanelList))
      AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
      AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown')
    ORDER BY PanelName, AgingBucket;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Elix_CS_PanelVsPayment;

    INSERT INTO dbo.Elix_CS_PanelVsPayment
        (PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(Panelname)),
        YEAR(TRY_CAST(CheckDate AS DATE)),
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT),
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')),
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0),
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND NULLIF(LTRIM(RTRIM(CheckDate)), '') IS NOT NULL
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
    GROUP BY
        LTRIM(RTRIM(Panelname)),
        YEAR(TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_CS_InsuranceVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            YEAR(TRY_CAST(CheckDate AS DATE)) AS BillYear,
            MONTH(TRY_CAST(CheckDate AS DATE)) AS BillMonth,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND NULLIF(LTRIM(RTRIM(CheckDate)), '') IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            YEAR(TRY_CAST(CheckDate AS DATE)),
            MONTH(TRY_CAST(CheckDate AS DATE))
    ),
    Grand AS
    (
        SELECT BillYear, BillMonth,
            NULLIF(SUM(InsurancePayment), 0) AS TotalInsurancePayment
        FROM Agg
        GROUP BY BillYear, BillMonth
    )
    SELECT
        a.PayerName,
        CAST(a.BillYear AS SMALLINT) AS BillYear,
        CAST(a.BillMonth AS TINYINT) AS BillMonth,
        a.NoOfPaidClaims,
        a.InsurancePayment,
        CAST(a.InsurancePayment * 100.0 /
             ISNULL(g.TotalInsurancePayment, 1) AS DECIMAL(9,4)) AS PaymentPct
    INTO #Out
    FROM Agg a
    INNER JOIN Grand g
        ON g.BillYear = a.BillYear AND g.BillMonth = a.BillMonth;

    TRUNCATE TABLE dbo.Elix_CS_InsuranceVsPayment;

    INSERT INTO dbo.Elix_CS_InsuranceVsPayment
        (PayerName, BillYear, BillMonth, NoOfPaidClaims,
         InsurancePayment, PaymentPct, RefreshedAt)
    SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims,
           InsurancePayment, PaymentPct, GETDATE()
    FROM #Out;

    DROP TABLE IF EXISTS #Out;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetElix_CS_InsuranceVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CAST(YEAR(TRY_CAST(CheckDate AS DATE)) AS INT) AS BillYear,
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT) AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND NULLIF(LTRIM(RTRIM(CheckDate)), '') IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
          AND (@HasPayerFilter = 0
               OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0
               OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo IS NULL OR TRY_CAST(CheckDate AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            CAST(YEAR(TRY_CAST(CheckDate AS DATE)) AS INT),
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)
    ),
    Grand AS
    (
        SELECT BillYear, BillMonth, NULLIF(SUM(InsurancePayment), 0) AS Total
        FROM Agg
        GROUP BY BillYear, BillMonth
    )
    SELECT
        a.PayerName, a.BillYear, a.BillMonth, a.NoOfPaidClaims,
        a.InsurancePayment,
        CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM Agg a
    INNER JOIN Grand g
        ON g.BillYear = a.BillYear AND g.BillMonth = a.BillMonth
    ORDER BY a.BillYear, a.BillMonth, a.InsurancePayment DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Elix_ES_ApplyClientCorrections
AS
BEGIN
    SET NOCOUNT ON;

    -- F - No. of Billed Claims
    UPDATE p
    SET p.ESMonthClaimCount =
        (
            SELECT COUNT(DISTINCT NULLIF(LTRIM(RTRIM(c.AccessionNumber)), ''))
            FROM dbo.ClaimLevelData c
            WHERE (p.ESYear = 0 OR
                  (YEAR(TRY_CAST(c.DateofService AS DATE)) = p.ESYear
                   AND MONTH(TRY_CAST(c.DateofService AS DATE)) = p.ESMonth))
              AND LTRIM(RTRIM(ISNULL(c.BillStatus, ''))) = 'Billed'
              AND LTRIM(RTRIM(ISNULL(c.ClaimStatus, '')))
                  NOT IN ('Billed Amount 0', 'Unbilled', 'Unbilled - PB')
        ),
        p.RefreshedAt = GETDATE()
    FROM dbo.Elix_ES_PMS p
    WHERE p.RoleID = 'F';

    -- J - Fully Paid count, independent of BillStatus.
    UPDATE p
    SET p.ESMonthClaimCount =
        (
            SELECT COUNT(DISTINCT NULLIF(LTRIM(RTRIM(c.AccessionNumber)), ''))
            FROM dbo.ClaimLevelData c
            WHERE (p.ESYear = 0 OR
                  (YEAR(TRY_CAST(c.DateofService AS DATE)) = p.ESYear
                   AND MONTH(TRY_CAST(c.DateofService AS DATE)) = p.ESMonth))
              AND LTRIM(RTRIM(ISNULL(c.ClaimStatus, ''))) = 'Fully Paid'
        ),
        p.RefreshedAt = GETDATE()
    FROM dbo.Elix_ES_PMS p
    WHERE p.RoleID = 'J';

    -- Q - Total Billed, excluding all unbilled statuses.
    UPDATE q
    SET q.ESMonthChargeAmount =
        (
            SELECT ISNULL(SUM(TRY_CAST(c.ChargeAmount AS DECIMAL(18,2))), 0)
            FROM dbo.ClaimLevelData c
            WHERE (q.ESYear = 0 OR
                  (YEAR(TRY_CAST(c.DateofService AS DATE)) = q.ESYear
                   AND MONTH(TRY_CAST(c.DateofService AS DATE)) = q.ESMonth))
              AND LTRIM(RTRIM(ISNULL(c.BillStatus, ''))) = 'Billed'
              AND LTRIM(RTRIM(ISNULL(c.ClaimStatus, '')))
                  NOT IN ('Billed Amount 0', 'Unbilled', 'Unbilled - PB')
        ),
        q.RefreshedAt = GETDATE()
    FROM dbo.Elix_ES_Cash q
    WHERE q.RoleID = 'Q';

    -- S - Fully Paid value, independent of BillStatus.
    UPDATE s
    SET s.ESMonthChargeAmount =
        (
            SELECT ISNULL(SUM(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2))), 0)
            FROM dbo.ClaimLevelData c
            WHERE (s.ESYear = 0 OR
                  (YEAR(TRY_CAST(c.DateofService AS DATE)) = s.ESYear
                   AND MONTH(TRY_CAST(c.DateofService AS DATE)) = s.ESMonth))
              AND LTRIM(RTRIM(ISNULL(c.ClaimStatus, ''))) = 'Fully Paid'
        ),
        s.RefreshedAt = GETDATE()
    FROM dbo.Elix_ES_Cash s
    WHERE s.RoleID = 'S';

    -- I - same mismatch logic used by Cove: MAX(F - LIS C, 0).
    UPDATE i
    SET i.ESMonthClaimCount =
        CASE WHEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(c.ESMonthClaimCount, 0) > 0
             THEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(c.ESMonthClaimCount, 0)
             ELSE 0 END,
        i.RefreshedAt = GETDATE()
    FROM dbo.Elix_ES_PMS i
    INNER JOIN dbo.Elix_ES_PMS f
        ON f.ESYear = i.ESYear AND f.ESMonth = i.ESMonth AND f.RoleID = 'F'
    LEFT JOIN dbo.Elix_ES_LIS c
        ON c.ESYear = i.ESYear AND c.ESMonth = i.ESMonth AND c.RoleID = 'C'
    WHERE i.RoleID = 'I';

    -- Rebuild monthly, annual and Grand Total averages from their components.
    DELETE FROM dbo.Elix_ES_Avg
    WHERE RoleID IN ('Y', 'Z', 'AA');

    ;WITH Periods AS
    (
        SELECT ESYear, ESMonth
        FROM dbo.Elix_ES_PMS
        WHERE RoleID = 'F'
    ),
    CashPeriod AS
    (
        SELECT ESYear, ESMonth,
            SUM(CASE WHEN RoleID IN ('S','W') THEN ESMonthChargeAmount ELSE 0 END) AS PayPlusPartial,
            SUM(CASE WHEN RoleID = 'S' THEN ESMonthChargeAmount ELSE 0 END) AS FullyPaidPayment,
            SUM(CASE WHEN RoleID IN ('S','W','V') THEN ESMonthChargeAmount ELSE 0 END) AS AdjudicatedPayment
        FROM dbo.Elix_ES_Cash
        GROUP BY ESYear, ESMonth
    ),
    PmsPeriod AS
    (
        SELECT ESYear, ESMonth,
            SUM(CASE WHEN RoleID = 'F' THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS BilledClaims,
            SUM(CASE WHEN RoleID = 'J' THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS PaidClaims,
            SUM(CASE WHEN RoleID IN ('J','M','K','L','N','O','P.1','P.2')
                     THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS AdjudicatedClaims
        FROM dbo.Elix_ES_PMS
        GROUP BY ESYear, ESMonth
    )
    INSERT INTO dbo.Elix_ES_Avg
        (RoleID, Description, ESYear, ESMonth,
         ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT v.RoleID, v.Description, p.ESYear, p.ESMonth,
        CONVERT(INT, v.Denominator),
        CONVERT(DECIMAL(18,2), CASE WHEN v.Denominator = 0 THEN 0
            ELSE ROUND(v.Numerator / v.Denominator, 2) END),
        GETDATE()
    FROM Periods p
    LEFT JOIN CashPeriod c ON c.ESYear = p.ESYear AND c.ESMonth = p.ESMonth
    LEFT JOIN PmsPeriod m ON m.ESYear = p.ESYear AND m.ESMonth = p.ESMonth
    CROSS APPLY
    (
        VALUES
            ('Y', 'Average Payment ($) - Total Pay/Billed Claims',
             CONVERT(DECIMAL(38,6), ISNULL(c.PayPlusPartial,0)), m.BilledClaims),
            ('Z', 'Average Payment ($) - Total Pay/Paid Claims',
             CONVERT(DECIMAL(38,6), ISNULL(c.FullyPaidPayment,0)), m.PaidClaims),
            ('AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
             CONVERT(DECIMAL(38,6), ISNULL(c.AdjudicatedPayment,0)), m.AdjudicatedClaims)
    ) v(RoleID, Description, Numerator, Denominator);

    ;WITH CashYear AS
    (
        SELECT ESYear,
            SUM(CASE WHEN RoleID IN ('S','W') THEN ESMonthChargeAmount ELSE 0 END) AS PayPlusPartial,
            SUM(CASE WHEN RoleID = 'S' THEN ESMonthChargeAmount ELSE 0 END) AS FullyPaidPayment,
            SUM(CASE WHEN RoleID IN ('S','W','V') THEN ESMonthChargeAmount ELSE 0 END) AS AdjudicatedPayment
        FROM dbo.Elix_ES_Cash
        WHERE ESYear > 0 AND ESMonth BETWEEN 1 AND 12
        GROUP BY ESYear
    ),
    PmsYear AS
    (
        SELECT ESYear,
            SUM(CASE WHEN RoleID = 'F' THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS BilledClaims,
            SUM(CASE WHEN RoleID = 'J' THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS PaidClaims,
            SUM(CASE WHEN RoleID IN ('J','M','K','L','N','O','P.1','P.2')
                     THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS AdjudicatedClaims
        FROM dbo.Elix_ES_PMS
        WHERE ESYear > 0 AND ESMonth BETWEEN 1 AND 12
        GROUP BY ESYear
    )
    INSERT INTO dbo.Elix_ES_Avg
        (RoleID, Description, ESYear, ESMonth,
         ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT v.RoleID, v.Description, p.ESYear, 0,
        CONVERT(INT, v.Denominator),
        CONVERT(DECIMAL(18,2), CASE WHEN v.Denominator = 0 THEN 0
            ELSE ROUND(v.Numerator / v.Denominator, 2) END),
        GETDATE()
    FROM PmsYear p
    LEFT JOIN CashYear c ON c.ESYear = p.ESYear
    CROSS APPLY
    (
        VALUES
            ('Y', 'Average Payment ($) - Total Pay/Billed Claims',
             CONVERT(DECIMAL(38,6), ISNULL(c.PayPlusPartial,0)), p.BilledClaims),
            ('Z', 'Average Payment ($) - Total Pay/Paid Claims',
             CONVERT(DECIMAL(38,6), ISNULL(c.FullyPaidPayment,0)), p.PaidClaims),
            ('AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
             CONVERT(DECIMAL(38,6), ISNULL(c.AdjudicatedPayment,0)), p.AdjudicatedClaims)
    ) v(RoleID, Description, Numerator, Denominator);
END;
GO

/*
    Append the correction helper to both refresh procedures while preserving
    their currently deployed implementations.
*/
DECLARE @Procedures TABLE (ProcedureName SYSNAME NOT NULL);
INSERT INTO @Procedures VALUES
    ('dbo.usp_RefreshElix_ExecutiveSummary'),
    ('dbo.usp_RefreshElix_ExecutiveSummary_LIS_Alt');

DECLARE @ProcedureName SYSNAME;

WHILE EXISTS (SELECT 1 FROM @Procedures)
BEGIN
    SELECT TOP (1) @ProcedureName = ProcedureName FROM @Procedures;

    DECLARE @ObjectId INT = OBJECT_ID(@ProcedureName, 'P');
    IF @ObjectId IS NULL
        THROW 52000, 'Required Elixir Executive Summary procedure was not found.', 1;

    DECLARE @Definition NVARCHAR(MAX) = OBJECT_DEFINITION(@ObjectId);
    IF @Definition IS NULL
        THROW 52001, 'Unable to read an Elixir Executive Summary procedure definition.', 1;

    IF @Definition NOT LIKE '%EXEC dbo.usp_Elix_ES_ApplyClientCorrections%'
    BEGIN
        DECLARE @ProcedureKeyword INT = PATINDEX('%PROCEDURE%', UPPER(@Definition));
        DECLARE @LastEnd INT =
            LEN(@Definition) - CHARINDEX('DNE', REVERSE(UPPER(@Definition))) - 1;

        IF @ProcedureKeyword = 0 OR @LastEnd <= 0
           OR LTRIM(RTRIM(REPLACE(REPLACE(
                SUBSTRING(@Definition, @LastEnd, LEN(@Definition)),
                CHAR(13), ''), CHAR(10), ''))) NOT IN ('END', 'END;')
            THROW 52002, 'Unable to safely patch an Elixir refresh procedure.', 1;

        SET @Definition =
            N'ALTER ' + SUBSTRING(
                @Definition, @ProcedureKeyword, @LastEnd - @ProcedureKeyword)
            + N'    EXEC dbo.usp_Elix_ES_ApplyClientCorrections;'
            + CHAR(13) + CHAR(10)
            + SUBSTRING(@Definition, @LastEnd, LEN(@Definition));

        EXEC sys.sp_executesql @Definition;
    END;

    DELETE FROM @Procedures WHERE ProcedureName = @ProcedureName;
END;
GO

-- Refresh all affected snapshots now.
EXEC dbo.usp_RefreshElix_UnbilledAging;
EXEC dbo.usp_RefreshElix_CS_PanelVsPayment;
EXEC dbo.usp_RefreshElix_CS_InsuranceVsPayment;
EXEC dbo.usp_RefreshElix_ExecutiveSummary;
EXEC dbo.usp_RefreshElix_ExecutiveSummary_LIS_Alt;
GO

-- Verification result sets.
SELECT 'UnbilledAgingBlankPayers' AS CheckName, COUNT(*) AS IssueCount
FROM dbo.ClaimLevelData
WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
  AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NULL;

SELECT 'ExecutiveMismatchDifference' AS CheckName,
    i.ESYear, i.ESMonth,
    i.ESMonthClaimCount -
        CASE WHEN ISNULL(f.ESMonthClaimCount,0) - ISNULL(c.ESMonthClaimCount,0) > 0
             THEN ISNULL(f.ESMonthClaimCount,0) - ISNULL(c.ESMonthClaimCount,0)
             ELSE 0 END AS Difference
FROM dbo.Elix_ES_PMS i
INNER JOIN dbo.Elix_ES_PMS f
    ON f.ESYear = i.ESYear AND f.ESMonth = i.ESMonth AND f.RoleID = 'F'
LEFT JOIN dbo.Elix_ES_LIS c
    ON c.ESYear = i.ESYear AND c.ESMonth = i.ESMonth AND c.RoleID = 'C'
WHERE i.RoleID = 'I';

SELECT RoleID, ESYear, ESMonth,
       ESMonthClaimCount AS Denominator,
       ESMonthChargeAmount AS WeightedAverage
FROM dbo.Elix_ES_Avg
WHERE ESYear > 0 AND ESMonth = 0
ORDER BY ESYear, RoleID;
GO
