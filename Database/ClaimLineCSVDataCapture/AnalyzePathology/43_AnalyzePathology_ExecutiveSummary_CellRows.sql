/* =============================================================================
   Analyze Pathology - Executive Summary cell rows (value click -> popup grid)
   File     : 43_AnalyzePathology_ExecutiveSummary_CellRows.sql
   Database : AnalyzePathology
   Requires : 41_AnalyzePathology_ExecutiveSummary_UnbilledZeroBilled_AvgX.sql (usp_AnP_ES_Compute)
   Object   : dbo.usp_GetAnP_ExecutiveSummaryCellRows

   Returns the source rows behind one Executive Summary cell, using exactly the rules of
   usp_GetAnP_ExecutiveSummary / usp_RefreshAnP_ExecutiveSummary (source rows, date basis,
   page filters, Bill Status / Claim Status normalisation) and usp_AnP_ES_Compute (row rules),
   so the row count / amount equals the clicked value.

   Parameters
     @Category / @RowCode   the clicked row (LIS A..H, PMS F..O4, Cash P..W3, Avg X..Z)
     @Year / @Month         (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetAnP_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured column for $ rows)
   Formula rows (PMS H, Avg X / Y / Z) return the formula and calculation in Rules,
   IsFormula = 1, TotalAmount = the grid value, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal) read from
   usp_GetAnP_ExecutiveSummary for the same period and filters.
   ============================================================================= */

