/* =====================================================================================
   InHealth DTR - Production Summary (Web UI + Download Excel share these SPs)
   Database : InHealthDTRLRN
   Panel    : PanelNameBasedOnCPT everywhere (never Panelname)
   Payer    : PayerName_Raw
   Billed   : FirstBilledDate is a date OR BillStatus = 'Billed'
   Unbilled : FirstBilledDate is blank OR BillStatus = 'Unbilled'
   Month    : ChargeEnteredDate (yyyy-MM)

   Tab                  Filter                                         Rows / Columns
   -------------------  ---------------------------------------------  ---------------------------------------
   Monthly Summary      Billed, FirstBilledDate set (blank payer kept) Panel > top payers  x  CED month
   Weekly               Billed, BilledWeek set                         Panel > top payers  x  BilledWeek
   CPT Breakdown        All lines (LineLevelData)                      CPT code  x  Count of CPT, Charge
   Payer Breakdown      Billed, PayerName_Raw set                      Payer  x  CED month
   Panel Breakdown      Billed                                         Panel > payers  x  CED month
   Unbilled x Aging     Unbilled                                       Payer  x  AgingDOS
   Payor x Panel        PayerName_Raw set                              Payer  x  Panel
   Coding Summary       Unbilled                                       Panel > CPTCodeXUnitsXModifier

   Claim-level export (ClaimLevel sheets): PanelNameBasedOnCPT is returned as [PanelName].
   ===================================================================================== */
USE InHealthDTRLRN;
GO

CREATE OR ALTER FUNCTION dbo.fn_InH_ProductionClaims
(
    @PayerNames      NVARCHAR(MAX),
    @PanelNames      NVARCHAR(MAX),
    @DosFrom         DATE,
    @DosTo           DATE,
    @FirstBillFrom   DATE,
    @FirstBillTo     DATE,
    @FirstBilledFrom DATE,
    @FirstBilledTo   DATE
)
RETURNS TABLE
AS
RETURN
    WITH Src AS
    (
        SELECT
            NULLIF(LTRIM(RTRIM(c.ClaimID)), N'')                                       AS ClaimID,
            NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N'')                                 AS PayerName,
            ISNULL(NULLIF(LTRIM(RTRIM(c.PanelNameBasedOnCPT)), N''), N'Unknown')       AS PanelName,
            TRY_CAST(NULLIF(LTRIM(RTRIM(c.FirstBilledDate)), N'') AS DATE)             AS FirstBilledDate,
            TRY_CAST(NULLIF(LTRIM(RTRIM(c.DateofService)), N'') AS DATE)               AS DateOfService,
            TRY_CAST(NULLIF(LTRIM(RTRIM(c.ChargeEnteredDate)), N'') AS DATE)           AS ChargeEnteredDate,
            LTRIM(RTRIM(ISNULL(c.BillStatus, N'')))                                    AS BillStatus,
            NULLIF(LTRIM(RTRIM(c.BilledWeek)), N'')                                    AS BilledWeek,
            ISNULL(NULLIF(LTRIM(RTRIM(c.AgingDOS)), N''), N'Unknown')                  AS AgingDOS,
            ISNULL(NULLIF(LTRIM(RTRIM(c.CPTCodeXUnitsXModifier)), N''), N'Unknown')    AS CptDetail,
            ISNULL(TRY_CAST(NULLIF(LTRIM(RTRIM(c.ChargeAmount)), N'') AS DECIMAL(18,2)), 0) AS ChargeAmount
        FROM dbo.ClaimLevelData c
    )
    SELECT
        s.ClaimID,
        s.PayerName,
        s.PanelName,
        s.FirstBilledDate,
        s.DateOfService,
        s.ChargeEnteredDate,
        s.BillStatus,
        s.BilledWeek,
        s.AgingDOS,
        s.CptDetail,
        s.ChargeAmount,
        CONVERT(CHAR(7), s.ChargeEnteredDate, 126) AS EnteredMonth,
        CAST(CASE WHEN s.FirstBilledDate IS NOT NULL OR s.BillStatus = N'Billed'   THEN 1 ELSE 0 END AS BIT) AS IsBilled,
        CAST(CASE WHEN s.FirstBilledDate IS NULL     OR s.BillStatus = N'Unbilled' THEN 1 ELSE 0 END AS BIT) AS IsUnbilled
    FROM Src s
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR ISNULL(s.PayerName, N'(blank)') IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR s.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom         IS NULL OR s.DateOfService     >= @DosFrom)
      AND (@DosTo           IS NULL OR s.DateOfService     <= @DosTo)
      -- @FirstBill* is the page's "Charge Entered Date From/To" filter (InHealth is Rule1).
      AND (@FirstBillFrom   IS NULL OR s.ChargeEnteredDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR s.ChargeEnteredDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR s.FirstBilledDate   >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR s.FirstBilledDate   <= @FirstBilledTo);
