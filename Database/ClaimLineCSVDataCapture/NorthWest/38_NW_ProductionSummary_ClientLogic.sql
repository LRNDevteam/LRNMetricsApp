/* =============================================================================
   NorthWest - Production Summary on the client logic sheet
   File     : 38_NW_ProductionSummary_ClientLogic.sql
   Database : NWL_LRN

   Values on every tab : Count of unique Claim ID, Sum of Charge Amount,
                         sorted by Claim Count.
   Billed filter       : FirstBilledDate is a date; when FirstBilledDate is blank,
                         EmedixSubmissionDate is a date. No ClaimStatus exclusion.
   Month / year columns: ChargeEnteredDate.

   Tab                       Source       Filter                         Rows / Columns
   Monthly                   Claim Level  Billed                         PanelType + Top 5 payers / month + year
   Weekly                    Claim Level  Billed + EnteredWeek not blank PanelType + Top 5 payers / Thu-Wed EnteredWeek
   Panel X Payer             Claim Level  Billed                         PayerName_Raw / PanelType
   Panel Breakdown           Claim Level  Billed                         PanelType / year (month grain, UI rolls the year)
   Unbilled X Aging          Claim Level  ClaimStatus Unbilled in Daq,   PayerName_Raw / Aging
                                          Unbilled in WebPM
   Payer Breakdown           Claim Level  Billed                         PayerName_Raw / year (month grain, UI rolls the year)
   CPT Breakdown             Line Level   Source Webpm & Daq             CPT Code / year (month grain, UI rolls the year)
   Highest payer Breakdown   Claim Level  Billed + Webpm & Daq           PayerName_Raw / month + year
   Top 10 Payer (Insight)    Claim Level  Billed + Webpm & Daq           Top 10 PayerName_Raw / month + year

   Each usp_GetNW_* returns its snapshot table when no filter is passed; with filters
   (or @Live = 1) it computes the same result from ClaimLevelData / LineLevelData.
   Each usp_RefreshNW_* stores the @Live = 1 result, so snapshot and filtered results
   always use the same logic.

   Dashboard date filters (NorthWest ProductionSummary Rule4):
     @FirstBillFrom / @FirstBillTo     -> ChargeEnteredDate ("Charge Entered Date")
     @FirstBilledFrom / @FirstBilledTo -> billed date (FirstBilledDate, else EmedixSubmissionDate)
     @DosFrom / @DosTo                 -> DateOfService
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'38_NW_ProductionSummary_ClientLogic.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

/* -----------------------------------------------------------------------------
   Shared claim rows
   ----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_NW_ProductionClaimBase
AS
SELECT
    ClaimID           = NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''),
    PanelType         = LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(cl.PanelType)), ''), N'Unknown'))),
    PayerName         = LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, N'Unknown'))),
    PayerNameRaw      = NULLIF(LTRIM(RTRIM(cl.PayerName_Raw)), ''),
    ChargeEnteredDate = TRY_CAST(cl.ChargeEnteredDate AS DATE),
    DateOfService     = TRY_CAST(cl.DateOfService AS DATE),
    BilledDate        = CASE
                            WHEN TRY_CAST(NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), '') AS DATE) IS NOT NULL
                                THEN TRY_CAST(NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), '') AS DATE)
                            WHEN NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), '') IS NULL
                                THEN TRY_CAST(NULLIF(LTRIM(RTRIM(cl.EmedixSubmissionDate)), '') AS DATE)
                        END,
    ChargeAmount      = TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2)),
    EnteredWeek       = NULLIF(LTRIM(RTRIM(cl.EnteredWeek)), ''),
    cl.AdditionalFields
FROM dbo.ClaimLevelData cl;
GO

CREATE OR ALTER FUNCTION dbo.fn_NW_BilledClaims
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
        b.PanelType,
        b.PayerName,
        b.PayerNameRaw,
        b.ChargeEnteredDate,
        BilledYearMonth = CONVERT(NVARCHAR(7), b.ChargeEnteredDate, 120),
        b.BilledDate,
        b.ChargeAmount,
        b.EnteredWeek,
        b.AdditionalFields
    FROM dbo.vw_NW_ProductionClaimBase b
    WHERE b.BilledDate IS NOT NULL
      AND b.ChargeEnteredDate IS NOT NULL
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
           OR b.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|'))
           OR ISNULL(b.PayerNameRaw, N'* none *') IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
           OR b.PanelType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')))
      AND (@DosFrom         IS NULL OR b.DateOfService     >= @DosFrom)
      AND (@DosTo           IS NULL OR b.DateOfService     <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR b.ChargeEnteredDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR b.ChargeEnteredDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR b.BilledDate        >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR b.BilledDate        <= @FirstBilledTo);
GO

-- Billed claims whose Source (AdditionalFields) is Daq or Webpm.
CREATE OR ALTER FUNCTION dbo.fn_NW_BilledClaimsBySource
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
        n.SourceName,
        c.ClaimID,
        c.PanelType,
        c.PayerName,
        c.PayerNameRaw,
        c.BilledYearMonth,
        c.ChargeAmount
    FROM dbo.fn_NW_BilledClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    CROSS APPLY (
        SELECT SourceValue = UPPER(LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(c.AdditionalFields, 'Source'), ''))))
    ) s
    CROSS APPLY (
        SELECT SourceName = CASE
                                WHEN s.SourceValue LIKE 'DAQ%'   THEN N'Daq'
                                WHEN s.SourceValue LIKE 'WEBPM%' THEN N'Webpm'
                            END
    ) n
    WHERE n.SourceName IS NOT NULL;
GO

/* -----------------------------------------------------------------------------
   1. Monthly - PanelType (PayerRank 0 = panel total) + Top 5 PayerName_Raw
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_MonthlyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.NW_MonthlyBilledProductionSummary
        ORDER BY BilledYearMonth, PanelType, PayerRank;
        RETURN;
    END;

    SELECT
        c.PanelType,
        PayerName    = CASE WHEN GROUPING(c.PayerName) = 1 THEN NULL ELSE c.PayerName END,
        IsPanelTotal = CAST(GROUPING(c.PayerName) AS BIT),
        c.BilledYearMonth,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    INTO #Agg
    FROM dbo.fn_NW_BilledClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    GROUP BY GROUPING SETS ((c.PanelType, c.PayerName, c.BilledYearMonth),
                            (c.PanelType, c.BilledYearMonth))
    OPTION (RECOMPILE);

    SELECT
        PanelType,
        PayerName,
        PayerRank = ROW_NUMBER() OVER (PARTITION BY PanelType
                                       ORDER BY SUM(ClaimCount) DESC, SUM(TotalCharges) DESC, PayerName)
    INTO #Rank
    FROM #Agg
    WHERE IsPanelTotal = 0
    GROUP BY PanelType, PayerName;

    SELECT a.PanelType, PayerName = N'', PayerRank = CAST(0 AS TINYINT),
           a.BilledYearMonth, a.ClaimCount, a.TotalCharges
    FROM #Agg a
    WHERE a.IsPanelTotal = 1
    UNION ALL
    SELECT a.PanelType, a.PayerName, CAST(r.PayerRank AS TINYINT),
           a.BilledYearMonth, a.ClaimCount, a.TotalCharges
    FROM #Agg a
    JOIN #Rank r ON r.PanelType = a.PanelType AND r.PayerName = a.PayerName
    WHERE a.IsPanelTotal = 0
      AND r.PayerRank <= 5
    ORDER BY BilledYearMonth, PanelType, PayerRank;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PanelType       NVARCHAR(MAX),
        PayerName       NVARCHAR(500),
        PayerRank       TINYINT,
        BilledYearMonth NVARCHAR(7),
        ClaimCount      INT,
        TotalCharges    DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_MonthlyBilledProductionSummary @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_MonthlyBilledProductionSummary;
        INSERT INTO dbo.NW_MonthlyBilledProductionSummary
            (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
        SELECT PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   2. Weekly - PanelType + Top 5 PayerName_Raw.
      Filter : Billed, and EnteredWeek is not blank.
      Column : one column per EnteredWeek label (Week 1..4). The range shown is the
               Thursday-Wednesday week holding the label's latest ChargeEnteredDate.
               1900-01-04 is a Thursday.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_WeeklyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PanelName = PanelType, PayerName, PayerRank,
               WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
        FROM dbo.NW_WeeklyBilledProductionSummary
        ORDER BY WeekStart, PanelName, PayerRank;
        RETURN;
    END;

    CREATE TABLE #Weeks
    (
        WeekLabel NVARCHAR(64) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
        WeekStart DATE NOT NULL
    );

    INSERT INTO #Weeks (WeekLabel, WeekStart)
    SELECT EnteredWeek,
           DATEADD(DAY, -(DATEDIFF(DAY, '19000104', MAX(ChargeEnteredDate)) % 7), MAX(ChargeEnteredDate))
    FROM dbo.vw_NW_ProductionClaimBase
    WHERE EnteredWeek IS NOT NULL
      AND ChargeEnteredDate IS NOT NULL
    GROUP BY EnteredWeek;

    SELECT
        c.PanelType,
        PayerName    = CASE WHEN GROUPING(c.PayerName) = 1 THEN NULL ELSE c.PayerName END,
        IsPanelTotal = CAST(GROUPING(c.PayerName) AS BIT),
        w.WeekLabel,
        w.WeekStart,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    INTO #Agg
    FROM dbo.fn_NW_BilledClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    JOIN #Weeks w ON w.WeekLabel = c.EnteredWeek
    GROUP BY GROUPING SETS ((c.PanelType, c.PayerName, w.WeekLabel, w.WeekStart),
                            (c.PanelType, w.WeekLabel, w.WeekStart))
    OPTION (RECOMPILE);

    SELECT
        PanelType,
        PayerName,
        PayerRank = ROW_NUMBER() OVER (PARTITION BY PanelType
                                       ORDER BY SUM(ClaimCount) DESC, SUM(TotalCharges) DESC, PayerName)
    INTO #Rank
    FROM #Agg
    WHERE IsPanelTotal = 0
    GROUP BY PanelType, PayerName;

    SELECT
        PanelName = x.PanelType,
        x.PayerName,
        x.PayerRank,
        x.WeekStart,
        WeekEnd   = DATEADD(DAY, 6, x.WeekStart),
        x.WeekLabel,
        x.ClaimCount,
        x.TotalCharges
    FROM (
        SELECT a.PanelType, PayerName = N'', PayerRank = CAST(0 AS TINYINT),
               a.WeekLabel, a.WeekStart, a.ClaimCount, a.TotalCharges
        FROM #Agg a
        WHERE a.IsPanelTotal = 1
        UNION ALL
        SELECT a.PanelType, a.PayerName, CAST(r.PayerRank AS TINYINT),
               a.WeekLabel, a.WeekStart, a.ClaimCount, a.TotalCharges
        FROM #Agg a
        JOIN #Rank r ON r.PanelType = a.PanelType AND r.PayerName = a.PayerName
        WHERE a.IsPanelTotal = 0
          AND r.PayerRank <= 5
    ) x
    ORDER BY x.WeekStart, PanelName, x.PayerRank;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PanelName    NVARCHAR(MAX),
        PayerName    NVARCHAR(500),
        PayerRank    TINYINT,
        WeekStart    DATE,
        WeekEnd      DATE,
        WeekLabel    NVARCHAR(64),
        ClaimCount   INT,
        TotalCharges DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_WeeklyBilledProductionSummary @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_WeeklyBilledProductionSummary;
        INSERT INTO dbo.NW_WeeklyBilledProductionSummary
            (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, RefreshedAt)
        SELECT PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   3. Panel X Payer - PayerName_Raw x PanelType
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PayerByPanel
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PayerName, PanelName = PanelType, ClaimCount, TotalCharges
        FROM dbo.NW_PayerByPanel
        ORDER BY PayerName, PanelName;
        RETURN;
    END;

    SELECT
        c.PayerName,
        PanelName    = c.PanelType,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_NW_BilledClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    GROUP BY c.PayerName, c.PanelType
    ORDER BY c.PayerName, PanelName
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_PayerByPanel
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PayerName    NVARCHAR(500),
        PanelName    NVARCHAR(MAX),
        ClaimCount   INT,
        TotalCharges DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_PayerByPanel @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_PayerByPanel;
        INSERT INTO dbo.NW_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
        SELECT PayerName, PanelName, ClaimCount, TotalCharges, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   4. Panel Breakdown - PanelType (+ payer children) x ChargeEnteredDate month
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PanelBreakdownWithPayers
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.NW_PanelBreakdownWithPayers
        ORDER BY PanelName, PayerName, BilledYearMonth;
        RETURN;
    END;

    SELECT
        PanelName    = c.PanelType,
        c.PayerName,
        c.BilledYearMonth,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_NW_BilledClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    GROUP BY c.PanelType, c.PayerName, c.BilledYearMonth
    ORDER BY PanelName, c.PayerName, c.BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_PanelBreakdownWithPayers
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PanelName       NVARCHAR(500),
        PayerName       NVARCHAR(500),
        BilledYearMonth NVARCHAR(7),
        ClaimCount      INT,
        TotalCharges    DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_PanelBreakdownWithPayers @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_PanelBreakdownWithPayers;
        INSERT INTO dbo.NW_PanelBreakdownWithPayers
            (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
        SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PanelBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PanelName, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.NW_PanelBreakdown
        ORDER BY PanelName, BilledYearMonth;
        RETURN;
    END;

    SELECT
        PanelName    = c.PanelType,
        c.BilledYearMonth,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_NW_BilledClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    GROUP BY c.PanelType, c.BilledYearMonth
    ORDER BY PanelName, c.BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_PanelBreakdown
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PanelName       NVARCHAR(500),
        BilledYearMonth NVARCHAR(7),
        ClaimCount      INT,
        TotalCharges    DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_PanelBreakdown @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_PanelBreakdown;
        INSERT INTO dbo.NW_PanelBreakdown (PanelName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
        SELECT PanelName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   6. Payer Breakdown - PayerName_Raw x ChargeEnteredDate month
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PayerBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.NW_PayerBreakdown
        ORDER BY PayerName, BilledYearMonth;
        RETURN;
    END;

    SELECT
        c.PayerName,
        c.BilledYearMonth,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_NW_BilledClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    GROUP BY c.PayerName, c.BilledYearMonth
    ORDER BY c.PayerName, c.BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PayerName       NVARCHAR(500),
        BilledYearMonth NVARCHAR(7),
        ClaimCount      INT,
        TotalCharges    DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_PayerBreakdown @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_PayerBreakdown;
        INSERT INTO dbo.NW_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
        SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   7. CPT Breakdown - LineLevelData, FirstBilledDate set, Source Webpm / Daq.
      CPTCount holds the count of unique Claim ID per CPT Code and month.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CPTBreakdownBySource
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM dbo.NW_CPTBreakdownBySource
        ORDER BY SourceName, CPTCode, BilledYearMonth;
        RETURN;
    END;

    ;WITH Lines AS
    (
        SELECT
            SourceName        = CASE
                                    WHEN UPPER(LTRIM(RTRIM(ISNULL(l.Source, '')))) LIKE 'WEBPM%' THEN N'WebPM'
                                    WHEN UPPER(LTRIM(RTRIM(ISNULL(l.Source, '')))) LIKE 'DAQ%'   THEN N'DAQ'
                                END,
            CPTCode           = LTRIM(RTRIM(l.CPTCode)),
            ChargeEnteredDate = TRY_CAST(l.ChargeEnteredDate AS DATE),
            FirstBilledDate   = TRY_CAST(NULLIF(LTRIM(RTRIM(l.FirstBilledDate)), '') AS DATE),
            DateOfService     = TRY_CAST(l.DateOfService AS DATE),
            ClaimID           = NULLIF(LTRIM(RTRIM(l.ClaimID)), ''),
            PayerName         = LTRIM(RTRIM(ISNULL(l.PayerName_Raw, N'Unknown'))),
            PanelName         = LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(l.Panelname)), ''), N'Unknown'))),
            UnitsValue        = TRY_CAST(l.Units AS DECIMAL(18,2)),
            ChargeAmountValue = TRY_CAST(l.ChargeAmount AS DECIMAL(18,2))
        FROM dbo.LineLevelData l
        WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), '') IS NOT NULL
    )
    SELECT
        SourceName,
        CPTCode,
        BilledYearMonth = CONVERT(NVARCHAR(7), ChargeEnteredDate, 120),
        CPTCount        = COUNT(DISTINCT ClaimID),
        BilledUnits     = ISNULL(SUM(UnitsValue), 0),
        TotalCharges    = ISNULL(SUM(ChargeAmountValue), 0)
    FROM Lines
    WHERE SourceName IS NOT NULL
      AND FirstBilledDate IS NOT NULL
      AND ChargeEnteredDate IS NOT NULL
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
           OR PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
           OR PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')))
      AND (@DosFrom         IS NULL OR DateOfService     >= @DosFrom)
      AND (@DosTo           IS NULL OR DateOfService     <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR ChargeEnteredDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR ChargeEnteredDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR FirstBilledDate   >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR FirstBilledDate   <= @FirstBilledTo)
    GROUP BY SourceName, CPTCode, CONVERT(NVARCHAR(7), ChargeEnteredDate, 120)
    ORDER BY SourceName, CPTCode, BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CPTBreakdownBySource
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        SourceName      NVARCHAR(20),
        CPTCode         NVARCHAR(50),
        BilledYearMonth NVARCHAR(7),
        CPTCount        INT,
        BilledUnits     DECIMAL(18,2),
        TotalCharges    DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CPTBreakdownBySource @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CPTBreakdownBySource;
        INSERT INTO dbo.NW_CPTBreakdownBySource
            (SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
        SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   8. Highest payer Breakdown - Source (Daq / WebPM) > PayerName_Raw x month
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_HighestPayerBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.NW_HighestPayerBreakdown
        ORDER BY SourceName, PayerName, BilledYearMonth;
        RETURN;
    END;

    SELECT
        SourceName   = CASE c.SourceName WHEN N'Webpm' THEN N'WebPM' ELSE c.SourceName END,
        PayerName    = ISNULL(c.PayerNameRaw, N'* none *'),
        c.BilledYearMonth,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_NW_BilledClaimsBySource(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                        @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    GROUP BY c.SourceName, ISNULL(c.PayerNameRaw, N'* none *'), c.BilledYearMonth
    ORDER BY SourceName, PayerName, c.BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_HighestPayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        SourceName      NVARCHAR(20),
        PayerName       NVARCHAR(500),
        BilledYearMonth NVARCHAR(7),
        ClaimCount      INT,
        TotalCharges    DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_HighestPayerBreakdown @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_HighestPayerBreakdown;
        INSERT INTO dbo.NW_HighestPayerBreakdown
            (SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
        SELECT SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   9. Top 10 Payer (Insight Daq / Webpm) - all payers per source; the app keeps the
      Top 10 by Claim Count and the grand total covers every payer.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_InsightBreakdownAllPayers
    @Source          NVARCHAR(20),
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

    DECLARE @SourceName NVARCHAR(20) =
        CASE WHEN UPPER(LTRIM(RTRIM(@Source))) LIKE 'WEBPM%' THEN N'Webpm' ELSE N'Daq' END;

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.NW_InsightBreakdownAllPayers
        WHERE SourceName = @SourceName
        ORDER BY PayerName, BilledYearMonth;
        RETURN;
    END;

    SELECT
        c.PayerName,
        c.BilledYearMonth,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_NW_BilledClaimsBySource(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                        @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    WHERE c.SourceName = @SourceName
    GROUP BY c.PayerName, c.BilledYearMonth
    ORDER BY c.PayerName, c.BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_InsightBreakdownAllPayers
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT
        c.SourceName,
        c.PayerName,
        c.BilledYearMonth,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    INTO #R
    FROM dbo.fn_NW_BilledClaimsBySource(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) c
    GROUP BY c.SourceName, c.PayerName, c.BilledYearMonth;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_InsightBreakdownAllPayers;
        INSERT INTO dbo.NW_InsightBreakdownAllPayers
            (SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
        SELECT SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

-- Legacy Top 10 snapshot (read only when usp_GetNW_InsightBreakdownAllPayers is missing).
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_InsightBreakdown
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT
        c.SourceName,
        c.PayerName,
        c.BilledYearMonth,
        ClaimCount   = COUNT(DISTINCT c.ClaimID),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    INTO #Agg
    FROM dbo.fn_NW_BilledClaimsBySource(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) c
    GROUP BY c.SourceName, c.PayerName, c.BilledYearMonth;

    SELECT SourceName, PayerName
    INTO #Top10
    FROM (
        SELECT SourceName, PayerName,
               rn = ROW_NUMBER() OVER (PARTITION BY SourceName
                                       ORDER BY SUM(ClaimCount) DESC, SUM(TotalCharges) DESC, PayerName)
        FROM #Agg
        GROUP BY SourceName, PayerName
    ) x
    WHERE rn <= 10;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_InsightBreakdown;
        INSERT INTO dbo.NW_InsightBreakdown
            (SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
        SELECT a.SourceName, a.PayerName, a.BilledYearMonth, a.ClaimCount, a.TotalCharges, GETDATE()
        FROM #Agg a
        JOIN #Top10 t ON t.SourceName = a.SourceName AND t.PayerName = a.PayerName;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   Rebuild the snapshots now
   ----------------------------------------------------------------------------- */
EXEC dbo.usp_RefreshNW_MonthlyBilledProductionSummary;
EXEC dbo.usp_RefreshNW_WeeklyBilledProductionSummary;
EXEC dbo.usp_RefreshNW_PayerByPanel;
EXEC dbo.usp_RefreshNW_PanelBreakdown;
EXEC dbo.usp_RefreshNW_PanelBreakdownWithPayers;
EXEC dbo.usp_RefreshNW_PayerBreakdown;
EXEC dbo.usp_RefreshNW_CPTBreakdownBySource;
EXEC dbo.usp_RefreshNW_HighestPayerBreakdown;
EXEC dbo.usp_RefreshNW_InsightBreakdownAllPayers;
EXEC dbo.usp_RefreshNW_InsightBreakdown;
GO

SET NOEXEC OFF;
GO