IF DB_NAME() <> N'AnalyzePathology'
BEGIN
    RAISERROR(N'43_AnalyzePathology_ExecutiveSummary_CellRows.sql must run on AnalyzePathology.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_ExecutiveSummaryCellRows
(
    @Category   VARCHAR(10),
    @RowCode    NVARCHAR(100),
    @Year       INT           = 0,
    @Month      INT           = 0,
    @YearFrom   INT           = NULL,
    @YearTo     INT           = NULL,
    @MonthFrom  INT           = NULL,
    @MonthTo    INT           = NULL,
    @DosFrom    DATE          = NULL,
    @DosTo      DATE          = NULL,
    @BilledFrom DATE          = NULL,
    @BilledTo   DATE          = NULL,
    @Panels     NVARCHAR(MAX) = NULL,
    @Clinics    NVARCHAR(MAX) = NULL,
    @Providers  NVARCHAR(MAX) = NULL,
    @Reps       NVARCHAR(MAX) = NULL,
    @Page       INT           = 1,
    @PageSize   INT           = 100
)
AS
BEGIN
    SET NOCOUNT ON;

    SET @Category = LTRIM(RTRIM(ISNULL(@Category, '')));
    SET @RowCode  = UPPER(LTRIM(RTRIM(ISNULL(@RowCode, N''))));
    SET @Year     = ISNULL(@Year, 0);
    SET @Month    = ISNULL(@Month, 0);
    IF ISNULL(@Page, 0) < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 0 SET @PageSize = 100;

    /* ---- Page filters (as usp_GetAnP_ExecutiveSummary) ---------------------- */
    DECLARE @UseBilledDate BIT = CASE WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
                                        AND @DosFrom IS NULL AND @DosTo IS NULL THEN 1 ELSE 0 END;
    DECLARE @From DATE = CASE WHEN @UseBilledDate = 1 THEN @BilledFrom ELSE @DosFrom END;
    DECLARE @To   DATE = CASE WHEN @UseBilledDate = 1 THEN @BilledTo   ELSE @DosTo   END;

    CREATE TABLE #Filters (Dim VARCHAR(10) NOT NULL, Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT INTO #Filters (Dim, Val)
    SELECT f.Dim, LTRIM(RTRIM(s.value))
    FROM (VALUES ('Panel', @Panels), ('Clinic', @Clinics), ('Provider', @Providers), ('Rep', @Reps)) f(Dim, Vals)
    CROSS APPLY STRING_SPLIT(ISNULL(f.Vals, N''), N',') s
    WHERE LTRIM(RTRIM(s.value)) <> N'';

    DECLARE @HasPanel    BIT = CASE WHEN EXISTS (SELECT 1 FROM #Filters WHERE Dim = 'Panel')    THEN 1 ELSE 0 END;
    DECLARE @HasClinic   BIT = CASE WHEN EXISTS (SELECT 1 FROM #Filters WHERE Dim = 'Clinic')   THEN 1 ELSE 0 END;
    DECLARE @HasProvider BIT = CASE WHEN EXISTS (SELECT 1 FROM #Filters WHERE Dim = 'Provider') THEN 1 ELSE 0 END;
    DECLARE @HasRep      BIT = CASE WHEN EXISTS (SELECT 1 FROM #Filters WHERE Dim = 'Rep')      THEN 1 ELSE 0 END;

    /* ---- Row definitions (as usp_AnP_ES_Compute) ---------------------------- */
    DECLARE @Billed   NVARCHAR(100) = N'Bill Status IN (Billed, Billed - Self Pay)';
    DECLARE @Unbilled NVARCHAR(100) = N'Bill Status IN (Unbilled, Unbilled - Self Pay)';
    DECLARE @Def TABLE
    (
        Category  VARCHAR(10)    NOT NULL,
        RowCode   NVARCHAR(20)   NOT NULL,
        RuleText  NVARCHAR(1000) NOT NULL,
        AmountCol NVARCHAR(100)  NULL,
        IsFormula BIT            NOT NULL
    );
    INSERT INTO @Def (Category, RowCode, RuleText, AmountCol, IsFormula) VALUES
        ('LIS', 'A',  N'Every sample (no status filter)', NULL, 0),
        ('LIS', 'B',  N'NewStatus = Billable', NULL, 0),
        ('LIS', 'C',  N'NewStatus = Billable AND BillCategory = Billed', NULL, 0),
        ('LIS', 'C1', N'NewStatus = Billable AND BillCategory = Billed', NULL, 0),
        ('LIS', 'D',  N'NewStatus = Billable AND BillCategory IN (Unbilled, Not Billed)', NULL, 0),
        ('LIS', 'D1', N'NewStatus = Billable AND BillCategory IN (Unbilled, Not Billed) AND SubStatus = Ready to Bill', NULL, 0),
        ('LIS', 'D2', N'NewStatus = Billable AND BillCategory IN (Unbilled, Not Billed) AND SubStatus IN (Entered Not Submitted, Entered Not Billed)', NULL, 0),
        ('LIS', 'E',  N'NewStatus <> Billable (blank included)', NULL, 0),
        ('LIS', 'F',  N'NewStatus IN (Duplicate, Duplicates, Duplicate - Sample Resulted in Spector)', NULL, 0),
        ('LIS', 'G',  N'NewStatus = System Test', NULL, 0),
        ('LIS', 'H',  N'NewStatus IN (Yet to Be Validate, Yet to be validated, Yet be validated) AND SubStatus <> Entered Not Submitted', NULL, 0),
        ('PMS', 'F',  @Billed + N' AND Claim Status <> 0 Billed Amount', NULL, 0),
        ('PMS', 'F1', @Billed + N' AND Claim Status <> 0 Billed Amount', NULL, 0),
        ('PMS', 'G',  @Unbilled + N' AND Claim Status <> 0 Billed Amount', NULL, 0),
        ('PMS', 'G1', N'Bill Status = Unbilled AND Claim Status <> 0 Billed Amount', NULL, 0),
        ('PMS', 'G2', N'Bill Status = Unbilled - Self Pay AND Claim Status <> 0 Billed Amount', NULL, 0),
        ('PMS', 'G3', N'Claim Status = 0 Billed Amount (any Bill Status)', NULL, 0),
        ('PMS', 'H',  N'Formula: No. of Billed Claims (PMS F) - LIS Billed samples (LIS C), for the same period', NULL, 1),
        ('PMS', 'I',  @Billed + N' AND Claim Status = Fully Paid', NULL, 0),
        ('PMS', 'J',  @Billed + N' AND Claim Status = Patient Responsibility', NULL, 0),
        ('PMS', 'K',  @Billed + N' AND Claim Status = Fully Adjusted', NULL, 0),
        ('PMS', 'L',  @Billed + N' AND Claim Status = Partially Adjusted', NULL, 0),
        ('PMS', 'M',  @Billed + N' AND Claim Status = Partially Paid', NULL, 0),
        ('PMS', 'N',  @Billed + N' AND Claim Status = Patient Payment', NULL, 0),
        ('PMS', 'O',  @Billed + N' AND Claim Status IN (Fully Denied, No Response, Partially Denied)', NULL, 0),
        ('PMS', 'O1', @Billed + N' AND Claim Status = Fully Denied', NULL, 0),
        ('PMS', 'O2', @Billed + N' AND Claim Status = Partially Denied', NULL, 0),
        ('PMS', 'O3', @Billed + N' AND Claim Status = No Response', NULL, 0),
        ('PMS', 'O4', N'Follow up note added - not tracked (always 0)', NULL, 0),
        ('Cash', 'P',  @Billed, N'ChargeAmount', 0),
        ('Cash', 'P1', @Billed, N'ChargeAmount', 0),
        ('Cash', 'Q',  @Unbilled, N'ChargeAmount', 0),
        ('Cash', 'Q1', N'Bill Status = Unbilled', N'ChargeAmount', 0),
        ('Cash', 'Q2', N'Bill Status = Unbilled - Self Pay', N'ChargeAmount', 0),
        ('Cash', 'R',  @Billed + N' AND Claim Status = Fully Paid', N'InsurancePayment', 0),
        ('Cash', 'S',  @Billed, N'PatientBalance', 0),
        ('Cash', 'T',  @Billed, N'TotalAdjustments', 0),
        ('Cash', 'U',  N'Claim Status IN (Fully Adjusted, Partially Adjusted, Partially Denied, Partially Paid) (any Bill Status)', N'InsurancePayment', 0),
        ('Cash', 'V',  @Billed, N'PatientPayment', 0),
        ('Cash', 'W',  @Billed, N'TotalInsuranceBalance', 0),
        ('Cash', 'W1', @Billed + N' AND Claim Status = Fully Denied', N'TotalInsuranceBalance', 0),
        ('Cash', 'W2', @Billed + N' AND Claim Status NOT IN (Fully Denied, No Response)', N'TotalInsuranceBalance', 0),
        ('Cash', 'W3', @Billed + N' AND Claim Status = No Response', N'TotalInsuranceBalance', 0),
        ('Avg', 'X',  N'Formula: (Insurance Payment $ + Partially Paid $) / No. of Billed Claims (PMS F)', NULL, 1),
        ('Avg', 'Y',  N'Formula: (Insurance Payment $ + Partially Paid $) / (Fully Paid + Partially Paid claims)', NULL, 1),
        ('Avg', 'Z',  N'Formula: (Insurance Payment $ + Partially Paid $) / (Fully Paid + Partially Paid + Patient Responsibility + Adjusted + Partially Adjusted + Patient Paid + Fully Denied + Partially Denied claims)', NULL, 1);

    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @IsFormula BIT;
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @IsFormula = IsFormula
    FROM @Def WHERE Category = @Category AND RowCode = @RowCode;

    IF @RuleText IS NULL
    BEGIN
        RAISERROR(N'usp_GetAnP_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCode);
        RETURN;
    END;

    DECLARE @IsLis BIT = CASE WHEN @Category = 'LIS' THEN 1 ELSE 0 END;
    DECLARE @PeriodCol NVARCHAR(60) =
        CASE WHEN @IsLis = 1 THEN CASE WHEN @UseBilledDate = 1 THEN N'BilledDate' ELSE N'RequestCollectDate' END
             ELSE CASE WHEN @UseBilledDate = 1 THEN N'FirstBilledDate' ELSE N'DateofService' END END;
    DECLARE @PeriodText NVARCHAR(200) =
        CASE WHEN @Year = 0 THEN N'all periods (Grand Total)'
             WHEN @Month = 0 THEN N'year ' + CAST(@Year AS NVARCHAR(4)) + N' (Year Total)'
             ELSE DATENAME(MONTH, DATEFROMPARTS(@Year, @Month, 1)) + N' ' + CAST(@Year AS NVARCHAR(4)) END;

    /* ---- 1. Rules ----------------------------------------------------------- */
    DECLARE @Rules TABLE (RuleOrder INT IDENTITY(1,1), RuleGroup NVARCHAR(40), RuleText NVARCHAR(2000));
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Source', CASE WHEN @IsLis = 1 THEN N'dbo.LIMSMaster - one row per sample'
                           ELSE N'dbo.ClaimLevelData - one row per claim' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Base filter', @PeriodCol + N' is a valid date; Bill Status with doubled spaces collapsed'
    WHERE @IsFormula = 0 AND @IsLis = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Base filter', @PeriodCol + N' is a valid date; blank NewStatus / BillCategory / SubStatus = empty text'
    WHERE @IsFormula = 0 AND @IsLis = 1;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Period', @PeriodCol + N' in ' + @PeriodText;
    INSERT INTO @Rules (RuleGroup, RuleText) VALUES (CASE WHEN @IsFormula = 1 THEN N'Formula' ELSE N'Row rule' END, @RuleText);
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Measure', CASE WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol
                            WHEN @IsLis = 1 THEN N'Count of samples (rows)'
                            ELSE N'Count of claims (rows)' END
    WHERE @IsFormula = 0;

    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', v.Txt
    FROM (VALUES
        (CASE WHEN @From IS NOT NULL OR @To IS NOT NULL
              THEN (CASE WHEN @UseBilledDate = 1 THEN N'Billed Date' ELSE N'DOS' END) + N' from '
                   + ISNULL(CONVERT(NVARCHAR(10), @From, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @To, 101), N'(any)') END),
        (CASE WHEN @YearFrom IS NOT NULL OR @YearTo IS NOT NULL
              THEN N'Year ' + ISNULL(CAST(@YearFrom AS NVARCHAR(4)), N'(any)') + N' - ' + ISNULL(CAST(@YearTo AS NVARCHAR(4)), N'(any)') END),
        (CASE WHEN @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL
              THEN N'Month ' + ISNULL(CAST(@MonthFrom AS NVARCHAR(2)), N'(any)') + N' - ' + ISNULL(CAST(@MonthTo AS NVARCHAR(2)), N'(any)') END),
        (CASE WHEN @HasPanel = 1    THEN (CASE WHEN @IsLis = 1 THEN N'PanelName' ELSE N'Panelname' END) + N' IN (' + @Panels + N')' END),
        (CASE WHEN @HasClinic = 1   THEN N'ClinicName IN (' + @Clinics + N')' END),
        (CASE WHEN @HasProvider = 1 THEN N'ReferringProvider IN (' + @Providers + N')' END),
        (CASE WHEN @HasRep = 1 AND @IsLis = 0 THEN N'SalesRepname IN (' + @Reps + N')' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL;

    /* ---- Formula rows: components from the Executive Summary itself ---------- */
    IF @IsFormula = 1
    BEGIN
        CREATE TABLE #Es
        (
            RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL,
            Category VARCHAR(10) NOT NULL,
            Description NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
            BillYear INT NOT NULL, BillMonth INT NOT NULL,
            MetricValue DECIMAL(18,2) NOT NULL,
            SortOrder INT NOT NULL
        );
        INSERT INTO #Es
        EXEC dbo.usp_GetAnP_ExecutiveSummary
            @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
            @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
            @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;

        DECLARE @Comp TABLE
        (
            Seq INT NOT NULL, Section NVARCHAR(20) NOT NULL, Op NVARCHAR(4) NOT NULL,
            Category VARCHAR(10) NULL, RowCode NVARCHAR(20) NULL, Label NVARCHAR(200) NULL,
            IsMoney BIT NOT NULL, IsTotal BIT NOT NULL
        );
        IF @RowCode = N'H'
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'PMS', N'F', NULL, 0, 0),
                (2, N'Calculation', N'-', 'LIS', N'C', NULL, 0, 0),
                (9, N'Result',      N'=', 'PMS', N'H', NULL, 0, 1);
        ELSE
        BEGIN
            INSERT INTO @Comp VALUES
                (1, N'Numerator', N'',  'Cash', N'R', NULL, 1, 0),
                (2, N'Numerator', N'+', 'Cash', N'U', NULL, 1, 0),
                (4, N'Numerator', N'=', NULL, NULL, N'Total Payments ($)', 1, 1);
            IF @RowCode = N'X'
                INSERT INTO @Comp VALUES (11, N'Denominator', N'', 'PMS', N'F', NULL, 0, 0);
            ELSE IF @RowCode = N'Y'
                INSERT INTO @Comp VALUES
                    (11, N'Denominator', N'',  'PMS', N'I', NULL, 0, 0),
                    (12, N'Denominator', N'+', 'PMS', N'M', NULL, 0, 0);
            ELSE
                INSERT INTO @Comp VALUES
                    (11, N'Denominator', N'',  'PMS', N'I',  NULL, 0, 0),
                    (12, N'Denominator', N'+', 'PMS', N'M',  NULL, 0, 0),
                    (13, N'Denominator', N'+', 'PMS', N'J',  NULL, 0, 0),
                    (14, N'Denominator', N'+', 'PMS', N'K',  NULL, 0, 0),
                    (15, N'Denominator', N'+', 'PMS', N'L',  NULL, 0, 0),
                    (16, N'Denominator', N'+', 'PMS', N'N',  NULL, 0, 0),
                    (17, N'Denominator', N'+', 'PMS', N'O1', NULL, 0, 0),
                    (18, N'Denominator', N'+', 'PMS', N'O2', NULL, 0, 0);
            IF @RowCode <> N'X'
                INSERT INTO @Comp VALUES (19, N'Denominator', N'=', NULL, NULL,
                    CASE @RowCode WHEN N'Y' THEN N'Paid claims' ELSE N'Adjudicated claims' END, 0, 1);
            INSERT INTO @Comp VALUES (29, N'Result', N'=', 'Avg', @RowCode, NULL, 1, 1);
        END;

        DROP TABLE IF EXISTS #CompV;
        SELECT c.Seq, c.Section, c.Op, c.Category, c.RowCode, c.IsMoney, c.IsTotal,
               COALESCE(c.Label, LTRIM(RTRIM(e.Description))) AS Component,
               e.MetricValue AS Value
        INTO #CompV
        FROM @Comp c
        LEFT JOIN #Es e ON e.Category = c.Category AND e.RowCode = c.RowCode
                       AND e.BillYear = @Year AND e.BillMonth = @Month;

        -- Subtotal lines = sum of their section's components.
        UPDATE t SET Value = s.Total
        FROM #CompV t
        CROSS APPLY (SELECT SUM(ISNULL(x.Value, 0)) AS Total FROM #CompV x
                     WHERE x.Section = t.Section AND x.IsTotal = 0) s
        WHERE t.IsTotal = 1 AND t.RowCode IS NULL;

        UPDATE #CompV SET Value = ISNULL(Value, 0);

        DECLARE @Result DECIMAL(18,2) = (SELECT Value FROM #CompV WHERE Section = N'Result');
        DECLARE @Calc NVARCHAR(1000);
        IF @RowCode = N'H'
            SELECT @Calc = FORMAT(MAX(CASE WHEN RowCode = N'F' THEN Value END), 'N0') + N' - '
                         + FORMAT(MAX(CASE WHEN RowCode = N'C' THEN Value END), 'N0') + N' = '
                         + FORMAT(@Result, 'N0')
            FROM #CompV;
        ELSE
            SELECT @Calc = N'$' + FORMAT(MAX(CASE WHEN Section = N'Numerator' AND IsTotal = 1 THEN Value END), 'N2') + N' / '
                         + FORMAT(MAX(CASE WHEN Section = N'Denominator' AND (IsTotal = 1 OR @RowCode = N'X') THEN Value END), 'N0')
                         + N' = $' + FORMAT(@Result, 'N2')
            FROM #CompV;

        INSERT INTO @Rules (RuleGroup, RuleText) VALUES (N'Calculation', @Calc);
        SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

        SELECT CAST(NULL AS NVARCHAR(100)) AS SourceTable, N'Formula' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               0 AS TotalRows, @Result AS TotalAmount, CAST(1 AS BIT) AS IsFormula;

        SELECT Section, Op AS [Operator], Component, Category, RowCode, Value, IsMoney, IsTotal
        FROM #CompV
        ORDER BY Seq;
        RETURN;
    END;

    SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

    /* ---- LIS samples -------------------------------------------------------- */
    IF @IsLis = 1
    BEGIN
        SELECT
            l.Accession,
            TRY_CAST(l.RequestCollectDate AS DATE) AS RequestCollectDate,
            TRY_CAST(l.BilledDate AS DATE)         AS BilledDate,
            l.NewStatus, l.BillCategory, l.SubStatus, l.ResultStatus,
            l.PanelName, l.ClinicName, l.ReferringProvider, l.PrimaryInsurance,
            d.PeriodDate
        INTO #L
        FROM dbo.LIMSMaster l
        CROSS APPLY (SELECT CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(l.BilledDate AS DATE)
                                 ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate) d
        CROSS APPLY (SELECT ISNULL(LTRIM(RTRIM(l.NewStatus)), N'')    AS NS,
                            ISNULL(LTRIM(RTRIM(l.BillCategory)), N'') AS BC,
                            ISNULL(LTRIM(RTRIM(l.SubStatus)), N'')    AS SS) n
        WHERE d.PeriodDate IS NOT NULL
          AND (@From      IS NULL OR d.PeriodDate >= @From)
          AND (@To        IS NULL OR d.PeriodDate <= @To)
          AND (@YearFrom  IS NULL OR YEAR(d.PeriodDate)  >= @YearFrom)
          AND (@YearTo    IS NULL OR YEAR(d.PeriodDate)  <= @YearTo)
          AND (@MonthFrom IS NULL OR MONTH(d.PeriodDate) >= @MonthFrom)
          AND (@MonthTo   IS NULL OR MONTH(d.PeriodDate) <= @MonthTo)
          AND (@Year  = 0 OR YEAR(d.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(d.PeriodDate) = @Month)
          AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(l.PanelName, N'')))         IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
          AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(l.ClinicName, N'')))        IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
          AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(l.ReferringProvider, N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
          AND (   @RowCode = N'A'
               OR (@RowCode = N'B'  AND n.NS = N'Billable')
               OR (@RowCode IN (N'C', N'C1') AND n.NS = N'Billable' AND n.BC = N'Billed')
               OR (@RowCode = N'D'  AND n.NS = N'Billable' AND n.BC IN (N'Unbilled', N'Not Billed'))
               OR (@RowCode = N'D1' AND n.NS = N'Billable' AND n.BC IN (N'Unbilled', N'Not Billed') AND n.SS = N'Ready to Bill')
               OR (@RowCode = N'D2' AND n.NS = N'Billable' AND n.BC IN (N'Unbilled', N'Not Billed')
                                    AND n.SS IN (N'Entered Not Submitted', N'Entered Not Billed'))
               OR (@RowCode = N'E'  AND n.NS <> N'Billable')
               OR (@RowCode = N'F'  AND n.NS IN (N'Duplicate', N'Duplicates', N'Duplicate - Sample Resulted in Spector'))
               OR (@RowCode = N'G'  AND n.NS = N'System Test')
               OR (@RowCode = N'H'  AND n.NS IN (N'Yet to Be Validate', N'Yet to be validated', N'Yet be validated')
                                    AND n.SS <> N'Entered Not Submitted'))
        OPTION (RECOMPILE);

        SELECT N'dbo.LIMSMaster' AS SourceTable, N'Count of samples' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #L;

        SELECT Accession, RequestCollectDate, BilledDate, NewStatus, BillCategory, SubStatus, ResultStatus,
               PanelName, ClinicName, ReferringProvider, PrimaryInsurance
        FROM #L
        ORDER BY PeriodDate, Accession
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- Claims (PMS / Cash) ------------------------------------------------ */
    SELECT
        c.ClaimID, c.AccessionNumber,
        TRY_CAST(c.DateofService AS DATE)   AS DateofService,
        TRY_CAST(c.FirstBilledDate AS DATE) AS FirstBilledDate,
        c.PayerName_Raw, c.Panelname, c.ClinicName, c.ReferringProvider, c.SalesRepname,
        n.BillStatus AS BilledStatus, n.ClaimStatus,
        v.ChargeAmount, v.InsurancePayment, v.PatientPayment, v.PatientBalance, v.TotalAdjustments, v.TotalInsuranceBalance,
        CASE @AmountCol
            WHEN N'ChargeAmount'          THEN v.ChargeAmount
            WHEN N'InsurancePayment'      THEN v.InsurancePayment
            WHEN N'PatientPayment'        THEN v.PatientPayment
            WHEN N'PatientBalance'        THEN v.PatientBalance
            WHEN N'TotalAdjustments'      THEN v.TotalAdjustments
            WHEN N'TotalInsuranceBalance' THEN v.TotalInsuranceBalance
        END AS Amount,
        d.PeriodDate
    INTO #C
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(c.FirstBilledDate AS DATE)
                             ELSE TRY_CAST(c.DateofService AS DATE) END AS PeriodDate) d
    CROSS APPLY (SELECT
        LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(ISNULL(c.BilledStatus, N''), N'  ', N' '), N'  ', N' '), N'  ', N' '))) AS BillStatus,
        ISNULL(LTRIM(RTRIM(c.ClaimStatus)), N'') AS ClaimStatus) n
    CROSS APPLY (SELECT
        ISNULL(TRY_CAST(c.ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(c.InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(c.PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(c.PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance,
        ISNULL(TRY_CAST(c.TotalAdjustments      AS DECIMAL(18,2)), 0) AS TotalAdjustments,
        ISNULL(TRY_CAST(c.TotalInsuranceBalance AS DECIMAL(18,2)), 0) AS TotalInsuranceBalance) v
    CROSS APPLY (SELECT CASE WHEN n.BillStatus IN (N'Billed', N'Billed - Self Pay') THEN 1 ELSE 0 END AS IsBilled,
                        CASE WHEN n.BillStatus IN (N'Unbilled', N'Unbilled - Self Pay') THEN 1 ELSE 0 END AS IsUnbilled) b
    WHERE d.PeriodDate IS NOT NULL
      AND (@From      IS NULL OR d.PeriodDate >= @From)
      AND (@To        IS NULL OR d.PeriodDate <= @To)
      AND (@YearFrom  IS NULL OR YEAR(d.PeriodDate)  >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR(d.PeriodDate)  <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(d.PeriodDate) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(d.PeriodDate) <= @MonthTo)
      AND (@Year  = 0 OR YEAR(d.PeriodDate)  = @Year)
      AND (@Month = 0 OR MONTH(d.PeriodDate) = @Month)
      AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(c.Panelname, N'')))         IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
      AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(c.ClinicName, N'')))        IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
      AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(c.ReferringProvider, N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
      AND (@HasRep      = 0 OR LTRIM(RTRIM(ISNULL(c.SalesRepname, N'')))      IN (SELECT Val FROM #Filters WHERE Dim = 'Rep'))
      AND (   (@RowCode IN (N'F', N'F1') AND b.IsBilled = 1 AND n.ClaimStatus <> N'0 Billed Amount')
           OR (@RowCode = N'G'  AND b.IsUnbilled = 1 AND n.ClaimStatus <> N'0 Billed Amount')
           OR (@RowCode = N'G1' AND n.BillStatus = N'Unbilled' AND n.ClaimStatus <> N'0 Billed Amount')
           OR (@RowCode = N'G2' AND n.BillStatus = N'Unbilled - Self Pay' AND n.ClaimStatus <> N'0 Billed Amount')
           OR (@RowCode = N'G3' AND n.ClaimStatus = N'0 Billed Amount')
           OR (@RowCode IN (N'I', N'R') AND b.IsBilled = 1 AND n.ClaimStatus = N'Fully Paid')
           OR (@RowCode = N'J'  AND b.IsBilled = 1 AND n.ClaimStatus = N'Patient Responsibility')
           OR (@RowCode = N'K'  AND b.IsBilled = 1 AND n.ClaimStatus = N'Fully Adjusted')
           OR (@RowCode = N'L'  AND b.IsBilled = 1 AND n.ClaimStatus = N'Partially Adjusted')
           OR (@RowCode = N'M'  AND b.IsBilled = 1 AND n.ClaimStatus = N'Partially Paid')
           OR (@RowCode = N'N'  AND b.IsBilled = 1 AND n.ClaimStatus = N'Patient Payment')
           OR (@RowCode = N'O'  AND b.IsBilled = 1 AND n.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied'))
           OR (@RowCode = N'O1' AND b.IsBilled = 1 AND n.ClaimStatus = N'Fully Denied')
           OR (@RowCode = N'O2' AND b.IsBilled = 1 AND n.ClaimStatus = N'Partially Denied')
           OR (@RowCode = N'O3' AND b.IsBilled = 1 AND n.ClaimStatus = N'No Response')
           OR (@RowCode IN (N'P', N'P1', N'S', N'T', N'V', N'W') AND b.IsBilled = 1)
           OR (@RowCode = N'Q'  AND b.IsUnbilled = 1)
           OR (@RowCode = N'Q1' AND n.BillStatus = N'Unbilled')
           OR (@RowCode = N'Q2' AND n.BillStatus = N'Unbilled - Self Pay')
           OR (@RowCode = N'U'  AND n.ClaimStatus IN (N'Fully Adjusted', N'Partially Adjusted', N'Partially Denied', N'Partially Paid'))
           OR (@RowCode = N'W1' AND b.IsBilled = 1 AND n.ClaimStatus = N'Fully Denied')
           OR (@RowCode = N'W2' AND b.IsBilled = 1 AND n.ClaimStatus NOT IN (N'Fully Denied', N'No Response'))
           OR (@RowCode = N'W3' AND b.IsBilled = 1 AND n.ClaimStatus = N'No Response'))
    OPTION (RECOMPILE);

    SELECT N'dbo.ClaimLevelData' AS SourceTable,
           CASE WHEN @AmountCol IS NULL THEN N'Count of claims' ELSE N'Sum of ' + @AmountCol END AS Measure,
           @AmountCol AS AmountColumn,
           COUNT(*) AS TotalRows,
           CAST(ISNULL(SUM(Amount), 0) AS DECIMAL(18,2)) AS TotalAmount,
           CAST(0 AS BIT) AS IsFormula
    FROM #C;

    IF @AmountCol IS NULL
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
               ReferringProvider, SalesRepname, BilledStatus, ClaimStatus,
               ChargeAmount, InsurancePayment, PatientPayment, PatientBalance, TotalAdjustments, TotalInsuranceBalance
        FROM #C
        ORDER BY PeriodDate, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
    ELSE
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
               ReferringProvider, SalesRepname, BilledStatus, ClaimStatus, Amount,
               ChargeAmount, InsurancePayment, PatientPayment, PatientBalance, TotalAdjustments, TotalInsuranceBalance
        FROM #C
        ORDER BY PeriodDate, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
END;
GO

SET NOEXEC OFF;
GO

PRINT '43_AnalyzePathology_ExecutiveSummary_CellRows.sql completed.';
GO