GO

/* ---- 1) Monthly Summary: (PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges) ---- */
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_MonthlyBilledProductionSummary
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

    -- Blank PayerName_Raw stays in (as "(blank)"), matching the client's Monthly pivot.
    SELECT PanelName, ISNULL(PayerName, N'(blank)') AS PayerName, EnteredMonth, ClaimID, ChargeAmount
    INTO   #Base
    FROM   dbo.fn_InH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
      AND  FirstBilledDate IS NOT NULL
      AND  EnteredMonth IS NOT NULL;

    ;WITH PayerRanks AS
    (
        SELECT PanelName, PayerName,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY COUNT(ClaimID) DESC, SUM(ChargeAmount) DESC, PayerName) AS PayerRank
        FROM   #Base
        GROUP BY PanelName, PayerName
    )
    SELECT CAST(PanelName AS NVARCHAR(1000))    AS PanelName,
           CAST(N'All Payers' AS NVARCHAR(1000)) AS PayerName,
           CAST(0 AS INT)                        AS PayerRank,
           CAST(EnteredMonth AS NVARCHAR(7))     AS BilledYearMonth,
           CAST(COUNT(ClaimID) AS INT)           AS ClaimCount,
           CAST(SUM(ChargeAmount) AS DECIMAL(18,2)) AS TotalCharges
    FROM   #Base
    GROUP BY PanelName, EnteredMonth
    UNION ALL
    SELECT CAST(b.PanelName AS NVARCHAR(1000)),
           CAST(b.PayerName AS NVARCHAR(1000)),
           CAST(r.PayerRank AS INT),
           CAST(b.EnteredMonth AS NVARCHAR(7)),
           CAST(COUNT(b.ClaimID) AS INT),
           CAST(SUM(b.ChargeAmount) AS DECIMAL(18,2))
    FROM   #Base b
    JOIN   PayerRanks r ON r.PanelName = b.PanelName AND r.PayerName = b.PayerName
    WHERE  r.PayerRank <= 3
    GROUP BY b.PanelName, b.PayerName, r.PayerRank, b.EnteredMonth
    ORDER BY PanelName, BilledYearMonth, PayerRank;
END
GO

/* ---- 2) Weekly: (PanelName, PayerName, PayerRank TINYINT, WeekStart, WeekEnd, WeekLabel, ClaimCount INT, TotalCharges) ----
   BilledWeek is a Tue-Mon label without a year ("Sep 15 - Sep 21"); the year comes from the claim's
   FirstBilledDate (always inside its BilledWeek), so weeks that span New Year resolve correctly. */
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_WeeklyBilledProductionSummary
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

    SELECT PanelName,
           ISNULL(PayerName, N'(blank)') AS PayerName,
           BilledWeek,
           COALESCE(FirstBilledDate, ChargeEnteredDate, CAST(GETDATE() AS DATE)) AS AnchorDate,
           ClaimID,
           ChargeAmount
    INTO   #Base
    FROM   dbo.fn_InH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
      AND  BilledWeek IS NOT NULL;

    ;WITH Parsed AS
    (
        SELECT b.*,
               TRY_CONVERT(DATE,
                   LTRIM(RTRIM(LEFT(b.BilledWeek, CHARINDEX(N'-', b.BilledWeek + N'-') - 1)))
                   + N', ' + CAST(YEAR(b.AnchorDate) AS NVARCHAR(4)), 107) AS ParsedStart
        FROM   #Base b
    )
    SELECT PanelName, PayerName, ClaimID, ChargeAmount,
           CASE
               WHEN ParsedStart IS NULL
                   THEN DATEADD(DAY, -(DATEDIFF(DAY, '19000102', AnchorDate) % 7), AnchorDate)
               WHEN ParsedStart > DATEADD(DAY, 7, AnchorDate)
                   THEN DATEADD(YEAR, -1, ParsedStart)
               ELSE ParsedStart
           END AS WeekStart
    INTO   #Weekly
    FROM   Parsed;

    ;WITH PayerRanks AS
    (
        SELECT PanelName, PayerName,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY COUNT(ClaimID) DESC, SUM(ChargeAmount) DESC, PayerName) AS PayerRank
        FROM   #Weekly
        GROUP BY PanelName, PayerName
    ),
    Agg AS
    (
        SELECT CAST(PanelName AS NVARCHAR(1000))     AS PanelName,
               CAST(N'All Payers' AS NVARCHAR(1000)) AS PayerName,
               CAST(0 AS TINYINT)                    AS PayerRank,
               WeekStart,
               CAST(COUNT(ClaimID) AS INT)           AS ClaimCount,
               CAST(SUM(ChargeAmount) AS DECIMAL(18,2)) AS TotalCharges
        FROM   #Weekly
        GROUP BY PanelName, WeekStart
        UNION ALL
        SELECT CAST(w.PanelName AS NVARCHAR(1000)),
               CAST(w.PayerName AS NVARCHAR(1000)),
               CAST(r.PayerRank AS TINYINT),
               w.WeekStart,
               CAST(COUNT(w.ClaimID) AS INT),
               CAST(SUM(w.ChargeAmount) AS DECIMAL(18,2))
        FROM   #Weekly w
        JOIN   PayerRanks r ON r.PanelName = w.PanelName AND r.PayerName = w.PayerName
        WHERE  r.PayerRank <= 3
        GROUP BY w.PanelName, w.PayerName, r.PayerRank, w.WeekStart
    )
    SELECT PanelName,
           PayerName,
           PayerRank,
           CAST(WeekStart AS DATE)                    AS WeekStart,
           CAST(DATEADD(DAY, 6, WeekStart) AS DATE)   AS WeekEnd,
           CAST(CONVERT(NVARCHAR(10), WeekStart, 23) + N' - '
                + CONVERT(NVARCHAR(10), DATEADD(DAY, 6, WeekStart), 23) AS NVARCHAR(30)) AS WeekLabel,
           ClaimCount,
           TotalCharges
    FROM   Agg
    ORDER BY PanelName, WeekStart, PayerRank;
