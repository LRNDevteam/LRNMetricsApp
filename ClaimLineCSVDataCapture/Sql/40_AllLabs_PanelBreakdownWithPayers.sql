/* =====================================================================
   Panel Breakdown with payer drill-down - ALL REMAINING LABS
   (Production Summary  ->  "Panel Breakdown" table)

   Until now this table was only populated for Augustus
   (usp_GetAug_PayerByPanel path) and NorthWest
   (fix_NW_PanelBreakdownWithPayers.sql). Every other lab returned an
   empty result because ILabProductionSummaryRepository had no
   GetPanelBreakdownAsync at all.

   This script creates, for the lab whose database you run it on:

       dbo.{Prefix}PanelBreakdownWithPayers            (snapshot table)
       dbo.usp_Refresh{Prefix}PanelBreakdownWithPayers (nightly refresh)
       dbo.usp_Get{Prefix}PanelBreakdownWithPayers     (read SP)

   Parent row : ClaimLevelData.Panelname
   Child row  : ClaimLevelData.PayerName_Raw
   Column     : yyyy-MM of the lab's billed-month column
   Values     : COUNT(DISTINCT ClaimID), SUM(ChargeAmount)
   Result     : PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges

   The base filter and the month column are copied from that lab's own
   usp_Get{Prefix}MonthlyBilledProductionSummary, so Panel Breakdown ties
   out to the Monthly Billed Production Summary on the same page.

   HOW TO RUN
   ----------
   Run as-is on each lab database below. The prefix is auto-detected from
   the lab's existing {Prefix}MonthlyBilledProductionSummary table, so the
   same script is correct everywhere - no editing per lab.

       Certus_LRN   -> Cert_      (month = FirstBilledDate)
       Cove         -> Cove_      (month = ChargeEnteredDate)
       Elixir_LRN   -> Elix_
       PCRLOA       -> PCR_
       Beech_Tree   -> BT_
       Rising_Tides -> RT_
       Phi_Life     -> Phi_
       InHealthDTR  -> InH_

   Augustus and NorthWest are intentionally skipped - they already have
   their own Panel Breakdown objects and the app routes them elsewhere.
   If auto-detect cannot identify the lab, set @Prefix by hand at the top.

   Re-runnable: table is only created when missing, SPs are CREATE OR ALTER.
   The script finishes by running the refresh and showing a sample.
   ===================================================================== */
SET NOCOUNT ON;
GO

DECLARE @Prefix   sysname = NULL;   -- <== set by hand to override auto-detect, e.g. N'Cove_'
DECLARE @MonthCol sysname;
DECLARE @BaseWhere NVARCHAR(MAX);
DECLARE @Tbl      sysname;
DECLARE @Sql      NVARCHAR(MAX);

IF @Prefix IS NULL
    SELECT @Prefix =
        CASE
            WHEN OBJECT_ID('dbo.Cert_MonthlyBilledProductionSummary', 'U') IS NOT NULL THEN N'Cert_'
            WHEN OBJECT_ID('dbo.Cove_MonthlyBilledProductionSummary', 'U') IS NOT NULL THEN N'Cove_'
            WHEN OBJECT_ID('dbo.Elix_MonthlyBilledProductionSummary', 'U') IS NOT NULL THEN N'Elix_'
            WHEN OBJECT_ID('dbo.PCR_MonthlyBilledProductionSummary',  'U') IS NOT NULL THEN N'PCR_'
            WHEN OBJECT_ID('dbo.BT_MonthlyBilledProductionSummary',   'U') IS NOT NULL THEN N'BT_'
            WHEN OBJECT_ID('dbo.RT_MonthlyBilledProductionSummary',   'U') IS NOT NULL THEN N'RT_'
            WHEN OBJECT_ID('dbo.Phi_MonthlyBilledProductionSummary',  'U') IS NOT NULL THEN N'Phi_'
            WHEN OBJECT_ID('dbo.InH_MonthlyBilledProductionSummary',  'U') IS NOT NULL THEN N'InH_'
        END;

IF @Prefix IS NULL
BEGIN
    RAISERROR('Could not auto-detect the lab prefix in database [%s]. Set @Prefix by hand at the top of this script.', 16, 1, @@SERVERNAME);
    RETURN;
END

IF OBJECT_ID('dbo.Aug_MonthlyBilledProductionSummary', 'U') IS NOT NULL
   OR OBJECT_ID('dbo.NW_PanelBreakdownWithPayers', 'U') IS NOT NULL
