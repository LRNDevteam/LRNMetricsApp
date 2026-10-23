/* =============================================================================
   CoreBio - Executive Summary cell rows (value click -> popup grid)
   File     : 37_CoreBio_ExecutiveSummary_CellRows.sql
   Database : CoreBio
   Object   : dbo.usp_GetCB_ExecutiveSummaryCellRows

   Returns the source rows behind one Executive Summary cell, using exactly the
   rules of dbo.usp_CB_ES_Load (source rows, date basis, page filters) and
   dbo.usp_CB_ES_Compute (per-row status rules), so the row count / amount equals
   the clicked value.

   Parameters
     @Category / @RowCode   the clicked row (LIS A..E6, PMS F..O3, Cash P..W3, Avg X..Z)
     @Year / @Month         the clicked column: (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetCB_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText - how the value is calculated
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured column for $ rows)
   Formula rows (PMS H, Cash T, Avg X / Y / Z) return the formula and the calculation in Rules,
   IsFormula = 1, TotalAmount = the result, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal) taken from
   usp_CB_ES_Load + usp_CB_ES_Compute for the same period and filters.
   ============================================================================= */

IF DB_NAME() <> N'CoreBio'
BEGIN
    RAISERROR(N'37_CoreBio_ExecutiveSummary_CellRows.sql must run on CoreBio.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCB_ExecutiveSummaryCellRows
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

    /* ---- Page filters (as usp_CB_ES_Load) ---------------------------------- */
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

    /* ---- Row definitions (as usp_CB_ES_Compute) ---------------------------- */
    DECLARE @Billed NVARCHAR(200) = N'(BillCategory = Billed OR BillingStatus = Billed)';
    DECLARE @Unbilled NVARCHAR(300) = N'(BillCategory IN (Unbilled, Not Billed) OR BillingStatus IN (Unbilled, Not Billed)) and not Billed in either column';
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
        ('LIS', 'C',  N'NewStatus = Billable AND ' + @Billed, NULL, 0),
        ('LIS', 'C1', N'NewStatus = Billable AND ' + @Billed, NULL, 0),
        ('LIS', 'D',  N'NewStatus = Billable AND ' + @Unbilled, NULL, 0),
        ('LIS', 'D1', N'NewStatus = Billable AND ' + @Unbilled + N' AND SubStatus = Entered but not billed', NULL, 0),
        ('LIS', 'D2', N'NewStatus = Billable AND ' + @Unbilled + N' AND SubStatus = Ready to Bill', NULL, 0),
        ('LIS', 'E',  N'NewStatus <> Billable', NULL, 0),
        ('LIS', 'E1', N'NewStatus = Cancelled/Rejected', NULL, 0),
        ('LIS', 'E2', N'NewStatus IN (Client Bill, Client Bills)', NULL, 0),
        ('LIS', 'E3', N'NewStatus IN (Newly Received Claims, Newly Received Samples)', NULL, 0),
        ('LIS', 'E4', N'NewStatus = System Test', NULL, 0),
        ('LIS', 'E5', N'NewStatus = Yet to be validated', NULL, 0),
        ('LIS', 'E6', N'NewStatus = CIP/Pending', NULL, 0),
        ('PMS', 'F',  N'BilledStatus = Billed', NULL, 0),
        ('PMS', 'F1', N'BilledStatus = Billed', NULL, 0),
        ('PMS', 'G',  N'BilledStatus = Unbilled', NULL, 0),
        ('PMS', 'H',  N'Formula: No. of Billed Claims (PMS F) - LIS Billed samples (LIS C), for the same period', NULL, 1),
        ('PMS', 'I',  N'BilledStatus = Billed AND ClaimStatus = Fully Paid', NULL, 0),
        ('PMS', 'J',  N'BilledStatus = Billed AND ClaimStatus = Patient Responsibility', NULL, 0),
        ('PMS', 'K',  N'BilledStatus = Billed AND ClaimStatus = Fully Adjusted', NULL, 0),
        ('PMS', 'L',  N'BilledStatus = Billed AND ClaimStatus = Partially Adjusted', NULL, 0),
        ('PMS', 'M',  N'BilledStatus = Billed AND ClaimStatus = Partially Paid', NULL, 0),
        ('PMS', 'N',  N'BilledStatus = Billed AND ClaimStatus = Patient Payment', NULL, 0),
        ('PMS', 'O',  N'ClaimStatus IN (Denied, Fully Denied, No Response, Partially Denied)', NULL, 0),
        ('PMS', 'O1', N'ClaimStatus IN (Denied, Fully Denied)', NULL, 0),
        ('PMS', 'O2', N'ClaimStatus = Partially Denied', NULL, 0),
        ('PMS', 'O3', N'ClaimStatus = No Response', NULL, 0),
        ('Cash', 'P',  N'BilledStatus = Billed', N'ChargeAmount', 0),
        ('Cash', 'P1', N'BilledStatus = Billed', N'ChargeAmount', 0),
        ('Cash', 'Q',  N'BilledStatus = Unbilled', N'ChargeAmount', 0),
        ('Cash', 'R',  N'BilledStatus = Billed AND ClaimStatus = Fully Paid', N'InsurancePayment', 0),
        ('Cash', 'S',  N'BilledStatus = Billed', N'PatientBalance', 0),
        ('Cash', 'T',  N'Formula: Total Billed ($) - Insurance Payment ($) - Partially Paid ($) - Patient Paid ($) - Insurance Balance ($) - Patient Responsibility ($)', NULL, 1),
        ('Cash', 'U',  N'BilledStatus = Billed AND ClaimStatus = Partially Paid', N'InsurancePayment', 0),
        ('Cash', 'V',  N'BilledStatus = Billed', N'PatientPayment', 0),
        ('Cash', 'W',  N'BilledStatus IN (Billed, Billed - Self Pay)', N'InsuranceBalance', 0),
        ('Cash', 'W1', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus IN (Denied, Fully Denied)', N'InsuranceBalance', 0),
        ('Cash', 'W2', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus NOT IN (Denied, Fully Denied, No Response)', N'InsuranceBalance', 0),
        ('Cash', 'W3', N'BilledStatus IN (Billed, Billed - Self Pay) AND ClaimStatus = No Response', N'InsuranceBalance', 0),
        ('Avg', 'X',  N'Formula: (Insurance Payment $ + Patient Paid $) / No. of Billed Claims (PMS F)', NULL, 1),
        ('Avg', 'Y',  N'Formula: (Insurance Payment $ + Partially Paid $) / (Fully Paid + Partially Paid claims)', NULL, 1),
        ('Avg', 'Z',  N'Formula: (Insurance Payment $ + Partially Paid $) / (Fully Paid + Partially Paid + Patient Responsibility + Adjusted + Partially Adjusted + Patient Paid + Fully Denied + Partially Denied claims)', NULL, 1);

    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @IsFormula BIT;
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @IsFormula = IsFormula
    FROM @Def WHERE Category = @Category AND RowCode = @RowCode;

    IF @RuleText IS NULL
    BEGIN
        RAISERROR(N'usp_GetCB_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCode);
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
    SELECT N'Base filter', N'RequestCollectDate / DateofService is a valid date'
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
            St VARCHAR(10) NOT NULL, Bill CHAR(1) NOT NULL, Sub VARCHAR(10) NOT NULL,
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
            InsuranceBalance DECIMAL(18,2) NOT NULL
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

        EXEC dbo.usp_CB_ES_Load
            @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
            @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
            @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;
        EXEC dbo.usp_CB_ES_Compute;

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
        ELSE IF @RowCode = N'T'
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'Cash', N'P', NULL, 1, 0),
                (2, N'Calculation', N'-', 'Cash', N'R', NULL, 1, 0),
                (3, N'Calculation', N'-', 'Cash', N'U', NULL, 1, 0),
                (4, N'Calculation', N'-', 'Cash', N'V', NULL, 1, 0),
                (5, N'Calculation', N'-', 'Cash', N'W', NULL, 1, 0),
                (6, N'Calculation', N'-', 'Cash', N'S', NULL, 1, 0),
                (9, N'Result',      N'=', 'Cash', N'T', NULL, 1, 1);
        ELSE
        BEGIN
            IF @RowCode = N'X'
                INSERT INTO @Comp VALUES
                    (1, N'Numerator', N'',  'Cash', N'R', NULL, 1, 0),
                    (2, N'Numerator', N'+', 'Cash', N'V', NULL, 1, 0);
            ELSE
                INSERT INTO @Comp VALUES
                    (1, N'Numerator', N'',  'Cash', N'R', NULL, 1, 0),
                    (2, N'Numerator', N'+', 'Cash', N'U', NULL, 1, 0);
            INSERT INTO @Comp VALUES (4, N'Numerator', N'=', NULL, NULL, N'Total Payments ($)', 1, 1);
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
        ELSE IF @RowCode = N'T'
            SELECT @Calc = STRING_AGG(CASE WHEN Op = N'' THEN N'' ELSE Op + N' ' END + N'$' + FORMAT(Value, 'N2'), N' ')
                               WITHIN GROUP (ORDER BY Seq)
                         + N' = $' + FORMAT(@Result, 'N2')
            FROM #CompV
            WHERE Section = N'Calculation';
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

    /* ---- LIS rows ----------------------------------------------------------- */
    IF @IsLis = 1
    BEGIN
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(200), l.Accession)))  AS Accession,
            p.Dos                                               AS RequestCollectDate,
            TRY_CAST(l.BilledDate AS DATE)                      AS BilledDate,
            l.NewStatus, l.BillCategory, l.BillingStatus, l.SubStatus,
            l.TestCategory, l.ClinicName, l.DoctorFullName, l.PrimaryInsurance, l.ResultStatus,
            p.PeriodDate
        INTO #L
        FROM dbo.LIMSMaster l
        CROSS APPLY (
            SELECT TRY_CAST(l.RequestCollectDate AS DATE) AS Dos,
                   CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(l.BilledDate AS DATE)
                        ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.NewStatus), N''))))     AS NS,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.BillCategory), N'')))) AS BC,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.BillingStatus), N''))))AS BS,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.SubStatus), N''))))    AS SS
        ) p
        CROSS APPLY (
            SELECT CASE
                       WHEN p.NS = N'BILLABLE' THEN 'INS'
                       WHEN p.NS IN (N'CANCELLED/REJECTED', N'CANCELED/REJECTED') THEN 'CAN'
                       WHEN p.NS IN (N'CLIENT BILL', N'CLIENT BILLS') THEN 'CLIENT'
                       WHEN p.NS IN (N'NEWLY RECEIVED CLAIMS', N'NEWLY RECEIVED SAMPLES') THEN 'NEW'
                       WHEN p.NS = N'SYSTEM TEST' THEN 'SYS'
                       WHEN p.NS IN (N'YET TO BE VALIDATED', N'YEST TO BE VALIDATED', N'YET TO BE VALIDATE', N'YET BE VALIDATED') THEN 'YET'
                       WHEN p.NS IN (N'CIP/PENDING', N'CIP / PENDING') THEN 'CIP'
                       ELSE 'OTH' END AS St,
                   CASE
                       WHEN p.BC = N'BILLED' OR p.BS = N'BILLED' THEN 'B'
                       WHEN p.BC IN (N'UNBILLED', N'NOT BILLED') OR p.BS IN (N'UNBILLED', N'NOT BILLED') THEN 'U'
                       ELSE '' END AS Bill,
                   CASE
                       WHEN p.SS = N'ENTERED BUT NOT BILLED' THEN 'ENTERED'
                       WHEN p.SS = N'READY TO BILL' THEN 'READY'
                       ELSE '' END AS Sub
        ) k
        WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), l.Accession))), N'') IS NOT NULL
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
          AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.TestCategory), N'')))   IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
          AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.ClinicName), N'')))     IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
          AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.DoctorFullName), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
          AND (   @RowCode = N'A'
               OR (@RowCode = N'B'  AND k.St = 'INS')
               OR (@RowCode IN (N'C', N'C1') AND k.St = 'INS' AND k.Bill = 'B')
               OR (@RowCode = N'D'  AND k.St = 'INS' AND k.Bill = 'U')
               OR (@RowCode = N'D1' AND k.St = 'INS' AND k.Bill = 'U' AND k.Sub = 'ENTERED')
               OR (@RowCode = N'D2' AND k.St = 'INS' AND k.Bill = 'U' AND k.Sub = 'READY')
               OR (@RowCode = N'E'  AND k.St <> 'INS')
               OR (@RowCode = N'E1' AND k.St = 'CAN')
               OR (@RowCode = N'E2' AND k.St = 'CLIENT')
               OR (@RowCode = N'E3' AND k.St = 'NEW')
               OR (@RowCode = N'E4' AND k.St = 'SYS')
               OR (@RowCode = N'E5' AND k.St = 'YET')
               OR (@RowCode = N'E6' AND k.St = 'CIP'))
        OPTION (RECOMPILE);

        SELECT N'dbo.LIMSMaster' AS SourceTable, N'Count of samples' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #L;

        SELECT Accession, RequestCollectDate, BilledDate, NewStatus, BillCategory, BillingStatus, SubStatus,
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
        n.ChargeAmount, n.InsurancePayment, n.PatientPayment, n.PatientBalance, n.InsuranceBalance,
        CASE @AmountCol
            WHEN N'ChargeAmount'     THEN n.ChargeAmount
            WHEN N'InsurancePayment' THEN n.InsurancePayment
            WHEN N'PatientPayment'   THEN n.PatientPayment
            WHEN N'PatientBalance'   THEN n.PatientBalance
            WHEN N'InsuranceBalance' THEN n.InsuranceBalance
        END AS Amount,
        n.PeriodDate
    INTO #C
    FROM dbo.ClaimLevelData c
    CROSS APPLY (
        SELECT
            UPPER(LTRIM(RTRIM(REPLACE(REPLACE(ISNULL(CONVERT(NVARCHAR(200), c.BilledStatus), N''), N'  ', N' '), N'  ', N' ')))) AS BS,
            UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.ClaimStatus), N'')))) AS CS,
            TRY_CAST(c.DateofService AS DATE) AS Dos,
            CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(c.FirstBilledDate AS DATE)
                 ELSE TRY_CAST(c.DateofService AS DATE) END AS PeriodDate,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.ChargeAmount))), N'$', N''), N',', N'')), 0) AS ChargeAmount,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsurancePayment))), N'$', N''), N',', N'')), 0) AS InsurancePayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientPayment))), N'$', N''), N',', N'')), 0) AS PatientPayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientBalance))), N'$', N''), N',', N'')), 0) AS PatientBalance,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceBalance))), N'$', N''), N',', N'')), 0) AS InsuranceBalance
    ) n
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'') IS NOT NULL
      AND n.Dos IS NOT NULL
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
      AND (   (@RowCode IN (N'F', N'F1', N'P', N'P1', N'S', N'V') AND n.BS = N'BILLED')
           OR (@RowCode IN (N'G', N'Q') AND n.BS = N'UNBILLED')
           OR (@RowCode IN (N'I', N'R') AND n.BS = N'BILLED' AND n.CS = N'FULLY PAID')
           OR (@RowCode = N'J'  AND n.BS = N'BILLED' AND n.CS = N'PATIENT RESPONSIBILITY')
           OR (@RowCode = N'K'  AND n.BS = N'BILLED' AND n.CS = N'FULLY ADJUSTED')
           OR (@RowCode = N'L'  AND n.BS = N'BILLED' AND n.CS = N'PARTIALLY ADJUSTED')
           OR (@RowCode IN (N'M', N'U') AND n.BS = N'BILLED' AND n.CS = N'PARTIALLY PAID')
           OR (@RowCode = N'N'  AND n.BS = N'BILLED' AND n.CS = N'PATIENT PAYMENT')
           OR (@RowCode = N'O'  AND n.CS IN (N'DENIED', N'FULLY DENIED', N'NO RESPONSE', N'PARTIALLY DENIED'))
           OR (@RowCode = N'O1' AND n.CS IN (N'DENIED', N'FULLY DENIED'))
           OR (@RowCode = N'O2' AND n.CS = N'PARTIALLY DENIED')
           OR (@RowCode = N'O3' AND n.CS = N'NO RESPONSE')
           OR (@RowCode = N'W'  AND n.BS IN (N'BILLED', N'BILLED - SELF PAY'))
           OR (@RowCode = N'W1' AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS IN (N'DENIED', N'FULLY DENIED'))
           OR (@RowCode = N'W2' AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS NOT IN (N'DENIED', N'FULLY DENIED', N'NO RESPONSE'))
           OR (@RowCode = N'W3' AND n.BS IN (N'BILLED', N'BILLED - SELF PAY') AND n.CS = N'NO RESPONSE'))
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
               ChargeAmount, InsurancePayment, PatientPayment, PatientBalance, InsuranceBalance
        FROM #C
        ORDER BY PeriodDate, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
    ELSE
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
               ReferringProvider, SalesRepname, BilledStatus, ClaimStatus, Amount,
               ChargeAmount, InsurancePayment, PatientPayment, PatientBalance, InsuranceBalance
        FROM #C
        ORDER BY PeriodDate, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
END;
GO

SET NOEXEC OFF;
GO

PRINT '37_CoreBio_ExecutiveSummary_CellRows.sql completed.';
GO