END
GO

/* ---- 3) CPT Breakdown: (CPTCode, BilledYearMonth, CPTCount INT, BilledUnits, TotalCharges) ----
   All LineLevelData lines, grouped by the base CPT code ("80307 - TOX SCREEN" -> "80307").
   CPTCount = Count of CPT lines; month = ChargeEnteredDate ('1900-01' when blank so totals stay complete). */
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_CPTBreakdown
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

    DECLARE @PayerList TABLE (Value NVARCHAR(1000) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(1000) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|') WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|') WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Lines AS
    (
        SELECT
            ISNULL(NULLIF(LEFT(LTRIM(l.CPTCode), CHARINDEX(N' ', LTRIM(l.CPTCode) + N' ') - 1), N''), N'Unknown') AS CPTCode,
            ISNULL(CONVERT(CHAR(7), TRY_CAST(NULLIF(LTRIM(RTRIM(l.ChargeEnteredDate)), N'') AS DATE), 126), '1900-01') AS BilledYearMonth,
            ISNULL(TRY_CAST(NULLIF(LTRIM(RTRIM(l.Units)), N'') AS DECIMAL(18,2)), 0)        AS Units,
            ISNULL(TRY_CAST(NULLIF(LTRIM(RTRIM(l.ChargeAmount)), N'') AS DECIMAL(18,2)), 0) AS ChargeAmount
        FROM dbo.LineLevelData l
        WHERE (@HasPayerFilter = 0 OR ISNULL(NULLIF(LTRIM(RTRIM(l.PayerName_Raw)), N''), N'(blank)') IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR EXISTS (
                  SELECT 1
                  FROM   dbo.ClaimLevelData c
                  WHERE  c.ClaimID = l.ClaimID
                    AND  ISNULL(NULLIF(LTRIM(RTRIM(c.PanelNameBasedOnCPT)), N''), N'Unknown') IN (SELECT Value FROM @PanelList)))
          AND (@DosFrom         IS NULL OR TRY_CAST(NULLIF(LTRIM(RTRIM(l.DateofService)),   N'') AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(NULLIF(LTRIM(RTRIM(l.DateofService)),   N'') AS DATE) <= @DosTo)
          AND (@FirstBillFrom   IS NULL OR TRY_CAST(NULLIF(LTRIM(RTRIM(l.ChargeEnteredDate)), N'') AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo     IS NULL OR TRY_CAST(NULLIF(LTRIM(RTRIM(l.ChargeEnteredDate)), N'') AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(NULLIF(LTRIM(RTRIM(l.FirstBilledDate)), N'') AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(NULLIF(LTRIM(RTRIM(l.FirstBilledDate)), N'') AS DATE) <= @FirstBilledTo)
    )
    SELECT CAST(CPTCode AS NVARCHAR(1000))           AS CPTCode,
           CAST(BilledYearMonth AS NVARCHAR(7))      AS BilledYearMonth,
           CAST(COUNT(*) AS INT)                     AS CPTCount,
           CAST(SUM(Units) AS DECIMAL(18,2))         AS BilledUnits,
           CAST(SUM(ChargeAmount) AS DECIMAL(18,2))  AS TotalCharges
    FROM   Lines
    GROUP BY CPTCode, BilledYearMonth
    ORDER BY CPTCode, BilledYearMonth;
END
GO

/* ---- 4) Payer Breakdown: (PayerName, BilledYearMonth, ClaimCount INT, TotalCharges) ---- */
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_PayerBreakdown
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

    SELECT CAST(PayerName AS NVARCHAR(1000))        AS PayerName,
           CAST(EnteredMonth AS NVARCHAR(7))        AS BilledYearMonth,
           CAST(COUNT(ClaimID) AS INT)              AS ClaimCount,
           CAST(SUM(ChargeAmount) AS DECIMAL(18,2)) AS TotalCharges
    FROM   dbo.fn_InH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
      AND  PayerName IS NOT NULL
      AND  EnteredMonth IS NOT NULL
    GROUP BY PayerName, EnteredMonth
    ORDER BY PayerName, BilledYearMonth;
END
GO

/* ---- 5) Panel Breakdown: (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges) ---- */
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_PanelBreakdownWithPayers
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

    SELECT CAST(PanelName AS NVARCHAR(1000))                    AS PanelName,
           CAST(ISNULL(PayerName, N'(blank)') AS NVARCHAR(1000)) AS PayerName,
           CAST(EnteredMonth AS NVARCHAR(7))                    AS BilledYearMonth,
           CAST(COUNT(ClaimID) AS INT)                          AS ClaimCount,
           CAST(SUM(ChargeAmount) AS DECIMAL(18,2))             AS TotalCharges
    FROM   dbo.fn_InH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
      AND  EnteredMonth IS NOT NULL
    GROUP BY PanelName, ISNULL(PayerName, N'(blank)'), EnteredMonth
    ORDER BY PanelName, PayerName, BilledYearMonth;
END
GO

/* ---- 6) Unbilled x Aging: (PayerName, AgingBucket, ClaimCount INT, TotalCharges) - buckets from AgingDOS ---- */
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_UnbilledAging
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

    SELECT CAST(ISNULL(PayerName, N'(blank)') AS NVARCHAR(1000)) AS PayerName,
           CAST(AgingDOS AS NVARCHAR(200))                      AS AgingBucket,
           CAST(COUNT(ClaimID) AS INT)                          AS ClaimCount,
           CAST(SUM(ChargeAmount) AS DECIMAL(18,2))             AS TotalCharges
    FROM   dbo.fn_InH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsUnbilled = 1
    GROUP BY ISNULL(PayerName, N'(blank)'), AgingDOS
    ORDER BY PayerName, AgingBucket;
END
GO

/* ---- 7) Payor x Panel: (PayerName, PanelName, ClaimCount INT, TotalCharges) - every claim with a payer ---- */
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_PayerByPanel
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

    SELECT CAST(PayerName AS NVARCHAR(1000))        AS PayerName,
           CAST(PanelName AS NVARCHAR(1000))        AS PanelName,
           CAST(COUNT(ClaimID) AS INT)              AS ClaimCount,
           CAST(SUM(ChargeAmount) AS DECIMAL(18,2)) AS TotalCharges
    FROM   dbo.fn_InH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  PayerName IS NOT NULL
    GROUP BY PayerName, PanelName
    ORDER BY PayerName, PanelName;
END
GO

/* ---- 8) Coding Summary (unbilled claims) ----
   Result set 1: (PanelName, ClaimCount INT, TotalCharges)
   Result set 2: (PanelName, CPTCodeXUnitsXModifier, ClaimCount INT, TotalCharges) */
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_CodingBreakdown
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

    SELECT PanelName, CptDetail, ClaimID, ChargeAmount
    INTO   #Base
    FROM   dbo.fn_InH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsUnbilled = 1;

    SELECT CAST(PanelName AS NVARCHAR(1000))        AS PanelName,
           CAST(COUNT(ClaimID) AS INT)              AS ClaimCount,
           CAST(SUM(ChargeAmount) AS DECIMAL(18,2)) AS TotalCharges
    FROM   #Base
    GROUP BY PanelName
    ORDER BY TotalCharges DESC;

    SELECT CAST(PanelName AS NVARCHAR(1000))        AS PanelName,
           CAST(CptDetail AS NVARCHAR(MAX))         AS CPTCodeXUnitsXModifier,
           CAST(COUNT(ClaimID) AS INT)              AS ClaimCount,
           CAST(SUM(ChargeAmount) AS DECIMAL(18,2)) AS TotalCharges
    FROM   #Base
    GROUP BY PanelName, CptDetail
    ORDER BY PanelName, TotalCharges DESC;
END
GO

/* ---- 9) Claim-level export buckets: panel filter on PanelNameBasedOnCPT ---- */
CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    CREATE TABLE #Base
    (
        FirstBilledDate DATE          NULL,
        ClaimId         NVARCHAR(100) NULL
    );

    INSERT INTO #Base (FirstBilledDate, ClaimId)
    SELECT
        TRY_CAST(FirstBilledDate AS DATE),
        CAST(ClaimId AS NVARCHAR(100))
    FROM dbo.ClaimLevelData
    WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(ISNULL(NULLIF(LTRIM(RTRIM(PanelNameBasedOnCPT)),''),'Unknown'),200) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo);

    DECLARE @cntClaim   INT = 0;
    DECLARE @cntUndated INT = 0;
    SELECT @cntClaim   = COUNT(*) FROM #Base;
    SELECT @cntUndated = COUNT(*) FROM #Base WHERE FirstBilledDate IS NULL;

    CREATE TABLE #Buckets
    (
        BucketType   VARCHAR(20),
        YearNo       INT           NULL,
        MonthNo      INT           NULL,
        FromDate     DATE          NULL,
        ToDate       DATE          NULL,
        RecordCount  INT,
        SheetName    NVARCHAR(50)
    );

    IF (@cntClaim <= @Threshold)
    BEGIN
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntClaim, 'All_Claim');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Claim'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
            HAVING COUNT(*) > @Threshold
        ),
        MonthCounts AS
        (
            SELECT YEAR(b.FirstBilledDate) AS YearNo,
                   MONTH(b.FirstBilledDate) AS MonthNo,
                   COUNT(*) AS RecordCount
            FROM #Base b
            INNER JOIN LargeYears y ON YEAR(b.FirstBilledDate) = y.YearNo
            GROUP BY YEAR(b.FirstBilledDate), MONTH(b.FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'MONTH', mc.YearNo, mc.MonthNo,
               DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1),
               EOMONTH(DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)),
               mc.RecordCount,
               LEFT(DATENAME(MONTH, DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)), 3)
                   + CAST(mc.YearNo AS VARCHAR(4)) + '_Claim'
        FROM MonthCounts mc;

        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Claim');
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END
GO