BEGIN
    RAISERROR('This looks like the Augustus or NorthWest database - they already have Panel Breakdown. Nothing to do.', 16, 1);
    RETURN;
END

SET @Tbl = @Prefix + N'PanelBreakdownWithPayers';

/* Billed month column.
   Certus reports its billed month from FirstBilledDate. Every other lab's read SP
   uses ChargeEnteredDate - but some labs (Elixir, for one) never populate that
   column and their own Monthly refresh SP falls back to FirstBilledDate. Probing
   the data keeps this script correct per lab with nothing to edit by hand:
   ChargeEnteredDate is used when it actually holds dates, FirstBilledDate otherwise. */
IF @Prefix = N'Cert_'
    SET @MonthCol = N'FirstBilledDate';
ELSE IF EXISTS (SELECT 1 FROM dbo.ClaimLevelData
                WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL)
    SET @MonthCol = N'ChargeEnteredDate';
ELSE
    SET @MonthCol = N'FirstBilledDate';

SET @BaseWhere = REPLACE(
                     CASE WHEN @Prefix = N'Cert_'
                          THEN N'TRY_CAST({MONTHCOL} AS DATE) IS NOT NULL
          AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''''))) <> ''''
          AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '''')))) NOT LIKE ''%NONE%''
          AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '''')))) NOT LIKE ''%ACCU%''
          AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '''')))) NOT LIKE ''%CLIENT%''
          AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '''')))) NOT LIKE ''%PATIENT%'''
                          ELSE N'TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''''))) <> ''''
          AND PayerName_Raw IS NOT NULL
          AND LTRIM(RTRIM(PayerName_Raw)) <> ''''
          AND TRY_CAST({MONTHCOL} AS DATE) IS NOT NULL'
                     END,
                     '{MONTHCOL}', @MonthCol);

PRINT 'Deploying Panel Breakdown for prefix: ' + @Prefix + '  (month column: ' + @MonthCol + ')';

-- ---------------------------------------------------------------------
-- 1) Snapshot table
-- ---------------------------------------------------------------------
IF OBJECT_ID(N'dbo.' + @Tbl, 'U') IS NULL
BEGIN
    SET @Sql = N'
CREATE TABLE dbo.' + QUOTENAME(@Tbl) + N'
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName       NVARCHAR(500)   NOT NULL,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);';
    EXEC sp_executesql @Sql;
    PRINT '  created table dbo.' + @Tbl;
END
ELSE
    PRINT '  table dbo.' + @Tbl + ' already exists - left as is.';

-- An earlier version of this script indexed (PanelName, PayerName, BilledYearMonth),
-- which is 2014 bytes and over the 1700-byte nonclustered key limit. Drop it.
SET @Sql = N'DROP INDEX IF EXISTS ' + QUOTENAME(N'IX_' + REPLACE(@Tbl, '_', '') + N'_Panel')
         + N' ON dbo.' + QUOTENAME(@Tbl) + N';';
EXEC sp_executesql @Sql;

-- ---------------------------------------------------------------------
-- 2) Refresh SP
-- ---------------------------------------------------------------------
SET @Sql = REPLACE(REPLACE(REPLACE(REPLACE(N'
CREATE OR ALTER PROCEDURE dbo.usp_Refresh{P}PanelBreakdownWithPayers
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''''), ''Unknown''))) AS PanelName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''''), ''Unknown''))) AS PayerName,
        FORMAT(TRY_CAST({MONTHCOL} AS DATE), ''yyyy-MM'')                      AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''''))                    AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)              AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE {BASEWHERE}
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''''), ''Unknown''))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''''), ''Unknown''))),
        FORMAT(TRY_CAST({MONTHCOL} AS DATE), ''yyyy-MM'');

    TRUNCATE TABLE dbo.{TBL};

    INSERT INTO dbo.{TBL}
        (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    WHERE BilledYearMonth IS NOT NULL
    ORDER BY PanelName, PayerName, BilledYearMonth;

    DECLARE @Rows INT = @@ROWCOUNT;   -- capture before DROP resets it

    DROP TABLE IF EXISTS #Raw;

    PRINT ''usp_Refresh{P}PanelBreakdownWithPayers completed - ''
        + CAST(@Rows AS NVARCHAR(20)) + '' rows.'';
END
',
                   '{TBL}',      @Tbl),
                   '{P}',        @Prefix),
                   '{MONTHCOL}', @MonthCol),
                   '{BASEWHERE}', @BaseWhere);
