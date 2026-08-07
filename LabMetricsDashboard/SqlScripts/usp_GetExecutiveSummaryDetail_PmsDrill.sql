/* =====================================================================
   dbo.usp_GetExecutiveSummaryDetail_PmsDrill_Core
   ---------------------------------------------------------------------
   PMS-side analytical drill (claims from dbo.ClaimLevelData), mirroring
   the LIS drill's result-set shape so the same LisDrill view renders it.

   Filters come from dbo.LisDrillRowDef (Source='PMS') and MUST match the
   lab's Executive Summary aggregate / detail predicates
   (e.g. BeechTree 16_*_Aggregate / 21_*_PMSCash).

   Parameters
     @Year          0 = Grand Total, else that year
     @DatePref      date column (default DateofService)
     @FilterCol     primary status/amount column
     @FilterOp      '=', 'IN', '<>', '>', '>=', '<', '<=', 'NOT IN'  (default IN)
     @FilterVals    value or comma-separated IN-list (empty string allowed for = / <>)
     @FilterCol2/Op2/Val2  optional AND second predicate
     @FilterCol3/Op3/Val3  optional AND third predicate (e.g. Source on F.1/F.2)
     @FilterCol4/Op4/Val4  optional AND fourth predicate
     @Sec1..3 Name/Col/Vals  optional secondary series (StatusBreakdown)

   Day-window (@DayWindow): end day of the billed week range. Applies ONLY
   to the N-day received band (set 6) and the 9-day summary fields.
   Summary KPIs, monthly trend, panels, MoM, status, and insurance use
   full-month counts so Latest / Grand Total match the Executive Summary
   refresh. Row DateCol (DateofService, FirstBilledDate, …) is the column
   whose day-of-month is used for the N-day window only.

   Returns 10 result sets:
     1 summary  2 monthly  3 panels (Avg6Months + MoM)  4 empty rate
     5 status breakdown  6 N-day received  7 empty rate-panels
     8 top 10 insurance (full-month + MoM %)
     9 top panels per top-10 insurance (full-month + MoM %)
    10 top 10 clinics per top panel (Avg6Months + MoM)

   Avg6Months window: WeekRange end-date month + 5 prior (e.g. week ending
   in June → Jan–Jun), full-month counts (including a partial end month).
   ===================================================================== */