/* ---- 10) Claim-level export data: same column order as ClaimLevelData, but the Panelname column
           carries PanelNameBasedOnCPT and is headed [PanelName]; panel filter on PanelNameBasedOnCPT ---- */
CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelExportDataByDateRange
    @FromDate         DATE          = NULL,
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'
AS
BEGIN
    SET NOCOUNT ON;

    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
        RETURN;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;

    CREATE TABLE #PayerList (Value NVARCHAR(200) NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    DECLARE @Cols NVARCHAR(MAX);
    SELECT @Cols = STRING_AGG(CAST(
               CASE WHEN c.name = N'Panelname' THEN N'[PanelNameBasedOnCPT] AS [PanelName]'
                    ELSE QUOTENAME(c.name) END AS NVARCHAR(MAX)), N', ')
           WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData');

    DECLARE @Sql NVARCHAR(MAX) = N'
    SELECT ' + @Cols + N'
    FROM dbo.ClaimLevelData
    WHERE (
              @BucketType = ''ALL''
           OR (@BucketType = ''UNDATED'' AND TRY_CAST(FirstBilledDate AS DATE) IS NULL)
           OR (@BucketType NOT IN (''ALL'',''UNDATED'')
               AND TRY_CAST(FirstBilledDate AS DATE) >= @FromDate
               AND TRY_CAST(FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
          )
      AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,''Unknown''))),200) IN (SELECT Value FROM #PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(ISNULL(NULLIF(LTRIM(RTRIM(PanelNameBasedOnCPT)),''''),''Unknown''),200) IN (SELECT Value FROM #PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimId;';

    EXEC sys.sp_executesql @Sql,
        N'@FromDate DATE, @ToDate DATE, @DosFrom DATE, @DosTo DATE, @CEDFrom DATE, @CEDTo DATE,
          @FirstBilledFrom DATE, @FirstBilledTo DATE, @BucketType VARCHAR(20), @HasPayerFilter BIT, @HasPanelFilter BIT',
        @FromDate, @ToDate, @DosFrom, @DosTo, @CEDFrom, @CEDTo,
        @FirstBilledFrom, @FirstBilledTo, @BucketType, @HasPayerFilter, @HasPanelFilter;
END
GO

/* ---- 11) Line-level export buckets: panel filter uses the claim's PanelNameBasedOnCPT ---- */
CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    CREATE TABLE #Base
    (
        FirstBilledDate DATE          NULL,
        ClaimId         NVARCHAR(100) NULL
    );

    INSERT INTO #Base (FirstBilledDate, ClaimId)
    SELECT
        TRY_CAST(l.FirstBilledDate AS DATE),
        CAST(l.ClaimId AS NVARCHAR(100))
    FROM dbo.LineLevelData l
    WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(l.PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR EXISTS (
              SELECT 1 FROM dbo.ClaimLevelData c
              WHERE c.ClaimID = l.ClaimID
                AND LEFT(ISNULL(NULLIF(LTRIM(RTRIM(c.PanelNameBasedOnCPT)),''),'Unknown'),200) IN (SELECT Value FROM @PanelList)))
      AND (@DosFrom         IS NULL OR TRY_CAST(l.DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(l.DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(l.ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(l.ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(l.FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(l.FirstBilledDate   AS DATE) <= @FirstBilledTo);

    DECLARE @cntLine    INT = 0;
    DECLARE @cntUndated INT = 0;
    SELECT @cntLine    = COUNT(*) FROM #Base;
    SELECT @cntUndated = COUNT(*) FROM #Base WHERE FirstBilledDate IS NULL;

    CREATE TABLE #Buckets
    (
        BucketType   VARCHAR(20),
        YearNo       INT           NULL,
        MonthNo      INT           NULL,
        FromDate     DATE          NULL,
        ToDate       DATE          NULL,
        RecordCount  INT,
        SheetName    NVARCHAR(50)
    );

    IF (@cntLine <= @Threshold)
    BEGIN
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntLine, 'All_Line');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Line'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
            HAVING COUNT(*) > @Threshold
        ),
        MonthCounts AS
        (
            SELECT YEAR(b.FirstBilledDate) AS YearNo,
                   MONTH(b.FirstBilledDate) AS MonthNo,
                   COUNT(*) AS RecordCount
            FROM #Base b
            INNER JOIN LargeYears y ON YEAR(b.FirstBilledDate) = y.YearNo
            GROUP BY YEAR(b.FirstBilledDate), MONTH(b.FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'MONTH', mc.YearNo, mc.MonthNo,
               DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1),
               EOMONTH(DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)),
               mc.RecordCount,
               LEFT(DATENAME(MONTH, DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)), 3)
                   + CAST(mc.YearNo AS VARCHAR(4)) + '_Line'
        FROM MonthCounts mc;

        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Line');
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END
GO

/* ---- 12) Line-level export data: panel filter uses the claim's PanelNameBasedOnCPT ---- */
CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelExportDataByDateRange
    @FromDate         DATE          = NULL,
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'
AS
BEGIN
    SET NOCOUNT ON;

    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
        RETURN;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT l.*
    FROM dbo.LineLevelData l
    WHERE (
              @BucketType = 'ALL'
           OR (@BucketType = 'UNDATED' AND TRY_CAST(l.FirstBilledDate AS DATE) IS NULL)
           OR (@BucketType NOT IN ('ALL','UNDATED')
               AND TRY_CAST(l.FirstBilledDate AS DATE) >= @FromDate
               AND TRY_CAST(l.FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
          )
      AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(l.PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR EXISTS (
              SELECT 1 FROM dbo.ClaimLevelData c
              WHERE c.ClaimID = l.ClaimID
                AND LEFT(ISNULL(NULLIF(LTRIM(RTRIM(c.PanelNameBasedOnCPT)),''),'Unknown'),200) IN (SELECT Value FROM @PanelList)))
      AND (@DosFrom         IS NULL OR TRY_CAST(l.DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(l.DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(l.ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(l.ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(l.FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(l.FirstBilledDate   AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(l.FirstBilledDate AS DATE), l.ClaimId;
END
GO
