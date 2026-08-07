/* =====================================================================
   dbo.usp_GetExecutiveSummaryDetail_LisDrill
   ---------------------------------------------------------------------
   Analytical drill-through for the Executive Summary "LIS Breakdown"
   section, backing the two clickable rows:

       @Metric = 'Samples'   -> "Total No. of Samples"        (RowCode L_0)
       @Metric = 'Billable'  -> "Billable Samples - Resulted" (RowCode L_A)

   Source: dbo.LIMSMaster (the "LIS Breakdown" source), grouped on the
   collection date. Mirrors the attached logic workbook
   ExecutiveSummary_DrillThrough_Logics&Formulas.

   SCHEMA-AGNOSTIC: dbo.LIMSMaster column names differ per lab (e.g. Cove
   uses DateOfCollection / PanelType / NewStatus, BeechTree uses
   RequestCollectDate / PanelCategory / RessultedStatus). This procedure
   resolves the collection-date, accession, panel and resulted-status
   columns at run time from the same candidate lists the LisSummary
   repository uses, then builds the base rowset with dynamic SQL. Deploy
   the SAME procedure into every lab database.

   Parameters
     @Metric  NVARCHAR(20)  'Samples' | 'Billable'   (default 'Samples')
     @Year    INT           0 = Grand Total (all years); else that year only

   Day-window (@DayWindow): end day of the billed week range (e.g. week
   07.01.2026–07.18.2026 → 18). Applies ONLY to the dedicated N-Day Range
   & Result Rate result sets (sets 4, 6, 7 and the 9-day summary fields).
   Summary KPIs, monthly trend, panels, MoM, and status use full-month
   counts so Latest / Grand Total match the Executive Summary refresh.

   Returns result sets:
     1) Summary band  (full-month KPIs + DayWindow 9-day fields)
     2) Monthly trend (trailing months; full-month; latest flagged partial)
     3) Top panels    (Avg6Months + full-month MoM + Share%)
     4) Result rate   (trailing months; DayWindow resulted / received)
     5) Status breakdown (Not Resulted; full-month)
     6) N-day received band (DayWindow)
     7) Result rate by panel (DayWindow)
     8) Top 10 clinics per top panel (Avg6Months + full-month MoM + Share%)

   Avg6Months window: trailing 6 months anchored on the WeekRange end-date
   month (that month + 5 prior; e.g. week ending in June → Jan–Jun),
   full-month counts (including a partial end month as of the report cutoff).
   ===================================================================== */
