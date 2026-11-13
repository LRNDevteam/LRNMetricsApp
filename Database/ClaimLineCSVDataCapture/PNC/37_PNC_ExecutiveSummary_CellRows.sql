/* =============================================================================
   PNC - Executive Summary cell rows (value click -> popup grid)
   File     : 37_PNC_ExecutiveSummary_CellRows.sql
   Database : PNC
   Object   : dbo.usp_GetPNC_ExecutiveSummaryCellRows
   Requires : 36_PNC_ExecutiveSummary.sql

   Returns the source rows behind one Executive Summary cell, using exactly the
   rules of dbo.usp_PNC_ES_Load (source rows, date basis, page filters) and
   dbo.usp_PNC_ES_Compute (per-row rules), so the row count / amount equals the
   clicked value. Keep the two files in step when a row rule changes.

   Parameters
     @Category / @RowCode   the clicked row (LIS A..E7, PMS F..O3, Cash P..W3, Avg AK..AM) or a
                            dynamic panel row: LIS B.{PANEL} ({PANEL} = UPPER(TRIM(panel name)))
     @Year / @Month         the clicked column: (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetPNC_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText - how the value is calculated, incl. page filters
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured column for $ rows)
   Formula rows (PMS G, Cash S, Avg AK / AL / AM) return the formula and the calculation in Rules,
   IsFormula = 1, TotalAmount = the result, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal) taken from
   usp_PNC_ES_Load + usp_PNC_ES_Compute for the same period and filters.
   ============================================================================= */

