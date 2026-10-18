/* =============================================================================
   NorthWest - Production Summary on ClaimLevelData.BilledUnbilled
   File     : 41_NW_ProductionSummary_BilledUnbilled.sql
   Database : NWL_LRN
   Requires : 38_NW_ProductionSummary_ClientLogic.sql, 40_NW_ClaimLevelData_BilledUnbilled.sql

   Billed filter : ClaimLevelData.BilledUnbilled = 'Billed'
                   (ClaimType exclusion is applied when BilledUnbilled is written.
                    No ClaimStatus / 'Billed Amount 0' exclusion on these tabs.)
   Values        : Count of unique Claim ID, Sum of Charge Amount, sorted by Claim Count.
   Month / year  : ChargeEnteredDate.

   Tab                       Source       Filter                              Rows / Columns
   Monthly                   Claim Level  Billed                              PanelType + Top 5 payers / month + year
   Weekly                    Claim Level  Billed + EnteredWeek not blank      PanelType + Top 5 payers / Thu-Wed EnteredWeek
   Panel X Payer             Claim Level  Billed                              PayerName_Raw / PanelType
   Panel Breakdown           Claim Level  Billed                              PanelType / year
   Unbilled X Aging          Claim Level  ClaimStatus Unbilled in Daq / WebPM PayerName_Raw / Aging
   Payer Breakdown           Claim Level  Billed                              PayerName_Raw / year
   CPT Breakdown             Line Level   Source Webpm & Daq (line Source)    CPT Code / year
   Highest payer Breakdown   Claim Level  Billed + Webpm & Daq                PayerName_Raw / month + year
   Top 10 Payer              Claim Level  Billed + Webpm & Daq                Top 10 PayerName_Raw / month + year

   The deployed ClaimLineCSVDataCapture job may not yet run
   usp_UpdateNW_ClaimLevelData_BilledUnbilled before the report SPs, so
   usp_RefreshNW_MonthlyBilledProductionSummary (first in the job's NW list)
   runs it first. It only writes rows whose value changed.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'41_NW_ProductionSummary_BilledUnbilled.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

IF COL_LENGTH(N'dbo.ClaimLevelData', N'BilledUnbilled') IS NULL
   OR OBJECT_ID(N'dbo.usp_UpdateNW_ClaimLevelData_BilledUnbilled', N'P') IS NULL
BEGIN
    RAISERROR(N'Run 40_NW_ClaimLevelData_BilledUnbilled.sql first.', 16, 1);
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
    BilledUnbilled    = cl.BilledUnbilled,
    BilledDate        = CASE
                            WHEN TRY_CAST(NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), '') AS DATE) IS NOT NULL
                                THEN TRY_CAST(NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), '') AS DATE)
                            WHEN NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), '') IS NULL
                                THEN TRY_CAST(NULLIF(LTRIM(RTRIM(cl.EmedixSubmissionDate)), '') AS DATE)
                        END,
    ChargeAmount      = TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2)),
    EnteredWeek       = NULLIF(LTRIM(RTRIM(cl.EnteredWeek)), ''),
    ClaimStatus       = LTRIM(RTRIM(ISNULL(cl.ClaimStatus, N''))),
    cl.AdditionalFields
FROM dbo.ClaimLevelData cl;
GO

-- BilledDate is kept for the "First Billed" date filter only.
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
    WHERE b.BilledUnbilled = N'Billed'
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

/* -----------------------------------------------------------------------------
   1. Monthly refresh - sets BilledUnbilled first (see header).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #BU
    (
        LogId INT, TotalRows INT, BilledFirstBilled INT, BilledEmedix INT,
        UnBilledBlank INT, UnBilledOther INT, RowsUpdated INT, DurationMs INT
    );
    INSERT INTO #BU
    EXEC dbo.usp_UpdateNW_ClaimLevelData_BilledUnbilled
         @TriggeredBy = N'usp_RefreshNW_MonthlyBilledProductionSummary';

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
   7. CPT Breakdown - LineLevelData only, Source Webpm / Daq (two separate tabs).
      Client sheet:
        Source : Line Level Data
        Filter : LineLevelData.Source = Webpm | Daq (no BilledUnbilled, no claim Source)
        Row    : CPT Code
        Column : ChargeEnteredDate Year Total (stored by month; UI rolls up year)
        Values : Count of unique Claim ID, Sum of Charge Amount
        Sort   : Claim Count (applied in the dashboard reader)
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
                                    WHEN UPPER(LTRIM(RTRIM(ISNULL(l.Source, N'')))) LIKE N'WEBPM%'
                                        THEN N'WebPM'
                                    WHEN UPPER(LTRIM(RTRIM(ISNULL(l.Source, N'')))) LIKE N'DAQ%'
                                        THEN N'DAQ'
                                END,
            CPTCode           = LTRIM(RTRIM(l.CPTCode)),
            ChargeEnteredDate = TRY_CAST(l.ChargeEnteredDate AS DATE),
            BilledDate        = TRY_CAST(NULLIF(LTRIM(RTRIM(l.FirstBilledDate)), N'') AS DATE),
            DateOfService     = TRY_CAST(l.DateOfService AS DATE),
            ClaimID           = NULLIF(LTRIM(RTRIM(l.ClaimID)), N''),
            PayerName         = LTRIM(RTRIM(ISNULL(l.PayerName_Raw, N'Unknown'))),
            PanelName         = LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(l.Panelname)), N''), N'Unknown'))),
            UnitsValue        = TRY_CAST(l.Units AS DECIMAL(18,2)),
            ChargeAmountValue = TRY_CAST(l.ChargeAmount AS DECIMAL(18,2))
        FROM dbo.LineLevelData l
        WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), N'') IS NOT NULL
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
      AND ChargeEnteredDate IS NOT NULL
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom         IS NULL OR DateOfService     >= @DosFrom)
      AND (@DosTo           IS NULL OR DateOfService     <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR ChargeEnteredDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR ChargeEnteredDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR BilledDate        >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR BilledDate        <= @FirstBilledTo)
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
   9. Top 10 Payer - one grid per Source (Daq, WebPM), Top 10 PayerName_Raw by
      Claim Count within each source.
      Result rows: SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges.
      PayerName = '' is the source's overall total across ALL payers (the grid's
      Grand Total); the other rows are that source's Top 10 payers.
      Unfiltered: built from NW_InsightBreakdownAllPayers (per source, all payers).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_Top10PayerBreakdown
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

    CREATE TABLE #Agg
    (
        SourceName      NVARCHAR(20)  COLLATE DATABASE_DEFAULT NOT NULL,
        PayerName       NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
        BilledYearMonth NVARCHAR(7)   COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimCount      INT           NOT NULL,
        TotalCharges    DECIMAL(18,2) NOT NULL
    );

    CREATE TABLE #Total
    (
        SourceName      NVARCHAR(20)  COLLATE DATABASE_DEFAULT NOT NULL,
        BilledYearMonth NVARCHAR(7)   COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimCount      INT           NOT NULL,
        TotalCharges    DECIMAL(18,2) NOT NULL
    );

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        INSERT INTO #Agg (SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges)
        SELECT SourceName, PayerName, BilledYearMonth, SUM(ClaimCount), SUM(TotalCharges)
        FROM dbo.NW_InsightBreakdownAllPayers
        GROUP BY SourceName, PayerName, BilledYearMonth;

        -- Each claim carries one payer, so per-payer unique counts add up to the source's unique count.
        INSERT INTO #Total (SourceName, BilledYearMonth, ClaimCount, TotalCharges)
        SELECT SourceName, BilledYearMonth, SUM(ClaimCount), SUM(TotalCharges)
        FROM #Agg
        GROUP BY SourceName, BilledYearMonth;
    END
    ELSE
    BEGIN
        SELECT c.SourceName, c.PayerName, c.BilledYearMonth, c.ClaimID, c.ChargeAmount
        INTO #Claims
        FROM dbo.fn_NW_BilledClaimsBySource(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                            @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
        OPTION (RECOMPILE);

        INSERT INTO #Agg (SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges)
        SELECT SourceName, PayerName, BilledYearMonth,
               COUNT(DISTINCT ClaimID), ISNULL(SUM(ChargeAmount), 0)
        FROM #Claims
        GROUP BY SourceName, PayerName, BilledYearMonth;

        INSERT INTO #Total (SourceName, BilledYearMonth, ClaimCount, TotalCharges)
        SELECT SourceName, BilledYearMonth,
               COUNT(DISTINCT ClaimID), ISNULL(SUM(ChargeAmount), 0)
        FROM #Claims
        GROUP BY SourceName, BilledYearMonth;
    END;

    ;WITH Ranked AS
    (
        SELECT SourceName, PayerName,
               PayerRank = ROW_NUMBER() OVER (PARTITION BY SourceName
                                              ORDER BY SUM(ClaimCount) DESC, SUM(TotalCharges) DESC, PayerName)
        FROM #Agg
        GROUP BY SourceName, PayerName
    )
    SELECT SourceName = CASE t.SourceName WHEN N'Webpm' THEN N'WebPM' ELSE t.SourceName END,
           PayerName  = N'',
           t.BilledYearMonth, t.ClaimCount, t.TotalCharges,
           PayerRank  = 0
    FROM #Total t
    UNION ALL
    SELECT SourceName = CASE a.SourceName WHEN N'Webpm' THEN N'WebPM' ELSE a.SourceName END,
           a.PayerName,
           a.BilledYearMonth, a.ClaimCount, a.TotalCharges,
           r.PayerRank
    FROM #Agg a
    JOIN Ranked r ON r.SourceName = a.SourceName AND r.PayerName = a.PayerName
    WHERE r.PayerRank <= 10
    ORDER BY SourceName, PayerRank, BilledYearMonth;
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

PRINT '41_NW_ProductionSummary_BilledUnbilled.sql completed.';
GO