EXEC sp_executesql @Sql;
PRINT '  created dbo.usp_Refresh' + @Prefix + 'PanelBreakdownWithPayers';

-- ---------------------------------------------------------------------
-- 3) Read SP  (no filters -> snapshot, filters -> live aggregate)
-- ---------------------------------------------------------------------
SET @Sql = REPLACE(REPLACE(REPLACE(REPLACE(N'
CREATE OR ALTER PROCEDURE dbo.usp_Get{P}PanelBreakdownWithPayers
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
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '''') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '''') IS NOT NULL THEN 1
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    -- No filters: serve the pre-aggregated snapshot.
    IF @HasFilter = 0
    BEGIN
        SELECT   PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM     dbo.{TBL}
        ORDER BY PanelName, PayerName, BilledYearMonth;
        RETURN;
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '''') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM   STRING_SPLIT(@PayerNames, ''|'')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '''') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM   STRING_SPLIT(@PanelNames, ''|'')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- Filtered: aggregate live, same base filter and month column as
    -- usp_Get{P}MonthlyBilledProductionSummary so the numbers tie out.
    ;WITH Agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''''), ''Unknown''))) AS PanelName,
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''''), ''Unknown''))) AS PayerName,
            FORMAT(TRY_CAST({MONTHCOL} AS DATE), ''yyyy-MM'')                      AS BilledYearMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''''))                    AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)              AS TotalCharges
        FROM dbo.ClaimLevelData
        WHERE {BASEWHERE}
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''''), ''Unknown''))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)),     ''''), ''Unknown''))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo     IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''''), ''Unknown''))),
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''''), ''Unknown''))),
            FORMAT(TRY_CAST({MONTHCOL} AS DATE), ''yyyy-MM'')
    )
    SELECT   PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
    FROM     Agg
    WHERE    BilledYearMonth IS NOT NULL
    ORDER BY PanelName, PayerName, BilledYearMonth;
END
',
                   '{TBL}',      @Tbl),
                   '{P}',        @Prefix),
                   '{MONTHCOL}', @MonthCol),
                   '{BASEWHERE}', @BaseWhere);
EXEC sp_executesql @Sql;
PRINT '  created dbo.usp_Get' + @Prefix + 'PanelBreakdownWithPayers';

-- ---------------------------------------------------------------------
-- 4) Populate + verify
-- ---------------------------------------------------------------------
SET @Sql = N'EXEC dbo.usp_Refresh' + @Prefix + N'PanelBreakdownWithPayers;';
EXEC sp_executesql @Sql;

SET @Sql = N'
SELECT TOP (20) PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
FROM   dbo.' + QUOTENAME(@Tbl) + N'
ORDER BY ClaimCount DESC;

SELECT Panels = COUNT(DISTINCT PanelName),
       Payers = COUNT(DISTINCT PayerName),
       Months = COUNT(DISTINCT BilledYearMonth),
       Rows_  = COUNT(*)
FROM   dbo.' + QUOTENAME(@Tbl) + N';';
EXEC sp_executesql @Sql;


-- If nothing landed, say why instead of leaving a silent empty table.
DECLARE @Rows INT;
SET @Sql = N'SELECT @n = COUNT(*) FROM dbo.' + QUOTENAME(@Tbl) + N';';
EXEC sp_executesql @Sql, N'@n INT OUTPUT', @n = @Rows OUTPUT;

IF @Rows = 0
BEGIN
    PRINT '';
    PRINT '*** 0 rows - the base filter matched nothing. Counts below show which column is empty:';
    SELECT
        TotalClaimRows        = COUNT(*),
        HasFirstBilledDate    = SUM(CASE WHEN TRY_CAST(FirstBilledDate   AS DATE) IS NOT NULL THEN 1 ELSE 0 END),
        HasChargeEnteredDate  = SUM(CASE WHEN TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL THEN 1 ELSE 0 END),
        HasPayerName_Raw      = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL THEN 1 ELSE 0 END),
        HasPanelname          = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Panelname)),     '') IS NOT NULL THEN 1 ELSE 0 END)
    FROM dbo.ClaimLevelData;
END

PRINT 'Done. Next: add usp_Refresh' + @Prefix + 'PanelBreakdownWithPayers to the nightly refresh list';
PRINT 'in ClaimLineCSVDataCapture (ClaimLineDbService: usp_Refresh{prefix}_* batch).';
GO