IF OBJECT_ID('dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core;
GO
/* =====================================================================
   CORE worker. Per-lab wrapper procedures pass the exact billable
   definition + collection-date column so the drill matches that lab's
   Executive Summary LIS breakdown. See the wrappers at the bottom of
   this file (and per-lab script folders).

   Parameters
     @Metric         'Samples' | 'Billable' | 'NotResulted'
     @Year           0 = Grand Total, else that year
     @BillableCol    LIMSMaster column that classifies "billable"
                     (e.g. Cove 'NewStatus', BeechTree 'RessultedStatus',
                      Certus 'BillTo', InHealth 'SampleStatus'). NULL/absent
                      → nothing is billable.
     @BillableVal    value in @BillableCol meaning billable
                     (e.g. 'Billable', 'Resulted', 'Insurance Bill').
     @NotResultedVal value in @BillableCol meaning "not resulted"
                     (e.g. BeechTree 'Not Resulted'); NULL → no such row.
     @DatePref       preferred collection-date column; falls back to the
                     usual candidates if it does not exist.
   ===================================================================== */
CREATE PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core
    @Metric         NVARCHAR(20)  = 'Samples',
    @Year           INT           = 0,
    @BillableCol    NVARCHAR(128) = NULL,   -- filter condition 1: column
    @BillableVal    NVARCHAR(200) = NULL,   -- filter condition 1: value
    @NotResultedVal NVARCHAR(200) = NULL,
    @DatePref       NVARCHAR(128) = NULL,
    -- Compound AND filter (conditions 2 & 3) so any LIS row is expressible,
    -- e.g. Billed = NewStatus='Billable' AND BillCategory='Billed'.
    @Op1            NVARCHAR(32)  = N'=',    -- '=', '<>', 'LIKE', 'NOT LIKE', 'IN', 'NOT IN'
    @Col2           NVARCHAR(128) = NULL,
    @Op2            NVARCHAR(32)  = N'=',
    @Val2           NVARCHAR(200) = NULL,
    @Col3           NVARCHAR(128) = NULL,
    @Op3            NVARCHAR(32)  = N'=',
    @Val3           NVARCHAR(200) = NULL,
    @Col4           NVARCHAR(128) = NULL,
    @Op4            NVARCHAR(32)  = N'=',
    @Val4           NVARCHAR(200) = NULL,
    @DayWindow      INT           = 9
AS
BEGIN
    SET NOCOUNT ON;

    SET @DayWindow = CASE WHEN @DayWindow BETWEEN 1 AND 31 THEN @DayWindow ELSE 9 END;

    -- Metric mode: 0 = Samples (all), 1 = Billable, 2 = Not Resulted.
    DECLARE @Mode TINYINT =
        CASE @Metric WHEN 'Billable' THEN 1 WHEN 'NotResulted' THEN 2 ELSE 0 END;

    /* ------------------------------------------------------------------
       1. Resolve schema differences: pick the first column that exists in
          dbo.LIMSMaster from each candidate list (priority = ord order).
       ------------------------------------------------------------------ */
    DECLARE @DateCol SYSNAME, @AccCol SYSNAME, @PanelCol SYSNAME;
    -- @DateCol is resolved further down, once the billable scheme is known,
    -- so the drill buckets on the same date column as the lab's Exec Summary.

    SELECT TOP (1) @AccCol = name
    FROM (VALUES (1,'Accession'),(2,'AccessionNumber'),(3,'AccessionNo'),(4,'OrderID'),
                 (5,'UniqueSampleID'),(6,'SampleID'),(7,'SpecimenID')) v(ord, name)
    WHERE COL_LENGTH('dbo.LIMSMaster', name) IS NOT NULL
    ORDER BY ord;

    SELECT TOP (1) @PanelCol = name
    FROM (VALUES
                 (1,'LRNPanelName'),(2,'LRN_PanelName'),(3,'LRNPanel'),
                 (4,'PanelType'),(5,'PanelCategory'),(6,'PanelName'),(7,'Panelname'),
                 (8,'Panel'),(9,'TestPanel'),(10,'TestPanelName'),(11,'PanelGroup'),
                 (12,'PanelNameBasedOnCPT')) v(ord, name)
    WHERE COL_LENGTH('dbo.LIMSMaster', name) IS NOT NULL
    ORDER BY ord;

    /* Clinic / facility — used for Panel → Clinic nest under Top 10 panels.
       Include Client (PCR Labs of America LIMSMaster) after ClientName variants.
       Inhealth uses Account for clinic/facility. */
    DECLARE @ClinicCol SYSNAME;
    SELECT TOP (1) @ClinicCol = name
    FROM (VALUES (1,'ClinicName'),(2,'ClientName'),(3,'Client_Name'),(4,'Client'),
                 (5,'Account'),(6,'Clinic'),(7,'FacilityName'),(8,'Facility'),
                 (9,'OrderingFacility'),(10,'LocationName'),(11,'PracticeName')) v(ord, name)
    WHERE COL_LENGTH('dbo.LIMSMaster', name) IS NOT NULL
    ORDER BY ord;

    /* ClientStatus drives the "Not Resulted" status breakdown. */
    DECLARE @ClientCol SYSNAME;
    SELECT TOP (1) @ClientCol = name
    FROM (VALUES (1,'ClientStatus'),(2,'SubStatus'),(3,'LRNSubStatus'),
                 (4,'FinalStatus'),(5,'NewStatus')) v(ord, name)
    WHERE COL_LENGTH('dbo.LIMSMaster', name) IS NOT NULL
    ORDER BY ord;

    /* Collection-date column: honour the caller's preferred column when it
       exists, else fall back to the usual candidates. */
    IF @DatePref IS NOT NULL AND COL_LENGTH('dbo.LIMSMaster', @DatePref) IS NOT NULL
        SET @DateCol = @DatePref;
    ELSE
        SELECT TOP (1) @DateCol = name
        FROM (VALUES (1,'RequestCollectDate'),(2,'ReqCollectDate'),(3,'DateOfCollection'),
                     (4,'CollectionDate'),(5,'CollectedDate'),(6,'ReceivedDate'),(7,'Entry_DateCreated')) v(ord, name)
        WHERE COL_LENGTH('dbo.LIMSMaster', name) IS NOT NULL
        ORDER BY ord;

    /* Compound filter for the drilled row.
       = / <> / LIKE / NOT LIKE use sp_executesql parameters.
       IN / NOT IN build a quoted list from the comma-separated Val (same as PMS Core).
       ISNULL(...,'') so blank checks match ES NULL/'' ClientStatus filters. */
    SET @Op1 = CASE UPPER(LTRIM(RTRIM(ISNULL(@Op1, N'='))))
                   WHEN N'<>' THEN N'<>' WHEN N'LIKE' THEN N'LIKE' WHEN N'NOT LIKE' THEN N'NOT LIKE'
                   WHEN N'IN' THEN N'IN' WHEN N'NOT IN' THEN N'NOT IN' ELSE N'=' END;
    SET @Op2 = CASE UPPER(LTRIM(RTRIM(ISNULL(@Op2, N'='))))
                   WHEN N'<>' THEN N'<>' WHEN N'LIKE' THEN N'LIKE' WHEN N'NOT LIKE' THEN N'NOT LIKE'
                   WHEN N'IN' THEN N'IN' WHEN N'NOT IN' THEN N'NOT IN' ELSE N'=' END;
    SET @Op3 = CASE UPPER(LTRIM(RTRIM(ISNULL(@Op3, N'='))))
                   WHEN N'<>' THEN N'<>' WHEN N'LIKE' THEN N'LIKE' WHEN N'NOT LIKE' THEN N'NOT LIKE'
                   WHEN N'IN' THEN N'IN' WHEN N'NOT IN' THEN N'NOT IN' ELSE N'=' END;
    SET @Op4 = CASE UPPER(LTRIM(RTRIM(ISNULL(@Op4, N'='))))
                   WHEN N'<>' THEN N'<>' WHEN N'LIKE' THEN N'LIKE' WHEN N'NOT LIKE' THEN N'NOT LIKE'
                   WHEN N'IN' THEN N'IN' WHEN N'NOT IN' THEN N'NOT IN' ELSE N'=' END;

    DECLARE @BCol  SYSNAME = CASE WHEN @BillableCol IS NOT NULL AND COL_LENGTH('dbo.LIMSMaster', @BillableCol) IS NOT NULL THEN @BillableCol ELSE NULL END;
    DECLARE @BCol2 SYSNAME = CASE WHEN @Col2 IS NOT NULL AND COL_LENGTH('dbo.LIMSMaster', @Col2) IS NOT NULL THEN @Col2 ELSE NULL END;
    DECLARE @BCol3 SYSNAME = CASE WHEN @Col3 IS NOT NULL AND COL_LENGTH('dbo.LIMSMaster', @Col3) IS NOT NULL THEN @Col3 ELSE NULL END;
    DECLARE @BCol4 SYSNAME = CASE WHEN @Col4 IS NOT NULL AND COL_LENGTH('dbo.LIMSMaster', @Col4) IS NOT NULL THEN @Col4 ELSE NULL END;

    DECLARE @colExpr1 NVARCHAR(400) = CASE WHEN @BCol  IS NULL THEN NULL ELSE N'LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(4000), ' + QUOTENAME(@BCol)  + N'), N'''')))' END;
    DECLARE @colExpr2 NVARCHAR(400) = CASE WHEN @BCol2 IS NULL THEN NULL ELSE N'LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(4000), ' + QUOTENAME(@BCol2) + N'), N'''')))' END;
    DECLARE @colExpr3 NVARCHAR(400) = CASE WHEN @BCol3 IS NULL THEN NULL ELSE N'LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(4000), ' + QUOTENAME(@BCol3) + N'), N'''')))' END;
    DECLARE @colExpr4 NVARCHAR(400) = CASE WHEN @BCol4 IS NULL THEN NULL ELSE N'LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(4000), ' + QUOTENAME(@BCol4) + N'), N'''')))' END;

    DECLARE @inList NVARCHAR(MAX);
    DECLARE @ResultedPred NVARCHAR(MAX) = N'';
    IF @colExpr1 IS NOT NULL AND @BillableVal IS NOT NULL
    BEGIN
        IF @Op1 IN (N'IN', N'NOT IN')
        BEGIN
            SELECT @inList = STRING_AGG(
                CASE WHEN LTRIM(RTRIM(value)) IN (N'', N'__BLANK__') THEN N'N'''''
                     ELSE N'N' + QUOTENAME(LTRIM(RTRIM(value)), '''') END, N',')
            FROM STRING_SPLIT(@BillableVal, N',');
            IF @inList IS NULL SET @ResultedPred = N'(1 = 0)';
            ELSE SET @ResultedPred = N'(' + @colExpr1 + N' ' + @Op1 + N' (' + @inList + N'))';
        END
        ELSE
            SET @ResultedPred = @colExpr1 + N' ' + @Op1 + N' @BillableVal';
    END
    IF @colExpr2 IS NOT NULL AND @Val2 IS NOT NULL
    BEGIN
        SET @ResultedPred = CASE WHEN @ResultedPred = N'' THEN N'' ELSE @ResultedPred + N' AND ' END;
        IF @Op2 IN (N'IN', N'NOT IN')
        BEGIN
            SELECT @inList = STRING_AGG(
                CASE WHEN LTRIM(RTRIM(value)) IN (N'', N'__BLANK__') THEN N'N'''''
                     ELSE N'N' + QUOTENAME(LTRIM(RTRIM(value)), '''') END, N',')
            FROM STRING_SPLIT(@Val2, N',');
            IF @inList IS NULL SET @ResultedPred = @ResultedPred + N'(1 = 0)';
            ELSE SET @ResultedPred = @ResultedPred + N'(' + @colExpr2 + N' ' + @Op2 + N' (' + @inList + N'))';
        END
        ELSE
            SET @ResultedPred = @ResultedPred + @colExpr2 + N' ' + @Op2 + N' @Val2';
    END
    IF @colExpr3 IS NOT NULL AND @Val3 IS NOT NULL
    BEGIN
        SET @ResultedPred = CASE WHEN @ResultedPred = N'' THEN N'' ELSE @ResultedPred + N' AND ' END;
        IF @Op3 IN (N'IN', N'NOT IN')
        BEGIN
            SELECT @inList = STRING_AGG(
                CASE WHEN LTRIM(RTRIM(value)) IN (N'', N'__BLANK__') THEN N'N'''''
                     ELSE N'N' + QUOTENAME(LTRIM(RTRIM(value)), '''') END, N',')
            FROM STRING_SPLIT(@Val3, N',');
            IF @inList IS NULL SET @ResultedPred = @ResultedPred + N'(1 = 0)';
            ELSE SET @ResultedPred = @ResultedPred + N'(' + @colExpr3 + N' ' + @Op3 + N' (' + @inList + N'))';
        END
        ELSE
            SET @ResultedPred = @ResultedPred + @colExpr3 + N' ' + @Op3 + N' @Val3';
    END
    IF @colExpr4 IS NOT NULL AND @Val4 IS NOT NULL
    BEGIN
        SET @ResultedPred = CASE WHEN @ResultedPred = N'' THEN N'' ELSE @ResultedPred + N' AND ' END;
        IF @Op4 IN (N'IN', N'NOT IN')
        BEGIN
            SELECT @inList = STRING_AGG(
                CASE WHEN LTRIM(RTRIM(value)) IN (N'', N'__BLANK__') THEN N'N'''''
                     ELSE N'N' + QUOTENAME(LTRIM(RTRIM(value)), '''') END, N',')
            FROM STRING_SPLIT(@Val4, N',');
            IF @inList IS NULL SET @ResultedPred = @ResultedPred + N'(1 = 0)';
            ELSE SET @ResultedPred = @ResultedPred + N'(' + @colExpr4 + N' ' + @Op4 + N' (' + @inList + N'))';
        END
        ELSE
            SET @ResultedPred = @ResultedPred + @colExpr4 + N' ' + @Op4 + N' @Val4';
    END
    IF @ResultedPred = N'' SET @ResultedPred = N'(1 = 0)';

    DECLARE @NotResultedPred NVARCHAR(MAX) =
        CASE WHEN @BCol IS NULL OR @NotResultedVal IS NULL THEN N'(1 = 0)'
             ELSE N'LTRIM(RTRIM(CONVERT(nvarchar(4000), ' + QUOTENAME(@BCol) + N'))) = @NotResultedVal' END;

    /* Panel + Clinic + ClientStatus expressions (literal fallbacks when absent).
       Constants must NOT appear in GROUP BY — SQL Server raises
       "Each GROUP BY expression must contain at least one column that is
       not an outer reference" when GROUP BY includes CAST('…' AS …). */
    DECLARE @PanelExpr NVARCHAR(MAX) =
        CASE WHEN @PanelCol IS NULL
             THEN N'CAST(N''All Panels'' AS nvarchar(4000))'
             ELSE N'ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), '
                  + QUOTENAME(@PanelCol) + N'))), ''''), ''Unspecified'')'
        END;
    DECLARE @PanelGb NVARCHAR(MAX) =
        CASE WHEN @PanelCol IS NULL THEN N'' ELSE N',' + CHAR(10) + N'            ' + @PanelExpr END;

    DECLARE @ClinicExpr NVARCHAR(MAX) =
        CASE WHEN @ClinicCol IS NULL
             THEN N'CAST(N''Unspecified'' AS nvarchar(4000))'
             ELSE N'ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), '
                  + QUOTENAME(@ClinicCol) + N'))), ''''), ''Unspecified'')'
        END;
    DECLARE @ClinicGb NVARCHAR(MAX) =
        CASE WHEN @ClinicCol IS NULL THEN N'' ELSE N',' + CHAR(10) + N'            ' + @ClinicExpr END;

    DECLARE @ClientExpr NVARCHAR(MAX) =
        CASE WHEN @ClientCol IS NULL
             THEN N'CAST(N''Unspecified'' AS nvarchar(4000))'
             ELSE N'ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), '
                  + QUOTENAME(@ClientCol) + N'))), ''''), ''Unspecified'')'
        END;
    DECLARE @ClientGb NVARCHAR(MAX) =
        CASE WHEN @ClientCol IS NULL THEN N'' ELSE N',' + CHAR(10) + N'            ' + @ClientExpr END;

    /* ------------------------------------------------------------------
       2. Base rowset: one row per accession/day/panel with a resulted flag.
          Built with dynamic SQL because the column names vary per lab.
          #Acc is created in this (outer) scope so it stays visible to the
          dynamic batch and to the static queries that follow.
       ------------------------------------------------------------------ */
    IF OBJECT_ID('tempdb..#Acc') IS NOT NULL DROP TABLE #Acc;
    CREATE TABLE #Acc
    (
        CollYear      INT,
        CollMonth     INT,
        CollDay       INT,
        Accession     NVARCHAR(4000),
        Panel         NVARCHAR(4000),
        Clinic        NVARCHAR(4000),
        ClientStatus  NVARCHAR(4000),
        IsResulted    BIT,
        IsNotResulted BIT
    );

    IF @DateCol IS NOT NULL AND @AccCol IS NOT NULL
    BEGIN
        DECLARE @dt  NVARCHAR(300) = N'TRY_CONVERT(date, ' + QUOTENAME(@DateCol) + N')';
        DECLARE @acc NVARCHAR(300) = N'NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), '
                                     + QUOTENAME(@AccCol) + N'))), '''')';

        /* Year filter is sargable (date range) so RequestCollectDate /
           DateOfCollection indexes can seek; DAY() is applied after load.
           Omit DATEFROMPARTS when @Year = 0 (Grand Total): SQL Server may
           evaluate both sides of OR and DATEFROMPARTS(0,…) raises
           "Cannot construct data type date…". */
        DECLARE @YearPred NVARCHAR(400) = N'';
        IF ISNULL(@Year, 0) <> 0
            SET @YearPred = N'
          AND ' + @dt + N' >= DATEFROMPARTS(@Year, 1, 1)
          AND ' + @dt + N' <  DATEFROMPARTS(@Year + 1, 1, 1)';

        DECLARE @sql NVARCHAR(MAX) = N'
        INSERT INTO #Acc (CollYear, CollMonth, CollDay, Accession, Panel, Clinic, ClientStatus, IsResulted, IsNotResulted)
        SELECT
            YEAR('  + @dt + N'),
            MONTH(' + @dt + N'),
            DAY('   + @dt + N'),
            ' + @acc + N',
            ' + @PanelExpr + N',
            ' + @ClinicExpr + N',
            ' + @ClientExpr + N',
            MAX(CASE WHEN ' + @ResultedPred    + N' THEN 1 ELSE 0 END),
            MAX(CASE WHEN ' + @NotResultedPred + N' THEN 1 ELSE 0 END)
        FROM dbo.LIMSMaster WITH (NOLOCK)
        WHERE ' + @dt + N' IS NOT NULL
          AND ' + @dt + N' >= ''19010101''
          AND ' + @acc + N' IS NOT NULL' + @YearPred + N'
        GROUP BY
            YEAR('  + @dt + N'),
            MONTH(' + @dt + N'),
            DAY('   + @dt + N'),
            ' + @acc + @PanelGb + @ClinicGb + @ClientGb + N';';

        EXEC sys.sp_executesql @sql,
             N'@Year INT, @BillableVal NVARCHAR(200), @NotResultedVal NVARCHAR(200), @Val2 NVARCHAR(200), @Val3 NVARCHAR(200), @Val4 NVARCHAR(200)',
             @Year = @Year, @BillableVal = @BillableVal, @NotResultedVal = @NotResultedVal, @Val2 = @Val2, @Val3 = @Val3, @Val4 = @Val4;
    END

    /* Cutoff from full-month data (no DayWindow shrink — main aggregates
       must match ES). TRY_CONVERT avoids DATEFROMPARTS failures. */
    DECLARE @CutoffDate date =
        (SELECT MAX(TRY_CONVERT(date, CONVERT(char(8),
                    CollYear * 10000 + CollMonth * 100 + CollDay)))
         FROM #Acc
         WHERE @Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1));

    IF EXISTS (SELECT 1 FROM #Acc)
        CREATE CLUSTERED INDEX IX_Acc_YM_Panel ON #Acc (CollYear, CollMonth, Panel, Clinic);

    /* ------------------------------------------------------------------
       3. Per-month rollup (distinct accessions). Static from here down.
       ------------------------------------------------------------------ */
    IF OBJECT_ID('tempdb..#Monthly') IS NOT NULL DROP TABLE #Monthly;

    /* MetricCount = full month (matches ES). Metric9Day / Received9 /
       ResultedCount / ReceivedCount = DayWindow only (N-Day section). */
    SELECT
        CollYear,
        CollMonth,
        MetricCount   = COUNT(DISTINCT CASE WHEN (@Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1))
                                            THEN Accession END),
        Metric9Day    = COUNT(DISTINCT CASE WHEN CollDay BETWEEN 1 AND @DayWindow
                                             AND (@Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1))
                                            THEN Accession END),
        ReceivedCount = COUNT(DISTINCT CASE WHEN CollDay BETWEEN 1 AND @DayWindow THEN Accession END),
        ResultedCount = COUNT(DISTINCT CASE WHEN CollDay BETWEEN 1 AND @DayWindow AND IsResulted = 1 THEN Accession END),
        Received9     = COUNT(DISTINCT CASE WHEN CollDay BETWEEN 1 AND @DayWindow THEN Accession END)
    INTO #Monthly
    FROM #Acc
    GROUP BY CollYear, CollMonth;

    /* ------------------------------------------------------------------
       4. Latest / previous month + 6-month average (includes WeekRange
          end month + 5 prior; full-month MetricCount).
       ------------------------------------------------------------------ */
    DECLARE @LatestY INT, @LatestM INT, @LatestCount BIGINT, @Latest9 BIGINT;
    DECLARE @PrevY   INT, @PrevM   INT, @PrevCount   BIGINT, @Prev9   BIGINT;
    DECLARE @Avg6 DECIMAL(18,2);

    SELECT @LatestY = CollYear, @LatestM = CollMonth,
           @LatestCount = MetricCount, @Latest9 = Metric9Day
    FROM #Monthly
    ORDER BY CollYear DESC, CollMonth DESC
    OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY;

    SELECT @PrevY = CollYear, @PrevM = CollMonth,
           @PrevCount = MetricCount, @Prev9 = Metric9Day
    FROM #Monthly
    ORDER BY CollYear DESC, CollMonth DESC
    OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY;

    /* Avg6 = end month + 5 prior (OFFSET 0, not 1). */
    SELECT @Avg6 = AVG(CAST(MetricCount AS DECIMAL(18,2)))
    FROM (
        SELECT MetricCount
        FROM #Monthly
        ORDER BY CollYear DESC, CollMonth DESC
        OFFSET 0 ROWS FETCH NEXT 6 ROWS ONLY
    ) x;

    /* Avg-6 month keys: WeekRange end month + 5 prior (full-month). */
    IF OBJECT_ID('tempdb..#AvgMonths') IS NOT NULL DROP TABLE #AvgMonths;
    SELECT CollYear, CollMonth
    INTO #AvgMonths
    FROM #Monthly
    ORDER BY CollYear DESC, CollMonth DESC
    OFFSET 0 ROWS FETCH NEXT 6 ROWS ONLY;

    /* If no monthly rows, fall back to the WeekRange end month alone. */
    IF NOT EXISTS (SELECT 1 FROM #AvgMonths) AND @LatestM IS NOT NULL
        INSERT INTO #AvgMonths (CollYear, CollMonth) VALUES (@LatestY, @LatestM);

    DECLARE @AvgMonthCount INT = (SELECT COUNT(*) FROM #AvgMonths);
    IF @AvgMonthCount < 1 SET @AvgMonthCount = 1;

    DECLARE @GrandMetric BIGINT =
        (SELECT COUNT(DISTINCT CASE WHEN (@Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1))
                                    THEN Accession END) FROM #Acc);

    /* Panel×month metric counts once — reused by Top panels + Clinic Top-10. */
    IF OBJECT_ID('tempdb..#PanelMonth') IS NOT NULL DROP TABLE #PanelMonth;
    SELECT
        Panel, CollYear, CollMonth,
        Cnt = COUNT(DISTINCT CASE WHEN (@Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1))
                                  THEN Accession END)
    INTO #PanelMonth
    FROM #Acc
    GROUP BY Panel, CollYear, CollMonth;

    IF OBJECT_ID('tempdb..#PanelMoM') IS NOT NULL DROP TABLE #PanelMoM;
    SELECT
        Panel,
        Prev9Day = COUNT(DISTINCT CASE WHEN (@Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1))
                                       AND @PrevM IS NOT NULL AND CollYear = @PrevY AND CollMonth = @PrevM
                                       THEN Accession END),
        Latest9Day = COUNT(DISTINCT CASE WHEN (@Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1))
                                         AND CollYear = @LatestY AND CollMonth = @LatestM
                                         THEN Accession END)
    INTO #PanelMoM
    FROM #Acc
    GROUP BY Panel;

    IF OBJECT_ID('tempdb..#PanelAgg') IS NOT NULL DROP TABLE #PanelAgg;
    SELECT
        a.Panel,
        a.Avg6Months,
        m.Prev9Day,
        m.Latest9Day
    INTO #PanelAgg
    FROM (
        SELECT
            p.Panel,
            Avg6Months = CAST(SUM(CAST(ISNULL(pm.Cnt, 0) AS DECIMAL(18,4))) / @AvgMonthCount AS DECIMAL(18,2))
        FROM (SELECT DISTINCT Panel FROM #Acc) p
        CROSS JOIN #AvgMonths am
        LEFT JOIN #PanelMonth pm
            ON pm.Panel = p.Panel AND pm.CollYear = am.CollYear AND pm.CollMonth = am.CollMonth
        GROUP BY p.Panel
    ) a
    INNER JOIN #PanelMoM m ON m.Panel = a.Panel
    WHERE a.Avg6Months > 0;

    DECLARE @PanelTot DECIMAL(18,2) = (SELECT SUM(Avg6Months) FROM #PanelAgg);

    IF OBJECT_ID('tempdb..#TopPanels') IS NOT NULL DROP TABLE #TopPanels;
    SELECT TOP (10) Panel, Avg6Months, Prev9Day, Latest9Day
    INTO #TopPanels
    FROM #PanelAgg
    ORDER BY Avg6Months DESC;

    /* === Result set 1 : Summary band ================================= */
    SELECT
        CutoffDate       = @CutoffDate,
        LatestMonthLabel = CASE WHEN @LatestM IS NULL THEN ''
                                ELSE LEFT(DATENAME(MONTH, DATEFROMPARTS(@LatestY, @LatestM, 1)), 3)
                                     + ' ' + CONVERT(varchar(4), @LatestY) END,
        LatestCount      = ISNULL(@LatestCount, 0),
        PrevMonthLabel   = CASE WHEN @PrevM IS NULL THEN ''
                                ELSE LEFT(DATENAME(MONTH, DATEFROMPARTS(@PrevY, @PrevM, 1)), 3)
                                     + ' ' + CONVERT(varchar(4), @PrevY) END,
        PrevCount        = ISNULL(@PrevCount, 0),
        MoMChangePct     = CASE WHEN ISNULL(@PrevCount, 0) = 0 THEN NULL
                                ELSE CAST((@LatestCount - @PrevCount) * 100.0 / @PrevCount AS DECIMAL(18,2)) END,
        Avg6             = @Avg6,
        CurrVsAvgPct     = CASE WHEN ISNULL(@Avg6, 0) = 0 THEN NULL
                                ELSE CAST((@LatestCount - @Avg6) * 100.0 / @Avg6 AS DECIMAL(18,2)) END,
        Latest9DayLabel  = CASE WHEN @LatestM IS NULL THEN ''
                                ELSE LEFT(DATENAME(MONTH, DATEFROMPARTS(@LatestY, @LatestM, 1)), 3) + ' (1-' + CONVERT(varchar(2), @DayWindow) + ')' END,
        Latest9DayCount  = ISNULL(@Latest9, 0),
        Prev9DayLabel    = CASE WHEN @PrevM IS NULL THEN ''
                                ELSE LEFT(DATENAME(MONTH, DATEFROMPARTS(@PrevY, @PrevM, 1)), 3) + ' (1-' + CONVERT(varchar(2), @DayWindow) + ')' END,
        Prev9DayCount    = ISNULL(@Prev9, 0),
        NineDayMoMPct    = CASE WHEN ISNULL(@Prev9, 0) = 0 THEN NULL
                                ELSE CAST((@Latest9 - @Prev9) * 100.0 / @Prev9 AS DECIMAL(18,2)) END;

    /* === Result set 2 : Monthly totals (full-month) for the trend chart =
       Trailing 13 months, ascending. Matches ES monthly cells.
       The latest month is flagged partial (as-of the report cutoff) so the UI
       can fade its bar. */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, DATEFROMPARTS(CollYear, CollMonth, 1)), 3)
                     + ' ' + CONVERT(varchar(4), CollYear),
        ShortLabel = LEFT(DATENAME(MONTH, DATEFROMPARTS(CollYear, CollMonth, 1)), 3),
        Total      = MetricCount,
        IsPartial  = CASE WHEN CollYear = @LatestY AND CollMonth = @LatestM THEN 1 ELSE 0 END
    FROM (
        SELECT TOP (13) CollYear, CollMonth, MetricCount
        FROM #Monthly
        ORDER BY CollYear DESC, CollMonth DESC
    ) m
    ORDER BY CollYear, CollMonth;

    /* === Result set 3 : Top panels (Avg 6 Months + full-month MoM) =====
       Avg6Months = mean of full-month counts over the WeekRange end month
       + 5 prior (e.g. June end → Jan–Jun). Prev9Day/Latest9Day columns
       hold full-month MoM (legacy names kept for the C# reader).
       PeriodTotal kept as rounded Avg6Months for older readers. */
    SELECT
        Panel,
        PeriodTotal = CAST(ROUND(Avg6Months, 0) AS BIGINT),
        Avg6Months,
        SharePct    = CASE WHEN ISNULL(@PanelTot, 0) = 0 THEN 0
                           ELSE CAST(Avg6Months * 100.0 / @PanelTot AS DECIMAL(18,2)) END,
        Prev9Day,
        Latest9Day,
        MoMDeltaPct = CASE WHEN Prev9Day = 0 THEN NULL
                           ELSE CAST((Latest9Day - Prev9Day) * 100.0 / Prev9Day AS DECIMAL(18,2)) END
    FROM #TopPanels
    ORDER BY Avg6Months DESC;

    /* === Result set 4 : Result rate (trailing 7 months) ============== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, DATEFROMPARTS(CollYear, CollMonth, 1)), 3)
                     + ' ' + CONVERT(varchar(4), CollYear),
        Resulted   = ResultedCount,
        Received   = ReceivedCount,
        RatePct    = CASE WHEN ReceivedCount = 0 THEN NULL
                          ELSE CAST(ResultedCount * 100.0 / ReceivedCount AS DECIMAL(18,2)) END
    FROM (
        SELECT TOP (7) CollYear, CollMonth, ResultedCount, ReceivedCount
        FROM #Monthly
        ORDER BY CollYear DESC, CollMonth DESC
    ) m
    ORDER BY CollYear, CollMonth;

    /* === Result set 5 : Not-Resulted status breakdown (ClientStatus x month)
       Long format (one row per status/month); the UI pivots it. Only populated
       for the Not Resulted metric (@Mode = 2). Full-month counts. */
    SELECT
        Status    = ClientStatus,
        CollYear,
        CollMonth,
        Cnt       = COUNT(DISTINCT Accession)
    FROM #Acc
    WHERE @Mode = 2
      AND IsNotResulted = 1
      AND (CollYear * 100 + CollMonth) IN (
            SELECT TOP (7) (CollYear * 100 + CollMonth)
            FROM #Monthly
            ORDER BY CollYear DESC, CollMonth DESC
      )
    GROUP BY ClientStatus, CollYear, CollMonth
    ORDER BY ClientStatus, CollYear, CollMonth;

    /* === Result set 6 : Data for 9 days range (samples received in first 9
       days, per month) — the denominator basis for the result-rate table. */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, DATEFROMPARTS(CollYear, CollMonth, 1)), 3)
                     + ' ' + CONVERT(varchar(4), CollYear),
        ShortLabel = LEFT(DATENAME(MONTH, DATEFROMPARTS(CollYear, CollMonth, 1)), 3),
        Received9  = Received9
    FROM (
        SELECT TOP (7) CollYear, CollMonth, Received9
        FROM #Monthly
        ORDER BY CollYear DESC, CollMonth DESC
    ) m
    ORDER BY CollYear, CollMonth;

    /* === Result set 7 : Result Rate by panel (DayWindow resulted / received),
       top panels x trailing months. Shown for every metric. Long format;
       the UI pivots it into a Panel x month rate matrix. */
    ;WITH RR AS (
        SELECT
            Panel, CollYear, CollMonth,
            Received9 = COUNT(DISTINCT Accession),
            Resulted9 = COUNT(DISTINCT CASE WHEN IsResulted = 1 THEN Accession END)
        FROM #Acc
        WHERE CollDay BETWEEN 1 AND @DayWindow
        GROUP BY Panel, CollYear, CollMonth
    ),
    TopP AS (
        SELECT TOP (8) Panel
        FROM (SELECT Panel, Tot = SUM(Received9) FROM RR GROUP BY Panel) z
        WHERE Tot > 0
        ORDER BY Tot DESC
    )
    SELECT
        rr.Panel, rr.CollYear, rr.CollMonth, rr.Resulted9, rr.Received9
    FROM RR rr
    JOIN TopP t ON t.Panel = rr.Panel
    WHERE (rr.CollYear * 100 + rr.CollMonth) IN (
            SELECT TOP (7) (CollYear * 100 + CollMonth)
            FROM #Monthly ORDER BY CollYear DESC, CollMonth DESC
    )
    ORDER BY rr.Panel, rr.CollYear, rr.CollMonth;

    /* === Result set 8 : Top 10 clinics per Top-10 panel ================
       Same Avg6Months window + full-month MoM as Set 3. SharePct is the
       clinic's share of its parent panel's Avg6Months. Uses #TopPanels. */
    ;WITH ClinicMonth AS (
        SELECT
            a.Panel, a.Clinic, a.CollYear, a.CollMonth,
            Cnt = COUNT(DISTINCT CASE WHEN (@Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1))
                                      THEN a.Accession END)
        FROM #Acc a
        INNER JOIN #TopPanels t ON t.Panel = a.Panel
        GROUP BY a.Panel, a.Clinic, a.CollYear, a.CollMonth
    ),
    ClinicAvg AS (
        SELECT
            c.Panel,
            c.Clinic,
            Avg6Months = CAST(SUM(CAST(ISNULL(cm.Cnt, 0) AS DECIMAL(18,4))) / @AvgMonthCount AS DECIMAL(18,2))
        FROM (SELECT DISTINCT a.Panel, a.Clinic FROM #Acc a INNER JOIN #TopPanels t ON t.Panel = a.Panel) c
        CROSS JOIN #AvgMonths am
        LEFT JOIN ClinicMonth cm
            ON cm.Panel = c.Panel AND cm.Clinic = c.Clinic
           AND cm.CollYear = am.CollYear AND cm.CollMonth = am.CollMonth
        GROUP BY c.Panel, c.Clinic
    ),
    ClinicMoM AS (
        SELECT
            a.Panel, a.Clinic,
            Prev9Day = COUNT(DISTINCT CASE WHEN (@Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1))
                                           AND @PrevM IS NOT NULL AND a.CollYear = @PrevY AND a.CollMonth = @PrevM
                                           THEN a.Accession END),
            Latest9Day = COUNT(DISTINCT CASE WHEN (@Mode = 0 OR (@Mode = 1 AND IsResulted = 1) OR (@Mode = 2 AND IsNotResulted = 1))
                                             AND a.CollYear = @LatestY AND a.CollMonth = @LatestM
                                             THEN a.Accession END)
        FROM #Acc a
        INNER JOIN #TopPanels t ON t.Panel = a.Panel
        GROUP BY a.Panel, a.Clinic
    ),
    Ranked AS (
        SELECT
            ca.Panel,
            ca.Clinic,
            ca.Avg6Months,
            m.Prev9Day,
            m.Latest9Day,
            tp.Avg6Months AS PanelAvg6,
            rn = ROW_NUMBER() OVER (PARTITION BY ca.Panel ORDER BY ca.Avg6Months DESC)
        FROM ClinicAvg ca
        INNER JOIN ClinicMoM m ON m.Panel = ca.Panel AND m.Clinic = ca.Clinic
        INNER JOIN #TopPanels tp ON tp.Panel = ca.Panel
        WHERE ca.Avg6Months > 0
    )
    SELECT
        Panel,
        Clinic,
        PeriodTotal = CAST(ROUND(Avg6Months, 0) AS BIGINT),
        Avg6Months,
        SharePct    = CASE WHEN ISNULL(PanelAvg6, 0) = 0 THEN 0
                           ELSE CAST(Avg6Months * 100.0 / PanelAvg6 AS DECIMAL(18,2)) END,
        Prev9Day,
        Latest9Day,
        MoMDeltaPct = CASE WHEN Prev9Day = 0 THEN NULL
                           ELSE CAST((Latest9Day - Prev9Day) * 100.0 / Prev9Day AS DECIMAL(18,2)) END
    FROM Ranked
    WHERE rn <= 10
    ORDER BY Panel, Avg6Months DESC;

    IF OBJECT_ID('tempdb..#Acc')        IS NOT NULL DROP TABLE #Acc;
    IF OBJECT_ID('tempdb..#Monthly')    IS NOT NULL DROP TABLE #Monthly;
    IF OBJECT_ID('tempdb..#AvgMonths')  IS NOT NULL DROP TABLE #AvgMonths;
    IF OBJECT_ID('tempdb..#PanelMonth') IS NOT NULL DROP TABLE #PanelMonth;
    IF OBJECT_ID('tempdb..#PanelMoM')   IS NOT NULL DROP TABLE #PanelMoM;
    IF OBJECT_ID('tempdb..#PanelAgg')   IS NOT NULL DROP TABLE #PanelAgg;
    IF OBJECT_ID('tempdb..#TopPanels')  IS NOT NULL DROP TABLE #TopPanels;
