/* =============================================================================
   Rising Tides - Executive Summary cell rows (value click -> popup grid)
   File     : 40_RisingTides_ExecutiveSummary_CellRows.sql
   Database : RisingTides
   Object   : dbo.usp_GetRT_ExecutiveSummaryCellRows

   Returns the source rows behind one Executive Summary cell. The rules follow the procedures
   deployed on RisingTides (read with OBJECT_DEFINITION on 2026-10-26) - keep this file in step
   with them:
     No page filter  -> the RT_ES_* snapshot: usp_RefreshRT_ExecutiveSummary (PMS / Cash),
                        usp_RefreshRT_ExecutiveSummary_LIS_Alt (LIS, RequestCollectDate month,
                        PanelCategory panels), usp_RT_ES_RefreshDerivedRows (P, Avg).
     Any page filter -> usp_GetRT_ExecutiveSummary's filtered path. LIS stays on the snapshot rules
                        bounded by the Year / Month range unless a Panel / Clinic / Provider filter,
                        a DOS range or Billed Date mode is set; then LIMSMaster is read live
                        (AMDLBD in Billed Date mode).

   Counts: PMS rows are COUNT(DISTINCT ClaimID) per month (one line per claim and month; Claims =
   claim rows sharing it). LIS rows count LIMSMaster rows (one line per row), except the live
   L_A.<panel> rows, which count distinct Accession per month. PMS R counts distinct SpecimenID in
   ClientPaidListData by BeginDOS month. $ rows return every claim row.

   Parameters
     @Category / @RowCode   the clicked row (LIS L_0..L_B4 and L_A.<panel>, PMS O..X3, Cash X..AG3, Avg AH / AI1 / AJ)
     @Year / @Month         the clicked column: (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetRT_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText - how the value is calculated, incl. page filters
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured column for $ rows)
   Formula rows (PMS P, Avg AH / AI1 / AJ) return the formula and the calculation in Rules,
   IsFormula = 1, TotalAmount = the result, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal).
   ============================================================================= */

