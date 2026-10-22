/* =============================================================================
   WellHealth - Executive Summary cell rows (value click -> popup grid)
   File     : 37_WellHealth_ExecutiveSummary_CellRows.sql
   Database : WellHealth
   Object   : dbo.usp_GetWH_ExecutiveSummaryCellRows

   Returns the source rows behind one Executive Summary cell, using exactly the
   rules of dbo.usp_WH_ES_Load (source rows, date basis, page filters) and
   dbo.usp_WH_ES_Compute (per-row status rules), so the row count / amount equals
   the clicked value.

   Parameters
     @Category / @RowCode   the clicked row (LIS A..E7, PMS F..P3, Cash Q..X3, Avg Y..AA)
     @Year / @Month         the clicked column: (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetWH_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText - how the value is calculated
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured column for $ rows)
   Formula rows (PMS H, Avg Y / Z / AA) return the formula and the calculation with values in Rules,
   IsFormula = 1, TotalAmount = the result, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal) taken from
   usp_WH_ES_Load + usp_WH_ES_Compute for the same period and filters.
   ============================================================================= */

IF DB_NAME() <> N'WellHealth'
BEGIN
    RAISERROR(N'37_WellHealth_ExecutiveSummary_CellRows.sql must run on WellHealth.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_ExecutiveSummaryCellRows
(
    @Category   VARCHAR(10),
    @RowCode    NVARCHAR(20),
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

    /* ---- Page filters (as usp_WH_ES_Load) ---------------------------------- */
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

    /* ---- Row definitions (as usp_WH_ES_Compute) ---------------------------- */
    DECLARE @Def TABLE
    (
        Category  VARCHAR(10)   NOT NULL,
        RowCode   NVARCHAR(20)  NOT NULL,
        RuleText  NVARCHAR(1000) NOT NULL,
        AmountCol NVARCHAR(100) NULL,
        IsFormula BIT           NOT NULL
    );
    INSERT INTO @Def (Category, RowCode, RuleText, AmountCol, IsFormula) VALUES
        ('LIS', 'A',  N'Every sample (no status filter)', NULL, 0),
        ('LIS', 'B',  N'NewStatus = Billable', NULL, 0),
        ('LIS', 'C',  N'NewStatus = Billable AND BillCategory = Billed', NULL, 0),
        ('LIS', 'C1', N'NewStatus = Billable AND BillCategory = Billed', NULL, 0),
        ('LIS', 'D',  N'NewStatus = Billable AND BillCategory IN (Unbilled, Not Billed)', NULL, 0),
        ('LIS', 'D1', N'NewStatus = Billable AND BillCategory IN (Unbilled, Not Billed) AND the accession has NO claim in ClaimLevelData (any date, any status)', NULL, 0),
        ('LIS', 'D2', N'NewStatus = Billable AND BillCategory IN (Unbilled, Not Billed) AND the accession HAS a claim in ClaimLevelData (any date, any status)', NULL, 0),
        ('LIS', 'E',  N'NewStatus <> Billable', NULL, 0),
        ('LIS', 'E1', N'NewStatus IN (Cancelled/Rejected, Canceled/Rejected)', NULL, 0),
        ('LIS', 'E2', N'NewStatus = Client Bill', NULL, 0),
        ('LIS', 'E3', N'NewStatus = Billing Hold', NULL, 0),
        ('LIS', 'E4', N'NewStatus = Self Pay', NULL, 0),
        ('LIS', 'E5', N'NewStatus IN (Yet to be validated, Yet to be validate, Yet be validated)', NULL, 0),
        ('LIS', 'E6', N'NewStatus = System Test', NULL, 0),
        ('LIS', 'E7', N'NewStatus IN (Duplicate, Duplicates)', NULL, 0),
        ('PMS', 'F',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus <> 0 Billed Amount', NULL, 0),
        ('PMS', 'F1', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus <> 0 Billed Amount', NULL, 0),
        ('PMS', 'G',  N'BilledStatus IN (Unbilled, Unbilled - Client Bill, Unbilled - Self Pay) AND ClaimStatus <> 0 Billed Amount', NULL, 0),
        ('PMS', 'G1', N'BilledStatus = Unbilled AND ClaimStatus <> 0 Billed Amount', NULL, 0),
        ('PMS', 'G2', N'BilledStatus = Unbilled - Client Bill AND ClaimStatus <> 0 Billed Amount', NULL, 0),
        ('PMS', 'G3', N'BilledStatus = Unbilled - Self Pay AND ClaimStatus <> 0 Billed Amount', NULL, 0),
        ('PMS', 'H',  N'Formula: No. of Billed Claims (PMS F) - LIS Billed samples (LIS C), for the same period', NULL, 1),
        ('PMS', 'I',  N'BilledStatus = Billed AND ClaimStatus = 0 Billed Amount', NULL, 0),
        ('PMS', 'J',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Fully Paid', NULL, 0),
        ('PMS', 'K',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Patient Responsibility', NULL, 0),
        ('PMS', 'L',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Fully Adjusted', NULL, 0),
        ('PMS', 'M',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Partially Adjusted', NULL, 0),
        ('PMS', 'N',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Partially Paid', NULL, 0),
        ('PMS', 'O',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Patient Payment', NULL, 0),
        ('PMS', 'P',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus IN (Fully Denied, No Response, Partially Denied)', NULL, 0),
        ('PMS', 'P1', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Fully Denied', NULL, 0),
        ('PMS', 'P2', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Partially Denied', NULL, 0),
        ('PMS', 'P3', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = No Response', NULL, 0),
        ('Cash', 'Q',  N'BilledStatus IN (Billed, Billed - Self Pay)', N'ChargeAmount', 0),
        ('Cash', 'Q1', N'BilledStatus IN (Billed, Billed - Self Pay)', N'ChargeAmount', 0),
        ('Cash', 'R',  N'BilledStatus IN (Unbilled, Unbilled - Self Pay, Unbilled - Client Bill)', N'ChargeAmount', 0),
        ('Cash', 'R1', N'BilledStatus = Unbilled', N'ChargeAmount', 0),
        ('Cash', 'R2', N'BilledStatus = Unbilled - Self Pay', N'ChargeAmount', 0),
        ('Cash', 'R3', N'BilledStatus = Unbilled - Client Bill', N'ChargeAmount', 0),
        ('Cash', 'S',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Fully Paid', N'InsurancePayment', 0),
        ('Cash', 'T',  N'BilledStatus IN (Billed, Billed - Self Pay)', N'PatientBalance', 0),
        ('Cash', 'U',  N'BilledStatus IN (Billed, Billed - Self Pay)', N'TotalAdjustments', 0),
        ('Cash', 'V',  N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus <> Fully Paid', N'InsurancePayment', 0),
        ('Cash', 'W',  N'BilledStatus IN (Billed, Billed - Self Pay)', N'PatientPayment', 0),
        ('Cash', 'X',  N'BilledStatus IN (Billed, Billed - Self Pay)', N'TotalInsuranceBalance', 0),
        ('Cash', 'X1', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = Fully Denied', N'TotalInsuranceBalance', 0),
        ('Cash', 'X2', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus NOT IN (Fully Denied, No Response)', N'TotalInsuranceBalance', 0),
        ('Cash', 'X3', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = No Response', N'TotalInsuranceBalance', 0),
        ('Avg', 'Y',  N'Formula: (Insurance Payment $ + Partially Paid $ + Patient Paid $) / No. of Billed Claims (PMS F)', NULL, 1),
        ('Avg', 'Z',  N'Formula: (Insurance Payment $ + Partially Paid $ + Patient Paid $) / (Fully Paid + Partially Paid claims)', NULL, 1),
        ('Avg', 'AA', N'Formula: (Insurance Payment $ + Partially Paid $ + Patient Paid $) / (Fully Paid + Patient Responsibility + Adjusted + Partially Adjusted + Partially Paid + Patient Paid + Fully Denied + Partially Denied claims)', NULL, 1);

    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @IsFormula BIT;
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @IsFormula = IsFormula
    FROM @Def WHERE Category = @Category AND RowCode = @RowCode;

    IF @RuleText IS NULL
    BEGIN
        RAISERROR(N'usp_GetWH_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCode);
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
    SELECT N'Source', CASE WHEN @IsLis = 1 THEN N'dbo.LIMSMaster - one row per sample (Accession not blank)'
                           ELSE N'dbo.ClaimLevelData - one row per claim (ClaimID not blank)' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Base filter', N'RequestCollectDate / DateofService is a valid date between 1901 and 2026'
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Period', @PeriodCol + N' in ' + @PeriodText;
    INSERT INTO @Rules (RuleGroup, RuleText) VALUES (CASE WHEN @IsFormula = 1 THEN N'Formula' ELSE N'Row rule' END, @RuleText);
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Measure', CASE WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol + N' ($ text converted to a number)'
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
        (CASE WHEN @HasPanel = 1    THEN (CASE WHEN @IsLis = 1 THEN N'TestCategory' ELSE N'Panelname' END) + N' IN (' + @Panels + N')' END),
        (CASE WHEN @HasClinic = 1   THEN N'ClinicName IN (' + @Clinics + N')' END),
        (CASE WHEN @HasProvider = 1 THEN (CASE WHEN @IsLis = 1 THEN N'DoctorFullName' ELSE N'ReferringProvider' END) + N' IN (' + @Providers + N')' END),
        (CASE WHEN @HasRep = 1 AND @IsLis = 0 THEN N'SalesRepname IN (' + @Reps + N')' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL;

    /* Formula rows: the component values of the same period / filters, from the Executive
       Summary's own load + compute, so every number equals the grid. */
    IF @IsFormula = 1
    BEGIN
        CREATE TABLE #EsLis
        (
            ESYear INT NOT NULL, ESMonth INT NOT NULL,
            NewStatus NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
            BillCategory NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
            SubStatus NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
            InPms BIT NOT NULL,
            Cnt INT NOT NULL
        );
        CREATE TABLE #EsClaims
        (
            ESYear INT NOT NULL, ESMonth INT NOT NULL,
            BillStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
            ClaimStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
            ClaimCnt INT NOT NULL,
            ChargeAmount DECIMAL(18,2) NOT NULL,
            InsurancePayment DECIMAL(18,2) NOT NULL,
            PatientPayment DECIMAL(18,2) NOT NULL,
            PatientBalance DECIMAL(18,2) NOT NULL,
            TotalAdjustments DECIMAL(18,2) NOT NULL,
            TotalInsuranceBalance DECIMAL(18,2) NOT NULL
        );
        CREATE TABLE #EsOut
        (
            Category VARCHAR(10) NOT NULL,
            RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL,
            Description NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
            SortOrder INT NOT NULL,
            ESYear INT NOT NULL, ESMonth INT NOT NULL,
            MetricValue DECIMAL(18,2) NOT NULL,
            ClaimCount INT NOT NULL
        );

        EXEC dbo.usp_WH_ES_Load
            @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
            @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
            @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;
        EXEC dbo.usp_WH_ES_Compute;

        -- Section / order / operator / component row; subtotal and result lines have IsTotal = 1.
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
                (1, N'Numerator', N'',  'Cash', N'S', NULL, 1, 0),
                (2, N'Numerator', N'+', 'Cash', N'V', NULL, 1, 0),
                (3, N'Numerator', N'+', 'Cash', N'W', NULL, 1, 0),
                (4, N'Numerator', N'=', NULL,   NULL, N'Total Payments ($)', 1, 1);
            IF @RowCode = N'Y'
                INSERT INTO @Comp VALUES (11, N'Denominator', N'', 'PMS', N'F', NULL, 0, 0);
            ELSE IF @RowCode = N'Z'
                INSERT INTO @Comp VALUES
                    (11, N'Denominator', N'',  'PMS', N'J', NULL, 0, 0),
                    (12, N'Denominator', N'+', 'PMS', N'N', NULL, 0, 0);
            ELSE
                INSERT INTO @Comp VALUES
                    (11, N'Denominator', N'',  'PMS', N'J',  NULL, 0, 0),
                    (12, N'Denominator', N'+', 'PMS', N'K',  NULL, 0, 0),
                    (13, N'Denominator', N'+', 'PMS', N'L',  NULL, 0, 0),
                    (14, N'Denominator', N'+', 'PMS', N'M',  NULL, 0, 0),
                    (15, N'Denominator', N'+', 'PMS', N'N',  NULL, 0, 0),
                    (16, N'Denominator', N'+', 'PMS', N'O',  NULL, 0, 0),
                    (17, N'Denominator', N'+', 'PMS', N'P1', NULL, 0, 0),
                    (18, N'Denominator', N'+', 'PMS', N'P2', NULL, 0, 0);
            IF @RowCode <> N'Y'
                INSERT INTO @Comp VALUES (19, N'Denominator', N'=', NULL, NULL,
                    CASE @RowCode WHEN N'Z' THEN N'Paid claims' ELSE N'Adjudicated claims' END, 0, 1);
            INSERT INTO @Comp VALUES (29, N'Result', N'=', 'Avg', @RowCode, NULL, 1, 1);
        END;

        DROP TABLE IF EXISTS #CompV;
        SELECT c.Seq, c.Section, c.Op, c.Category, c.RowCode, c.IsMoney, c.IsTotal,
               COALESCE(c.Label, LTRIM(RTRIM(o.Description))) AS Component,
               CAST(CASE WHEN o.Category IN ('Cash', 'Avg') THEN o.MetricValue ELSE o.ClaimCount END AS DECIMAL(18,2)) AS Value
        INTO #CompV
        FROM @Comp c
        LEFT JOIN #EsOut o ON o.Category = c.Category AND o.RowCode = c.RowCode
                          AND o.ESYear = @Year AND o.ESMonth = @Month;

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
                         + FORMAT(MAX(CASE WHEN Section = N'Denominator' AND (IsTotal = 1 OR @RowCode = N'Y') THEN Value END), 'N0')
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

    /* ---- LIS rows ----------------------------------------------------------- */
    IF @IsLis = 1
    BEGIN
        CREATE TABLE #PmsAcc (Acc NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
        INSERT INTO #PmsAcc (Acc)
            SELECT DISTINCT UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.AccessionNumber))))
            FROM dbo.ClaimLevelData c
            WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.AccessionNumber))), N'') IS NOT NULL;

        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(200), l.Accession)))  AS Accession,
            p.Dos                                               AS RequestCollectDate,
            TRY_CAST(l.BilledDate AS DATE)                      AS BilledDate,
            l.NewStatus, l.BillCategory, l.SubStatus,
            CASE WHEN p.InPms = 1 THEN N'Yes' ELSE N'No' END    AS ClaimInPMS,
            l.TestCategory, l.ClinicName, l.DoctorFullName, l.PrimaryInsurance, l.ResultStatus,
            p.PeriodDate
        INTO #L
        FROM dbo.LIMSMaster l
        CROSS APPLY (
            SELECT TRY_CAST(l.RequestCollectDate AS DATE) AS Dos,
                   CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(l.BilledDate AS DATE)
                        ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.NewStatus), N''))))    AS NS,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.BillCategory), N'')))) AS BC,
                   CASE WHEN EXISTS (SELECT 1 FROM #PmsAcc a
                                         WHERE a.Acc = UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(200), l.Accession)))))
                        THEN 1 ELSE 0 END AS InPms
        ) p
        WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), l.Accession))), N'') IS NOT NULL
          AND p.Dos IS NOT NULL
          AND YEAR(p.Dos) > 1900
          AND YEAR(p.Dos) <= 2026
          AND p.PeriodDate IS NOT NULL
          AND (@From IS NULL OR p.PeriodDate >= @From)
          AND (@To   IS NULL OR p.PeriodDate <= @To)
          AND (@YearFrom  IS NULL OR YEAR(p.PeriodDate)  >= @YearFrom)
          AND (@YearTo    IS NULL OR YEAR(p.PeriodDate)  <= @YearTo)
          AND (@MonthFrom IS NULL OR MONTH(p.PeriodDate) >= @MonthFrom)
          AND (@MonthTo   IS NULL OR MONTH(p.PeriodDate) <= @MonthTo)
          AND (@Year  = 0 OR YEAR(p.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(p.PeriodDate) = @Month)
          AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.TestCategory), N'')))   IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
          AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.ClinicName), N'')))     IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
          AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.DoctorFullName), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
          AND (   @RowCode = N'A'
               OR (@RowCode = N'B'  AND p.NS = N'BILLABLE')
               OR (@RowCode IN (N'C', N'C1') AND p.NS = N'BILLABLE' AND p.BC = N'BILLED')
               OR (@RowCode = N'D'  AND p.NS = N'BILLABLE' AND p.BC IN (N'UNBILLED', N'NOT BILLED'))
               OR (@RowCode = N'D1' AND p.NS = N'BILLABLE' AND p.BC IN (N'UNBILLED', N'NOT BILLED') AND p.InPms = 0)
               OR (@RowCode = N'D2' AND p.NS = N'BILLABLE' AND p.BC IN (N'UNBILLED', N'NOT BILLED') AND p.InPms = 1)
               OR (@RowCode = N'E'  AND p.NS <> N'BILLABLE')
               OR (@RowCode = N'E1' AND p.NS IN (N'CANCELLED/REJECTED', N'CANCELED/REJECTED'))
               OR (@RowCode = N'E2' AND p.NS = N'CLIENT BILL')
               OR (@RowCode = N'E3' AND p.NS = N'BILLING HOLD')
               OR (@RowCode = N'E4' AND p.NS = N'SELF PAY')
               OR (@RowCode = N'E5' AND p.NS IN (N'YET TO BE VALIDATED', N'YET TO BE VALIDATE', N'YET BE VALIDATED'))
               OR (@RowCode = N'E6' AND p.NS = N'SYSTEM TEST')
               OR (@RowCode = N'E7' AND p.NS IN (N'DUPLICATE', N'DUPLICATES')))
        OPTION (RECOMPILE);

        SELECT N'dbo.LIMSMaster' AS SourceTable, N'Count of samples' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #L;

        SELECT Accession, RequestCollectDate, BilledDate, NewStatus, BillCategory, SubStatus, ClaimInPMS,
               TestCategory, ClinicName, DoctorFullName, PrimaryInsurance, ResultStatus
        FROM #L
        ORDER BY PeriodDate, Accession
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- Claim rows (PMS / Cash) ------------------------------------------- */
    SELECT
        LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID)))           AS ClaimID,
        LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.AccessionNumber)))   AS AccessionNumber,
        n.Dos                                                     AS DateofService,
        TRY_CAST(c.FirstBilledDate AS DATE)                       AS FirstBilledDate,
        c.PayerName_Raw, c.Panelname, c.ClinicName, c.ReferringProvider, c.SalesRepname,
        c.BilledStatus, c.ClaimStatus,
        n.ChargeAmount, n.InsurancePayment, n.PatientPayment, n.PatientBalance, n.TotalAdjustments, n.TotalInsuranceBalance,
        CASE @AmountCol
            WHEN N'ChargeAmount'          THEN n.ChargeAmount
            WHEN N'InsurancePayment'      THEN n.InsurancePayment
            WHEN N'PatientPayment'        THEN n.PatientPayment
            WHEN N'PatientBalance'        THEN n.PatientBalance
            WHEN N'TotalAdjustments'      THEN n.TotalAdjustments
            WHEN N'TotalInsuranceBalance' THEN n.TotalInsuranceBalance
        END AS Amount,
        n.PeriodDate
    INTO #C
    FROM dbo.ClaimLevelData c
    CROSS APPLY (
        SELECT
            UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(
                ISNULL(CONVERT(NVARCHAR(200), c.BilledStatus), N''), N'  ', N' '), N'  ', N' '), N'  ', N' '), N'  ', N' ')))) AS BS,
            UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.ClaimStatus), N'')))) AS CS,
            TRY_CAST(c.DateofService AS DATE) AS Dos,
            CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(c.FirstBilledDate AS DATE)
                 ELSE TRY_CAST(c.DateofService AS DATE) END AS PeriodDate,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.ChargeAmount))), N'$', N''), N',', N'')), 0) AS ChargeAmount,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsurancePayment))), N'$', N''), N',', N'')), 0) AS InsurancePayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientPayment))), N'$', N''), N',', N'')), 0) AS PatientPayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientBalance))), N'$', N''), N',', N'')), 0) AS PatientBalance,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.TotalAdjustments))), N'$', N''), N',', N'')), 0) AS TotalAdjustments,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.TotalInsuranceBalance))), N'$', N''), N',', N'')), 0) AS TotalInsuranceBalance
    ) n
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'') IS NOT NULL
      AND n.Dos IS NOT NULL
      AND YEAR(n.Dos) > 1900
      AND YEAR(n.Dos) <= 2026
      AND n.PeriodDate IS NOT NULL
      AND (@From IS NULL OR n.PeriodDate >= @From)
      AND (@To   IS NULL OR n.PeriodDate <= @To)
      AND (@YearFrom  IS NULL OR YEAR(n.PeriodDate)  >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR(n.PeriodDate)  <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(n.PeriodDate) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(n.PeriodDate) <= @MonthTo)
      AND (@Year  = 0 OR YEAR(n.PeriodDate)  = @Year)
      AND (@Month = 0 OR MONTH(n.PeriodDate) = @Month)
      AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.Panelname), N'')))         IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
      AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.ClinicName), N'')))        IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
      AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.ReferringProvider), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
      AND (@HasRep      = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.SalesRepname), N'')))      IN (SELECT Val FROM #Filters WHERE Dim = 'Rep'))
      AND (   (@RowCode IN (N'F', N'F1') AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS <> N'0 BILLED AMOUNT')
           OR (@RowCode = N'G'  AND n.BS IN (N'UNBILLED', N'UNBILLED - CLIENT BILL', N'UNBILLED - SELF PAY') AND n.CS <> N'0 BILLED AMOUNT')
           OR (@RowCode = N'G1' AND n.BS = N'UNBILLED' AND n.CS <> N'0 BILLED AMOUNT')
           OR (@RowCode = N'G2' AND n.BS = N'UNBILLED - CLIENT BILL' AND n.CS <> N'0 BILLED AMOUNT')
           OR (@RowCode = N'G3' AND n.BS = N'UNBILLED - SELF PAY' AND n.CS <> N'0 BILLED AMOUNT')
           OR (@RowCode = N'I'  AND n.BS = N'BILLED' AND n.CS = N'0 BILLED AMOUNT')
           OR (@RowCode = N'J'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'FULLY PAID')
           OR (@RowCode = N'K'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'PATIENT RESPONSIBILITY')
           OR (@RowCode = N'L'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'FULLY ADJUSTED')
           OR (@RowCode = N'M'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'PARTIALLY ADJUSTED')
           OR (@RowCode = N'N'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'PARTIALLY PAID')
           OR (@RowCode = N'O'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'PATIENT PAYMENT')
           OR (@RowCode = N'P'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS IN (N'FULLY DENIED', N'NO RESPONSE', N'PARTIALLY DENIED'))
           OR (@RowCode = N'P1' AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'FULLY DENIED')
           OR (@RowCode = N'P2' AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'PARTIALLY DENIED')
           OR (@RowCode = N'P3' AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'NO RESPONSE')
           OR (@RowCode IN (N'Q', N'Q1', N'T', N'U', N'W', N'X') AND n.BS IN (N'BILLED', N'BILLED - SELF PAY'))
           OR (@RowCode = N'R'  AND n.BS IN (N'UNBILLED', N'UNBILLED - SELF PAY', N'UNBILLED - CLIENT BILL'))
           OR (@RowCode = N'R1' AND n.BS = N'UNBILLED')
           OR (@RowCode = N'R2' AND n.BS = N'UNBILLED - SELF PAY')
           OR (@RowCode = N'R3' AND n.BS = N'UNBILLED - CLIENT BILL')
           OR (@RowCode = N'S'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'FULLY PAID')
           OR (@RowCode = N'V'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS <> N'FULLY PAID')
           OR (@RowCode = N'X1' AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'FULLY DENIED')
           OR (@RowCode = N'X2' AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS NOT IN (N'FULLY DENIED', N'NO RESPONSE'))
           OR (@RowCode = N'X3' AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'NO RESPONSE'))
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

PRINT '37_WellHealth_ExecutiveSummary_CellRows.sql completed.';
GO