IF DB_NAME() <> N'PNC'
BEGIN
    RAISERROR(N'37_PNC_ExecutiveSummary_CellRows.sql must run on PNC.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_ExecutiveSummaryCellRows
(
    @Category   VARCHAR(10),
    @RowCode    NVARCHAR(420),
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

    /* ---- Page filters (as usp_PNC_ES_Load) --------------------------------- */
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

    /* ---- Row definitions (as usp_PNC_ES_Compute) --------------------------- */
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
        ('LIS', 'C1', N'NewStatus = Billable AND BillCategory = Billed AND SubStatus = Claim Submitted in Historical Lab', NULL, 0),
        ('LIS', 'C2', N'NewStatus = Billable AND BillCategory = Billed AND SubStatus = Claim Submitted in PNC Lab', NULL, 0),
        ('LIS', 'D',  N'NewStatus = Billable AND BillCategory = Unbilled', NULL, 0),
        ('LIS', 'D1', N'NewStatus = Billable AND BillCategory = Unbilled AND SubStatus = Ready to Bill', NULL, 0),
        ('LIS', 'D2', N'NewStatus = Billable AND BillCategory = Unbilled AND SubStatus IN (No Insurance Info, Missing Insurance Info)', NULL, 0),
        ('LIS', 'E',  N'NewStatus <> Billable', NULL, 0),
        ('LIS', 'E1', N'NewStatus = Deleted / Rejected', NULL, 0),
        ('LIS', 'E2', N'NewStatus = Client Bill', NULL, 0),
        ('LIS', 'E3', N'NewStatus = System Test', NULL, 0),
        ('LIS', 'E4', N'NewStatus = Self Pay', NULL, 0),
        ('LIS', 'E5', N'NewStatus = Missing Accession', NULL, 0),
        ('LIS', 'E6', N'NewStatus = Yet to be Validated', NULL, 0),
        ('LIS', 'E7', N'NewStatus = Duplicate (Dublicate)', NULL, 0),
        ('PMS', 'F',  N'ClaimStatus NOT IN (Unbilled, Unbilled - Patient Balance)', NULL, 0),
        ('PMS', 'G',  N'Formula: No. of Billed Claims (PMS F) - LIS Billed samples (LIS C), for the same period', NULL, 1),
        ('PMS', 'I',  N'ClaimStatus IN (Unbilled, Unbilled - Patient Balance)', NULL, 0),
        ('PMS', 'J',  N'ClaimStatus = Fully Paid', NULL, 0),
        ('PMS', 'K',  N'ClaimStatus = Partially Paid', NULL, 0),
        ('PMS', 'L',  N'ClaimStatus = Pat Responsibility (Patient Responsibility)', NULL, 0),
        ('PMS', 'M',  N'ClaimStatus = Fully Adjusted', NULL, 0),
        ('PMS', 'MP', N'ClaimStatus = Partially Adjusted', NULL, 0),
        ('PMS', 'N',  N'ClaimStatus = Patient Payment', NULL, 0),
        ('PMS', 'O',  N'ClaimStatus IN (Fully Denied, Partially Denied, No Response) (O1 + O2 + O3)', NULL, 0),
        ('PMS', 'O1', N'ClaimStatus = Fully Denied', NULL, 0),
        ('PMS', 'O2', N'ClaimStatus = Partially Denied', NULL, 0),
        ('PMS', 'O3', N'ClaimStatus = No Response', NULL, 0),
        ('Cash', 'P',   N'ClaimStatus NOT IN (Unbilled, Unbilled - Patient Balance)', N'ChargeAmount', 0),
        ('Cash', 'Q',   N'ClaimStatus = Fully Paid', N'InsurancePayment', 0),
        ('Cash', 'R',   N'ClaimStatus = Partially Paid', N'InsurancePayment', 0),
        ('Cash', 'RP',  N'FirstBilledDate is a valid date', N'PatientPayment', 0),
        ('Cash', 'S',   N'Formula: Insurance Payment $ (Cash Q) + Partially Paid $ (Cash R) + Patient Paid $ (Cash RP)', NULL, 1),
        ('Cash', 'T',   N'ClaimStatus = Fully Adjusted', N'InsuranceAdjustments', 0),
        ('Cash', 'U',   N'ClaimStatus NOT IN (Fully Adjusted, Unbilled, Unbilled - Patient Balance)', N'InsuranceAdjustments', 0),
        ('Cash', 'V',   N'ClaimStatus NOT IN (Unbilled, Unbilled - Patient Balance)', N'PatientBalance', 0),
        ('Cash', 'W',   N'W1 + W2 + W3: ClaimStatus IN (Fully Denied, Partially Adjusted, Partially Paid, Partially Denied, No Response)', N'InsuranceBalance', 0),
        ('Cash', 'W1',  N'ClaimStatus = Fully Denied', N'InsuranceBalance', 0),
        ('Cash', 'W2',  N'ClaimStatus IN (Partially Adjusted, Partially Paid, Partially Denied)', N'InsuranceBalance', 0),
        ('Cash', 'W3',  N'ClaimStatus = No Response', N'InsuranceBalance', 0),
        ('Avg', 'AK',  N'Formula: Total Payments $ (Cash S) / No. of Billed Claims (PMS F)', NULL, 1),
        ('Avg', 'AL',  N'Formula: Insurance Payment $ (Cash Q) / No. of Fully Paid Claims (PMS J)', NULL, 1),
        ('Avg', 'AM',  N'Formula: Total Payments $ (Cash S) / (No. of Billed Claims (PMS F) - No Response claims (PMS O3))', NULL, 1);

    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @IsFormula BIT, @Panel NVARCHAR(300);
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @IsFormula = IsFormula
    FROM @Def WHERE Category = @Category AND RowCode = @RowCode;

    -- Dynamic panel rows (usp_PNC_ES_Compute): B.{PANEL}.
    IF @RuleText IS NULL AND @Category = 'LIS' AND LEFT(@RowCode, 2) = N'B.' AND LEN(@RowCode) > 2
    BEGIN
        SET @Panel = SUBSTRING(@RowCode, 3, 300);
        DECLARE @PanelText NVARCHAR(300) = COALESCE(
            (SELECT TOP (1) LTRIM(RTRIM(CONVERT(NVARCHAR(300), PanelName))) FROM dbo.LIMSMaster
             WHERE UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), PanelName), N'')))) = @Panel),
            @Panel);
        SELECT @IsFormula = 0, @AmountCol = NULL,
               @RuleText = N'NewStatus = Billable AND PanelName = ' + @PanelText;
    END;

    IF @RuleText IS NULL
    BEGIN
        RAISERROR(N'usp_GetPNC_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCode);
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
            Panel NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
            PanelLabel NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
            Cnt INT NOT NULL
        );
        CREATE TABLE #EsClaims
        (
            ESYear INT NOT NULL, ESMonth INT NOT NULL,
            IsBilled BIT NOT NULL,
            ClaimStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
            ClaimCnt INT NOT NULL,
            ChargeAmount DECIMAL(18,2) NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL,
            PatientPaymentBilled DECIMAL(18,2) NOT NULL, InsuranceAdjustments DECIMAL(18,2) NOT NULL,
            PatientBalance DECIMAL(18,2) NOT NULL, InsuranceBalance DECIMAL(18,2) NOT NULL
        );
        CREATE TABLE #EsOut
        (
            Category VARCHAR(10) NOT NULL,
            RowCode NVARCHAR(320) COLLATE DATABASE_DEFAULT NOT NULL,
            Description NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
            SortOrder INT NOT NULL,
            ESYear INT NOT NULL, ESMonth INT NOT NULL,
            MetricValue DECIMAL(18,2) NOT NULL,
            ClaimCount INT NOT NULL
        );

        EXEC dbo.usp_PNC_ES_Load
            @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
            @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
            @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;
        EXEC dbo.usp_PNC_ES_Compute;

        DECLARE @Comp TABLE
        (
            Seq INT NOT NULL, Section NVARCHAR(20) NOT NULL, Op NVARCHAR(4) NOT NULL,
            Category VARCHAR(10) NULL, RowCode NVARCHAR(320) NULL, Label NVARCHAR(400) NULL,
            IsMoney BIT NOT NULL, IsTotal BIT NOT NULL
        );

        IF @RowCode = N'G'
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'PMS', N'F', NULL, 0, 0),
                (2, N'Calculation', N'-', 'LIS', N'C', NULL, 0, 0),
                (9, N'Result',      N'=', 'PMS', N'G', NULL, 0, 1);
        ELSE IF @RowCode = N'S'
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'Cash', N'Q',  NULL, 1, 0),
                (2, N'Calculation', N'+', 'Cash', N'R',  NULL, 1, 0),
                (3, N'Calculation', N'+', 'Cash', N'RP', NULL, 1, 0),
                (9, N'Result',      N'=', 'Cash', N'S',  NULL, 1, 1);
        ELSE IF @RowCode = N'AK'
            INSERT INTO @Comp VALUES
                (1,  N'Numerator',   N'',  'Cash', N'S',  NULL, 1, 0),
                (11, N'Denominator', N'',  'PMS',  N'F',  NULL, 0, 0),
                (29, N'Result',      N'=', 'Avg',  N'AK', NULL, 1, 1);
        ELSE IF @RowCode = N'AL'
            INSERT INTO @Comp VALUES
                (1,  N'Numerator',   N'',  'Cash', N'Q',  NULL, 1, 0),
                (11, N'Denominator', N'',  'PMS',  N'J',  NULL, 0, 0),
                (29, N'Result',      N'=', 'Avg',  N'AL', NULL, 1, 1);
        ELSE
            INSERT INTO @Comp VALUES
                (1,  N'Numerator',   N'',  'Cash', N'S',  NULL, 1, 0),
                (11, N'Denominator', N'',  'PMS',  N'F',  NULL, 0, 0),
                (12, N'Denominator', N'-', 'PMS',  N'O3', NULL, 0, 0),
                (19, N'Denominator', N'=', NULL, NULL, N'Adjudicated claims', 0, 1),
                (29, N'Result',      N'=', 'Avg',  N'AM', NULL, 1, 1);

        DROP TABLE IF EXISTS #CompV;
        SELECT c.Seq, c.Section, c.Op, c.Category, c.RowCode, c.IsMoney, c.IsTotal,
               COALESCE(c.Label, LTRIM(RTRIM(o.Description))) AS Component,
               CAST(CASE WHEN o.Category IN ('Cash', 'Avg') THEN o.MetricValue
                         ELSE o.ClaimCount END AS DECIMAL(18,2)) AS Value
        INTO #CompV
        FROM @Comp c
        LEFT JOIN #EsOut o ON o.Category = c.Category AND o.RowCode = c.RowCode
                          AND o.ESYear = @Year AND o.ESMonth = @Month;

        -- Subtotal lines = signed sum of their section's components.
        UPDATE t SET Value = s.Total
        FROM #CompV t
        CROSS APPLY (SELECT SUM(CASE WHEN x.Op = N'-' THEN -ISNULL(x.Value, 0) ELSE ISNULL(x.Value, 0) END) AS Total
                     FROM #CompV x
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
        ELSE IF @RowCode = N'S'
            SELECT @Calc = N'$' + FORMAT(MAX(CASE WHEN RowCode = N'Q' THEN Value END), 'N2') + N' + $'
                         + FORMAT(MAX(CASE WHEN RowCode = N'R' THEN Value END), 'N2') + N' + $'
                         + FORMAT(MAX(CASE WHEN RowCode = N'RP' THEN Value END), 'N2') + N' = $'
                         + FORMAT(@Result, 'N2')
            FROM #CompV;
        ELSE
            SELECT @Calc = N'$' + FORMAT(SUM(CASE WHEN Section = N'Numerator' THEN Value END), 'N2') + N' / '
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

    DECLARE @Skip INT = CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END;
    DECLARE @Take INT = CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END;
    DECLARE @Extra NVARCHAR(MAX), @Sql NVARCHAR(MAX);

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
            p.PeriodDate,
            l.%%physloc%% AS EsRowLoc   -- LIMSMaster has no unique key
        INTO #L
        FROM dbo.LIMSMaster l
        CROSS APPLY (
            SELECT TRY_CAST(l.RequestCollectDate AS DATE) AS Dos,
                   CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(l.BilledDate AS DATE)
                        ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate,
                   UPPER(REPLACE(REPLACE(ISNULL(CONVERT(NVARCHAR(255), l.NewStatus), N''), N' ', N''), N'-', N'')) AS NS,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), l.BillCategory), N'')))) AS BC,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), l.SubStatus), N''))))    AS SS,
                   UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), l.PanelName), N''))))    AS PN
        ) p
        CROSS APPLY (
            SELECT CASE
                       WHEN p.NS = N'BILLABLE' THEN 'INS'
                       WHEN p.NS IN (N'DELETED/REJECTED', N'REJECTED/DELETED') THEN 'DELREJ'
                       WHEN p.NS IN (N'CLIENTBILL', N'CLIENTBILLS') THEN 'CLIENT'
                       WHEN p.NS = N'SYSTEMTEST' THEN 'SYS'
                       WHEN p.NS = N'SELFPAY' THEN 'SELF'
                       WHEN p.NS = N'MISSINGACCESSION' THEN 'MISSACC'
                       WHEN p.NS IN (N'YETTOBEVALIDATED', N'YESTTOBEVALIDATED', N'YETTOBEVALIDATE', N'YETBEVALIDATED') THEN 'YET'
                       WHEN p.NS IN (N'DUPLICATE', N'DUBLICATE') THEN 'DUP'
                       ELSE 'OTH' END AS St,
                   CASE
                       WHEN p.BC = N'BILLED' THEN 'B'
                       WHEN p.BC IN (N'UNBILLED', N'NOT BILLED') THEN 'U'
                       ELSE '' END AS Bill,
                   CASE
                       WHEN p.SS = N'CLAIM SUBMITTED IN HISTORICAL LAB' THEN 'HIST'
                       WHEN p.SS = N'CLAIM SUBMITTED IN PNC LAB' THEN 'PNCLAB'
                       WHEN p.SS = N'READY TO BILL' THEN 'READY'
                       WHEN p.SS IN (N'NO INSURANCE INFO', N'MISSING INSURANCE INFO') THEN 'MISSINS'
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
               OR (LEFT(@RowCode, 2) = N'B.' AND k.St = 'INS' AND p.PN = @Panel)
               OR (@RowCode = N'C'  AND k.St = 'INS' AND k.Bill = 'B')
               OR (@RowCode = N'C1' AND k.St = 'INS' AND k.Bill = 'B' AND k.Sub = 'HIST')
               OR (@RowCode = N'C2' AND k.St = 'INS' AND k.Bill = 'B' AND k.Sub = 'PNCLAB')
               OR (@RowCode = N'D'  AND k.St = 'INS' AND k.Bill = 'U')
               OR (@RowCode = N'D1' AND k.St = 'INS' AND k.Bill = 'U' AND k.Sub = 'READY')
               OR (@RowCode = N'D2' AND k.St = 'INS' AND k.Bill = 'U' AND k.Sub = 'MISSINS')
               OR (@RowCode = N'E'  AND k.St <> 'INS')
               OR (@RowCode = N'E1' AND k.St = 'DELREJ')
               OR (@RowCode = N'E2' AND k.St = 'CLIENT')
               OR (@RowCode = N'E3' AND k.St = 'SYS')
               OR (@RowCode = N'E4' AND k.St = 'SELF')
               OR (@RowCode = N'E5' AND k.St = 'MISSACC')
               OR (@RowCode = N'E6' AND k.St = 'YET')
               OR (@RowCode = N'E7' AND k.St = 'DUP'))
        OPTION (RECOMPILE);

        SELECT N'dbo.LIMSMaster' AS SourceTable, N'Count of samples' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #L;

        -- Source columns already shown above (some under another name) are not repeated.
        SELECT @Extra = STRING_AGG(CAST(N's.' + QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.column_id)
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.LIMSMaster')
          AND c.name NOT IN (N'Accession', N'Requisition', N'RequestCollectDate', N'BilledDate', N'NewStatus', N'BillCategory',
                             N'SubStatus', N'TestCategory', N'PanelName', N'ClinicName', N'DoctorFullName', N'SalesRepName',
                             N'PrimaryInsurance', N'ResultStatus');

        SET @Sql = N'SELECT p.SampleID, p.RequisitionID, p.CollectionDate, p.BilledDate, p.NewStatus, p.BillCategory, p.SubStatus,
               p.Category, p.PanelName, p.Client, p.ProviderName, p.SalesRepName, p.PrimaryInsurance, p.ResultStatus'
             + ISNULL(N', ' + @Extra, N'') + N'
        FROM (SELECT * FROM #L ORDER BY PeriodDate, SampleID OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY) p
        JOIN dbo.LIMSMaster s ON s.%%physloc%% = p.EsRowLoc
        ORDER BY p.PeriodDate, p.SampleID
        OPTION (HASH JOIN);';
        EXEC sys.sp_executesql @Sql, N'@Skip INT, @Take INT', @Skip = @Skip, @Take = @Take;
        RETURN;
    END;

    /* ---- Claim rows (PMS / Cash) ------------------------------------------- */
    ;WITH c AS
    (
        SELECT
            c.ClaimID, c.RecordId, c.AccessionNumber, c.DateofService, c.FirstBilledDate, c.PayerName_Raw, c.Panelname,
            c.ClinicName, c.ReferringProvider, c.SalesRepname, c.BilledStatus, c.ClaimStatus,
            UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.ClaimStatus), N''))))  AS CS,
            CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.ClaimStatus), N''))))
                      IN (N'UNBILLED', N'UNBILLED - PATIENT BALANCE') THEN 0 ELSE 1 END AS IsBilled
        FROM dbo.ClaimLevelData c
        WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'') IS NOT NULL
    )
    SELECT
        LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID)))           AS ClaimID,
        LTRIM(RTRIM(CONVERT(NVARCHAR(1000), c.AccessionNumber)))  AS AccessionNumber,
        n.Dos                                                     AS DateofService,
        n.FirstBill                                               AS FirstBilledDate,
        c.PayerName_Raw, c.Panelname, c.ClinicName, c.ReferringProvider, c.SalesRepname,
        c.BilledStatus, c.ClaimStatus,
        n.ChargeAmount, n.InsurancePayment, n.PatientPayment, n.TotalPayments,
        n.InsuranceAdjustments, n.TotalAdjustments, n.PatientBalance, n.InsuranceBalance, n.TotalBalance,
        CASE @AmountCol
            WHEN N'ChargeAmount'         THEN n.ChargeAmount
            WHEN N'InsurancePayment'     THEN n.InsurancePayment
            WHEN N'PatientPayment'       THEN n.PatientPayment
            WHEN N'InsuranceAdjustments' THEN n.InsuranceAdjustments
            WHEN N'PatientBalance'       THEN n.PatientBalance
            WHEN N'InsuranceBalance'     THEN n.InsuranceBalance
        END AS Amount,
        n.PeriodDate,
        c.RecordId AS EsRecordId
    INTO #C
    FROM c
    CROSS APPLY (
        SELECT
            COALESCE(TRY_CONVERT(DATE, x.DateofService, 101), TRY_CAST(x.DateofService AS DATE)) AS Dos,
            COALESCE(TRY_CONVERT(DATE, x.FirstBilledDate, 101), TRY_CAST(x.FirstBilledDate AS DATE)) AS FirstBill,
            CASE WHEN @UseBilledDate = 1
                 THEN COALESCE(TRY_CONVERT(DATE, x.FirstBilledDate, 101), TRY_CAST(x.FirstBilledDate AS DATE))
                 ELSE COALESCE(TRY_CONVERT(DATE, x.DateofService, 101), TRY_CAST(x.DateofService AS DATE)) END AS PeriodDate,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.ChargeAmount))), N'$', N''), N',', N'')), 0)         AS ChargeAmount,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.InsurancePayment))), N'$', N''), N',', N'')), 0)     AS InsurancePayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.PatientPayment))), N'$', N''), N',', N'')), 0)       AS PatientPayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.TotalPayments))), N'$', N''), N',', N'')), 0)        AS TotalPayments,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.InsuranceAdjustments))), N'$', N''), N',', N'')), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.TotalAdjustments))), N'$', N''), N',', N'')), 0)     AS TotalAdjustments,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.PatientBalance))), N'$', N''), N',', N'')), 0)       AS PatientBalance,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.InsuranceBalance))), N'$', N''), N',', N'')), 0)     AS InsuranceBalance,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), x.TotalBalance))), N'$', N''), N',', N'')), 0)         AS TotalBalance
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
      AND (   (@RowCode IN (N'F', N'P', N'V') AND c.IsBilled = 1)
           OR (@RowCode = N'I'  AND c.IsBilled = 0)
           OR (@RowCode IN (N'J', N'Q') AND c.CS = N'FULLY PAID')
           OR (@RowCode IN (N'K', N'R') AND c.CS = N'PARTIALLY PAID')
           OR (@RowCode = N'RP' AND n.FirstBill IS NOT NULL)
           OR (@RowCode = N'L'  AND c.CS IN (N'PAT RESPONSIBILITY', N'PATIENT RESPONSIBILITY'))
           OR (@RowCode IN (N'M', N'T') AND c.CS = N'FULLY ADJUSTED')
           OR (@RowCode = N'MP' AND c.CS = N'PARTIALLY ADJUSTED')
           OR (@RowCode = N'N'  AND c.CS = N'PATIENT PAYMENT')
           OR (@RowCode = N'O'  AND c.CS IN (N'FULLY DENIED', N'PARTIALLY DENIED', N'NO RESPONSE'))
           OR (@RowCode IN (N'O1', N'W1') AND c.CS = N'FULLY DENIED')
           OR (@RowCode = N'O2' AND c.CS = N'PARTIALLY DENIED')
           OR (@RowCode IN (N'O3', N'W3') AND c.CS = N'NO RESPONSE')
           OR (@RowCode = N'U'  AND c.IsBilled = 1 AND c.CS <> N'FULLY ADJUSTED')
           OR (@RowCode = N'W'  AND c.CS IN (N'FULLY DENIED', N'PARTIALLY ADJUSTED', N'PARTIALLY PAID',
                                             N'PARTIALLY DENIED', N'NO RESPONSE'))
           OR (@RowCode = N'W2' AND c.CS IN (N'PARTIALLY ADJUSTED', N'PARTIALLY PAID', N'PARTIALLY DENIED')))
    OPTION (RECOMPILE);

    SELECT N'dbo.ClaimLevelData' AS SourceTable,
           CASE WHEN @AmountCol IS NULL THEN N'Count of claims' ELSE N'Sum of ' + @AmountCol END AS Measure,
           @AmountCol AS AmountColumn,
           COUNT(*) AS TotalRows,
           CAST(ISNULL(SUM(Amount), 0) AS DECIMAL(18,2)) AS TotalAmount,
           CAST(0 AS BIT) AS IsFormula
    FROM #C;

    -- $ rows lead with the measured Amount.
    SET @Sql = N'SELECT ' + CASE WHEN @AmountCol IS NULL THEN N'' ELSE N'p.Amount, ' END + N'
               s.LabID, s.LabName, p.ClaimID, p.AccessionNumber, p.PayerName_Raw, s.PayerName, s.PayerType,
               s.BillingProvider, p.ReferringProvider, p.ClinicName, s.PatientID, s.PatientDOB, p.DateofService,
               s.ChargeEnteredDate, p.FirstBilledDate, p.Panelname, s.CPTCodeXUnitsXModifier, s.POS, s.TOS,
               p.ChargeAmount, s.AllowedAmount, p.InsurancePayment, p.PatientPayment, p.TotalPayments,
               p.InsuranceAdjustments, s.PatientAdjustments, p.TotalAdjustments,
               p.InsuranceBalance, p.PatientBalance, p.TotalBalance, s.CheckDate, p.ClaimStatus,
               s.DenialCode, s.DenialCodeNormalized, s.DenialDescription, s.ICDCode,
               s.DaystoDOS, s.RollingDays, s.DaystoBill, s.DaystoPost,
               s.PaymentPercent, s.FullyPaidCount, s.FullyPaidAmount, s.Adjudicated, s.AdjudicatedAmount,
               s.Bucket30, s.Bucket30Amount, s.Bucket60, s.Bucket60Amount,
               s.CheckNumber, s.EntryWeek, s.DepositWeek, s.BilledWeek
        FROM (SELECT * FROM #C ORDER BY PeriodDate, ClaimID OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY) p
        JOIN dbo.ClaimLevelData s ON s.RecordId = p.EsRecordId
        ORDER BY p.PeriodDate, p.ClaimID;';
    EXEC sys.sp_executesql @Sql, N'@Skip INT, @Take INT', @Skip = @Skip, @Take = @Take;
END;
GO

SET NOEXEC OFF;
GO

PRINT '37_PNC_ExecutiveSummary_CellRows.sql completed.';
GO