IF OBJECT_ID('dbo.usp_GetExecutiveSummaryDetail_PmsDrill_Core', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PmsDrill_Core;
GO
CREATE PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PmsDrill_Core
    @Year         INT           = 0,
    @DatePref     NVARCHAR(128) = N'DateofService',
    @FilterCol    NVARCHAR(128) = NULL,
    @FilterOp     NVARCHAR(32)  = N'IN',
    @FilterVals   NVARCHAR(MAX) = NULL,
    @FilterCol2   NVARCHAR(128) = NULL,
    @FilterOp2    NVARCHAR(32)  = NULL,
    @FilterVal2   NVARCHAR(MAX) = NULL,
    @FilterCol3   NVARCHAR(128) = NULL,
    @FilterOp3    NVARCHAR(32)  = NULL,
    @FilterVal3   NVARCHAR(MAX) = NULL,
    @FilterCol4   NVARCHAR(128) = NULL,
    @FilterOp4    NVARCHAR(32)  = NULL,
    @FilterVal4   NVARCHAR(MAX) = NULL,
    @Sec1Name     NVARCHAR(200) = NULL, @Sec1Col NVARCHAR(128) = NULL, @Sec1Vals NVARCHAR(MAX) = NULL,
    @Sec2Name     NVARCHAR(200) = NULL, @Sec2Col NVARCHAR(128) = NULL, @Sec2Vals NVARCHAR(MAX) = NULL,
    @Sec3Name     NVARCHAR(200) = NULL, @Sec3Col NVARCHAR(128) = NULL, @Sec3Vals NVARCHAR(MAX) = NULL,
    @DayWindow    INT           = 9
AS
BEGIN
    SET NOCOUNT ON;

    SET @DayWindow = CASE WHEN @DayWindow BETWEEN 1 AND 31 THEN @DayWindow ELSE 9 END;

    /* ── Resolve date / panel / payer / claim-key columns ─────────────── */
    DECLARE @DateCol SYSNAME;
    IF @DatePref IS NOT NULL AND COL_LENGTH('dbo.ClaimLevelData', @DatePref) IS NOT NULL
        SET @DateCol = @DatePref;
    ELSE
        SELECT TOP (1) @DateCol = name
        FROM (VALUES (1,'DateofService'),(2,'DateOfService'),(3,'ServiceDate'),(4,'FirstBilledDate')) v(ord, name)
        WHERE COL_LENGTH('dbo.ClaimLevelData', name) IS NOT NULL ORDER BY ord;

    DECLARE @PanelCol SYSNAME =
        (SELECT TOP (1) name FROM (VALUES
            (1,'Panelname'),(2,'PanelName'),(3,'PanelType'),(4,'PanelNew'),(5,'Panel')) v(ord,name)
         WHERE COL_LENGTH('dbo.ClaimLevelData', name) IS NOT NULL ORDER BY ord);

    DECLARE @PayerCol SYSNAME =
        (SELECT TOP (1) name FROM (VALUES
            (1,'PayerName'),(2,'PayerName_Raw'),(3,'InsuranceName'),(4,'Payer')) v(ord,name)
         WHERE COL_LENGTH('dbo.ClaimLevelData', name) IS NOT NULL ORDER BY ord);

    DECLARE @ClinicCol SYSNAME =
        (SELECT TOP (1) name FROM (VALUES
            (1,'ClinicName'),(2,'Clinic'),(3,'FacilityName'),(4,'Facility'),(5,'ClientName')) v(ord,name)
         WHERE COL_LENGTH('dbo.ClaimLevelData', name) IS NOT NULL ORDER BY ord);

    DECLARE @ClaimKeyCol SYSNAME =
        (SELECT TOP (1) name FROM (VALUES
            (1,'ClaimID'),(2,'ClaimNumber'),(3,'AccessionNumber')) v(ord,name)
         WHERE COL_LENGTH('dbo.ClaimLevelData', name) IS NOT NULL ORDER BY ord);

    /* ── Predicate helper: builds "expr OP value(s)" ──────────────────── */
    -- Empty Val is allowed for = / <> (FirstBilledDate blank / populated checks).
    DECLARE @PrimaryPred NVARCHAR(MAX) = N'(1 = 1)'; -- no filter = all claims with a date
    DECLARE @And2Pred    NVARCHAR(MAX) = N'(1 = 1)';
    DECLARE @And3Pred    NVARCHAR(MAX) = N'(1 = 1)';
    DECLARE @And4Pred    NVARCHAR(MAX) = N'(1 = 1)';

    -- Treat MISMATCH / MIS / MI (truncated Op1) / MISMATCH|IN / MISMATCH|NOT IN as mismatch mode.
    -- Pipe suffix preserves the PMS billed-side operator (default '=').
    DECLARE @opRaw NVARCHAR(30) = UPPER(LTRIM(RTRIM(ISNULL(@FilterOp, N'IN'))));
    DECLARE @isMismatch BIT = CASE
        WHEN LEFT(@opRaw, 3) = N'MIS' OR @opRaw IN (N'MI') THEN 1
        ELSE 0 END;
    DECLARE @op NVARCHAR(10) = @opRaw;
    DECLARE @ClAccCol SYSNAME = NULL, @LmAccCol SYSNAME = NULL, @LmBillCol SYSNAME = NULL;
    DECLARE @LmDateCol SYSNAME = NULL;
    IF @isMismatch = 1
    BEGIN
        IF CHARINDEX(N'|', @opRaw) > 0
            SET @op = UPPER(LTRIM(RTRIM(SUBSTRING(@opRaw, CHARINDEX(N'|', @opRaw) + 1, 20))));
        ELSE
            SET @op = N'=';
        IF @op NOT IN (N'=', N'<>', N'>', N'>=', N'<', N'<=', N'IN', N'NOT IN')
            SET @op = N'=';
    END
    ELSE IF @op NOT IN (N'=', N'<>', N'>', N'>=', N'<', N'<=', N'IN', N'NOT IN')
        SET @op = N'IN';

    -- Allow empty @FilterVals for = / <> (blank / non-blank string checks).
    IF @FilterCol IS NOT NULL AND COL_LENGTH('dbo.ClaimLevelData', @FilterCol) IS NOT NULL
       AND (@FilterVals IS NOT NULL)
       AND (@op IN (N'=', N'<>') OR LTRIM(RTRIM(@FilterVals)) <> N'')
    BEGIN
        DECLARE @colExpr NVARCHAR(400) =
            N'LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(4000), ' + QUOTENAME(@FilterCol) + N'), N'''')))';
        DECLARE @numExpr NVARCHAR(400) =
            N'TRY_CONVERT(decimal(18,4), ' + QUOTENAME(@FilterCol) + N')';

        IF @op IN (N'>', N'>=', N'<', N'<=')
            SET @PrimaryPred = N'(' + @numExpr + N' ' + @op + N' TRY_CONVERT(decimal(18,4), N'''
                + REPLACE(LTRIM(RTRIM(@FilterVals)), N'''', N'''''') + N'''))';
        ELSE IF @op IN (N'IN', N'NOT IN')
        BEGIN
            DECLARE @inList NVARCHAR(MAX);
            SELECT @inList = STRING_AGG(
                CASE WHEN LTRIM(RTRIM(value)) IN (N'', N'__BLANK__') THEN N'N'''''
                     ELSE N'N' + QUOTENAME(LTRIM(RTRIM(value)), '''') END, N',')
            FROM STRING_SPLIT(@FilterVals, N',');
            IF @inList IS NULL SET @PrimaryPred = N'(1 = 0)';
            ELSE SET @PrimaryPred = N'(' + @colExpr + N' ' + @op + N' (' + @inList + N'))';
        END
        ELSE -- = / <>  (empty Val → blank / non-blank)
            SET @PrimaryPred = N'(' + @colExpr + N' ' + @op + N' N'''
                + REPLACE(LTRIM(RTRIM(@FilterVals)), N'''', N'''''') + N''')';
    END

    IF @isMismatch = 1
    BEGIN
        SET @ClAccCol = (
            SELECT TOP (1) name FROM (VALUES
                (1,'AccessionNumber'),(2,'VisitNumber'),(3,'OrderID'),(4,'Accession')) v(ord,name)
            WHERE COL_LENGTH('dbo.ClaimLevelData', name) IS NOT NULL ORDER BY ord);
        IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
        BEGIN
            SET @LmAccCol = (
                SELECT TOP (1) name FROM (VALUES
                    (1,'AccessionNumber'),(2,'VisitNumber'),(3,'OrderID'),(4,'Accession'),(5,'AccessionNo')) v(ord,name)
                WHERE COL_LENGTH('dbo.LIMSMaster', name) IS NOT NULL ORDER BY ord);
            SET @LmBillCol = (
                SELECT TOP (1) name FROM (VALUES
                    (1,'BilledorNot'),(2,'BilledOrNot'),(3,'BillCategory'),(4,'BilledStatus'),(5,'BillingStatus')) v(ord,name)
                WHERE COL_LENGTH('dbo.LIMSMaster', name) IS NOT NULL ORDER BY ord);
            -- Same date preference as BeechTree ES aggregate #LisBilled
            SET @LmDateCol = (
                SELECT TOP (1) name FROM (VALUES
                    (1,'RequestCollectDate'),(2,'ReqCollectDate'),(3,'DateOfCollection'),
                    (4,'DateofService'),(5,'CollectionDate'),(6,'ServiceDate'),(7,'AccessionDate')) v(ord,name)
                WHERE COL_LENGTH('dbo.LIMSMaster', name) IS NOT NULL ORDER BY ord);
        END
    END

    -- Optional AND predicates 2–4 (same op rules; default '=').
    -- Applied for MISMATCH too (PMS billed-side extras: ClaimStatus, ClaimType, Source).
    DECLARE @op2 NVARCHAR(10) = UPPER(LTRIM(RTRIM(ISNULL(NULLIF(@FilterOp2, N''), N'='))));
    IF @op2 NOT IN (N'=', N'<>', N'>', N'>=', N'<', N'<=', N'IN', N'NOT IN')
        SET @op2 = N'=';
    IF @FilterCol2 IS NOT NULL AND COL_LENGTH('dbo.ClaimLevelData', @FilterCol2) IS NOT NULL
       AND (@FilterVal2 IS NOT NULL)
       AND (@op2 IN (N'=', N'<>') OR LTRIM(RTRIM(@FilterVal2)) <> N'')
    BEGIN
        DECLARE @col2Expr NVARCHAR(400) =
            N'LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(4000), ' + QUOTENAME(@FilterCol2) + N'), N'''')))';
        DECLARE @num2Expr NVARCHAR(400) =
            N'TRY_CONVERT(decimal(18,4), ' + QUOTENAME(@FilterCol2) + N')';
        IF @op2 IN (N'>', N'>=', N'<', N'<=')
            SET @And2Pred = N'(' + @num2Expr + N' ' + @op2 + N' TRY_CONVERT(decimal(18,4), N'''
                + REPLACE(LTRIM(RTRIM(@FilterVal2)), N'''', N'''''') + N'''))';
        ELSE IF @op2 IN (N'IN', N'NOT IN')
        BEGIN
            DECLARE @in2 NVARCHAR(MAX);
            SELECT @in2 = STRING_AGG(
                CASE WHEN LTRIM(RTRIM(value)) IN (N'', N'__BLANK__') THEN N'N'''''
                     ELSE N'N' + QUOTENAME(LTRIM(RTRIM(value)), '''') END, N',')
            FROM STRING_SPLIT(@FilterVal2, N',');
            IF @in2 IS NULL SET @And2Pred = N'(1 = 0)';
            ELSE SET @And2Pred = N'(' + @col2Expr + N' ' + @op2 + N' (' + @in2 + N'))';
        END
        ELSE
            SET @And2Pred = N'(' + @col2Expr + N' ' + @op2 + N' N'''
                + REPLACE(LTRIM(RTRIM(@FilterVal2)), N'''', N'''''') + N''')';
    END

    DECLARE @op3 NVARCHAR(10) = UPPER(LTRIM(RTRIM(ISNULL(NULLIF(@FilterOp3, N''), N'='))));
    IF @op3 NOT IN (N'=', N'<>', N'>', N'>=', N'<', N'<=', N'IN', N'NOT IN')
        SET @op3 = N'=';
    IF @FilterCol3 IS NOT NULL AND COL_LENGTH('dbo.ClaimLevelData', @FilterCol3) IS NOT NULL
       AND (@FilterVal3 IS NOT NULL)
       AND (@op3 IN (N'=', N'<>') OR LTRIM(RTRIM(@FilterVal3)) <> N'')
    BEGIN
        DECLARE @col3Expr NVARCHAR(400) =
            N'LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(4000), ' + QUOTENAME(@FilterCol3) + N'), N'''')))';
        DECLARE @num3Expr NVARCHAR(400) =
            N'TRY_CONVERT(decimal(18,4), ' + QUOTENAME(@FilterCol3) + N')';
        IF @op3 IN (N'>', N'>=', N'<', N'<=')
            SET @And3Pred = N'(' + @num3Expr + N' ' + @op3 + N' TRY_CONVERT(decimal(18,4), N'''
                + REPLACE(LTRIM(RTRIM(@FilterVal3)), N'''', N'''''') + N'''))';
        ELSE IF @op3 IN (N'IN', N'NOT IN')
        BEGIN
            DECLARE @in3 NVARCHAR(MAX);
            SELECT @in3 = STRING_AGG(
                CASE WHEN LTRIM(RTRIM(value)) IN (N'', N'__BLANK__') THEN N'N'''''
                     ELSE N'N' + QUOTENAME(LTRIM(RTRIM(value)), '''') END, N',')
            FROM STRING_SPLIT(@FilterVal3, N',');
            IF @in3 IS NULL SET @And3Pred = N'(1 = 0)';
            ELSE SET @And3Pred = N'(' + @col3Expr + N' ' + @op3 + N' (' + @in3 + N'))';
        END
        ELSE
            SET @And3Pred = N'(' + @col3Expr + N' ' + @op3 + N' N'''
                + REPLACE(LTRIM(RTRIM(@FilterVal3)), N'''', N'''''') + N''')';
    END

    DECLARE @op4 NVARCHAR(10) = UPPER(LTRIM(RTRIM(ISNULL(NULLIF(@FilterOp4, N''), N'='))));
    IF @op4 NOT IN (N'=', N'<>', N'>', N'>=', N'<', N'<=', N'IN', N'NOT IN')
        SET @op4 = N'=';
    IF @FilterCol4 IS NOT NULL AND COL_LENGTH('dbo.ClaimLevelData', @FilterCol4) IS NOT NULL
       AND (@FilterVal4 IS NOT NULL)
       AND (@op4 IN (N'=', N'<>') OR LTRIM(RTRIM(@FilterVal4)) <> N'')
    BEGIN
        DECLARE @col4Expr NVARCHAR(400) =
            N'LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(4000), ' + QUOTENAME(@FilterCol4) + N'), N'''')))';
        DECLARE @num4Expr NVARCHAR(400) =
            N'TRY_CONVERT(decimal(18,4), ' + QUOTENAME(@FilterCol4) + N')';
        IF @op4 IN (N'>', N'>=', N'<', N'<=')
            SET @And4Pred = N'(' + @num4Expr + N' ' + @op4 + N' TRY_CONVERT(decimal(18,4), N'''
                + REPLACE(LTRIM(RTRIM(@FilterVal4)), N'''', N'''''') + N'''))';
        ELSE IF @op4 IN (N'IN', N'NOT IN')
        BEGIN
            DECLARE @in4 NVARCHAR(MAX);
            SELECT @in4 = STRING_AGG(
                CASE WHEN LTRIM(RTRIM(value)) IN (N'', N'__BLANK__') THEN N'N'''''
                     ELSE N'N' + QUOTENAME(LTRIM(RTRIM(value)), '''') END, N',')
            FROM STRING_SPLIT(@FilterVal4, N',');
            IF @in4 IS NULL SET @And4Pred = N'(1 = 0)';
            ELSE SET @And4Pred = N'(' + @col4Expr + N' ' + @op4 + N' (' + @in4 + N'))';
        END
        ELSE
            SET @And4Pred = N'(' + @col4Expr + N' ' + @op4 + N' N'''
                + REPLACE(LTRIM(RTRIM(@FilterVal4)), N'''', N'''''') + N''')';
    END

    IF @DateCol IS NULL
    BEGIN
        SELECT CutoffDate=CAST(NULL AS date), LatestMonthLabel=N'', LatestCount=CAST(0 AS bigint),
               PrevMonthLabel=N'', PrevCount=CAST(0 AS bigint), MoMChangePct=CAST(NULL AS decimal(18,2)),
               Avg6=CAST(NULL AS decimal(18,2)), CurrVsAvgPct=CAST(NULL AS decimal(18,2)),
               Latest9DayLabel=N'', Latest9DayCount=CAST(0 AS bigint), Prev9DayLabel=N'', Prev9DayCount=CAST(0 AS bigint),
               NineDayMoMPct=CAST(NULL AS decimal(18,2));
        SELECT MonthLabel=N'', ShortLabel=N'', Total=CAST(0 AS bigint), IsPartial=0 WHERE 1=0;
        SELECT Panel=N'', PeriodTotal=CAST(0 AS bigint), Avg6Months=CAST(0 AS decimal(18,2)), SharePct=CAST(0 AS decimal(18,2)), Prev9Day=CAST(0 AS bigint), Latest9Day=CAST(0 AS bigint), MoMDeltaPct=CAST(NULL AS decimal(18,2)) WHERE 1=0;
        SELECT MonthLabel=N'', Resulted=CAST(0 AS bigint), Received=CAST(0 AS bigint), RatePct=CAST(NULL AS decimal(18,2)) WHERE 1=0;
        SELECT Status=N'', CollYear=0, CollMonth=0, Cnt=CAST(0 AS bigint) WHERE 1=0;
        SELECT MonthLabel=N'', ShortLabel=N'', Received9=CAST(0 AS bigint) WHERE 1=0;
        SELECT Panel=N'', CollYear=0, CollMonth=0, Resulted9=CAST(0 AS bigint), Received9=CAST(0 AS bigint) WHERE 1=0;
        SELECT Payer=N'', Claims=CAST(0 AS bigint), MoMPct=CAST(NULL AS decimal(18,2)) WHERE 1=0;
        SELECT Payer=N'', Panel=N'', Claims=CAST(0 AS bigint), MoMPct=CAST(NULL AS decimal(18,2)) WHERE 1=0;
        SELECT Panel=N'', Clinic=N'', PeriodTotal=CAST(0 AS bigint), Avg6Months=CAST(0 AS decimal(18,2)), SharePct=CAST(0 AS decimal(18,2)), Prev9Day=CAST(0 AS bigint), Latest9Day=CAST(0 AS bigint), MoMDeltaPct=CAST(NULL AS decimal(18,2)) WHERE 1=0;
        RETURN;
    END

    /* ── Secondary series predicates (IN-list only, same as LIS Sec*) ─── */
    DECLARE @s1 NVARCHAR(MAX) = N'(1=0)', @s2 NVARCHAR(MAX) = N'(1=0)', @s3 NVARCHAR(MAX) = N'(1=0)';
    DECLARE @tmpIn NVARCHAR(MAX);
    IF @Sec1Col IS NOT NULL AND COL_LENGTH('dbo.ClaimLevelData',@Sec1Col) IS NOT NULL AND @Sec1Vals IS NOT NULL
    BEGIN SELECT @tmpIn = STRING_AGG(N'N'+QUOTENAME(LTRIM(RTRIM(value)),''''),N',') FROM STRING_SPLIT(@Sec1Vals,N',') WHERE LTRIM(RTRIM(value))<>N'';
          IF @tmpIn IS NOT NULL SET @s1 = N'LTRIM(RTRIM(CONVERT(nvarchar(4000),'+QUOTENAME(@Sec1Col)+N'))) IN ('+@tmpIn+N')'; END
    IF @Sec2Col IS NOT NULL AND COL_LENGTH('dbo.ClaimLevelData',@Sec2Col) IS NOT NULL AND @Sec2Vals IS NOT NULL
    BEGIN SELECT @tmpIn = STRING_AGG(N'N'+QUOTENAME(LTRIM(RTRIM(value)),''''),N',') FROM STRING_SPLIT(@Sec2Vals,N',') WHERE LTRIM(RTRIM(value))<>N'';
          IF @tmpIn IS NOT NULL SET @s2 = N'LTRIM(RTRIM(CONVERT(nvarchar(4000),'+QUOTENAME(@Sec2Col)+N'))) IN ('+@tmpIn+N')'; END
    IF @Sec3Col IS NOT NULL AND COL_LENGTH('dbo.ClaimLevelData',@Sec3Col) IS NOT NULL AND @Sec3Vals IS NOT NULL
    BEGIN SELECT @tmpIn = STRING_AGG(N'N'+QUOTENAME(LTRIM(RTRIM(value)),''''),N',') FROM STRING_SPLIT(@Sec3Vals,N',') WHERE LTRIM(RTRIM(value))<>N'';
          IF @tmpIn IS NOT NULL SET @s3 = N'LTRIM(RTRIM(CONVERT(nvarchar(4000),'+QUOTENAME(@Sec3Col)+N'))) IN ('+@tmpIn+N')'; END

    DECLARE @dt NVARCHAR(300) = N'TRY_CONVERT(date, ' + QUOTENAME(@DateCol) + N')';
    /* Omit DATEFROMPARTS when @Year = 0 (Grand Total): SQL Server may evaluate
       both sides of (@Year = 0 OR DATEFROMPARTS(@Year,…)) and year 0 raises
       "Cannot construct data type date…". */
    DECLARE @YearPred NVARCHAR(400) = N'';
    IF ISNULL(@Year, 0) <> 0
        SET @YearPred = N'
          AND ' + @dt + N' >= DATEFROMPARTS(@Year, 1, 1)
          AND ' + @dt + N' <  DATEFROMPARTS(@Year + 1, 1, 1)';
    DECLARE @claimExpr NVARCHAR(400) = CASE
        WHEN @ClaimKeyCol IS NOT NULL
            THEN N'NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100), ' + QUOTENAME(@ClaimKeyCol) + N'))), N'''')'
        ELSE N'CONVERT(nvarchar(100), NEWID())' -- fallback: every row counts
    END;
    DECLARE @panelExpr NVARCHAR(400) = CASE
        WHEN @PanelCol IS NOT NULL
            THEN N'NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(200), ' + QUOTENAME(@PanelCol) + N'))), N'''')'
        ELSE N'NULL'
    END;
    DECLARE @payerExpr NVARCHAR(400) = CASE
        WHEN @PayerCol IS NOT NULL
            THEN N'NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(200), ' + QUOTENAME(@PayerCol) + N'))), N'''')'
        ELSE N'NULL'
    END;
    DECLARE @clinicExpr NVARCHAR(400) = CASE
        WHEN @ClinicCol IS NOT NULL
            THEN N'ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(200), ' + QUOTENAME(@ClinicCol) + N'))), N''''), N''Unspecified'')'
        ELSE N'N''Unspecified'''
    END;

    IF OBJECT_ID('tempdb..#Claim') IS NOT NULL DROP TABLE #Claim;
    CREATE TABLE #Claim (
        ClaimKey  NVARCHAR(100) NULL,
        Panel     NVARCHAR(200) NULL,
        Clinic    NVARCHAR(200) NULL,
        Payer     NVARCHAR(200) NULL,
        CollYear  INT, CollMonth INT, CollDay INT,
        IsPrimary BIT, S1 BIT, S2 BIT, S3 BIT
    );

    DECLARE @Cutoff date = NULL;

    -- Create once (SELECT INTO in both IF/ELSE branches → Msg 2714).
    IF OBJECT_ID('tempdb..#M')  IS NOT NULL DROP TABLE #M;
    IF OBJECT_ID('tempdb..#MP') IS NOT NULL DROP TABLE #MP;
    CREATE TABLE #M (
        CollYear INT NOT NULL,
        CollMonth INT NOT NULL,
        PrimaryCount BIGINT NOT NULL,
        Primary9 BIGINT NOT NULL
    );
    CREATE TABLE #MP (
        CollYear INT NOT NULL,
        CollMonth INT NOT NULL,
        PrimaryCount BIGINT NOT NULL,
        Primary9 BIGINT NOT NULL
    );

    /* ── Load #Claim / #M / #MP ─────────────────────────────────────────
       MISMATCH (BeechTree S / Cove G / …): full-month formula for KPIs —
         PrimaryCount = COUNT(PMS billed, full month)
                      − COUNT(LIS billed, full month)
         Primary9     = same formula DayWindow-capped (N-day band only)
       Panels / Top-10 insurance stay empty for mismatch (not a claim-level set).
       When LIMSMaster columns are missing, still emit PMS−0 so KPIs are not blank.
    */
    DECLARE @sql NVARCHAR(MAX);
    IF @isMismatch = 1
    BEGIN
    -- Create once (CREATE in both IF/ELSE branches → Msg 2714 at compile time).
    IF OBJECT_ID('tempdb..#PmsBilledM') IS NOT NULL DROP TABLE #PmsBilledM;
    IF OBJECT_ID('tempdb..#LisBilledM') IS NOT NULL DROP TABLE #LisBilledM;
    CREATE TABLE #PmsBilledM (
        CollYear INT NOT NULL, CollMonth INT NOT NULL,
        Cnt BIGINT NOT NULL, MaxDay INT NULL, Day9 BIGINT NOT NULL
    );
    CREATE TABLE #LisBilledM (
        CollYear INT NOT NULL, CollMonth INT NOT NULL,
        Cnt BIGINT NOT NULL, Day9 BIGINT NOT NULL
    );

    IF @LmBillCol IS NOT NULL AND @LmDateCol IS NOT NULL
    BEGIN
        SET @sql = N'
        INSERT INTO #PmsBilledM (CollYear, CollMonth, Cnt, MaxDay, Day9)
        SELECT YEAR(' + @dt + N'), MONTH(' + @dt + N'),
               COUNT_BIG(*),
               MAX(DAY(' + @dt + N')),
               COUNT_BIG(CASE WHEN DAY(' + @dt + N') BETWEEN 1 AND @DayWindow THEN 1 END)
        FROM dbo.ClaimLevelData WITH (NOLOCK)
        WHERE ' + @dt + N' IS NOT NULL AND ' + @dt + N' >= ''19010101''' + @YearPred + N'
          AND (' + @PrimaryPred + N') AND (' + @And2Pred + N') AND (' + @And3Pred + N') AND (' + @And4Pred + N')
        GROUP BY YEAR(' + @dt + N'), MONTH(' + @dt + N');';
        EXEC sys.sp_executesql @sql, N'@Year INT, @DayWindow INT', @Year = @Year, @DayWindow = @DayWindow;

        DECLARE @lmDt NVARCHAR(300) = N'TRY_CONVERT(date, ' + QUOTENAME(@LmDateCol) + N')';
        DECLARE @YearPredLm NVARCHAR(400) = N'';
        IF ISNULL(@Year, 0) <> 0
            SET @YearPredLm = N'
          AND ' + @lmDt + N' >= DATEFROMPARTS(@Year, 1, 1)
          AND ' + @lmDt + N' <  DATEFROMPARTS(@Year + 1, 1, 1)';

        SET @sql = N'
        INSERT INTO #LisBilledM (CollYear, CollMonth, Cnt, Day9)
        SELECT YEAR(' + @lmDt + N'),
               MONTH(' + @lmDt + N'),
               COUNT_BIG(*),
               COUNT_BIG(CASE WHEN DAY(' + @lmDt + N') BETWEEN 1 AND @DayWindow THEN 1 END)
        FROM dbo.LIMSMaster WITH (NOLOCK)
        WHERE ' + @lmDt + N' IS NOT NULL
          AND ' + @lmDt + N' >= ''19010101''' + @YearPredLm + N'
          AND LTRIM(RTRIM(CONVERT(nvarchar(100), ' + QUOTENAME(@LmBillCol) + N'))) = N''Billed''
        GROUP BY YEAR(' + @lmDt + N'),
                 MONTH(' + @lmDt + N');';
        EXEC sys.sp_executesql @sql, N'@Year INT, @DayWindow INT', @Year = @Year, @DayWindow = @DayWindow;

        INSERT INTO #M (CollYear, CollMonth, PrimaryCount, Primary9)
        SELECT
            COALESCE(p.CollYear, l.CollYear),
            COALESCE(p.CollMonth, l.CollMonth),
            CASE
                WHEN ISNULL(p.Cnt,0) - ISNULL(l.Cnt,0) < 0 THEN CAST(0 AS bigint)
                ELSE CAST(ISNULL(p.Cnt,0) - ISNULL(l.Cnt,0) AS bigint)
            END,
            CASE
                WHEN ISNULL(p.Day9,0) - ISNULL(l.Day9,0) < 0 THEN CAST(0 AS bigint)
                ELSE CAST(ISNULL(p.Day9,0) - ISNULL(l.Day9,0) AS bigint)
            END
        FROM #PmsBilledM p
        FULL OUTER JOIN #LisBilledM l
            ON l.CollYear = p.CollYear AND l.CollMonth = p.CollMonth;

        INSERT INTO #MP (CollYear, CollMonth, PrimaryCount, Primary9)
        SELECT CollYear, CollMonth, PrimaryCount, Primary9
        FROM #M WHERE PrimaryCount > 0;

        -- Cutoff from latest PMS billed day in scope (for the partial-month banner).
        SET @sql = N'
        INSERT INTO #Claim (ClaimKey, Panel, Clinic, Payer, CollYear, CollMonth, CollDay, IsPrimary, S1, S2, S3)
        SELECT TOP (1) N''cutoff'', NULL, NULL, NULL,
               YEAR(' + @dt + N'), MONTH(' + @dt + N'), DAY(' + @dt + N'), 1, 0, 0, 0
        FROM dbo.ClaimLevelData WITH (NOLOCK)
        WHERE ' + @dt + N' IS NOT NULL AND ' + @dt + N' >= ''19010101''' + @YearPred + N'
          AND (' + @PrimaryPred + N') AND (' + @And2Pred + N') AND (' + @And3Pred + N') AND (' + @And4Pred + N')
        ORDER BY ' + @dt + N' DESC;';
        EXEC sys.sp_executesql @sql, N'@Year INT', @Year = @Year;
    END
    ELSE
    BEGIN
        -- LIMSMaster billed/date columns unavailable — PMS billed full-month + Day9.
        SET @sql = N'
        INSERT INTO #PmsBilledM (CollYear, CollMonth, Cnt, MaxDay, Day9)
        SELECT YEAR(' + @dt + N'), MONTH(' + @dt + N'),
               COUNT_BIG(*), MAX(DAY(' + @dt + N')),
               COUNT_BIG(CASE WHEN DAY(' + @dt + N') BETWEEN 1 AND @DayWindow THEN 1 END)
        FROM dbo.ClaimLevelData WITH (NOLOCK)
        WHERE ' + @dt + N' IS NOT NULL AND ' + @dt + N' >= ''19010101''' + @YearPred + N'
          AND (' + @PrimaryPred + N') AND (' + @And2Pred + N') AND (' + @And3Pred + N') AND (' + @And4Pred + N')
        GROUP BY YEAR(' + @dt + N'), MONTH(' + @dt + N');';
        EXEC sys.sp_executesql @sql, N'@Year INT, @DayWindow INT', @Year = @Year, @DayWindow = @DayWindow;

        INSERT INTO #M (CollYear, CollMonth, PrimaryCount, Primary9)
        SELECT CollYear, CollMonth, Cnt, Day9 FROM #PmsBilledM WHERE Cnt > 0;
        INSERT INTO #MP (CollYear, CollMonth, PrimaryCount, Primary9)
        SELECT CollYear, CollMonth, PrimaryCount, Primary9 FROM #M;

        SET @sql = N'
        INSERT INTO #Claim (ClaimKey, Panel, Clinic, Payer, CollYear, CollMonth, CollDay, IsPrimary, S1, S2, S3)
        SELECT TOP (1) N''cutoff'', NULL, NULL, NULL,
               YEAR(' + @dt + N'), MONTH(' + @dt + N'), DAY(' + @dt + N'), 1, 0, 0, 0
        FROM dbo.ClaimLevelData WITH (NOLOCK)
        WHERE ' + @dt + N' IS NOT NULL AND ' + @dt + N' >= ''19010101''' + @YearPred + N'
          AND (' + @PrimaryPred + N') AND (' + @And2Pred + N') AND (' + @And3Pred + N') AND (' + @And4Pred + N')
        ORDER BY ' + @dt + N' DESC;';
        EXEC sys.sp_executesql @sql, N'@Year INT', @Year = @Year;
    END

    IF OBJECT_ID('tempdb..#PmsBilledM') IS NOT NULL DROP TABLE #PmsBilledM;
    IF OBJECT_ID('tempdb..#LisBilledM') IS NOT NULL DROP TABLE #LisBilledM;
    END -- @isMismatch
    ELSE
    BEGIN
        -- Normal PMS rows: pull only rows that match primary OR a secondary series.
        -- Full-month load; DayWindow applied only when computing Primary9.
        DECLARE @needSec BIT = CASE WHEN @Sec1Name IS NOT NULL OR @Sec2Name IS NOT NULL OR @Sec3Name IS NOT NULL THEN 1 ELSE 0 END;
        SET @sql = N'
        INSERT INTO #Claim (ClaimKey, Panel, Clinic, Payer, CollYear, CollMonth, CollDay, IsPrimary, S1, S2, S3)
        SELECT DISTINCT
               ' + @claimExpr + N',
               ' + @panelExpr + N',
               ' + @clinicExpr + N',
               ' + @payerExpr + N',
               YEAR(' + @dt + N'), MONTH(' + @dt + N'), DAY(' + @dt + N'),
               CASE WHEN (' + @PrimaryPred + N') AND (' + @And2Pred + N') AND (' + @And3Pred + N') AND (' + @And4Pred + N') THEN 1 ELSE 0 END,
               CASE WHEN ' + @s1 + N' THEN 1 ELSE 0 END,
               CASE WHEN ' + @s2 + N' THEN 1 ELSE 0 END,
               CASE WHEN ' + @s3 + N' THEN 1 ELSE 0 END
        FROM dbo.ClaimLevelData WITH (NOLOCK)
        WHERE ' + @dt + N' IS NOT NULL AND ' + @dt + N' >= ''19010101''' + @YearPred + N'
          AND ' + @claimExpr + N' IS NOT NULL
          AND (
                ((' + @PrimaryPred + N') AND (' + @And2Pred + N') AND (' + @And3Pred + N') AND (' + @And4Pred + N'))
                OR (' + CASE WHEN @needSec = 1 THEN N'(' + @s1 + N') OR (' + @s2 + N') OR (' + @s3 + N')' ELSE N'0=1' END + N')
              );';
        EXEC sys.sp_executesql @sql, N'@Year INT', @Year = @Year;

        -- Cutoff from full-month primary rows (no DayWindow shrink).
        SET @Cutoff =
            (SELECT MAX(TRY_CONVERT(date, CONVERT(char(8),
                        CollYear * 10000 + CollMonth * 100 + CollDay)))
             FROM #Claim WHERE IsPrimary=1);

        IF EXISTS (SELECT 1 FROM #Claim)
            CREATE CLUSTERED INDEX IX_Claim_YM_Panel ON #Claim (CollYear, CollMonth, Panel, Payer, Clinic);

        INSERT INTO #M (CollYear, CollMonth, PrimaryCount, Primary9)
        SELECT CollYear, CollMonth,
               COUNT(DISTINCT CASE WHEN IsPrimary=1 THEN ClaimKey END),
               COUNT(DISTINCT CASE WHEN IsPrimary=1 AND CollDay BETWEEN 1 AND @DayWindow THEN ClaimKey END)
        FROM #Claim
        GROUP BY CollYear, CollMonth
        HAVING COUNT(DISTINCT CASE WHEN IsPrimary=1 THEN ClaimKey END) > 0
            OR COUNT(DISTINCT ClaimKey) > 0;

        INSERT INTO #MP (CollYear, CollMonth, PrimaryCount, Primary9)
        SELECT CollYear, CollMonth, PrimaryCount, Primary9
        FROM #M WHERE PrimaryCount > 0;
    END

    IF OBJECT_ID('tempdb..#LisBilledAcc') IS NOT NULL DROP TABLE #LisBilledAcc;

    DECLARE @LatestY INT,@LatestM INT,@LatestC BIGINT,@Latest9 BIGINT,@PrevY INT,@PrevM INT,@PrevC BIGINT,@Prev9 BIGINT,@Avg6 DECIMAL(18,2);
    SELECT @LatestY=CollYear,@LatestM=CollMonth,@LatestC=PrimaryCount,@Latest9=Primary9
    FROM #MP ORDER BY CollYear DESC,CollMonth DESC OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY;
    SELECT @PrevY=CollYear,@PrevM=CollMonth,@PrevC=PrimaryCount,@Prev9=Primary9
    FROM #MP ORDER BY CollYear DESC,CollMonth DESC OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY;
    /* Avg6 = WeekRange end month + 5 prior (OFFSET 0; full-month). */
    SELECT @Avg6=AVG(CAST(PrimaryCount AS decimal(18,2)))
    FROM (SELECT PrimaryCount FROM #MP ORDER BY CollYear DESC,CollMonth DESC OFFSET 0 ROWS FETCH NEXT 6 ROWS ONLY) x;

    -- Mismatch path: cutoff from the single #Claim sentinel row (uncapped).
    IF @isMismatch = 1
        SET @Cutoff = (SELECT MAX(TRY_CONVERT(date, CONVERT(char(8),
                            CollYear * 10000 + CollMonth * 100 + CollDay)))
                       FROM #Claim WHERE IsPrimary=1);
    IF OBJECT_ID('tempdb..#AvgMonths') IS NOT NULL DROP TABLE #AvgMonths;
    /* Avg-6 keys: end month + 5 prior (include partial WeekRange end month). */
    SELECT CollYear, CollMonth INTO #AvgMonths
    FROM #MP ORDER BY CollYear DESC, CollMonth DESC OFFSET 0 ROWS FETCH NEXT 6 ROWS ONLY;
    IF NOT EXISTS (SELECT 1 FROM #AvgMonths) AND @LatestM IS NOT NULL
        INSERT INTO #AvgMonths (CollYear, CollMonth) VALUES (@LatestY, @LatestM);
    DECLARE @AvgMonthCount INT = (SELECT COUNT(*) FROM #AvgMonths);
    IF @AvgMonthCount < 1 SET @AvgMonthCount = 1;

    -- Materialize panel aggregates once (Sets 3 + 10). Full-month #Claim.
    IF OBJECT_ID('tempdb..#PanelMonth') IS NOT NULL DROP TABLE #PanelMonth;
    SELECT Panel, CollYear, CollMonth,
           Cnt = COUNT(DISTINCT ClaimKey)
    INTO #PanelMonth
    FROM #Claim
    WHERE IsPrimary=1 AND Panel IS NOT NULL
    GROUP BY Panel, CollYear, CollMonth;

    IF OBJECT_ID('tempdb..#PanelMoM') IS NOT NULL DROP TABLE #PanelMoM;
    SELECT Panel,
           Prev9Day = COUNT(DISTINCT CASE WHEN @PrevM IS NOT NULL AND CollYear=@PrevY AND CollMonth=@PrevM THEN ClaimKey END),
           Latest9Day = COUNT(DISTINCT CASE WHEN CollYear=@LatestY AND CollMonth=@LatestM THEN ClaimKey END)
    INTO #PanelMoM
    FROM #Claim
    WHERE IsPrimary=1 AND Panel IS NOT NULL
    GROUP BY Panel;

    IF OBJECT_ID('tempdb..#PanelAgg') IS NOT NULL DROP TABLE #PanelAgg;
    SELECT a.Panel, a.Avg6Months, m.Prev9Day, m.Latest9Day
    INTO #PanelAgg
    FROM (
        SELECT p.Panel,
               Avg6Months = CAST(SUM(CAST(ISNULL(pm.Cnt,0) AS decimal(18,4))) / @AvgMonthCount AS decimal(18,2))
        FROM (SELECT DISTINCT Panel FROM #Claim WHERE IsPrimary=1 AND Panel IS NOT NULL) p
        CROSS JOIN #AvgMonths am
        LEFT JOIN #PanelMonth pm ON pm.Panel=p.Panel AND pm.CollYear=am.CollYear AND pm.CollMonth=am.CollMonth
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

    -- Payer×month once (Sets 8 + 9)
    IF OBJECT_ID('tempdb..#PayerMonth') IS NOT NULL DROP TABLE #PayerMonth;
    SELECT Payer, CollYear, CollMonth, Cnt = COUNT(DISTINCT ClaimKey)
    INTO #PayerMonth
    FROM #Claim
    WHERE IsPrimary=1 AND Payer IS NOT NULL
    GROUP BY Payer, CollYear, CollMonth;

    IF OBJECT_ID('tempdb..#TopPayers') IS NOT NULL DROP TABLE #TopPayers;
    SELECT TOP (10) Payer, Claims = SUM(Cnt)
    INTO #TopPayers
    FROM #PayerMonth
    GROUP BY Payer
    ORDER BY SUM(Cnt) DESC;

    -- Set 1: summary
    SELECT
        CutoffDate = @Cutoff,
        LatestMonthLabel = CASE WHEN @LatestM IS NULL THEN N'' ELSE LEFT(DATENAME(MONTH,DATEFROMPARTS(@LatestY,@LatestM,1)),3)+' '+CONVERT(varchar(4),@LatestY) END,
        LatestCount = ISNULL(@LatestC,0),
        PrevMonthLabel = CASE WHEN @PrevM IS NULL THEN N'' ELSE LEFT(DATENAME(MONTH,DATEFROMPARTS(@PrevY,@PrevM,1)),3)+' '+CONVERT(varchar(4),@PrevY) END,
        PrevCount = ISNULL(@PrevC,0),
        MoMChangePct = CASE WHEN ISNULL(@PrevC,0)=0 THEN NULL ELSE CAST((@LatestC-@PrevC)*100.0/@PrevC AS decimal(18,2)) END,
        Avg6 = @Avg6,
        CurrVsAvgPct = CASE WHEN ISNULL(@Avg6,0)=0 THEN NULL ELSE CAST((@LatestC-@Avg6)*100.0/@Avg6 AS decimal(18,2)) END,
        Latest9DayLabel = CASE WHEN @LatestM IS NULL THEN N'' ELSE LEFT(DATENAME(MONTH,DATEFROMPARTS(@LatestY,@LatestM,1)),3)+' '+CONVERT(varchar(4),@LatestY)+N' (1–'+CONVERT(varchar(2),@DayWindow)+N')' END,
        Latest9DayCount = ISNULL(@Latest9,0),
        Prev9DayLabel = CASE WHEN @PrevM IS NULL THEN N'' ELSE LEFT(DATENAME(MONTH,DATEFROMPARTS(@PrevY,@PrevM,1)),3)+' '+CONVERT(varchar(4),@PrevY)+N' (1–'+CONVERT(varchar(2),@DayWindow)+N')' END,
        Prev9DayCount = ISNULL(@Prev9,0),
        NineDayMoMPct = CASE WHEN ISNULL(@Prev9,0)=0 THEN NULL ELSE CAST((@Latest9-@Prev9)*100.0/@Prev9 AS decimal(18,2)) END;

    -- Set 2: monthly totals (trailing 13, full-month; latest partial)
    SELECT MonthLabel = LEFT(DATENAME(MONTH,DATEFROMPARTS(CollYear,CollMonth,1)),3)+' '+CONVERT(varchar(4),CollYear),
           ShortLabel = LEFT(DATENAME(MONTH,DATEFROMPARTS(CollYear,CollMonth,1)),3),
           Total = PrimaryCount,
           IsPartial = CASE WHEN CollYear=@LatestY AND CollMonth=@LatestM THEN 1 ELSE 0 END
    FROM (SELECT TOP (13) CollYear,CollMonth,PrimaryCount FROM #MP ORDER BY CollYear DESC,CollMonth DESC) m
    ORDER BY CollYear,CollMonth;

    -- Set 3: panels (from #TopPanels)
    SELECT
           p.Panel,
           PeriodTotal = CAST(ROUND(p.Avg6Months, 0) AS bigint),
           p.Avg6Months,
           SharePct = CASE WHEN ISNULL(@PanelTot,0)=0 THEN 0 ELSE CAST(p.Avg6Months*100.0/@PanelTot AS decimal(18,2)) END,
           p.Prev9Day, p.Latest9Day,
           MoMDeltaPct = CASE WHEN ISNULL(p.Prev9Day,0)=0 THEN NULL
                              ELSE CAST((p.Latest9Day-p.Prev9Day)*100.0/p.Prev9Day AS decimal(18,2)) END
    FROM #TopPanels p
    ORDER BY p.Avg6Months DESC;

    -- Set 4: result rate (empty for PMS)
    SELECT MonthLabel=N'', Resulted=CAST(0 AS bigint), Received=CAST(0 AS bigint), RatePct=CAST(NULL AS decimal(18,2)) WHERE 1=0;

    -- Set 5: secondary series as Status x month matrix (trailing 7 months)
    ;WITH Trail AS (
        SELECT TOP (7) CollYear, CollMonth FROM #M ORDER BY CollYear DESC, CollMonth DESC
    )
    SELECT Status, CollYear, CollMonth, Cnt FROM (
        SELECT @Sec1Name AS Status, c.CollYear, c.CollMonth,
               COUNT(DISTINCT CASE WHEN c.S1=1 THEN c.ClaimKey END) AS Cnt
        FROM #Claim c JOIN Trail t ON t.CollYear=c.CollYear AND t.CollMonth=c.CollMonth
        WHERE @Sec1Name IS NOT NULL GROUP BY c.CollYear,c.CollMonth
        UNION ALL
        SELECT @Sec2Name, c.CollYear, c.CollMonth,
               COUNT(DISTINCT CASE WHEN c.S2=1 THEN c.ClaimKey END)
        FROM #Claim c JOIN Trail t ON t.CollYear=c.CollYear AND t.CollMonth=c.CollMonth
        WHERE @Sec2Name IS NOT NULL GROUP BY c.CollYear,c.CollMonth
        UNION ALL
        SELECT @Sec3Name, c.CollYear, c.CollMonth,
               COUNT(DISTINCT CASE WHEN c.S3=1 THEN c.ClaimKey END)
        FROM #Claim c JOIN Trail t ON t.CollYear=c.CollYear AND t.CollMonth=c.CollMonth
        WHERE @Sec3Name IS NOT NULL GROUP BY c.CollYear,c.CollMonth
    ) s
    WHERE Status IS NOT NULL
    ORDER BY Status, CollYear, CollMonth;

    -- Set 6: 9-day range (primary)
    SELECT MonthLabel = LEFT(DATENAME(MONTH,DATEFROMPARTS(CollYear,CollMonth,1)),3)+' '+CONVERT(varchar(4),CollYear),
           ShortLabel = LEFT(DATENAME(MONTH,DATEFROMPARTS(CollYear,CollMonth,1)),3),
           Received9  = Primary9
    FROM (SELECT TOP (13) CollYear,CollMonth,Primary9 FROM #MP ORDER BY CollYear DESC,CollMonth DESC) m
    ORDER BY CollYear,CollMonth;

    -- Set 7: rate panels (empty for PMS)
    SELECT Panel=N'', CollYear=0, CollMonth=0, Resulted9=CAST(0 AS bigint), Received9=CAST(0 AS bigint) WHERE 1=0;

    -- Set 8: Top 10 insurance / payer (from #TopPayers / #PayerMonth)
    SELECT t.Payer,
           t.Claims,
           MoMPct = CASE
               WHEN ISNULL(prev.Cnt,0)=0 THEN NULL
               ELSE CAST((ISNULL(curr.Cnt,0)-prev.Cnt)*100.0/prev.Cnt AS decimal(18,2))
           END
    FROM #TopPayers t
    LEFT JOIN #PayerMonth curr ON curr.Payer=t.Payer AND curr.CollYear=@LatestY AND curr.CollMonth=@LatestM
    LEFT JOIN #PayerMonth prev ON prev.Payer=t.Payer AND prev.CollYear=@PrevY   AND prev.CollMonth=@PrevM
    ORDER BY t.Claims DESC;

    -- Set 9: Top panel groups within each Top-10 payer
    ;WITH PayerPanelMonth AS (
        SELECT c.Payer, c.Panel, c.CollYear, c.CollMonth,
               Cnt = COUNT(DISTINCT c.ClaimKey)
        FROM #Claim c
        INNER JOIN #TopPayers t ON t.Payer = c.Payer
        WHERE c.IsPrimary=1 AND c.Panel IS NOT NULL
        GROUP BY c.Payer, c.Panel, c.CollYear, c.CollMonth
    ),
    PayerPanelTot AS (
        SELECT Payer, Panel, Claims = SUM(Cnt)
        FROM PayerPanelMonth
        GROUP BY Payer, Panel
    ),
    Ranked AS (
        SELECT ppt.Payer, ppt.Panel, ppt.Claims,
               rn = ROW_NUMBER() OVER (PARTITION BY ppt.Payer ORDER BY ppt.Claims DESC)
        FROM PayerPanelTot ppt
    )
    SELECT r.Payer,
           r.Panel,
           r.Claims,
           MoMPct = CASE
               WHEN ISNULL(prev.Cnt,0)=0 THEN NULL
               ELSE CAST((ISNULL(curr.Cnt,0)-prev.Cnt)*100.0/prev.Cnt AS decimal(18,2))
           END
    FROM Ranked r
    LEFT JOIN PayerPanelMonth curr
        ON curr.Payer=r.Payer AND curr.Panel=r.Panel
       AND curr.CollYear=@LatestY AND curr.CollMonth=@LatestM
    LEFT JOIN PayerPanelMonth prev
        ON prev.Payer=r.Payer AND prev.Panel=r.Panel
       AND prev.CollYear=@PrevY AND prev.CollMonth=@PrevM
    WHERE r.rn <= 5
    ORDER BY r.Payer, r.Claims DESC;

    -- Set 10: Top 10 clinics per Top-10 panel (uses #TopPanels)
    ;WITH ClinicMonth AS (
        SELECT c.Panel, c.Clinic, c.CollYear, c.CollMonth,
               Cnt = COUNT(DISTINCT c.ClaimKey)
        FROM #Claim c
        INNER JOIN #TopPanels t ON t.Panel = c.Panel
        WHERE c.IsPrimary=1 AND c.Clinic IS NOT NULL
        GROUP BY c.Panel, c.Clinic, c.CollYear, c.CollMonth
    ),
    ClinicAvg AS (
        SELECT x.Panel, x.Clinic,
               Avg6Months = CAST(SUM(CAST(ISNULL(cm.Cnt,0) AS decimal(18,4))) / @AvgMonthCount AS decimal(18,2))
        FROM (SELECT DISTINCT c.Panel, c.Clinic FROM #Claim c INNER JOIN #TopPanels t ON t.Panel=c.Panel
              WHERE c.IsPrimary=1 AND c.Clinic IS NOT NULL) x
        CROSS JOIN #AvgMonths am
        LEFT JOIN ClinicMonth cm ON cm.Panel=x.Panel AND cm.Clinic=x.Clinic
               AND cm.CollYear=am.CollYear AND cm.CollMonth=am.CollMonth
        GROUP BY x.Panel, x.Clinic
    ),
    ClinicMoM AS (
        SELECT c.Panel, c.Clinic,
               Prev9Day = COUNT(DISTINCT CASE WHEN @PrevM IS NOT NULL AND c.CollYear=@PrevY AND c.CollMonth=@PrevM THEN c.ClaimKey END),
               Latest9Day = COUNT(DISTINCT CASE WHEN c.CollYear=@LatestY AND c.CollMonth=@LatestM THEN c.ClaimKey END)
        FROM #Claim c
        INNER JOIN #TopPanels t ON t.Panel = c.Panel
        WHERE c.IsPrimary=1 AND c.Clinic IS NOT NULL
        GROUP BY c.Panel, c.Clinic
    ),
    RankedClinics AS (
        SELECT ca.Panel, ca.Clinic, ca.Avg6Months, m.Prev9Day, m.Latest9Day,
               tp.Avg6Months AS PanelAvg6,
               rn = ROW_NUMBER() OVER (PARTITION BY ca.Panel ORDER BY ca.Avg6Months DESC)
        FROM ClinicAvg ca
        INNER JOIN ClinicMoM m ON m.Panel=ca.Panel AND m.Clinic=ca.Clinic
        INNER JOIN #TopPanels tp ON tp.Panel=ca.Panel
        WHERE ca.Avg6Months > 0
    )
    SELECT Panel, Clinic,
           PeriodTotal = CAST(ROUND(Avg6Months, 0) AS bigint),
           Avg6Months,
           SharePct = CASE WHEN ISNULL(PanelAvg6,0)=0 THEN 0 ELSE CAST(Avg6Months*100.0/PanelAvg6 AS decimal(18,2)) END,
           Prev9Day, Latest9Day,
           MoMDeltaPct = CASE WHEN Prev9Day=0 THEN NULL
                              ELSE CAST((Latest9Day-Prev9Day)*100.0/Prev9Day AS decimal(18,2)) END
    FROM RankedClinics
    WHERE rn <= 10
    ORDER BY Panel, Avg6Months DESC;

    IF OBJECT_ID('tempdb..#Claim')      IS NOT NULL DROP TABLE #Claim;
    IF OBJECT_ID('tempdb..#M')          IS NOT NULL DROP TABLE #M;
    IF OBJECT_ID('tempdb..#MP')         IS NOT NULL DROP TABLE #MP;
    IF OBJECT_ID('tempdb..#AvgMonths')  IS NOT NULL DROP TABLE #AvgMonths;
    IF OBJECT_ID('tempdb..#PanelMonth') IS NOT NULL DROP TABLE #PanelMonth;
    IF OBJECT_ID('tempdb..#PanelMoM')   IS NOT NULL DROP TABLE #PanelMoM;
    IF OBJECT_ID('tempdb..#PanelAgg')   IS NOT NULL DROP TABLE #PanelAgg;
    IF OBJECT_ID('tempdb..#TopPanels')  IS NOT NULL DROP TABLE #TopPanels;
    IF OBJECT_ID('tempdb..#PayerMonth') IS NOT NULL DROP TABLE #PayerMonth;
    IF OBJECT_ID('tempdb..#TopPayers')  IS NOT NULL DROP TABLE #TopPayers;
END
GO
