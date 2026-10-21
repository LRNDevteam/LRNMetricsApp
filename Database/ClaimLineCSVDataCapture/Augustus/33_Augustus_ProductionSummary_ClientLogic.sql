/* =============================================================================
   Augustus - Production Summary client logic (2026-10-21 logic sheet)
   File     : 33_Augustus_ProductionSummary_ClientLogic.sql
   Database : Augustus_LRN

   NEW SP names only (*_v3). The existing usp_GetAug_* / *_v2 SPs and the
   Aug_* snapshot tables are not changed, so a dashboard build that still calls
   them keeps working. The dashboard reads these SPs live from ClaimLevelData /
   LineLevelData (about 40k claims, 350k lines).

   Values on every tab : Count of unique ClaimID, Sum of ChargeAmount. Sort: Claim Count.

   S.No Tab               Source      Filter                                   Row                              Column
   1    Monthly           Claim Level FirstBilledDate is a date                PanelCategory + Top 3 PayerName_Raw ChargeEnteredDate month / year
   2    Weekly            Claim Level FirstBilledDate is a date,               PanelCategory + Top 3 PayerName_Raw EnteredWeek
                                      EnteredWeek not blank                                                     (range = that week's ChargeEnteredDate span)
   3    Panel X Payer     Claim Level FirstBilledDate is a date                PayerName_Raw                    PanelCategory
   4    Panel Breakdown   Claim Level FirstBilledDate is a date                PanelCategory > PayerName_Raw    ChargeEnteredDate month / year
   5    Unbilled X Aging  Claim Level ClaimStatus = Unbilled in Altumed        PayerName_Raw                    Aging
   6    Payer Breakdown   Claim Level FirstBilledDate is a date                PayerName_Raw                    ChargeEnteredDate month / year
   7    CPT Breakdown     Line Level  FirstBilledDate is a date                CPT Code                         [Date] month / year

   Client sheet revised 2026-10-21: "FirstBilledDate = Date" replaced "BillingStatus = Billed" on tabs 1-4 and 6.
   ClaimStatus = Unbilled in Altumed is an exact match ("Unbilled in Altumed - PR" is not included).

   Page filters (same parameters as every usp_GetAug_* SP):
     @PayerNames      PayerName_Raw ('Unknown' = blank)          '|' separated
     @PanelNames      PanelCategory ('Unknown' = blank)          '|' separated
                      CPT Breakdown matches the claim's PanelCategory.
     @DosFrom/@DosTo  DateOfService
     @FirstBillFrom/To ChargeEnteredDate (CPT Breakdown: line [Date])
     @FirstBilledFrom/To FirstBilledDate
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'Augustus_LRN'
BEGIN
    RAISERROR(N'Run 33_Augustus_ProductionSummary_ClientLogic.sql on the Augustus_LRN database.', 16, 1);
    SET NOEXEC ON;
END;
GO

CREATE OR ALTER VIEW dbo.vw_Aug_ProductionClaimBase
AS
SELECT
    ClaimID           = NULLIF(LTRIM(RTRIM(cl.ClaimID)), N''),
    PanelCategory     = ISNULL(NULLIF(LTRIM(RTRIM(cl.PanelCategory)), N''), N'Unknown'),
    PayerName         = ISNULL(NULLIF(LTRIM(RTRIM(cl.PayerName_Raw)), N''), N'Unknown'),
    BillingStatus     = LTRIM(RTRIM(ISNULL(cl.BillingStatus, N''))),
    ClaimStatus       = LTRIM(RTRIM(ISNULL(cl.ClaimStatus, N''))),
    EnteredWeek       = NULLIF(LTRIM(RTRIM(cl.EnteredWeek)), N''),
    Aging             = ISNULL(NULLIF(LTRIM(RTRIM(cl.Aging)), N''), N'Unknown'),
    ChargeEnteredDate = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.ChargeEnteredDate)), N'') AS DATE),
    FirstBilledDate   = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), N'') AS DATE),
    DateOfService     = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.DateofService)), N'') AS DATE),
    ChargeAmount      = TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))
FROM dbo.ClaimLevelData cl;
GO

CREATE OR ALTER FUNCTION dbo.fn_Aug_ProductionClaims
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
    SELECT
        b.ClaimID,
        b.PanelCategory,
        b.PayerName,
        b.BillingStatus,
        b.ClaimStatus,
        b.EnteredWeek,
        b.Aging,
        b.ChargeEnteredDate,
        BilledYearMonth = CONVERT(NVARCHAR(7), b.ChargeEnteredDate, 120),
        b.FirstBilledDate,
        b.ChargeAmount
    FROM dbo.vw_Aug_ProductionClaimBase b
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR b.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR b.PanelCategory IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom         IS NULL OR b.DateOfService     >= @DosFrom)
      AND (@DosTo           IS NULL OR b.DateOfService     <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR b.ChargeEnteredDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR b.ChargeEnteredDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR b.FirstBilledDate   >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR b.FirstBilledDate   <= @FirstBilledTo);
GO

/* -----------------------------------------------------------------------------
   Filter dropdowns: PayerName_Raw and PanelCategory, the values the tabs group by.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_ProductionFilterOptions_v3
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT PayerName
    FROM dbo.vw_Aug_ProductionClaimBase
    ORDER BY PayerName;

    SELECT DISTINCT PanelCategory
    FROM dbo.vw_Aug_ProductionClaimBase
    ORDER BY PanelCategory;
END;
GO

/* -----------------------------------------------------------------------------
   1. Monthly - PanelCategory + Top 3 PayerName_Raw by claim count.
      PayerRank 0 = panel total (all payers); 1..3 = top payers.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_MonthlyBilledProductionSummary_v3
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

    SELECT c.PanelCategory, c.PayerName, c.BilledYearMonth, c.ClaimID, c.ChargeAmount
    INTO #Claims
    FROM dbo.fn_Aug_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                     @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    WHERE c.FirstBilledDate IS NOT NULL
      AND c.ChargeEnteredDate IS NOT NULL
    OPTION (RECOMPILE);

    ;WITH Ranked AS
    (
        SELECT PanelCategory, PayerName,
               PayerRank = ROW_NUMBER() OVER (PARTITION BY PanelCategory
                                              ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(ChargeAmount) DESC, PayerName)
        FROM #Claims
        GROUP BY PanelCategory, PayerName
    )
    SELECT PanelName = c.PanelCategory,
           PayerName = N'',
           PayerRank = CAST(0 AS TINYINT),
           c.BilledYearMonth,
           ClaimCount   = COUNT(DISTINCT c.ClaimID),
           TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM #Claims c
    GROUP BY c.PanelCategory, c.BilledYearMonth
    UNION ALL
    SELECT c.PanelCategory,
           c.PayerName,
           CAST(r.PayerRank AS TINYINT),
           c.BilledYearMonth,
           COUNT(DISTINCT c.ClaimID),
           ISNULL(SUM(c.ChargeAmount), 0)
    FROM #Claims c
    JOIN Ranked r ON r.PanelCategory = c.PanelCategory AND r.PayerName = c.PayerName
    WHERE r.PayerRank <= 3
    GROUP BY c.PanelCategory, c.PayerName, r.PayerRank, c.BilledYearMonth
    ORDER BY PanelName, BilledYearMonth, PayerRank;
END;
GO

/* -----------------------------------------------------------------------------
   2. Weekly - one column per EnteredWeek label (Week 1..4).
      WeekStart / WeekEnd = first / last ChargeEnteredDate of that EnteredWeek
      across all claims, so the range matches the lab's week file.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_WeeklyBilledProductionSummary_v3
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

    CREATE TABLE #Weeks
    (
        WeekLabel NVARCHAR(64) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
        WeekStart DATE NOT NULL,
        WeekEnd   DATE NOT NULL
    );

    INSERT INTO #Weeks (WeekLabel, WeekStart, WeekEnd)
    SELECT EnteredWeek, MIN(ChargeEnteredDate), MAX(ChargeEnteredDate)
    FROM dbo.vw_Aug_ProductionClaimBase
    WHERE EnteredWeek IS NOT NULL
      AND ChargeEnteredDate IS NOT NULL
    GROUP BY EnteredWeek;

    SELECT c.PanelCategory, c.PayerName, w.WeekLabel, w.WeekStart, w.WeekEnd, c.ClaimID, c.ChargeAmount
    INTO #Claims
    FROM dbo.fn_Aug_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                     @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    JOIN #Weeks w ON w.WeekLabel = c.EnteredWeek
    WHERE c.FirstBilledDate IS NOT NULL
    OPTION (RECOMPILE);

    ;WITH Ranked AS
    (
        SELECT PanelCategory, PayerName,
               PayerRank = ROW_NUMBER() OVER (PARTITION BY PanelCategory
                                              ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(ChargeAmount) DESC, PayerName)
        FROM #Claims
        GROUP BY PanelCategory, PayerName
    )
    SELECT PanelName = c.PanelCategory,
           PayerName = N'',
           PayerRank = CAST(0 AS TINYINT),
           c.WeekStart, c.WeekEnd, c.WeekLabel,
           ClaimCount   = COUNT(DISTINCT c.ClaimID),
           TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM #Claims c
    GROUP BY c.PanelCategory, c.WeekStart, c.WeekEnd, c.WeekLabel
    UNION ALL
    SELECT c.PanelCategory,
           c.PayerName,
           CAST(r.PayerRank AS TINYINT),
           c.WeekStart, c.WeekEnd, c.WeekLabel,
           COUNT(DISTINCT c.ClaimID),
           ISNULL(SUM(c.ChargeAmount), 0)
    FROM #Claims c
    JOIN Ranked r ON r.PanelCategory = c.PanelCategory AND r.PayerName = c.PayerName
    WHERE r.PayerRank <= 3
    GROUP BY c.PanelCategory, c.PayerName, r.PayerRank, c.WeekStart, c.WeekEnd, c.WeekLabel
    ORDER BY WeekStart, PanelName, PayerRank;
END;
GO

/* -----------------------------------------------------------------------------
   3. Panel X Payer - rows PayerName_Raw, columns PanelCategory.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_PayerByPanel_v3
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

    SELECT PayerName    = c.PayerName,
           PanelName    = c.PanelCategory,
           ClaimCount   = COUNT(DISTINCT c.ClaimID),
           TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_Aug_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                     @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    WHERE c.FirstBilledDate IS NOT NULL
    GROUP BY c.PayerName, c.PanelCategory
    ORDER BY PayerName, PanelName
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   4. Panel Breakdown - PanelCategory with PayerName_Raw children, ChargeEnteredDate month.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_PanelBreakdown_v3
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

    SELECT PanelName    = c.PanelCategory,
           PayerName    = c.PayerName,
           c.BilledYearMonth,
           ClaimCount   = COUNT(DISTINCT c.ClaimID),
           TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_Aug_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                     @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    WHERE c.FirstBilledDate IS NOT NULL
      AND c.ChargeEnteredDate IS NOT NULL
    GROUP BY c.PanelCategory, c.PayerName, c.BilledYearMonth
    ORDER BY PanelName, PayerName, BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   5. Unbilled X Aging - ClaimStatus = Unbilled in Altumed, rows PayerName_Raw, columns Aging.
      First column keeps the name PanelName so the dashboard reader is unchanged.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_UnbilledAging_v3
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

    SELECT PanelName    = c.PayerName,
           AgingBucket  = c.Aging,
           ClaimCount   = COUNT(DISTINCT c.ClaimID),
           TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_Aug_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                     @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    WHERE c.ClaimStatus = N'Unbilled in Altumed'
    GROUP BY c.PayerName, c.Aging
    ORDER BY PanelName, AgingBucket
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   6. Payer Breakdown - rows PayerName_Raw, ChargeEnteredDate month.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_PayerBreakdown_v3
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

    SELECT PayerName    = c.PayerName,
           c.BilledYearMonth,
           ClaimCount   = COUNT(DISTINCT c.ClaimID),
           TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_Aug_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                     @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    WHERE c.FirstBilledDate IS NOT NULL
      AND c.ChargeEnteredDate IS NOT NULL
    GROUP BY c.PayerName, c.BilledYearMonth
    ORDER BY PayerName, BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   7. CPT Breakdown - LineLevelData, FirstBilledDate is a date, column = line [Date] month.
      CPTCount = Count of unique ClaimID for the CPT in that month.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CPTBreakdown_v3
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

    DECLARE @HasPanelFilter BIT = CASE WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL THEN 0 ELSE 1 END;

    ;WITH Lines AS
    (
        SELECT
            CPTCode         = LTRIM(RTRIM(l.CPTCode)),
            ClaimID         = NULLIF(LTRIM(RTRIM(l.ClaimID)), N''),
            LineDate        = TRY_CAST(NULLIF(LTRIM(RTRIM(l.[Date])), N'') AS DATE),
            FirstBilledDate = TRY_CAST(NULLIF(LTRIM(RTRIM(l.FirstBilledDate)), N'') AS DATE),
            DateOfService   = TRY_CAST(NULLIF(LTRIM(RTRIM(l.DateofService)), N'') AS DATE),
            PayerName       = ISNULL(NULLIF(LTRIM(RTRIM(l.PayerName_Raw)), N''), N'Unknown'),
            ChargeAmount    = TRY_CAST(l.ChargeAmount AS DECIMAL(18,2))
        FROM dbo.LineLevelData l
        WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), N'') IS NOT NULL
    )
    SELECT
        CPTCode,
        BilledYearMonth = CONVERT(NVARCHAR(7), LineDate, 120),
        CPTCount        = COUNT(DISTINCT ClaimID),
        BilledUnits     = CAST(COUNT(DISTINCT ClaimID) AS DECIMAL(18,2)),
        TotalCharges    = ISNULL(SUM(ChargeAmount), 0)
    FROM Lines ln
    WHERE ln.FirstBilledDate IS NOT NULL
      AND ln.LineDate IS NOT NULL
      AND YEAR(ln.LineDate) > 1900
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR ln.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (@HasPanelFilter = 0
           OR EXISTS (SELECT 1
                      FROM dbo.vw_Aug_ProductionClaimBase b
                      WHERE b.ClaimID = ln.ClaimID
                        AND b.PanelCategory IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|'))))
      AND (@DosFrom         IS NULL OR ln.DateOfService   >= @DosFrom)
      AND (@DosTo           IS NULL OR ln.DateOfService   <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR ln.LineDate        >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR ln.LineDate        <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR ln.FirstBilledDate >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR ln.FirstBilledDate <= @FirstBilledTo)
    GROUP BY CPTCode, CONVERT(NVARCHAR(7), LineDate, 120)
    ORDER BY CPTCode, BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

SET NOEXEC OFF;
GO

PRINT '33_Augustus_ProductionSummary_ClientLogic.sql completed.';
GO
