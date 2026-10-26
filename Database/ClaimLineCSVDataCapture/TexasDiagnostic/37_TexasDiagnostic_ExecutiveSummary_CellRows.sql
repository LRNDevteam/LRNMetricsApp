/* =============================================================================
   TexasDiagnostic - Executive Summary cell rows (value click -> popup grid)
   File     : 37_TexasDiagnostic_ExecutiveSummary_CellRows.sql
   Database : TexasDiagnostic
   Object   : dbo.usp_GetTD_ExecutiveSummaryCellRows
   Requires : 36_TexasDiagnostic_ExecutiveSummary.sql

   Returns the source rows behind one Executive Summary cell, using exactly the
   rules of dbo.usp_TD_ES_Load (source rows, date basis, page filters) and
   dbo.usp_TD_ES_Compute (per-row rules), so the row count / amount equals the
   clicked value. Keep the two files in step when a PROVISIONAL rule changes.

   Parameters
     @Category / @RowCode   the clicked row (LIS A..E6, PMS F..O3, Cash P..X3 / Y..Y9, Avg Z..AB)
     @Year / @Month         the clicked column: (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetTD_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText - how the value is calculated, incl. page filters
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured column for $ rows)
   Formula rows (PMS G, Cash Y / Y1-Y9, Avg Z / AA / AB) return the formula and the calculation in
   Rules, IsFormula = 1, TotalAmount = the result, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal) taken from
   usp_TD_ES_Load + usp_TD_ES_Compute for the same period and filters.
   ============================================================================= */

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
    RAISERROR(N'37_TexasDiagnostic_ExecutiveSummary_CellRows.sql must run on TexasDiagnostic.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetTD_ExecutiveSummaryCellRows
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

    /* ---- Page filters (as usp_TD_ES_Load) ---------------------------------- */
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

    /* ---- Row definitions (as usp_TD_ES_Compute) ---------------------------- */
    DECLARE @Def TABLE
    (
        Category  VARCHAR(10)    NOT NULL,
        RowCode   NVARCHAR(20)   NOT NULL,
        RuleText  NVARCHAR(1000) NOT NULL,
        AmountCol NVARCHAR(100)  NULL,
        IsFormula BIT            NOT NULL,
        Panel     NVARCHAR(20)   NULL
    );
    INSERT INTO @Def (Category, RowCode, RuleText, AmountCol, IsFormula, Panel) VALUES
        ('LIS', 'A',  N'Every sample (no status filter)', NULL, 0, NULL),
        ('LIS', 'B',  N'NewStatus = Billable', NULL, 0, NULL),
        ('LIS', 'B1', N'NewStatus = Billable AND PanelName = Toxicology', NULL, 0, N'TOXICOLOGY'),
        ('LIS', 'B2', N'NewStatus = Billable AND PanelName = Blood', NULL, 0, N'BLOOD'),
        ('LIS', 'B3', N'NewStatus = Billable AND PanelName = Urinalysis', NULL, 0, N'URINALYSIS'),
        ('LIS', 'B4', N'NewStatus = Billable AND PanelName = Wound', NULL, 0, N'WOUND'),
        ('LIS', 'B5', N'NewStatus = Billable AND PanelName = PGX', NULL, 0, N'PGX'),
        ('LIS', 'B6', N'NewStatus = Billable AND PanelName = UTI', NULL, 0, N'UTI'),
        ('LIS', 'B7', N'NewStatus = Billable AND PanelName = STI', NULL, 0, N'STI'),
        ('LIS', 'B8', N'NewStatus = Billable AND PanelName = RPP', NULL, 0, N'RPP'),
        ('LIS', 'B9', N'NewStatus = Billable AND PanelName = GI', NULL, 0, N'GI'),
        ('LIS', 'C',  N'NewStatus = Billable AND BillCategory = Billed', NULL, 0, NULL),
        ('LIS', 'D',  N'NewStatus = Billable AND BillCategory = Unbilled', NULL, 0, NULL),
        ('LIS', 'D1', N'NewStatus = Billable AND BillCategory = Unbilled AND SubStatus = Ready to Bill', NULL, 0, NULL),
        ('LIS', 'D2', N'NewStatus = Billable AND BillCategory = Unbilled AND SubStatus = Missing Insurance Info', NULL, 0, NULL),
        ('LIS', 'E',  N'NewStatus <> Billable', NULL, 0, NULL),
        ('LIS', 'E1', N'NewStatus IN (Client Bill, Client Bills)', NULL, 0, NULL),
        ('LIS', 'E2', N'NewStatus = Rejected', NULL, 0, NULL),
        ('LIS', 'E3', N'NewStatus = Yet to be Validated', NULL, 0, NULL),
        ('LIS', 'E4', N'NewStatus = System Test', NULL, 0, NULL),
        ('LIS', 'E5', N'NewStatus = Self Pay', NULL, 0, NULL),
        ('LIS', 'E6', N'NewStatus = CIP/Pending', NULL, 0, NULL),
        ('PMS', 'F',  N'BilledStatus = Billed (provisional)', NULL, 0, NULL),
        ('PMS', 'G',  N'Formula (provisional): No. of Billed Claims (PMS F) - LIS Billed samples (LIS C), for the same period', NULL, 1, NULL),
        ('PMS', 'H',  N'BilledStatus = Billed AND the claim''s AccessionNumber is already on another claim (every claim after the first) (provisional)', NULL, 0, NULL),
        ('PMS', 'I',  N'BilledStatus = Unbilled', NULL, 0, NULL),
        ('PMS', 'J',  N'ClaimStatus = Fully Paid (provisional)', NULL, 0, NULL),
        ('PMS', 'K',  N'ClaimStatus = Partially Paid (provisional)', NULL, 0, NULL),
        ('PMS', 'L',  N'ClaimStatus = Patient Responsibility', NULL, 0, NULL),
        ('PMS', 'M',  N'ClaimStatus = Fully Adjusted (provisional)', NULL, 0, NULL),
        ('PMS', 'N',  N'ClaimStatus = Partially Adjusted', NULL, 0, NULL),
        ('PMS', 'O',  N'ClaimStatus IN (Denied, Fully Denied, Partially Denied, No Response) (provisional)', NULL, 0, NULL),
        ('PMS', 'O1', N'ClaimStatus IN (Denied, Fully Denied) (provisional)', NULL, 0, NULL),
        ('PMS', 'O2', N'ClaimStatus = Partially Denied', NULL, 0, NULL),
        ('PMS', 'O3', N'ClaimStatus = No Response (provisional)', NULL, 0, NULL),
        ('Cash', 'P',   N'BilledStatus = Billed (provisional)', N'ChargeAmount', 0, NULL),
        ('Cash', 'Q',   N'BilledStatus = Billed (provisional)', N'ExpectedPayment', 0, NULL),
        ('Cash', 'Q1',  N'BilledStatus = Billed AND Panelname = Toxicology (provisional)', N'ExpectedPayment', 0, N'TOXICOLOGY'),
        ('Cash', 'Q2',  N'BilledStatus = Billed AND Panelname = Blood (provisional)', N'ExpectedPayment', 0, N'BLOOD'),
        ('Cash', 'Q3',  N'BilledStatus = Billed AND Panelname = PGX (provisional)', N'ExpectedPayment', 0, N'PGX'),
        ('Cash', 'Q4',  N'BilledStatus = Billed AND Panelname = Wound (provisional)', N'ExpectedPayment', 0, N'WOUND'),
        ('Cash', 'Q5',  N'BilledStatus = Billed AND Panelname = RPP (provisional)', N'ExpectedPayment', 0, N'RPP'),
        ('Cash', 'Q6',  N'BilledStatus = Billed AND Panelname = UTI (provisional)', N'ExpectedPayment', 0, N'UTI'),
        ('Cash', 'Q7',  N'BilledStatus = Billed AND Panelname = STI (provisional)', N'ExpectedPayment', 0, N'STI'),
        ('Cash', 'Q8',  N'BilledStatus = Billed AND Panelname = GI (provisional)', N'ExpectedPayment', 0, N'GI'),
        ('Cash', 'Q9',  N'BilledStatus = Billed AND Panelname = Urinalysis (provisional)', N'ExpectedPayment', 0, N'URINALYSIS'),
        ('Cash', 'Q10', N'BilledStatus = Billed AND Panelname is none of the listed panels (provisional)', N'ExpectedPayment', 0, N''),
        ('Cash', 'R',   N'BilledStatus = Billed AND ClaimStatus = Fully Paid (provisional)', N'InsurancePayment', 0, NULL),
        ('Cash', 'S',   N'BilledStatus = Billed AND ClaimStatus = Partially Paid (provisional)', N'InsurancePayment', 0, NULL),
        ('Cash', 'T',   N'BilledStatus = Billed (provisional)', N'TotalPayments', 0, NULL),
        ('Cash', 'U',   N'BilledStatus = Billed (provisional)', N'TotalAdjustments', 0, NULL),
        ('Cash', 'V',   N'BilledStatus = Billed (provisional)', N'InsuranceAdjustments', 0, NULL),
        ('Cash', 'W',   N'BilledStatus = Billed (provisional)', N'PatientBalance', 0, NULL),
        ('Cash', 'X',   N'BilledStatus = Billed (provisional)', N'InsuranceBalance', 0, NULL),
        ('Cash', 'X1',  N'BilledStatus = Billed AND ClaimStatus IN (Denied, Fully Denied) (provisional)', N'InsuranceBalance', 0, NULL),
        ('Cash', 'X2',  N'BilledStatus = Billed AND ClaimStatus = Partially Denied (provisional)', N'InsuranceBalance', 0, NULL),
        ('Cash', 'X3',  N'BilledStatus = Billed AND ClaimStatus = No Response (provisional)', N'InsuranceBalance', 0, NULL),
        ('Cash', 'Y',   N'Formula (provisional): Expected Payment $ (Cash Q) / No. of Billed Claims (PMS F)', NULL, 1, NULL),
        ('Cash', 'Y1',  N'Formula (provisional): Toxicology Expected Payment $ (Cash Q1) / Toxicology billed claims', NULL, 1, NULL),
        ('Cash', 'Y2',  N'Formula (provisional): Blood Expected Payment $ (Cash Q2) / Blood billed claims', NULL, 1, NULL),
        ('Cash', 'Y3',  N'Formula (provisional): PGX Expected Payment $ (Cash Q3) / PGX billed claims', NULL, 1, NULL),
        ('Cash', 'Y4',  N'Formula (provisional): Wound Expected Payment $ (Cash Q4) / Wound billed claims', NULL, 1, NULL),
        ('Cash', 'Y5',  N'Formula (provisional): RPP Expected Payment $ (Cash Q5) / RPP billed claims', NULL, 1, NULL),
        ('Cash', 'Y6',  N'Formula (provisional): UTI Expected Payment $ (Cash Q6) / UTI billed claims', NULL, 1, NULL),
        ('Cash', 'Y7',  N'Formula (provisional): STI Expected Payment $ (Cash Q7) / STI billed claims', NULL, 1, NULL),
        ('Cash', 'Y8',  N'Formula (provisional): GI Expected Payment $ (Cash Q8) / GI billed claims', NULL, 1, NULL),
        ('Cash', 'Y9',  N'Formula (provisional): Urinalysis Expected Payment $ (Cash Q9) / Urinalysis billed claims', NULL, 1, NULL),
        ('Avg', 'Z',   N'Formula (provisional): Total Payments $ (Cash T) / No. of Billed Claims (PMS F)', NULL, 1, NULL),
        ('Avg', 'AA',  N'Formula (provisional): (Insurance Payment $ + Partially Paid $) / (Fully Paid + Partially Paid claims)', NULL, 1, NULL),
        ('Avg', 'AB',  N'Formula (provisional): (Insurance Payment $ + Partially Paid $) / (Fully Paid + Partially Paid + Patient Responsibility + Fully Adjusted + Partially Adjusted + Fully Denied + Partially Denied claims)', NULL, 1, NULL);

    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @IsFormula BIT, @Panel NVARCHAR(20);
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @IsFormula = IsFormula, @Panel = Panel
    FROM @Def WHERE Category = @Category AND RowCode = @RowCode;

    IF @RuleText IS NULL
    BEGIN
        RAISERROR(N'usp_GetTD_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCode);
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
    SELECT N'Source', CASE WHEN @IsLis = 1 THEN N'dbo.LIMSMaster - one row per sample (Sample IDs / Accession not blank)'
                           ELSE N'dbo.ClaimLevelData - one row per claim (ClaimID not blank)' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Base filter', CASE WHEN @IsLis = 1 THEN N'RequestCollectDate is a valid date' ELSE N'DateofService is a valid date' END
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
        (CASE WHEN @HasPanel = 1    THEN (CASE WHEN @IsLis = 1 THEN N'PanelName' ELSE N'Panelname' END) + N' IN (' + @Panels + N')' END),
        (CASE WHEN @HasClinic = 1   THEN N'ClinicName IN (' + @Clinics + N')' END),
        (CASE WHEN @HasProvider = 1 THEN (CASE WHEN @IsLis = 1 THEN N'DoctorFullName' ELSE N'ReferringProvider' END) + N' IN (' + @Providers + N')' END),
        (CASE WHEN @HasRep = 1      THEN (CASE WHEN @IsLis = 1 THEN N'SalesRepName' ELSE N'SalesRepname' END) + N' IN (' + @Reps + N')' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL;

    /* Formula rows: component values of the same period / filters, from the Executive
       Summary's own load + compute, so every number equals the grid. */
    IF @IsFormula = 1
    BEGIN
        CREATE TABLE #EsLis
        (
            ESYear INT NOT NULL, ESMonth INT NOT NULL,
            St VARCHAR(10) NOT NULL, Bill CHAR(1) NOT NULL, Sub VARCHAR(10) NOT NULL,
            Panel NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL,
            Cnt INT NOT NULL
        );
        CREATE TABLE #EsClaims
        (
            ESYear INT NOT NULL, ESMonth INT NOT NULL,
            BillStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
            ClaimStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
            Panel NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL,
            ClaimCnt INT NOT NULL, DupCnt INT NOT NULL,
            ChargeAmount DECIMAL(18,2) NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL,
            TotalPayments DECIMAL(18,2) NOT NULL, TotalAdjustments DECIMAL(18,2) NOT NULL,
            InsuranceAdjustments DECIMAL(18,2) NOT NULL, PatientBalance DECIMAL(18,2) NOT NULL,
            InsuranceBalance DECIMAL(18,2) NOT NULL, ExpectedPayment DECIMAL(18,2) NOT NULL
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

        EXEC dbo.usp_TD_ES_Load
            @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
            @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
            @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;
        EXEC dbo.usp_TD_ES_Compute;

        -- Section / order / operator / component; UseCount = 1 takes the row's claim count
        -- (the Avg panel rows carry their billed-claim denominator there).
        DECLARE @Comp TABLE
        (
            Seq INT NOT NULL, Section NVARCHAR(20) NOT NULL, Op NVARCHAR(4) NOT NULL,
            Category VARCHAR(10) NULL, RowCode NVARCHAR(20) NULL, Label NVARCHAR(200) NULL,
            IsMoney BIT NOT NULL, IsTotal BIT NOT NULL, UseCount BIT NOT NULL
        );

        IF @RowCode = N'G'
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'PMS', N'F', NULL, 0, 0, 0),
                (2, N'Calculation', N'-', 'LIS', N'C', NULL, 0, 0, 0),
                (9, N'Result',      N'=', 'PMS', N'G', NULL, 0, 1, 0);
        ELSE IF @RowCode = N'Y'
            INSERT INTO @Comp VALUES
                (1,  N'Numerator',   N'',  'Cash', N'Q', NULL, 1, 0, 0),
                (11, N'Denominator', N'',  'PMS',  N'F', NULL, 0, 0, 0),
                (29, N'Result',      N'=', 'Cash', N'Y', NULL, 1, 1, 0);
        ELSE IF @RowCode LIKE N'Y[1-9]'
            INSERT INTO @Comp VALUES
                (1,  N'Numerator',   N'',  'Cash', N'Q' + RIGHT(@RowCode, 1), NULL, 1, 0, 0),
                (11, N'Denominator', N'',  'Cash', @RowCode,
                     (SELECT TOP (1) LTRIM(o.Description) FROM #EsOut o WHERE o.Category = 'Cash' AND o.RowCode = @RowCode) + N' billed claims',
                     0, 0, 1),
                (29, N'Result',      N'=', 'Cash', @RowCode, NULL, 1, 1, 0);
        ELSE IF @RowCode = N'Z'
            INSERT INTO @Comp VALUES
                (1,  N'Numerator',   N'',  'Cash', N'T', NULL, 1, 0, 0),
                (11, N'Denominator', N'',  'PMS',  N'F', NULL, 0, 0, 0),
                (29, N'Result',      N'=', 'Avg',  N'Z', NULL, 1, 1, 0);
        ELSE
        BEGIN
            INSERT INTO @Comp VALUES
                (1, N'Numerator', N'',  'Cash', N'R', NULL, 1, 0, 0),
                (2, N'Numerator', N'+', 'Cash', N'S', NULL, 1, 0, 0),
                (4, N'Numerator', N'=', NULL, NULL, N'Paid ($)', 1, 1, 0),
                (11, N'Denominator', N'',  'PMS', N'J', NULL, 0, 0, 0),
                (12, N'Denominator', N'+', 'PMS', N'K', NULL, 0, 0, 0);
            IF @RowCode = N'AB'
                INSERT INTO @Comp VALUES
                    (13, N'Denominator', N'+', 'PMS', N'L',  NULL, 0, 0, 0),
                    (14, N'Denominator', N'+', 'PMS', N'M',  NULL, 0, 0, 0),
                    (15, N'Denominator', N'+', 'PMS', N'N',  NULL, 0, 0, 0),
                    (16, N'Denominator', N'+', 'PMS', N'O1', NULL, 0, 0, 0),
                    (17, N'Denominator', N'+', 'PMS', N'O2', NULL, 0, 0, 0);
            INSERT INTO @Comp VALUES
                (19, N'Denominator', N'=', NULL, NULL,
                     CASE @RowCode WHEN N'AA' THEN N'Paid claims' ELSE N'Adjudicated claims' END, 0, 1, 0),
                (29, N'Result', N'=', 'Avg', @RowCode, NULL, 1, 1, 0);
        END;

        DROP TABLE IF EXISTS #CompV;
        SELECT c.Seq, c.Section, c.Op, c.Category, c.RowCode, c.IsMoney, c.IsTotal,
               COALESCE(c.Label, LTRIM(RTRIM(o.Description))) AS Component,
               CAST(CASE WHEN c.UseCount = 1 THEN o.ClaimCount
                         WHEN o.Category IN ('Cash', 'Avg') THEN o.MetricValue
                         ELSE o.ClaimCount END AS DECIMAL(18,2)) AS Value
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
        IF @RowCode = N'G'
            SELECT @Calc = FORMAT(MAX(CASE WHEN RowCode = N'F' THEN Value END), 'N0') + N' - '
                         + FORMAT(MAX(CASE WHEN RowCode = N'C' THEN Value END), 'N0') + N' = '
                         + FORMAT(@Result, 'N0')
            FROM #CompV;
        ELSE
            SELECT @Calc = N'$' + FORMAT(COALESCE(MAX(CASE WHEN Section = N'Numerator' AND IsTotal = 1 THEN Value END),
                                                  SUM(CASE WHEN Section = N'Numerator' THEN Value END)), 'N2') + N' / '
                         + FORMAT(COALESCE(MAX(CASE WHEN Section = N'Denominator' AND IsTotal = 1 THEN Value END),
                                           SUM(CASE WHEN Section = N'Denominator' THEN Value END)), 'N0')
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
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(500), l.Accession)))  AS SampleID,
            l.Requisition                                       AS RequisitionID,
            p.Dos                                               AS CollectionDate,
            TRY_CAST(l.BilledDate AS DATE)                      AS BilledDate,
            l.NewStatus, l.BillCategory, l.SubStatus,
            l.TestCategory AS Category, l.PanelName, l.ClinicName AS Client, l.DoctorFullName AS ProviderName,
            l.SalesRepName, l.PrimaryInsurance, l.ResultStatus,
            p.PeriodDate
        INTO #L
        FROM dbo.LIMSMaster l
        CROSS APPLY (
            SELECT TRY_CAST(l.RequestCollectDate AS DATE) AS Dos,
                   CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(l.BilledDate AS DATE)
                        ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), l.NewStatus), N''))))    AS NS,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), l.BillCategory), N'')))) AS BC,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), l.SubStatus), N''))))    AS SS,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), l.PanelName), N''))))    AS PN
        ) p
        CROSS APPLY (
            SELECT CASE
                       WHEN p.NS = N'BILLABLE' THEN 'INS'
                       WHEN p.NS IN (N'CLIENT BILL', N'CLIENT BILLS') THEN 'CLIENT'
                       WHEN p.NS = N'REJECTED' THEN 'REJ'
                       WHEN p.NS IN (N'YET TO BE VALIDATED', N'YEST TO BE VALIDATED', N'YET TO BE VALIDATE', N'YET BE VALIDATED') THEN 'YET'
                       WHEN p.NS = N'SYSTEM TEST' THEN 'SYS'
                       WHEN p.NS IN (N'SELF PAY', N'SELFPAY', N'SELF-PAY') THEN 'SELF'
                       WHEN p.NS IN (N'CIP/PENDING', N'CIP / PENDING') THEN 'CIP'
                       ELSE 'OTH' END AS St,
                   CASE
                       WHEN p.BC = N'BILLED' THEN 'B'
                       WHEN p.BC IN (N'UNBILLED', N'NOT BILLED') THEN 'U'
                       ELSE '' END AS Bill,
                   CASE
                       WHEN p.SS = N'READY TO BILL' THEN 'READY'
                       WHEN p.SS = N'MISSING INSURANCE INFO' THEN 'MISSINS'
                       ELSE '' END AS Sub
        ) k
        WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), l.Accession))), N'') IS NOT NULL
          AND p.Dos IS NOT NULL
          AND YEAR(p.Dos) > 1900
          AND p.PeriodDate IS NOT NULL
          AND (@From IS NULL OR p.PeriodDate >= @From)
          AND (@To   IS NULL OR p.PeriodDate <= @To)
          AND (@YearFrom  IS NULL OR YEAR(p.PeriodDate)  >= @YearFrom)
          AND (@YearTo    IS NULL OR YEAR(p.PeriodDate)  <= @YearTo)
          AND (@MonthFrom IS NULL OR MONTH(p.PeriodDate) >= @MonthFrom)
          AND (@MonthTo   IS NULL OR MONTH(p.PeriodDate) <= @MonthTo)
          AND (@Year  = 0 OR YEAR(p.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(p.PeriodDate) = @Month)
          AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.PanelName), N'')))      IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
          AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.ClinicName), N'')))     IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
          AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.DoctorFullName), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
          AND (@HasRep      = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.SalesRepName), N'')))   IN (SELECT Val FROM #Filters WHERE Dim = 'Rep'))
          AND (   @RowCode = N'A'
               OR (@RowCode = N'B'  AND k.St = 'INS')
               OR (@RowCode LIKE N'B[1-9]' AND k.St = 'INS' AND p.PN = @Panel)
               OR (@RowCode = N'C'  AND k.St = 'INS' AND k.Bill = 'B')
               OR (@RowCode = N'D'  AND k.St = 'INS' AND k.Bill = 'U')
               OR (@RowCode = N'D1' AND k.St = 'INS' AND k.Bill = 'U' AND k.Sub = 'READY')
               OR (@RowCode = N'D2' AND k.St = 'INS' AND k.Bill = 'U' AND k.Sub = 'MISSINS')
               OR (@RowCode = N'E'  AND k.St <> 'INS')
               OR (@RowCode = N'E1' AND k.St = 'CLIENT')
               OR (@RowCode = N'E2' AND k.St = 'REJ')
               OR (@RowCode = N'E3' AND k.St = 'YET')
               OR (@RowCode = N'E4' AND k.St = 'SYS')
               OR (@RowCode = N'E5' AND k.St = 'SELF')
               OR (@RowCode = N'E6' AND k.St = 'CIP'))
        OPTION (RECOMPILE);

        SELECT N'dbo.LIMSMaster' AS SourceTable, N'Count of samples' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #L;

        SELECT SampleID, RequisitionID, CollectionDate, BilledDate, NewStatus, BillCategory, SubStatus,
               Category, PanelName, Client, ProviderName, SalesRepName, PrimaryInsurance, ResultStatus
        FROM #L
        ORDER BY PeriodDate, SampleID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- Claim rows (PMS / Cash) ------------------------------------------- */
    ;WITH c AS
    (
        SELECT
            c.ClaimID, c.RecordId, c.AccessionNumber, c.DateofService, c.FirstBilledDate, c.PayerName_Raw, c.Panelname,
            c.ClinicName, c.ReferringProvider, c.SalesRepname, c.BilledStatus, c.ClaimStatus,
            UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.BilledStatus), N'')))) AS BS,
            UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.ClaimStatus), N''))))  AS CS,
            CAST(CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), c.Panelname), N''))))
                           IN (N'TOXICOLOGY', N'BLOOD', N'URINALYSIS', N'WOUND', N'PGX', N'UTI', N'STI', N'RPP', N'GI')
                      THEN UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(500), c.Panelname)))) ELSE N'' END AS NVARCHAR(20)) AS PanelKey,
            CASE WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(1000), c.AccessionNumber))), N'') IS NOT NULL
                      AND ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(CONVERT(NVARCHAR(1000), c.AccessionNumber)))
                                             ORDER BY c.ClaimID, c.RecordId) > 1
                 THEN 1 ELSE 0 END AS IsDup
        FROM dbo.ClaimLevelData c
        WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'') IS NOT NULL
    )
    SELECT
        LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID)))           AS ClaimID,
        LTRIM(RTRIM(CONVERT(NVARCHAR(1000), c.AccessionNumber)))  AS AccessionNumber,
        n.Dos                                                     AS DateofService,
        COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE)) AS FirstBilledDate,
        c.PayerName_Raw, c.Panelname, c.ClinicName, c.ReferringProvider, c.SalesRepname,
        c.BilledStatus, c.ClaimStatus,
        n.ChargeAmount, n.ExpectedPayment, n.InsurancePayment, n.TotalPayments, n.TotalAdjustments,
        n.InsuranceAdjustments, n.PatientBalance, n.InsuranceBalance,
        CASE @AmountCol
            WHEN N'ChargeAmount'         THEN n.ChargeAmount
            WHEN N'ExpectedPayment'      THEN n.ExpectedPayment
            WHEN N'InsurancePayment'     THEN n.InsurancePayment
            WHEN N'TotalPayments'        THEN n.TotalPayments
            WHEN N'TotalAdjustments'     THEN n.TotalAdjustments
            WHEN N'InsuranceAdjustments' THEN n.InsuranceAdjustments
            WHEN N'PatientBalance'       THEN n.PatientBalance
            WHEN N'InsuranceBalance'     THEN n.InsuranceBalance
        END AS Amount,
        n.PeriodDate
    INTO #C
    FROM c
    CROSS APPLY (
        SELECT
            COALESCE(TRY_CONVERT(DATE, c.DateofService, 101), TRY_CAST(c.DateofService AS DATE)) AS Dos,
            CASE WHEN @UseBilledDate = 1
                 THEN COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE))
                 ELSE COALESCE(TRY_CONVERT(DATE, c.DateofService, 101), TRY_CAST(c.DateofService AS DATE)) END AS PeriodDate,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.ChargeAmount))), N'$', N''), N',', N'')), 0)         AS ChargeAmount,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.ExpectedPayment))), N'$', N''), N',', N'')), 0)      AS ExpectedPayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.InsurancePayment))), N'$', N''), N',', N'')), 0)     AS InsurancePayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.TotalPayments))), N'$', N''), N',', N'')), 0)        AS TotalPayments,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.TotalAdjustments))), N'$', N''), N',', N'')), 0)     AS TotalAdjustments,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.InsuranceAdjustments))), N'$', N''), N',', N'')), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.PatientBalance))), N'$', N''), N',', N'')), 0)       AS PatientBalance,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.InsuranceBalance))), N'$', N''), N',', N'')), 0)     AS InsuranceBalance
        FROM dbo.ClaimLevelData x
        WHERE x.RecordId = c.RecordId
    ) n
    WHERE n.Dos IS NOT NULL
      AND YEAR(n.Dos) > 1900
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
      AND (   (@RowCode IN (N'F', N'P', N'Q', N'T', N'U', N'V', N'W', N'X') AND c.BS = N'BILLED')
           OR (@RowCode LIKE N'Q[1-9]' AND c.BS = N'BILLED' AND c.PanelKey = @Panel)
           OR (@RowCode = N'Q10' AND c.BS = N'BILLED' AND c.PanelKey = N'')
           OR (@RowCode = N'H'  AND c.BS = N'BILLED' AND c.IsDup = 1)
           OR (@RowCode = N'I'  AND c.BS = N'UNBILLED')
           OR (@RowCode = N'J'  AND c.CS = N'FULLY PAID')
           OR (@RowCode = N'K'  AND c.CS = N'PARTIALLY PAID')
           OR (@RowCode = N'L'  AND c.CS = N'PATIENT RESPONSIBILITY')
           OR (@RowCode = N'M'  AND c.CS = N'FULLY ADJUSTED')
           OR (@RowCode = N'N'  AND c.CS = N'PARTIALLY ADJUSTED')
           OR (@RowCode = N'O'  AND c.CS IN (N'DENIED', N'FULLY DENIED', N'PARTIALLY DENIED', N'NO RESPONSE'))
           OR (@RowCode = N'O1' AND c.CS IN (N'DENIED', N'FULLY DENIED'))
           OR (@RowCode = N'O2' AND c.CS = N'PARTIALLY DENIED')
           OR (@RowCode = N'O3' AND c.CS = N'NO RESPONSE')
           OR (@RowCode = N'R'  AND c.BS = N'BILLED' AND c.CS = N'FULLY PAID')
           OR (@RowCode = N'S'  AND c.BS = N'BILLED' AND c.CS = N'PARTIALLY PAID')
           OR (@RowCode = N'X1' AND c.BS = N'BILLED' AND c.CS IN (N'DENIED', N'FULLY DENIED'))
           OR (@RowCode = N'X2' AND c.BS = N'BILLED' AND c.CS = N'PARTIALLY DENIED')
           OR (@RowCode = N'X3' AND c.BS = N'BILLED' AND c.CS = N'NO RESPONSE'))
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
               ChargeAmount, ExpectedPayment, InsurancePayment, TotalPayments, TotalAdjustments,
               InsuranceAdjustments, PatientBalance, InsuranceBalance
        FROM #C
        ORDER BY PeriodDate, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
    ELSE
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
               ReferringProvider, SalesRepname, BilledStatus, ClaimStatus, Amount,
               ChargeAmount, ExpectedPayment, InsurancePayment, TotalPayments, TotalAdjustments,
               InsuranceAdjustments, PatientBalance, InsuranceBalance
        FROM #C
        ORDER BY PeriodDate, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
END;
GO

SET NOEXEC OFF;
GO

PRINT '37_TexasDiagnostic_ExecutiveSummary_CellRows.sql completed.';
GO