IF DB_NAME() NOT LIKE N'%Rising%'
BEGIN
    RAISERROR(N'40_RisingTides_ExecutiveSummary_CellRows.sql must run on the Rising Tides lab database (RisingTides).', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRT_ExecutiveSummaryCellRows
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
    SET @RowCode  = LTRIM(RTRIM(ISNULL(@RowCode, N'')));
    SET @Year     = ISNULL(@Year, 0);
    SET @Month    = ISNULL(@Month, 0);
    IF ISNULL(@Page, 0) < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 0 SET @PageSize = 100;

    /* ---- Page filters (as usp_GetRT_ExecutiveSummary) ---------------------- */
    DECLARE @HasFilter BIT = CASE
        WHEN @YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL
          OR @DosFrom  IS NOT NULL OR @DosTo  IS NOT NULL OR @BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Panels)),    N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Clinics)),   N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Reps)),      N'') IS NOT NULL
        THEN 1 ELSE 0 END;

    DECLARE @UseBilledDate BIT = CASE WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
                                        AND @DosFrom IS NULL AND @DosTo IS NULL THEN 1 ELSE 0 END;

    DECLARE @HasPanel    BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Panels,    N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;
    DECLARE @HasClinic   BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Clinics,   N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;
    DECLARE @HasProvider BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Providers, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;
    DECLARE @HasRep      BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Reps,      N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;

    -- LIS source: 0 = snapshot rules, 1 = snapshot bounded by the Year / Month range,
    -- 2 = live LIMSMaster (Panel / Clinic / Provider filter, DOS range or Billed Date mode).
    DECLARE @LisMode TINYINT = CASE
        WHEN @HasFilter = 0 THEN 0
        WHEN @HasPanel = 1 OR @HasClinic = 1 OR @HasProvider = 1 OR @DosFrom IS NOT NULL OR @DosTo IS NOT NULL OR @UseBilledDate = 1 THEN 2
        ELSE 1 END;

    /* ---- Row definitions ---------------------------------------------------- */
    DECLARE @Def TABLE
    (
        Category    VARCHAR(10)    COLLATE DATABASE_DEFAULT NOT NULL,
        RowCode     NVARCHAR(20)   COLLATE DATABASE_DEFAULT NOT NULL,
        Description NVARCHAR(420)  COLLATE DATABASE_DEFAULT NOT NULL,
        RuleText    NVARCHAR(1000) COLLATE DATABASE_DEFAULT NOT NULL,
        AmountCol   NVARCHAR(100)  COLLATE DATABASE_DEFAULT NULL,
        IsFormula   BIT            NOT NULL
    );
    INSERT INTO @Def (Category, RowCode, Description, RuleText, AmountCol, IsFormula) VALUES
        ('LIS', 'L_0',   N'Total Samples',               N'Every sample', NULL, 0),
        ('LIS', 'L_A',   N'Billable Samples - Resulted', N'Resulted/Not = Resulted', NULL, 0),
        ('LIS', 'L_A1',  N'Billed to Insurance',         N'Resulted AND PaymentMethod = Insurance AND ClaimStatus = Billed AND ClientStatus <> Test Entries', NULL, 0),
        ('LIS', 'L_A1A', N'Billed In AMD',               N'Resulted AND PaymentMethod = Insurance AND ClaimStatus = Billed AND ClientStatus <> Test Entries', NULL, 0),
        ('LIS', 'L_A2',  N'Not Entered in AMD',          N'Resulted AND PaymentMethod = Insurance AND ClaimStatus = Not Entered in AMD AND ClientStatus IN (Billing Review Required, blank) AND BillingStatus IN (Billed, Not Ready To Bill, Ready To Bill)', NULL, 0),
        ('LIS', 'L_A2A', N'Received',                    N'Not Entered in AMD (L_A2) AND SampleStatus = Received', NULL, 0),
        ('LIS', 'L_A2B', N'Billing Review Required',     N'Resulted AND PaymentMethod = Insurance AND ClaimStatus = Not Entered in AMD AND ClientStatus = Billing Review Required AND BillingStatus IN (Billed, Not Ready To Bill, Ready To Bill)', NULL, 0),
        ('LIS', 'L_A2C', N'Transferred',                 N'Not Entered in AMD (L_A2) AND SampleStatus = Transferred', NULL, 0),
        ('LIS', 'L_A2D', N'Collected',                   N'Not Entered in AMD (L_A2) AND SampleStatus = Collected', NULL, 0),
        ('LIS', 'L_A3',  N'Unbilled',                    N'Resulted AND ClientStatus is blank AND Billed/Not = Unbilled AND ClaimStatus = Entered', NULL, 0),
        ('LIS', 'L_A4',  N'Client Bill',                 N'Resulted AND ClientStatus = Client Bill AND BillingStatus IN (Billed, Ready to Bill)', NULL, 0),
        ('LIS', 'L_A4A', N'Not Entered in AMD',          N'Client Bill (L_A4) AND ClaimStatus = Not Entered in AMD', NULL, 0),
        ('LIS', 'L_A4B', N'Billed',                      N'Resulted AND ClientStatus = Client Bill AND BillingStatus <> No Bill AND ClaimStatus = Billed', NULL, 0),
        ('LIS', 'L_A4C', N'Entered',                     N'Resulted AND ClaimStatus = Entered AND Billed/Not = Unbilled AND ClientStatus = Client Bill', NULL, 0),
        ('LIS', 'L_A5',  N'Self Pay',                    N'Resulted AND ClientStatus = Self Pay AND BillingStatus <> No Bill', NULL, 0),
        ('LIS', 'L_A5A', N'Billed',                      N'Resulted AND PaymentMethod = Self Pay AND ClaimStatus = Billed AND Billed/Not = Billed AND ClientStatus = Self Pay AND BillingStatus IN (Billed, Not Ready To Bill)', NULL, 0),
        ('LIS', 'L_A5B', N'Not Entered in AMD',          N'Resulted AND BillingStatus <> No Bill AND ClaimStatus = Not Entered in AMD AND ClientStatus = Self Pay', NULL, 0),
        ('LIS', 'L_A5C', N'Entered',                     N'Resulted AND ClaimStatus = Entered AND BillingStatus <> No Bill AND ClientStatus = Self Pay', NULL, 0),
        ('LIS', 'L_A6',  N'Test Entries',                N'Resulted AND BillingStatus <> No Bill AND ClientStatus = Test Entries', NULL, 0),
        ('LIS', 'L_A6A', N'Not Entered in AMD',          N'Test Entries (L_A6) AND ClaimStatus = Not Entered in AMD', NULL, 0),
        ('LIS', 'L_A6B', N'Billed',                      N'Test Entries (L_A6) AND ClaimStatus = Billed', NULL, 0),
        ('LIS', 'L_A6C', N'Entered',                     N'Test Entries (L_A6) AND ClaimStatus = Entered', NULL, 0),
        ('LIS', 'L_A7',  N'Billing Status - No Bill',    N'Resulted AND BillingStatus = No Bill', NULL, 0),
        ('LIS', 'L_A7A', N'Rejected',                    N'Resulted AND BillingStatus = No Bill AND OrderStatus = Rejected', NULL, 0),
        ('LIS', 'L_A7B', N'Completed',                   N'Resulted AND BillingStatus = No Bill AND OrderStatus = Completed', NULL, 0),
        ('LIS', 'L_A7C', N'Recollect Required',          N'Resulted AND BillingStatus = No Bill AND OrderStatus = Recollect Required', NULL, 0),
        ('LIS', 'L_B',   N'Not Resulted',                N'Resulted/Not = Not Resulted', NULL, 0),
        ('LIS', 'L_B1',  N'Not Entered in AMD',          N'Not Resulted AND ClaimStatus = Not Entered in AMD AND ClientStatus is blank', NULL, 0),
        ('LIS', 'L_B1A', N'Collected',                   N'Not Entered in AMD (L_B1) AND SampleStatus = Collected', NULL, 0),
        ('LIS', 'L_B1B', N'Received',                    N'Not Entered in AMD (L_B1) AND SampleStatus = Received', NULL, 0),
        ('LIS', 'L_B1C', N'In Transit',                  N'Not Entered in AMD (L_B1) AND SampleStatus = In Transit', NULL, 0),
        ('LIS', 'L_B2',  N'Rejected Sample',             N'Not Resulted AND ClaimStatus = Not Entered in AMD AND SampleStatus = Rejected', NULL, 0),
        ('LIS', 'L_B3',  N'Test Entries',                N'Not Resulted AND ClientStatus = Test Entries', NULL, 0),
        ('LIS', 'L_B4',  N'Self Pay',                    N'Not Resulted AND ClientStatus = Self Pay', NULL, 0),
        ('PMS', 'O',   N'Billed - Includes all Claims Billed in AMD', N'BilledUnbilled = Billed', NULL, 0),
        ('PMS', 'P',   N'Billed Mismatches - Non Diagnose LIS Samples',
                       N'Formula: MAX(Billed claims (PMS O) - (LIS Billed to Insurance L_A1 + Client Bill Billed L_A4b + Self Pay Billed L_A5a), 0) per month', NULL, 1),
        ('PMS', 'Q',   N'Unbilled - Entered in AMD - Yet to be released to Payer', N'BilledUnbilled = Unbilled', NULL, 0),
        ('PMS', 'R',   N'Paid - Client', N'dbo.ClientPaidListData rows with a SpecimenID (page filters do not apply, as on the grid)', NULL, 0),
        ('PMS', 'S',   N'Fully Paid - Insurance Pay', N'BilledUnbilled = Billed AND ClaimStatus = Fully Paid', NULL, 0),
        ('PMS', 'T',   N'Fully Adjusted',             N'BilledUnbilled = Billed AND ClaimStatus = Complete W/O', NULL, 0),
        ('PMS', 'U',   N'Patient Responsibility',     N'BilledUnbilled = Billed AND ClaimStatus = Patient Responsibility', NULL, 0),
        ('PMS', 'V',   N'Partially Paid',             N'BilledUnbilled = Billed AND ClaimStatus = Partially Paid', NULL, 0),
        ('PMS', 'W',   N'Patient Payment',            N'BilledUnbilled = Billed AND ClaimStatus = Patient Payment', NULL, 0),
        ('PMS', 'X',   N'Insurance Balance',          N'BilledUnbilled = Billed AND ClaimStatus IN (Fully Denied, No Response, Partially Denied, Partially Adjusted)', NULL, 0),
        ('PMS', 'X1',  N'Fully Denied',               N'BilledUnbilled = Billed AND ClaimStatus = Fully Denied', NULL, 0),
        ('PMS', 'X2',  N'No Response',                N'BilledUnbilled = Billed AND ClaimStatus = No Response', NULL, 0),
        ('PMS', 'X3',  N'Partially Denied',           N'BilledUnbilled = Billed AND ClaimStatus IN (Partially Denied, Partially Adjusted)', NULL, 0),
        ('Cash', 'X',   N'Total Billed ($)',          N'BilledUnbilled = Billed', N'ChargeAmount', 0),
        ('Cash', 'Y',   N'Unbilled ($)',              N'BilledUnbilled = Unbilled', N'ChargeAmount', 0),
        ('Cash', 'Z',   N'Insurance Payment (fully paid) ($)', N'BilledUnbilled = Billed AND ClaimStatus = Fully Paid', N'InsurancePayment', 0),
        ('Cash', 'AA',  N'Partially Paid ($)',        N'BilledUnbilled = Billed AND ClaimStatus = Partially Paid', N'InsurancePayment', 0),
        ('Cash', 'AB',  N'Patient Payment ($)',       N'BilledUnbilled = Billed', N'PatientPayment', 0),
        ('Cash', 'AC',  N'Fully Adjusted (Complete W/O) ($)', N'BilledUnbilled = Billed AND ClaimStatus = Complete W/O', N'InsuranceAdjustments', 0),
        ('Cash', 'AD',  N'Contractual Obligation W/O ($)', N'BilledUnbilled = Billed AND ClaimStatus <> Complete W/O', N'InsuranceAdjustments', 0),
        ('Cash', 'AE',  N'Patient Balance ($)',       N'BilledUnbilled = Billed', N'PatientBalance', 0),
        ('Cash', 'AF',  N'Patient WO ($)',            N'BilledUnbilled = Billed', N'PatientAdjustments', 0),
        ('Cash', 'AG',  N'Insurance Balance ($)',     N'BilledUnbilled = Billed', N'InsuranceBalance', 0),
        ('Cash', 'AG1', N'No Response ($)',           N'BilledUnbilled = Billed AND ClaimStatus = No Response', N'InsuranceBalance', 0),
        ('Cash', 'AG2', N'Fully Denied ($)',          N'BilledUnbilled = Billed AND ClaimStatus = Fully Denied', N'InsuranceBalance', 0),
        ('Cash', 'AG3', N'Partially Denied ($)',      N'BilledUnbilled = Billed AND ClaimStatus NOT IN (Fully Denied, No Response)', N'InsuranceBalance', 0),
        ('Avg', 'AH',  N'Average Payment ($) - Total Pay/Billed Claims',
                       N'Formula: Total Pay (Cash Z + AA + AB) / Billed claims (PMS O); Year / Grand Total = sum of the monthly values', NULL, 1),
        ('Avg', 'AI1', N'Average Payment ($) - Total Pay/Paid Claims',
                       N'Formula: Total Pay (Cash Z + AA + AB) / (PMS S + V + W); Year / Grand Total = sum of the monthly values', NULL, 1),
        ('Avg', 'AJ',  N'Average Payment ($) - Total Pay/Adjudicated Claims',
                       N'Formula: Total Pay (Cash Z + AA + AB) / (PMS S + T + U + V + W + X1 + X3); Year / Grand Total = sum of the monthly values', NULL, 1);

    -- LIS panel sub-rows: "L_A." + the panel (PanelCategory).
    DECLARE @PanelVal NVARCHAR(400) = NULL;
    IF @Category = 'LIS' AND @RowCode LIKE N'L[_]A.%'
    BEGIN
        SET @PanelVal = LTRIM(RTRIM(SUBSTRING(@RowCode, 5, 400)));
        INSERT INTO @Def (Category, RowCode, Description, RuleText, AmountCol, IsFormula)
        VALUES ('LIS', N'L_A.*', @PanelVal, N'Resulted AND PanelCategory = ' + @PanelVal, NULL, 0);
    END;

    DECLARE @DefCode NVARCHAR(20) = CASE WHEN @PanelVal IS NOT NULL THEN N'L_A.*' ELSE UPPER(LEFT(@RowCode, 20)) END;
    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @IsFormula BIT;
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @IsFormula = IsFormula
    FROM @Def WHERE Category = @Category AND UPPER(RowCode) = @DefCode;

    IF @RuleText IS NULL OR (LEN(@RowCode) > 20 AND @PanelVal IS NULL)
    BEGIN
        DECLARE @RowCodeMsg NVARCHAR(100) = LEFT(@RowCode, 100);
        RAISERROR(N'usp_GetRT_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCodeMsg);
        RETURN;
    END;

    DECLARE @IsLis BIT = CASE WHEN @Category = 'LIS' THEN 1 ELSE 0 END;
    DECLARE @IsCpl BIT = CASE WHEN @Category = 'PMS' AND @DefCode = N'R' THEN 1 ELSE 0 END;
    -- Hit key for claim rows: PMS and Cash both use X, so the category is part of it.
    DECLARE @HitCode NVARCHAR(30) = @Category + N':' + @DefCode;
    DECLARE @LisDateCol NVARCHAR(40) = CASE WHEN @LisMode = 2 AND @UseBilledDate = 1 THEN N'AMDLBD' ELSE N'RequestCollectDate' END;
    DECLARE @ClaimDateCol NVARCHAR(40) = CASE WHEN @HasFilter = 1 AND @UseBilledDate = 1 THEN N'FirstBilledDate' ELSE N'DateofService' END;
    DECLARE @PeriodText NVARCHAR(200) =
        CASE WHEN @Year = 0 THEN N'all periods (Grand Total)'
             WHEN @Month = 0 THEN N'year ' + CAST(@Year AS NVARCHAR(4)) + N' (Year Total)'
             ELSE DATENAME(MONTH, DATEFROMPARTS(@Year, @Month, 1)) + N' ' + CAST(@Year AS NVARCHAR(4)) END;
    DECLARE @LisDistinct BIT = CASE WHEN @PanelVal IS NOT NULL AND @LisMode = 2 THEN 1 ELSE 0 END;

    /* ---- 1. Rules ----------------------------------------------------------- */
    DECLARE @Rules TABLE (RuleOrder INT IDENTITY(1,1), RuleGroup NVARCHAR(40), RuleText NVARCHAR(2000));
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Source', CASE WHEN @IsLis = 1 THEN N'dbo.LIMSMaster - samples (Accession not blank)'
                           WHEN @IsCpl = 1 THEN N'dbo.ClientPaidListData - client paid specimens'
                           ELSE N'dbo.ClaimLevelData - claims (ClaimID not blank)' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Period', CASE WHEN @IsLis = 1 THEN @LisDateCol WHEN @IsCpl = 1 THEN N'BeginDOS' ELSE @ClaimDateCol END
                      + N' (a valid date) in ' + @PeriodText;
    INSERT INTO @Rules (RuleGroup, RuleText) VALUES (CASE WHEN @IsFormula = 1 THEN N'Formula' ELSE N'Row rule' END, @RuleText);
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Measure',
           CASE WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol + N' over every matching claim row'
                WHEN @IsCpl = 1 THEN N'Count of distinct SpecimenID per month - one line per specimen and month (Records = rows sharing it)'
                WHEN @IsLis = 1 AND @LisDistinct = 1 THEN N'Count of distinct Accession per month - one line per Accession and month (Records = rows sharing it)'
                WHEN @IsLis = 1 THEN N'Count of samples - one line per LIMSMaster row'
                ELSE N'Count of distinct ClaimID per month - one line per claim and month (Claims = claim rows sharing it)' END
    WHERE @IsFormula = 0;

    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', v.Txt
    FROM (VALUES
        (CASE WHEN @UseBilledDate = 1
              THEN N'FirstBilledDate from ' + ISNULL(CONVERT(NVARCHAR(10), @BilledFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @BilledTo, 101), N'(any)')
              WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL
              THEN N'DateofService from ' + ISNULL(CONVERT(NVARCHAR(10), @DosFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @DosTo, 101), N'(any)') END),
        (CASE WHEN @UseBilledDate = 0 AND (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL)
              THEN N'DateofService year ' + ISNULL(CAST(@YearFrom AS NVARCHAR(4)), N'(any)') + N' - ' + ISNULL(CAST(@YearTo AS NVARCHAR(4)), N'(any)') END),
        (CASE WHEN @UseBilledDate = 0 AND (@MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
              THEN N'DateofService month ' + ISNULL(CAST(@MonthFrom AS NVARCHAR(2)), N'(any)') + N' - ' + ISNULL(CAST(@MonthTo AS NVARCHAR(2)), N'(any)') END),
        (CASE WHEN @HasPanel = 1    THEN N'Panelname IN (' + @Panels + N')' END),
        (CASE WHEN @HasClinic = 1   THEN N'ClinicName IN (' + @Clinics + N')' END),
        (CASE WHEN @HasProvider = 1 THEN N'ReferringProvider IN (' + @Providers + N')' END),
        (CASE WHEN @HasRep = 1      THEN N'SalesRepname IN (' + @Reps + N')' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL AND @IsLis = 0 AND @IsCpl = 0;

    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', v.Txt
    FROM (VALUES
        (CASE WHEN @LisMode = 1 AND (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
              THEN N'RequestCollectDate year ' + ISNULL(CAST(@YearFrom AS NVARCHAR(4)), N'(any)') + N' - ' + ISNULL(CAST(@YearTo AS NVARCHAR(4)), N'(any)')
                   + N', month ' + ISNULL(CAST(@MonthFrom AS NVARCHAR(2)), N'(any)') + N' - ' + ISNULL(CAST(@MonthTo AS NVARCHAR(2)), N'(any)') END),
        (CASE WHEN @LisMode = 2 AND @UseBilledDate = 1
              THEN N'AMDLBD from ' + ISNULL(CONVERT(NVARCHAR(10), @BilledFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @BilledTo, 101), N'(any)') END),
        (CASE WHEN @LisMode = 2 AND @UseBilledDate = 0 AND (@DosFrom IS NOT NULL OR @DosTo IS NOT NULL)
              THEN N'RequestCollectDate from ' + ISNULL(CONVERT(NVARCHAR(10), @DosFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @DosTo, 101), N'(any)') END),
        (CASE WHEN @LisMode = 2 AND (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
              THEN N'Year / Month filters do not apply to the live LIS section (as on the grid)' END),
        (CASE WHEN @LisMode = 2 AND @HasPanel = 1    THEN N'PanelCategory IN (' + @Panels + N')' END),
        (CASE WHEN @LisMode = 2 AND @HasClinic = 1   THEN N'Facility IN (' + @Clinics + N')' END),
        (CASE WHEN @LisMode = 2 AND @HasProvider = 1 THEN N'Provider IN (' + @Providers + N')' END),
        (CASE WHEN @HasRep = 1 THEN N'Sales Rep does not apply to the LIS section (as on the grid)' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL AND @IsLis = 1;

    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', N'Page filters do not apply to ClientPaidListData (as on the grid)'
    WHERE @IsCpl = 1 AND @HasFilter = 1;

    /* ---- Claim rows in scope ------------------------------------------------- */
    CREATE TABLE #xC
    (
        RowId                INT IDENTITY(1,1) PRIMARY KEY,
        ClaimID              NVARCHAR(255) COLLATE DATABASE_DEFAULT NOT NULL,
        AccessionNumber      NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        DateofService        DATE NULL,
        FirstBilledDate      DATE NULL,
        PayerName_Raw        NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        Panelname            NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        ClinicName           NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        ReferringProvider    NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        SalesRepname         NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        BilledUnbilled       NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
        ClaimStatus          NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        BU                   NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        CS                   NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ChargeAmount         DECIMAL(18,2) NOT NULL,
        InsurancePayment     DECIMAL(18,2) NOT NULL,
        PatientPayment       DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL,
        PY                   INT NOT NULL,
        PM                   INT NOT NULL,
        DedupeKey            NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL
    );

    IF @IsLis = 0 AND @IsCpl = 0
        INSERT INTO #xC (ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
                         ReferringProvider, SalesRepname, BilledUnbilled, ClaimStatus, BU, CS,
                         ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments,
                         InsuranceBalance, PatientBalance, PY, PM, DedupeKey)
        SELECT
            k.VisitNumber, CONVERT(NVARCHAR(200), c.AccessionNumber), d.Dos, d.Fbd,
            c.PayerName_Raw, c.Panelname, c.ClinicName, c.ReferringProvider, c.SalesRepname, c.BilledUnbilled, c.ClaimStatus,
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), c.BilledUnbilled), N''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.ClaimStatus), N''))),
            ISNULL(TRY_CAST(c.ChargeAmount         AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.InsurancePayment     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.PatientPayment       AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.InsuranceAdjustments AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.PatientAdjustments   AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.InsuranceBalance     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.PatientBalance       AS DECIMAL(18,2)), 0),
            YEAR(p.PeriodDate), MONTH(p.PeriodDate),
            k.VisitNumber + N'|' + CONVERT(NVARCHAR(6), YEAR(p.PeriodDate) * 100 + MONTH(p.PeriodDate))
        FROM dbo.ClaimLevelData c
        CROSS APPLY (SELECT LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), c.ClaimID), N''))) AS VisitNumber) k
        CROSS APPLY (SELECT TRY_CAST(c.DateofService AS DATE) AS Dos, TRY_CAST(c.FirstBilledDate AS DATE) AS Fbd) d
        CROSS APPLY (SELECT CASE WHEN @HasFilter = 1 AND @UseBilledDate = 1 THEN d.Fbd ELSE d.Dos END AS PeriodDate) p
        WHERE k.VisitNumber <> N''
          AND p.PeriodDate IS NOT NULL
          AND (@Year  = 0 OR YEAR(p.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(p.PeriodDate) = @Month)
          AND (@HasFilter = 0 OR (
                   (@UseBilledDate = 1 OR (
                        (@YearFrom  IS NULL OR YEAR(d.Dos)  >= @YearFrom)
                    AND (@YearTo    IS NULL OR YEAR(d.Dos)  <= @YearTo)
                    AND (@MonthFrom IS NULL OR MONTH(d.Dos) >= @MonthFrom)
                    AND (@MonthTo   IS NULL OR MONTH(d.Dos) <= @MonthTo)
                    AND (@DosFrom   IS NULL OR d.Dos >= @DosFrom)
                    AND (@DosTo     IS NULL OR d.Dos <= @DosTo)))
               AND (@UseBilledDate = 0 OR (
                        (@BilledFrom IS NULL OR d.Fbd >= @BilledFrom)
                    AND (@BilledTo   IS NULL OR d.Fbd <= @BilledTo)))
               AND (@HasPanel    = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(c.Panelname,         N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Panels    + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasClinic   = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(c.ClinicName,        N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Clinics   + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasProvider = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(c.ReferringProvider, N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Providers + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasRep      = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(c.SalesRepname,      N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Reps      + N',') COLLATE DATABASE_DEFAULT) > 0)))
        OPTION (RECOMPILE);

    DECLARE @Need TABLE (HitCode NVARCHAR(30) COLLATE DATABASE_DEFAULT PRIMARY KEY);
    IF @IsLis = 0 AND @IsCpl = 0 AND @IsFormula = 0
        INSERT INTO @Need VALUES (@HitCode);
    ELSE IF @DefCode = N'P' AND @Category = 'PMS'
        INSERT INTO @Need VALUES (N'PMS:O');
    ELSE IF @Category = 'Avg'
        INSERT INTO @Need SELECT v.HitCode
        FROM (VALUES (N'PMS:O'), (N'PMS:S'), (N'PMS:T'), (N'PMS:U'), (N'PMS:V'), (N'PMS:W'), (N'PMS:X1'), (N'PMS:X3'),
                     (N'Cash:Z'), (N'Cash:AA'), (N'Cash:AB')) v(HitCode);

    CREATE TABLE #xHit (RowId INT NOT NULL, HitCode NVARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (HitCode, RowId));
    INSERT INTO #xHit (RowId, HitCode)
    SELECT c.RowId, r.HitCode
    FROM #xC c
    CROSS APPLY (VALUES
        (N'PMS:O',    CASE WHEN c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'PMS:Q',    CASE WHEN c.BU = N'Unbilled' THEN 1 ELSE 0 END),
        (N'PMS:S',    CASE WHEN c.BU = N'Billed' AND c.CS = N'Fully Paid' THEN 1 ELSE 0 END),
        (N'PMS:T',    CASE WHEN c.BU = N'Billed' AND c.CS = N'Complete W/O' THEN 1 ELSE 0 END),
        (N'PMS:U',    CASE WHEN c.BU = N'Billed' AND c.CS = N'Patient Responsibility' THEN 1 ELSE 0 END),
        (N'PMS:V',    CASE WHEN c.BU = N'Billed' AND c.CS = N'Partially Paid' THEN 1 ELSE 0 END),
        (N'PMS:W',    CASE WHEN c.BU = N'Billed' AND c.CS = N'Patient Payment' THEN 1 ELSE 0 END),
        (N'PMS:X',    CASE WHEN c.BU = N'Billed' AND c.CS IN (N'Fully Denied', N'No Response', N'Partially Denied', N'Partially Adjusted') THEN 1 ELSE 0 END),
        (N'PMS:X1',   CASE WHEN c.BU = N'Billed' AND c.CS = N'Fully Denied' THEN 1 ELSE 0 END),
        (N'PMS:X2',   CASE WHEN c.BU = N'Billed' AND c.CS = N'No Response' THEN 1 ELSE 0 END),
        (N'PMS:X3',   CASE WHEN c.BU = N'Billed' AND c.CS IN (N'Partially Denied', N'Partially Adjusted') THEN 1 ELSE 0 END),
        (N'Cash:X',   CASE WHEN c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'Cash:Y',   CASE WHEN c.BU = N'Unbilled' THEN 1 ELSE 0 END),
        (N'Cash:Z',   CASE WHEN c.BU = N'Billed' AND c.CS = N'Fully Paid' THEN 1 ELSE 0 END),
        (N'Cash:AA',  CASE WHEN c.BU = N'Billed' AND c.CS = N'Partially Paid' THEN 1 ELSE 0 END),
        (N'Cash:AB',  CASE WHEN c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'Cash:AC',  CASE WHEN c.BU = N'Billed' AND c.CS = N'Complete W/O' THEN 1 ELSE 0 END),
        (N'Cash:AD',  CASE WHEN c.BU = N'Billed' AND c.CS <> N'Complete W/O' THEN 1 ELSE 0 END),
        (N'Cash:AE',  CASE WHEN c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'Cash:AF',  CASE WHEN c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'Cash:AG',  CASE WHEN c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'Cash:AG1', CASE WHEN c.BU = N'Billed' AND c.CS = N'No Response' THEN 1 ELSE 0 END),
        (N'Cash:AG2', CASE WHEN c.BU = N'Billed' AND c.CS = N'Fully Denied' THEN 1 ELSE 0 END),
        (N'Cash:AG3', CASE WHEN c.BU = N'Billed' AND c.CS NOT IN (N'Fully Denied', N'No Response') THEN 1 ELSE 0 END)
    ) r(HitCode, Hit)
    WHERE r.Hit = 1
      AND r.HitCode IN (SELECT HitCode FROM @Need);

    /* ---- LIS rows in scope (LIS cells, and the LIS side of PMS P) ----------- */
    DECLARE @NeedLis BIT = CASE WHEN @IsLis = 1 OR (@Category = 'PMS' AND @DefCode = N'P') THEN 1 ELSE 0 END;

    CREATE TABLE #xL
    (
        RowRef           INT IDENTITY(1,1) PRIMARY KEY,
        Accession        NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        OrderID          NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        RequestCollectDate DATE NULL,
        AMDLBD           NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
        RN               NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
        PM               NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        CS               NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        CL               NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        BN               NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
        BS               NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        OS               NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        SS               NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        PanelCategory    NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        Facility         NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        Provider         NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        PrimaryInsurance NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        PeriodDate       DATE NOT NULL,
        PY               INT NOT NULL,
        PMo              INT NOT NULL
    );

    IF @NeedLis = 1
        INSERT INTO #xL (Accession, OrderID, RequestCollectDate, AMDLBD, RN, PM, CS, CL, BN, BS, OS, SS, PanelCategory,
                         Facility, Provider, PrimaryInsurance, PeriodDate, PY, PMo)
        SELECT
            k.Acc, LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.OrderID), N''))),
            TRY_CAST(l.RequestCollectDate AS DATE), CONVERT(NVARCHAR(100), l.AMDLBD),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50),  l.RessultedStatus), N''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.PaymentMethod), N''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.ClaimStatus), N''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.ClientStatus), N''))),
            LEFT(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50), l.BilledorNot), N''))), 20),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.BillingStatus), N''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.OrderStatus), N''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.SampleStatus), N''))),
            k.Panel,
            CONVERT(NVARCHAR(300), l.Facility), CONVERT(NVARCHAR(300), l.Provider), CONVERT(NVARCHAR(300), l.PrimaryInsurance),
            p.PeriodDate, YEAR(p.PeriodDate), MONTH(p.PeriodDate)
        FROM dbo.LIMSMaster l
        CROSS APPLY (SELECT LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.Accession), N''))) AS Acc,
                            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.PanelCategory), N''))) AS Panel) k
        CROSS APPLY (SELECT CASE WHEN @LisMode = 2 AND @UseBilledDate = 1 THEN TRY_CAST(l.AMDLBD AS DATE)
                                 ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate) p
        WHERE k.Acc <> N''
          AND p.PeriodDate IS NOT NULL
          AND (@Year  = 0 OR YEAR(p.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(p.PeriodDate) = @Month)
          AND (@LisMode <> 1 OR (
                   (@YearFrom  IS NULL OR YEAR(p.PeriodDate)  >= @YearFrom)
               AND (@YearTo    IS NULL OR YEAR(p.PeriodDate)  <= @YearTo)
               AND (@MonthFrom IS NULL OR MONTH(p.PeriodDate) >= @MonthFrom)
               AND (@MonthTo   IS NULL OR MONTH(p.PeriodDate) <= @MonthTo)))
          AND (@LisMode <> 2 OR (
                   (@UseBilledDate = 1 OR ((@DosFrom IS NULL OR p.PeriodDate >= @DosFrom) AND (@DosTo IS NULL OR p.PeriodDate <= @DosTo)))
               AND (@UseBilledDate = 0 OR ((@BilledFrom IS NULL OR p.PeriodDate >= @BilledFrom) AND (@BilledTo IS NULL OR p.PeriodDate <= @BilledTo)))
               AND (@HasPanel    = 0 OR CHARINDEX((N',' + k.Panel + N',') COLLATE DATABASE_DEFAULT, (N',' + @Panels + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasClinic   = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.Facility), N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Clinics   + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasProvider = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.Provider), N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Providers + N',') COLLATE DATABASE_DEFAULT) > 0)))
        OPTION (RECOMPILE);

    -- LIS row rules (as usp_RefreshRT_ExecutiveSummary_LIS_Alt / the read SP's live path).
    CREATE TABLE #xLHit (Accession NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL, Code NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL,
                         PY INT NOT NULL, PMo INT NOT NULL, RowRef INT NOT NULL);
    IF @NeedLis = 1
    BEGIN
        INSERT INTO #xLHit (Accession, Code, PY, PMo, RowRef)
        SELECT n.Accession, r.Code, n.PY, n.PMo, n.RowRef
        FROM #xL n
        CROSS APPLY (VALUES
            (N'L_0',   1),
            (N'L_A',   CASE WHEN n.RN = N'Resulted' THEN 1 ELSE 0 END),
            (N'L_A1',  CASE WHEN n.RN = N'Resulted' AND n.PM = N'Insurance' AND n.CS = N'Billed' AND n.CL <> N'Test Entries' THEN 1 ELSE 0 END),
            (N'L_A1A', CASE WHEN n.RN = N'Resulted' AND n.PM = N'Insurance' AND n.CS = N'Billed' AND n.CL <> N'Test Entries' THEN 1 ELSE 0 END),
            (N'L_A2',  CASE WHEN n.RN = N'Resulted' AND n.PM = N'Insurance' AND n.CS = N'Not Entered in AMD' AND n.CL IN (N'Billing Review Required', N'')
                             AND n.BS IN (N'Billed', N'Not Ready To Bill', N'Ready To Bill') THEN 1 ELSE 0 END),
            (N'L_A2A', CASE WHEN n.RN = N'Resulted' AND n.PM = N'Insurance' AND n.CS = N'Not Entered in AMD' AND n.CL IN (N'Billing Review Required', N'')
                             AND n.BS IN (N'Billed', N'Not Ready To Bill', N'Ready To Bill') AND n.SS = N'Received' THEN 1 ELSE 0 END),
            (N'L_A2B', CASE WHEN n.RN = N'Resulted' AND n.PM = N'Insurance' AND n.CS = N'Not Entered in AMD' AND n.CL = N'Billing Review Required'
                             AND n.BS IN (N'Billed', N'Not Ready To Bill', N'Ready To Bill') THEN 1 ELSE 0 END),
            (N'L_A2C', CASE WHEN n.RN = N'Resulted' AND n.PM = N'Insurance' AND n.CS = N'Not Entered in AMD' AND n.CL IN (N'Billing Review Required', N'')
                             AND n.BS IN (N'Billed', N'Not Ready To Bill', N'Ready To Bill') AND n.SS = N'Transferred' THEN 1 ELSE 0 END),
            (N'L_A2D', CASE WHEN n.RN = N'Resulted' AND n.PM = N'Insurance' AND n.CS = N'Not Entered in AMD' AND n.CL IN (N'Billing Review Required', N'')
                             AND n.BS IN (N'Billed', N'Not Ready To Bill', N'Ready To Bill') AND n.SS = N'Collected' THEN 1 ELSE 0 END),
            (N'L_A3',  CASE WHEN n.RN = N'Resulted' AND n.CL = N'' AND n.BN = N'Unbilled' AND n.CS = N'Entered' THEN 1 ELSE 0 END),
            (N'L_A4',  CASE WHEN n.RN = N'Resulted' AND n.CL = N'Client Bill' AND n.BS IN (N'Billed', N'Ready to Bill') THEN 1 ELSE 0 END),
            (N'L_A4A', CASE WHEN n.RN = N'Resulted' AND n.CL = N'Client Bill' AND n.BS IN (N'Billed', N'Ready to Bill') AND n.CS = N'Not Entered in AMD' THEN 1 ELSE 0 END),
            (N'L_A4B', CASE WHEN n.RN = N'Resulted' AND n.CL = N'Client Bill' AND n.BS <> N'No Bill' AND n.CS = N'Billed' THEN 1 ELSE 0 END),
            (N'L_A4C', CASE WHEN n.RN = N'Resulted' AND n.CS = N'Entered' AND n.BN = N'Unbilled' AND n.CL = N'Client Bill' THEN 1 ELSE 0 END),
            (N'L_A5',  CASE WHEN n.RN = N'Resulted' AND n.CL = N'Self Pay' AND n.BS <> N'No Bill' THEN 1 ELSE 0 END),
            (N'L_A5A', CASE WHEN n.RN = N'Resulted' AND n.PM = N'Self Pay' AND n.CS = N'Billed' AND n.BN = N'Billed' AND n.CL = N'Self Pay'
                             AND n.BS IN (N'Billed', N'Not Ready To Bill') THEN 1 ELSE 0 END),
            (N'L_A5B', CASE WHEN n.RN = N'Resulted' AND n.BS <> N'No Bill' AND n.CS = N'Not Entered in AMD' AND n.CL = N'Self Pay' THEN 1 ELSE 0 END),
            (N'L_A5C', CASE WHEN n.RN = N'Resulted' AND n.CS = N'Entered' AND n.BS <> N'No Bill' AND n.CL = N'Self Pay' THEN 1 ELSE 0 END),
            (N'L_A6',  CASE WHEN n.RN = N'Resulted' AND n.BS <> N'No Bill' AND n.CL = N'Test Entries' THEN 1 ELSE 0 END),
            (N'L_A6A', CASE WHEN n.RN = N'Resulted' AND n.CS = N'Not Entered in AMD' AND n.BS <> N'No Bill' AND n.CL = N'Test Entries' THEN 1 ELSE 0 END),
            (N'L_A6B', CASE WHEN n.RN = N'Resulted' AND n.CL = N'Test Entries' AND n.BS <> N'No Bill' AND n.CS = N'Billed' THEN 1 ELSE 0 END),
            (N'L_A6C', CASE WHEN n.RN = N'Resulted' AND n.CL = N'Test Entries' AND n.BS <> N'No Bill' AND n.CS = N'Entered' THEN 1 ELSE 0 END),
            (N'L_A7',  CASE WHEN n.RN = N'Resulted' AND n.BS = N'No Bill' THEN 1 ELSE 0 END),
            (N'L_A7A', CASE WHEN n.RN = N'Resulted' AND n.BS = N'No Bill' AND n.OS = N'Rejected' THEN 1 ELSE 0 END),
            (N'L_A7B', CASE WHEN n.RN = N'Resulted' AND n.BS = N'No Bill' AND n.OS = N'Completed' THEN 1 ELSE 0 END),
            (N'L_A7C', CASE WHEN n.RN = N'Resulted' AND n.BS = N'No Bill' AND n.OS = N'Recollect Required' THEN 1 ELSE 0 END),
            (N'L_B',   CASE WHEN n.RN = N'Not Resulted' THEN 1 ELSE 0 END),
            (N'L_B1',  CASE WHEN n.RN = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.CL = N'' THEN 1 ELSE 0 END),
            (N'L_B1A', CASE WHEN n.RN = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.CL = N'' AND n.SS = N'Collected' THEN 1 ELSE 0 END),
            (N'L_B1B', CASE WHEN n.RN = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.CL = N'' AND n.SS = N'Received' THEN 1 ELSE 0 END),
            (N'L_B1C', CASE WHEN n.RN = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.CL = N'' AND n.SS = N'In Transit' THEN 1 ELSE 0 END),
            (N'L_B2',  CASE WHEN n.RN = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.SS = N'Rejected' THEN 1 ELSE 0 END),
            (N'L_B3',  CASE WHEN n.RN = N'Not Resulted' AND n.CL = N'Test Entries' THEN 1 ELSE 0 END),
            (N'L_B4',  CASE WHEN n.RN = N'Not Resulted' AND n.CL = N'Self Pay' THEN 1 ELSE 0 END),
            (N'L_A.*', CASE WHEN n.RN = N'Resulted' AND n.PanelCategory <> N'' AND n.PanelCategory = @PanelVal THEN 1 ELSE 0 END)
        ) r(Code, Hit)
        WHERE r.Hit = 1
          AND (   (@IsLis = 1 AND r.Code = @DefCode)
               OR (@IsLis = 0 AND r.Code IN (N'L_A1', N'L_A4B', N'L_A5A')));
    END;

    /* ---- Formula rows -------------------------------------------------------- */
    IF @IsFormula = 1
    BEGIN
        DECLARE @Comp TABLE
        (
            Seq INT NOT NULL, Section NVARCHAR(20) NOT NULL, Op NVARCHAR(4) NOT NULL,
            Category VARCHAR(10) NULL, RowCode NVARCHAR(20) NULL, Component NVARCHAR(420) NOT NULL,
            Value DECIMAL(18,2) NOT NULL, IsMoney BIT NOT NULL, IsTotal BIT NOT NULL
        );
        DECLARE @Result DECIMAL(18,2), @Calc NVARCHAR(1000);

        IF @Category = 'PMS'
        BEGIN
            -- P per month present in the claim rows; the grid's Year / Grand Total add the months.
            DECLARE @Mon TABLE (PY INT NOT NULL, PMo INT NOT NULL, Billed INT NOT NULL, A1 INT NOT NULL, A4b INT NOT NULL, A5a INT NOT NULL, PRIMARY KEY (PY, PMo));
            INSERT INTO @Mon (PY, PMo, Billed, A1, A4b, A5a)
            SELECT m.PY, m.PM,
                   (SELECT COUNT(DISTINCT c.ClaimID) FROM #xC c JOIN #xHit h ON h.RowId = c.RowId AND h.HitCode = N'PMS:O' WHERE c.PY = m.PY AND c.PM = m.PM),
                   (SELECT COUNT(*) FROM #xLHit x WHERE x.Code = N'L_A1'  AND x.PY = m.PY AND x.PMo = m.PM),
                   (SELECT COUNT(*) FROM #xLHit x WHERE x.Code = N'L_A4B' AND x.PY = m.PY AND x.PMo = m.PM),
                   (SELECT COUNT(*) FROM #xLHit x WHERE x.Code = N'L_A5A' AND x.PY = m.PY AND x.PMo = m.PM)
            FROM (SELECT DISTINCT PY, PM FROM #xC) m;

            DECLARE @BilledSum INT = ISNULL((SELECT SUM(Billed) FROM @Mon), 0);
            SET @Result = ISNULL((SELECT SUM(CASE WHEN Billed - (A1 + A4b + A5a) > 0 THEN Billed - (A1 + A4b + A5a) ELSE 0 END) FROM @Mon), 0);

            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'PMS', N'O',     N'Billed - Includes all Claims Billed in AMD', @BilledSum, 0, 0),
                (2, N'Calculation', N'-', 'LIS', N'L_A1',  N'Billed to Insurance', ISNULL((SELECT SUM(A1) FROM @Mon), 0), 0, 0),
                (3, N'Calculation', N'-', 'LIS', N'L_A4b', N'Client Bill - Billed', ISNULL((SELECT SUM(A4b) FROM @Mon), 0), 0, 0),
                (4, N'Calculation', N'-', 'LIS', N'L_A5a', N'Self Pay - Billed', ISNULL((SELECT SUM(A5a) FROM @Mon), 0), 0, 0),
                (9, N'Result', N'=', 'PMS', N'P', N'Billed Mismatches - Non Diagnose LIS Samples', @Result, 0, 1);

            SET @Calc = CASE WHEN (SELECT COUNT(*) FROM @Mon) <= 1
                             THEN N'MAX(' + FORMAT(@BilledSum, 'N0') + N' - ' + FORMAT(ISNULL((SELECT SUM(A1 + A4b + A5a) FROM @Mon), 0), 'N0') + N', 0) = ' + FORMAT(@Result, 'N0')
                             ELSE N'Sum of the monthly MAX(O - LIS Billed, 0) values = ' + FORMAT(@Result, 'N0') END;
        END
        ELSE
        BEGIN
            -- Avg: monthly distinct-claim counts and $ sums, added over the cell's months.
            DECLARE @Val TABLE (HitCode NVARCHAR(30) COLLATE DATABASE_DEFAULT PRIMARY KEY, Value DECIMAL(18,2) NOT NULL);
            INSERT INTO @Val (HitCode, Value)
            SELECT n.HitCode,
                   ISNULL(CASE WHEN n.HitCode LIKE N'PMS:%'
                               THEN (SELECT CAST(COUNT(DISTINCT c.DedupeKey) AS DECIMAL(18,2)) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.HitCode = n.HitCode)
                               WHEN n.HitCode = N'Cash:AB'
                               THEN (SELECT SUM(c.PatientPayment) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.HitCode = n.HitCode)
                               ELSE (SELECT SUM(c.InsurancePayment) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.HitCode = n.HitCode) END, 0)
            FROM @Need n;

            DECLARE @Parts TABLE (Seq INT, Section NVARCHAR(20), Category VARCHAR(10), RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT);
            INSERT INTO @Parts VALUES (1, N'Numerator', 'Cash', N'Z'), (2, N'Numerator', 'Cash', N'AA'), (3, N'Numerator', 'Cash', N'AB');
            IF @DefCode = N'AH'  INSERT INTO @Parts VALUES (11, N'Denominator', 'PMS', N'O');
            IF @DefCode = N'AI1' INSERT INTO @Parts VALUES (11, N'Denominator', 'PMS', N'S'), (12, N'Denominator', 'PMS', N'V'), (13, N'Denominator', 'PMS', N'W');
            IF @DefCode = N'AJ'  INSERT INTO @Parts VALUES (11, N'Denominator', 'PMS', N'S'), (12, N'Denominator', 'PMS', N'T'), (13, N'Denominator', 'PMS', N'U'),
                                                           (14, N'Denominator', 'PMS', N'V'), (15, N'Denominator', 'PMS', N'W'), (16, N'Denominator', 'PMS', N'X1'),
                                                           (17, N'Denominator', 'PMS', N'X3');

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT x.Seq, x.Section, CASE WHEN x.Seq IN (1, 11) THEN N'' ELSE N'+' END, x.Category, x.RowCode,
                   d.Description, v.Value, CASE WHEN x.Category = 'Cash' THEN 1 ELSE 0 END, 0
            FROM @Parts x
            JOIN @Val v ON v.HitCode = x.Category + N':' + x.RowCode
            JOIN @Def d ON d.Category = x.Category AND d.RowCode = x.RowCode;

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 9, N'Numerator', N'=', NULL, NULL, N'Total Pay ($)', SUM(Value), 1, 1 FROM @Comp WHERE Section = N'Numerator';
            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 19, N'Denominator', N'=', NULL, NULL,
                   CASE @DefCode WHEN N'AH' THEN N'Billed claims' WHEN N'AI1' THEN N'Paid claims' ELSE N'Adjudicated claims' END,
                   SUM(Value), 0, 1 FROM @Comp WHERE Section = N'Denominator';

            DECLARE @NumTotal DECIMAL(18,2) = (SELECT Value FROM @Comp WHERE Section = N'Numerator' AND IsTotal = 1);
            DECLARE @DenTotal DECIMAL(18,2) = (SELECT Value FROM @Comp WHERE Section = N'Denominator' AND IsTotal = 1);
            -- Same DECIMAL(18,2) / count division as the grid, stored at 2 decimals.
            SET @Result = CASE WHEN ISNULL(@DenTotal, 0) = 0 THEN 0
                               ELSE CONVERT(DECIMAL(18,2), @NumTotal / CONVERT(INT, @DenTotal)) END;

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 29, N'Result', N'=', 'Avg', d.RowCode, d.Description, @Result, 1, 1
            FROM @Def d WHERE d.Category = 'Avg' AND UPPER(d.RowCode) = @DefCode;

            SET @Calc = N'$' + FORMAT(ISNULL(@NumTotal, 0), 'N2') + N' / ' + FORMAT(ISNULL(@DenTotal, 0), 'N0')
                      + N' = $' + FORMAT(@Result, 'N2');
        END;

        INSERT INTO @Rules (RuleGroup, RuleText) VALUES (N'Calculation', @Calc);
        SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

        SELECT CAST(NULL AS NVARCHAR(100)) AS SourceTable, N'Formula' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               0 AS TotalRows, @Result AS TotalAmount, CAST(1 AS BIT) AS IsFormula;

        SELECT Section, Op AS [Operator], Component, Category, RowCode, Value, IsMoney, IsTotal
        FROM @Comp
        ORDER BY Seq;
        RETURN;
    END;

    SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

    /* ---- LIS rows ------------------------------------------------------------ */
    IF @IsLis = 1
    BEGIN
        ;WITH hit AS
        (
            SELECT n.*,
                   CASE WHEN @LisDistinct = 1 THEN n.Accession + N'|' + CONVERT(NVARCHAR(6), n.PY * 100 + n.PMo)
                        ELSE CONVERT(NVARCHAR(20), n.RowRef) END AS DedupeKey
            FROM #xL n
            WHERE EXISTS (SELECT 1 FROM #xLHit x WHERE x.RowRef = n.RowRef)
        ),
        r AS
        (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY DedupeKey ORDER BY PeriodDate) AS KeySeq,
                      COUNT(*)     OVER (PARTITION BY DedupeKey)                    AS Records
            FROM hit
        )
        SELECT Accession, OrderID, RequestCollectDate, AMDLBD, RN AS ResultedNot, PM AS PaymentMethod, CS AS ClaimStatus,
               CL AS ClientStatus, BN AS BilledorNot, BS AS BillingStatus, OS AS OrderStatus, SS AS SampleStatus,
               PanelCategory, Facility, Provider, PrimaryInsurance, Records, PeriodDate
        INTO #xLOut
        FROM r
        WHERE KeySeq = 1;

        SELECT N'dbo.LIMSMaster' AS SourceTable,
               CASE WHEN @LisDistinct = 1 THEN N'Count of distinct Accession' ELSE N'Count of samples' END AS Measure,
               CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #xLOut;

        SELECT Accession, OrderID, RequestCollectDate, AMDLBD, ResultedNot, PaymentMethod, ClaimStatus, ClientStatus,
               BilledorNot, BillingStatus, OrderStatus, SampleStatus, PanelCategory, Facility, Provider, PrimaryInsurance, Records
        FROM #xLOut
        ORDER BY PeriodDate, Accession
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- PMS R: ClientPaidListData, one line per specimen and month ---------- */
    IF @IsCpl = 1
    BEGIN
        ;WITH s AS
        (
            SELECT LTRIM(RTRIM(c.SpecimenID)) AS SpecimenID, TRY_CAST(c.BeginDOS AS DATE) AS BeginDOS,
                   c.VisitNum, c.Carrier, c.FinancialClass, c.ClinicName, c.Provider, c.ReferringProvider, c.PaymentStatus,
                   c.TotalCharge, c.CarrierPayment, c.PatientPayment
            FROM dbo.ClientPaidListData c
            WHERE NULLIF(LTRIM(RTRIM(c.SpecimenID)), N'') IS NOT NULL
              AND TRY_CAST(c.BeginDOS AS DATE) IS NOT NULL
              AND (@Year  = 0 OR YEAR(TRY_CAST(c.BeginDOS AS DATE))  = @Year)
              AND (@Month = 0 OR MONTH(TRY_CAST(c.BeginDOS AS DATE)) = @Month)
        ),
        r AS
        (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY SpecimenID, YEAR(BeginDOS), MONTH(BeginDOS) ORDER BY BeginDOS) AS rn,
                      COUNT(*)     OVER (PARTITION BY SpecimenID, YEAR(BeginDOS), MONTH(BeginDOS))                  AS Records
            FROM s
        )
        SELECT SpecimenID, BeginDOS, VisitNum, Carrier, FinancialClass, ClinicName, Provider, ReferringProvider, PaymentStatus,
               TotalCharge, CarrierPayment, PatientPayment, Records
        INTO #xCplOut
        FROM r
        WHERE rn = 1;

        SELECT N'dbo.ClientPaidListData' AS SourceTable, N'Count of distinct SpecimenID' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #xCplOut;

        SELECT SpecimenID, BeginDOS, VisitNum, Carrier, FinancialClass, ClinicName, Provider, ReferringProvider, PaymentStatus,
               TotalCharge, CarrierPayment, PatientPayment, Records
        FROM #xCplOut
        ORDER BY BeginDOS, SpecimenID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- $ rows: every matching claim row ------------------------------------ */
    IF @AmountCol IS NOT NULL
    BEGIN
        SELECT c.*,
               CASE @AmountCol
                   WHEN N'ChargeAmount'         THEN c.ChargeAmount
                   WHEN N'InsurancePayment'     THEN c.InsurancePayment
                   WHEN N'PatientPayment'       THEN c.PatientPayment
                   WHEN N'InsuranceAdjustments' THEN c.InsuranceAdjustments
                   WHEN N'PatientAdjustments'   THEN c.PatientAdjustments
                   WHEN N'PatientBalance'       THEN c.PatientBalance
                   WHEN N'InsuranceBalance'     THEN c.InsuranceBalance
               END AS Amount
        INTO #xCOut
        FROM #xC c
        JOIN #xHit h ON h.RowId = c.RowId AND h.HitCode = @HitCode;

        SELECT N'dbo.ClaimLevelData' AS SourceTable, N'Sum of ' + @AmountCol AS Measure, @AmountCol AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(ISNULL(SUM(Amount), 0) AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #xCOut;

        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
               ReferringProvider, SalesRepname, BilledUnbilled, ClaimStatus, Amount,
               ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance
        FROM #xCOut
        ORDER BY PY, PM, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- Count rows: one line per claim and month ---------------------------- */
    ;WITH r AS
    (
        SELECT c.*,
               ROW_NUMBER() OVER (PARTITION BY c.DedupeKey ORDER BY c.DateofService) AS rn,
               COUNT(*)     OVER (PARTITION BY c.DedupeKey)                          AS Claims
        FROM #xC c
        JOIN #xHit h ON h.RowId = c.RowId AND h.HitCode = @HitCode
    )
    SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
           ReferringProvider, SalesRepname, BilledUnbilled, ClaimStatus, Claims,
           ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance,
           PY, PM
    INTO #xAcc
    FROM r
    WHERE rn = 1;

    SELECT N'dbo.ClaimLevelData' AS SourceTable, N'Count of distinct ClaimID' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
           COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
    FROM #xAcc;

    SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
           ReferringProvider, SalesRepname, BilledUnbilled, ClaimStatus, Claims,
           ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance
    FROM #xAcc
    ORDER BY PY, PM, ClaimID
    OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
    FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
END;
GO

SET NOEXEC OFF;
GO

PRINT '40_RisingTides_ExecutiveSummary_CellRows.sql completed.';
GO