END
GO

/* =====================================================================
   Generic fallback wrapper — auto-detects the billable scheme for labs
   without a dedicated wrapper below. The C# controller calls the per-lab
   wrapper (usp_Get<Prefix>_ExecutiveSummaryDetail_LisDrill) first and only
   falls back to this generic name when the per-lab one is not deployed.
   ===================================================================== */
IF OBJECT_ID('dbo.usp_GetExecutiveSummaryDetail_LisDrill', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LisDrill;
GO
CREATE PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LisDrill
    @Metric    NVARCHAR(20) = 'Samples',
    @Year      INT          = 0,
    @DayWindow INT          = 9
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Col NVARCHAR(128) = NULL, @Val NVARCHAR(200) = NULL,
            @NotVal NVARCHAR(200) = NULL, @DatePref NVARCHAR(128) = NULL;

    IF      COL_LENGTH('dbo.LIMSMaster','RessultedStatus') IS NOT NULL
        SELECT @Col = N'RessultedStatus', @Val = N'Resulted', @NotVal = N'Not Resulted', @DatePref = N'RequestCollectDate';
    ELSE IF COL_LENGTH('dbo.LIMSMaster','ResultedStatus')  IS NOT NULL
        SELECT @Col = N'ResultedStatus',  @Val = N'Resulted', @NotVal = N'Not Resulted', @DatePref = N'RequestCollectDate';
    ELSE IF COL_LENGTH('dbo.LIMSMaster','NewStatus')       IS NOT NULL
        SELECT @Col = N'NewStatus',       @Val = N'Billable', @DatePref = N'DateOfCollection';
    ELSE IF COL_LENGTH('dbo.LIMSMaster','SampleStatus')    IS NOT NULL
        SELECT @Col = N'SampleStatus',    @Val = N'Billable';
    ELSE IF COL_LENGTH('dbo.LIMSMaster','BillTo')          IS NOT NULL
        SELECT @Col = N'BillTo',          @Val = N'Insurance Bill';

    EXEC dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core
         @Metric = @Metric, @Year = @Year,
         @BillableCol = @Col, @BillableVal = @Val,
         @NotResultedVal = @NotVal, @DatePref = @DatePref,
         @DayWindow = @DayWindow;
END
GO

/* =====================================================================
   Per-lab wrappers — each passes its lab's exact Executive Summary
   "Billable" definition + collection-date column. Deploy the wrapper into
   the matching lab DB (alongside the shared _Core procedure above).
   ===================================================================== */

-- BeechTree: Billable = RessultedStatus 'Resulted' / 'Not Resulted', bucket RequestCollectDate
IF OBJECT_ID('dbo.usp_GetBT_ExecutiveSummaryDetail_LisDrill','P') IS NOT NULL DROP PROCEDURE dbo.usp_GetBT_ExecutiveSummaryDetail_LisDrill;
GO
CREATE PROCEDURE dbo.usp_GetBT_ExecutiveSummaryDetail_LisDrill @Metric NVARCHAR(20)='Samples', @Year INT=0, @DayWindow INT=9 AS
BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core @Metric=@Metric, @Year=@Year,
         @BillableCol=N'RessultedStatus', @BillableVal=N'Resulted', @NotResultedVal=N'Not Resulted', @DatePref=N'RequestCollectDate',
         @DayWindow=@DayWindow;
END
GO

-- PhiLife: Billable = RessultedStatus 'Resulted' / 'Not Resulted', bucket RequestCollectDate
IF OBJECT_ID('dbo.usp_GetPhi_ExecutiveSummaryDetail_LisDrill','P') IS NOT NULL DROP PROCEDURE dbo.usp_GetPhi_ExecutiveSummaryDetail_LisDrill;
GO
CREATE PROCEDURE dbo.usp_GetPhi_ExecutiveSummaryDetail_LisDrill @Metric NVARCHAR(20)='Samples', @Year INT=0, @DayWindow INT=9 AS
BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core @Metric=@Metric, @Year=@Year,
         @BillableCol=N'RessultedStatus', @BillableVal=N'Resulted', @NotResultedVal=N'Not Resulted', @DatePref=N'RequestCollectDate',
         @DayWindow=@DayWindow;
END
GO

-- RisingTides: Billable = RessultedStatus 'Resulted' / 'Not Resulted', bucket RequestCollectDate
IF OBJECT_ID('dbo.usp_GetRT_ExecutiveSummaryDetail_LisDrill','P') IS NOT NULL DROP PROCEDURE dbo.usp_GetRT_ExecutiveSummaryDetail_LisDrill;
GO
CREATE PROCEDURE dbo.usp_GetRT_ExecutiveSummaryDetail_LisDrill @Metric NVARCHAR(20)='Samples', @Year INT=0, @DayWindow INT=9 AS
BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core @Metric=@Metric, @Year=@Year,
         @BillableCol=N'RessultedStatus', @BillableVal=N'Resulted', @NotResultedVal=N'Not Resulted', @DatePref=N'RequestCollectDate',
         @DayWindow=@DayWindow;
END
GO

-- PCR Labs of America: Billable = RessultedStatus 'Resulted' / 'Not Resulted', bucket RequestCollectDate
IF OBJECT_ID('dbo.usp_GetPCR_ExecutiveSummaryDetail_LisDrill','P') IS NOT NULL DROP PROCEDURE dbo.usp_GetPCR_ExecutiveSummaryDetail_LisDrill;
GO
CREATE PROCEDURE dbo.usp_GetPCR_ExecutiveSummaryDetail_LisDrill @Metric NVARCHAR(20)='Samples', @Year INT=0, @DayWindow INT=9 AS
BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core @Metric=@Metric, @Year=@Year,
         @BillableCol=N'RessultedStatus', @BillableVal=N'Resulted', @NotResultedVal=N'Not Resulted', @DatePref=N'RequestCollectDate',
         @DayWindow=@DayWindow;
END
GO

-- Cove: Billable = NewStatus = 'Billable' (no Not Resulted), bucket DateOfCollection
IF OBJECT_ID('dbo.usp_GetCove_ExecutiveSummaryDetail_LisDrill','P') IS NOT NULL DROP PROCEDURE dbo.usp_GetCove_ExecutiveSummaryDetail_LisDrill;
GO
CREATE PROCEDURE dbo.usp_GetCove_ExecutiveSummaryDetail_LisDrill @Metric NVARCHAR(20)='Samples', @Year INT=0, @DayWindow INT=9 AS
BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core @Metric=@Metric, @Year=@Year,
         @BillableCol=N'NewStatus', @BillableVal=N'Billable', @NotResultedVal=NULL, @DatePref=N'DateOfCollection',
         @DayWindow=@DayWindow;
END
GO

-- Elixir: Billable = NewStatus = 'Billable' (no Not Resulted), bucket DateOfCollection
IF OBJECT_ID('dbo.usp_GetElix_ExecutiveSummaryDetail_LisDrill','P') IS NOT NULL DROP PROCEDURE dbo.usp_GetElix_ExecutiveSummaryDetail_LisDrill;
GO
CREATE PROCEDURE dbo.usp_GetElix_ExecutiveSummaryDetail_LisDrill @Metric NVARCHAR(20)='Samples', @Year INT=0, @DayWindow INT=9 AS
BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core @Metric=@Metric, @Year=@Year,
         @BillableCol=N'NewStatus', @BillableVal=N'Billable', @NotResultedVal=NULL, @DatePref=N'DateOfCollection',
         @DayWindow=@DayWindow;
END
GO

-- Certus: Billable = BillTo = 'Insurance Bill' (no Not Resulted), bucket ReqCollectDate
IF OBJECT_ID('dbo.usp_GetCert_ExecutiveSummaryDetail_LisDrill','P') IS NOT NULL DROP PROCEDURE dbo.usp_GetCert_ExecutiveSummaryDetail_LisDrill;
GO
CREATE PROCEDURE dbo.usp_GetCert_ExecutiveSummaryDetail_LisDrill @Metric NVARCHAR(20)='Samples', @Year INT=0, @DayWindow INT=9 AS
BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core @Metric=@Metric, @Year=@Year,
         @BillableCol=N'BillTo', @BillableVal=N'Insurance Bill', @NotResultedVal=NULL, @DatePref=N'ReqCollectDate',
         @DayWindow=@DayWindow;
END
GO

-- InHealth: Billable = SampleStatus = 'Billable' (no Not Resulted), bucket ReqCollectDate
IF OBJECT_ID('dbo.usp_GetInh_ExecutiveSummaryDetail_LisDrill','P') IS NOT NULL DROP PROCEDURE dbo.usp_GetInh_ExecutiveSummaryDetail_LisDrill;
GO
CREATE PROCEDURE dbo.usp_GetInh_ExecutiveSummaryDetail_LisDrill @Metric NVARCHAR(20)='Samples', @Year INT=0, @DayWindow INT=9 AS
BEGIN SET NOCOUNT ON;
    EXEC dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core @Metric=@Metric, @Year=@Year,
         @BillableCol=N'SampleStatus', @BillableVal=N'Billable', @NotResultedVal=NULL, @DatePref=N'ReqCollectDate',
         @DayWindow=@DayWindow;
END
GO
