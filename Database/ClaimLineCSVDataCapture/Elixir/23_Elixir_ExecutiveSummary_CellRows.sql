/* =============================================================================
   Elixir - Executive Summary cell rows (value click -> popup grid)
   File     : 23_Elixir_ExecutiveSummary_CellRows.sql
   Database : Elixir_LRN
   Object   : dbo.usp_GetElix_ExecutiveSummaryCellRows
   Requires : 15-19 (Elix_ES_* tables, refresh and read SPs) and
              Database/LabMetricsDashboard/FIX_Elixir_ClientFeedback_20260923.sql

   Returns the source rows behind one Executive Summary cell. The rules follow the procedures
   deployed on Elixir_LRN (read with OBJECT_DEFINITION on 2026-10-26; same on the localhost copy),
   which differ from the repo's 16 / 17 / 19 scripts - keep this file in step with the deployed ones:
     No page filter  -> the Elix_ES_* snapshot:
                        LIS  = usp_RefreshElix_ExecutiveSummary_LIS_Alt (DateOfCollection; row counts;
                               B.<panel> = distinct Accession on PanelName)
                        PMS / Cash = usp_RefreshElix_ExecutiveSummary (row counts, no base filter;
                               G / R / X include the 'Billed Amount 0' / 'Billed Amoutn 0' statuses,
                               P.2 = Partially Denied only), then usp_Elix_ES_ApplyClientCorrections
                               (F, J = distinct accessions; Q, S; I; Avg)
     Any page filter -> usp_GetElix_ExecutiveSummary's filtered path (distinct accessions; LIS from the
                        snapshot bounded by Year / Month / DOS month, or a live LIMSMaster scan on
                        PanelName / FacilityName / PhysicianName / SaleRepName).

   Distinct counts return one line per accession (Claims / Records = the source rows sharing it);
   row counts return one line per row. $ rows return every claim. Year Total cells without a filter
   count an accession once per month, as the grid sums its months.

   Parameters
     @Category / @RowCode   the clicked row (LIS A..E.6 and B.<Panel>, PMS F..P.3, Cash Q..X.3, Avg Y / Z / AA)
     @Year / @Month         the clicked column: (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetElix_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText - how the value is calculated, incl. page filters
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured column for $ rows)
   Formula rows (PMS I, Avg Y / Z / AA) return the formula and the calculation in Rules,
   IsFormula = 1, TotalAmount = the result, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal).
   ============================================================================= */

IF DB_NAME() NOT LIKE N'Elixir%'
BEGIN
    RAISERROR(N'23_Elixir_ExecutiveSummary_CellRows.sql must run on the Elixir lab database (Elixir_LRN).', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetElix_ExecutiveSummaryCellRows
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

    /* ---- Page filters (as usp_GetElix_ExecutiveSummary) -------------------- */
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

    -- LIS section source: 0 = snapshot rules, 1 = snapshot bounded by Year / Month / DOS month,
    -- 2 = live LIMSMaster scan (a Panel / Clinic / Provider / Rep filter or Billed Date mode).
    DECLARE @LisMode TINYINT = CASE
        WHEN @HasFilter = 0 THEN 0
        WHEN @HasPanel = 1 OR @HasClinic = 1 OR @HasProvider = 1 OR @HasRep = 1 OR @UseBilledDate = 1 THEN 2
        ELSE 1 END;

    -- The grid's Year Total for a count row is the sum of its months; filtered Avg year values
    -- (and every Grand Total the popup can open) count an accession once across the period.
    DECLARE @DedupeByMonth BIT = CASE WHEN @HasFilter = 0 AND @Year <> 0 AND @Month = 0 THEN 1 ELSE 0 END;

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
        ('LIS', 'A',   N'Total Samples',             N'Every sample (no status filter)', NULL, 0),
        ('LIS', 'B',   N'Billable Samples',          N'NewStatus = Billable', NULL, 0),
        ('LIS', 'C',   N'Billed',                    N'NewStatus = Billable AND BillCategory = Billed', NULL, 0),
        ('LIS', 'D',   N'Unbilled',                  N'NewStatus = Billable AND BillCategory = Not Billed', NULL, 0),
        ('LIS', 'D.1', N'Resulted yet to be billed', N'NewStatus = Billable AND BillCategory = Not Billed AND ResultStatus = Resulted', NULL, 0),
        ('LIS', 'E',   N'Other Samples',             N'NewStatus <> Billable (blank NewStatus included)', NULL, 0),
        ('LIS', 'E.1', N'Client Bill',               N'NewStatus = Client Bill', NULL, 0),
        ('LIS', 'E.2', N'Self Pay',                  N'NewStatus = Self Pay', NULL, 0),
        ('LIS', 'E.3', N'System Test',               N'NewStatus = System Test', NULL, 0),
        ('LIS', 'E.4', N'Deleted/Rejected',          N'NewStatus = Deleted/Rejected', NULL, 0),
        ('LIS', 'E.5', N'CIP/Pending',               N'NewStatus = CIP/Pending', NULL, 0),
        ('LIS', 'E.6', N'Yet to be validated',       N'NewStatus = Yet to be validated', NULL, 0),
        ('PMS', 'F',   N'No. of Billed Claims',
                       CASE WHEN @HasFilter = 0 THEN N'BillStatus = Billed AND ClaimStatus NOT IN (Billed Amount 0, Unbilled, Unbilled - PB)'
                            ELSE N'BillStatus = Billed AND ClaimStatus NOT IN (Billed Amount 0, Unbilled)' END, NULL, 0),
        ('PMS', 'G',   N'Unbilled Claims',
                       CASE WHEN @HasFilter = 0 THEN N'ClaimStatus IN (Unbilled, Unbilled - PB, Billed Amount 0, Billed Amoutn 0)'
                            ELSE N'ClaimStatus IN (Unbilled, Unbilled - PB)' END, NULL, 0),
        ('PMS', 'H',   N'Voided claims',             N'ClaimStatus = Voided', NULL, 0),
        ('PMS', 'I',   N'Billed Mismatches - LIS Accession Cannot be Matched',
                       CASE WHEN @HasFilter = 0
                            THEN N'Formula: MAX(No. of Billed Claims (PMS F) - LIS Billed (LIS C), 0) per month, for the same period'
                            ELSE N'Formula: Billed claims (BillStatus = Billed, any ClaimStatus) - LIS Billed samples (NewStatus = Billable AND BillCategory = Billed) per month, for the same period' END,
                       NULL, 1),
        ('PMS', 'J',   N'No. of Fully Paid Claims',
                       CASE WHEN @HasFilter = 0 THEN N'ClaimStatus = Fully Paid (any BillStatus)' ELSE N'BillStatus = Billed AND ClaimStatus = Fully Paid' END, NULL, 0),
        ('PMS', 'K',   N'No. of Fully Patient Responsibility Claims', N'BillStatus = Billed AND ClaimStatus = Patient Responsibility', NULL, 0),
        ('PMS', 'L',   N'No. of Patient Paid Claims', N'BillStatus = Billed AND ClaimStatus = Patient Payment', NULL, 0),
        ('PMS', 'M',   N'No. of Adjusted/Written Off Claims', N'BillStatus = Billed AND ClaimStatus = Fully Adjusted', NULL, 0),
        ('PMS', 'N',   N'No. of Partially Adjusted claims', N'BillStatus = Billed AND ClaimStatus = Partially Adjusted', NULL, 0),
        ('PMS', 'O',   N'No. of Partially Paid Claims', N'BillStatus = Billed AND ClaimStatus = Partially Paid', NULL, 0),
        ('PMS', 'P',   N'No. of Insurance Balance Claims', N'BillStatus = Billed AND ClaimStatus IN (Denied, No Response, Partially Denied)', NULL, 0),
        ('PMS', 'P.1', N'No. of Fully Denied Claims', N'BillStatus = Billed AND ClaimStatus = Denied', NULL, 0),
        ('PMS', 'P.2', N'No. of Partially Denied Claims',
                       CASE WHEN @HasFilter = 0 THEN N'BillStatus = Billed AND ClaimStatus = Partially Denied'
                            ELSE N'BillStatus = Billed AND ClaimStatus IN (Partially Adjusted, Partially Denied)' END, NULL, 0),
        ('PMS', 'P.3', N'No. of No Response from Payor Claims', N'BillStatus = Billed AND ClaimStatus = No Response', NULL, 0),
        ('Cash', 'Q',   N'Total Billed ($)',
                        CASE WHEN @HasFilter = 0 THEN N'BillStatus = Billed AND ClaimStatus NOT IN (Unbilled, Unbilled - PB, Billed Amount 0)'
                             ELSE N'BillStatus = Billed AND ClaimStatus NOT IN (Unbilled, Billed Amount 0)' END, N'ChargeAmount', 0),
        ('Cash', 'R',   N'Unbilled Claims ($)',
                        CASE WHEN @HasFilter = 0 THEN N'ClaimStatus IN (Unbilled, Unbilled PB, Unbilled - PB, Billed Amount 0, Billed Amoutn 0)'
                             ELSE N'ClaimStatus = Unbilled' END, N'ChargeAmount', 0),
        ('Cash', 'S',   N'Insurance Payment ($)',
                        CASE WHEN @HasFilter = 0 THEN N'ClaimStatus = Fully Paid (any BillStatus)' ELSE N'BillStatus = Billed AND ClaimStatus = Fully Paid' END, N'InsurancePayment', 0),
        ('Cash', 'T',   N'Patient Responsibility ($)', N'BillStatus = Billed', N'PatientBalance', 0),
        ('Cash', 'U',   N'Adjustments / Write Off ($)', N'BillStatus = Billed', N'InsuranceAdjustments', 0),
        ('Cash', 'V',   N'Patient Paid ($)',          N'BillStatus = Billed', N'PatientPayment', 0),
        ('Cash', 'W',   N'Partially Paid ($)',        N'BillStatus = Billed AND ClaimStatus = Partially Paid', N'InsurancePayment', 0),
        ('Cash', 'X',   N'Insurance Balance ($)',
                        CASE WHEN @HasFilter = 0 THEN N'BillStatus = Billed AND ClaimStatus NOT IN (Unbilled, Billed Amount 0, Billed Amoutn 0)'
                             ELSE N'BillStatus = Billed AND ClaimStatus NOT IN (Unbilled, Billed Amount 0)' END, N'InsuranceBalance', 0),
        ('Cash', 'X.1', N'Denials ($)',               N'BillStatus = Billed AND ClaimStatus = Denied', N'InsuranceBalance', 0),
        ('Cash', 'X.2', N'Partially Denied ($)',      N'BillStatus = Billed AND ClaimStatus IN (Partially Denied, Partially Paid, Partially Adjusted, Patient Responsibility)', N'InsuranceBalance', 0),
        ('Cash', 'X.3', N'No Response from Payor ($)', N'BillStatus = Billed AND ClaimStatus = No Response', N'InsuranceBalance', 0),
        ('Avg', 'Y',   N'Average Payment ($) - Total Pay/Billed Claims',
                       N'Formula: (Insurance Payment $ (Cash S) + Partially Paid $ (Cash W)) / No. of Billed Claims (PMS F)', NULL, 1),
        ('Avg', 'Z',   N'Average Payment ($) - Total Pay/Paid Claims',
                       N'Formula: Insurance Payment $ (Cash S) / No. of Fully Paid Claims (PMS J)', NULL, 1),
        ('Avg', 'AA',  N'Average Payment ($) - Total Pay/Adjudicated Claims',
                       CASE WHEN @HasFilter = 0
                            THEN N'Formula: (Insurance Payment $ + Partially Paid $ + Patient Paid $) / (Fully Paid + Fully Adjusted + Patient Responsibility + Patient Paid + Partially Adjusted + Partially Paid + Fully Denied + Partially Denied claims)'
                            ELSE N'Formula: (Insurance Payment $ + Partially Paid $ + Patient Paid $) / distinct Billed accessions with ClaimStatus IN (Fully Paid, Fully Adjusted, Patient Responsibility, Partially Paid, Fully Denied, Partially Denied); Year Total = sum of the monthly averages' END,
                       NULL, 1);

    -- LIS panel sub-rows: "B." + the PanelName value (snapshot and live scan alike).
    DECLARE @PanelVal NVARCHAR(400) = NULL;
    IF @Category = 'LIS' AND @RowCode LIKE N'B.%'
    BEGIN
        SET @PanelVal = LTRIM(RTRIM(SUBSTRING(@RowCode, 3, 400)));
        INSERT INTO @Def (Category, RowCode, Description, RuleText, AmountCol, IsFormula)
        VALUES ('LIS', N'B.*', @PanelVal, N'NewStatus = Billable AND PanelName = ' + @PanelVal, NULL, 0);
    END;

    DECLARE @DefCode NVARCHAR(20) = CASE WHEN @PanelVal IS NOT NULL THEN N'B.*' ELSE LEFT(@RowCode, 20) END;
    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @IsFormula BIT;
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @IsFormula = IsFormula
    FROM @Def WHERE Category = @Category AND UPPER(RowCode) = UPPER(@DefCode);

    IF @RuleText IS NULL OR LEN(@RowCode) > 20 AND @PanelVal IS NULL
    BEGIN
        DECLARE @RowCodeMsg NVARCHAR(100) = LEFT(@RowCode, 100);
        RAISERROR(N'usp_GetElix_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCodeMsg);
        RETURN;
    END;
    SET @RowCode = CASE WHEN @PanelVal IS NOT NULL THEN @RowCode ELSE UPPER(@DefCode) END;

    DECLARE @IsLis BIT = CASE WHEN @Category = 'LIS' THEN 1 ELSE 0 END;
    -- The snapshot's PMS rows count rows; F and J (client corrections) and every filtered row count
    -- distinct accessions.
    DECLARE @RowsCounted BIT = CASE WHEN @HasFilter = 0 AND @Category = 'PMS' AND @RowCode NOT IN (N'F', N'J') THEN 1 ELSE 0 END;
    -- LIS read live (distinct accessions, Accession not blank) or from the snapshot (row counts).
    DECLARE @LisLive BIT = CASE WHEN @IsLis = 1 THEN CASE WHEN @LisMode = 2 THEN 1 ELSE 0 END ELSE @HasFilter END;
    DECLARE @PeriodCol NVARCHAR(60) =
        CASE WHEN @IsLis = 1 THEN CASE WHEN @LisMode = 2 AND @UseBilledDate = 1 THEN N'BilledDate' ELSE N'DateOfCollection' END
             ELSE CASE WHEN @UseBilledDate = 1 THEN N'FirstBilledDate' ELSE N'DateofService' END END;
    DECLARE @PeriodText NVARCHAR(200) =
        CASE WHEN @Year = 0 THEN N'all periods (Grand Total)'
             WHEN @Month = 0 THEN N'year ' + CAST(@Year AS NVARCHAR(4)) + N' (Year Total)'
             ELSE DATENAME(MONTH, DATEFROMPARTS(@Year, @Month, 1)) + N' ' + CAST(@Year AS NVARCHAR(4)) END;

    /* ---- 1. Rules ----------------------------------------------------------- */
    DECLARE @Rules TABLE (RuleOrder INT IDENTITY(1,1), RuleGroup NVARCHAR(40), RuleText NVARCHAR(2000));
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Source', CASE WHEN @IsLis = 1 THEN N'dbo.LIMSMaster - samples (Accession not blank)'
                           ELSE N'dbo.ClaimLevelData - claims (AccessionNumber not blank)' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Base filter', CASE WHEN @HasFilter = 0 AND @IsLis = 0
                                THEN N'none - claims with no valid ' + @PeriodCol + N' reach the Grand Total only'
                                ELSE @PeriodCol + N' is a valid date' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Period', CASE WHEN @IsFormula = 1 AND @IsLis = 0
                           THEN CASE WHEN @UseBilledDate = 1 THEN N'FirstBilledDate' ELSE N'DateofService' END
                           ELSE @PeriodCol END + N' in ' + @PeriodText;
    INSERT INTO @Rules (RuleGroup, RuleText) VALUES (CASE WHEN @IsFormula = 1 THEN N'Formula' ELSE N'Row rule' END, @RuleText);
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Measure',
           CASE WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol + N' over every matching claim'
                WHEN @IsLis = 1 AND (@LisLive = 1 OR @PanelVal IS NOT NULL) THEN N'Count of distinct Accession - one line per sample (Records = LIMSMaster rows sharing it)'
                WHEN @IsLis = 1 THEN N'Count of LIMSMaster rows - one line per row'
                WHEN @RowsCounted = 1 THEN N'Count of claim rows with an AccessionNumber - one line per row'
                ELSE N'Count of distinct AccessionNumber - one line per accession (Claims = claim rows sharing it)' END
           + CASE WHEN @AmountCol IS NULL AND @DedupeByMonth = 1 THEN N', counted once per month as the Year Total adds its months' ELSE N'' END
    WHERE @IsFormula = 0;

    -- Page filters that reach the claim rows (PMS / Cash / Avg / PMS I).
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
        (CASE WHEN @UseBilledDate = 1 AND (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
              THEN N'Year / Month filters do not apply in Billed Date mode (as on the grid)' END),
        (CASE WHEN @HasPanel = 1    THEN N'Panelname IN (' + @Panels + N')' END),
        (CASE WHEN @HasClinic = 1   THEN N'ClinicName IN (' + @Clinics + N')' END),
        (CASE WHEN @HasProvider = 1 THEN N'ReferringProvider IN (' + @Providers + N')' END),
        (CASE WHEN @HasRep = 1      THEN N'SalesRepname IN (' + @Reps + N')' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL AND @IsLis = 0;

    -- Page filters that reach the LIS section (they differ from the claim rows, as on the grid).
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', v.Txt
    FROM (VALUES
        (CASE WHEN @LisMode = 1 AND (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL)
              THEN N'DateOfCollection year ' + ISNULL(CAST(@YearFrom AS NVARCHAR(4)), N'(any)') + N' - ' + ISNULL(CAST(@YearTo AS NVARCHAR(4)), N'(any)') END),
        (CASE WHEN @LisMode = 1 AND (@MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
              THEN N'DateOfCollection month ' + ISNULL(CAST(@MonthFrom AS NVARCHAR(2)), N'(any)') + N' - ' + ISNULL(CAST(@MonthTo AS NVARCHAR(2)), N'(any)') END),
        (CASE WHEN @LisMode = 1 AND (@DosFrom IS NOT NULL OR @DosTo IS NOT NULL)
              THEN N'DOS range applied to DateOfCollection by month: ' + ISNULL(CONVERT(NVARCHAR(7), @DosFrom, 120), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(7), @DosTo, 120), N'(any)') END),
        (CASE WHEN @LisMode = 2 AND @UseBilledDate = 1
              THEN N'BilledDate from ' + ISNULL(CONVERT(NVARCHAR(10), @BilledFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @BilledTo, 101), N'(any)') END),
        (CASE WHEN @LisMode = 2 AND @UseBilledDate = 0
                   AND (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL OR @DosFrom IS NOT NULL OR @DosTo IS NOT NULL)
              THEN N'Year / Month / DOS filters do not apply to the LIS section while a Panel / Clinic / Provider / Rep filter is set (as on the grid)' END),
        (CASE WHEN @LisMode = 2 AND @HasPanel = 1    THEN N'PanelName IN (' + @Panels + N')' END),
        (CASE WHEN @LisMode = 2 AND @HasClinic = 1   THEN N'FacilityName IN (' + @Clinics + N')' END),
        (CASE WHEN @LisMode = 2 AND @HasProvider = 1 THEN N'PhysicianName IN (' + @Providers + N')' END),
        (CASE WHEN @LisMode = 2 AND @HasRep = 1      THEN N'SaleRepName IN (' + @Reps + N')' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL AND @IsLis = 1;

    -- The LIS side of the filtered PMS I follows the read SP's #LisBilled, not the LIS section.
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter',
           N'LIS Billed samples: '
           + CASE WHEN @UseBilledDate = 1 THEN N'BilledDate in the Billed Date range'
                  ELSE N'DateOfCollection within the Year / Month range' END
           + CASE WHEN @HasPanel = 1 OR @HasClinic = 1 OR @HasProvider = 1 OR @HasRep = 1
                  THEN N', PanelName / FacilityName / PhysicianName / SaleRepName in the selected values' ELSE N'' END
    WHERE @HasFilter = 1 AND @RowCode = N'I' AND @Category = 'PMS';

    /* ---- Claim rows in scope (every PMS / Cash / Avg cell) ------------------- */
    CREATE TABLE #xC
    (
        RowId                INT IDENTITY(1,1) PRIMARY KEY,
        ClaimID              NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
        AccessionNumber      NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        DateofService        DATE NULL,
        FirstBilledDate      DATE NULL,
        PayerName_Raw        NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        Panelname            NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        ClinicName           NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        ReferringProvider    NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        SalesRepname         NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        BillStatus           NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        ClaimStatus          NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        BS                   NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        CS                   NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ChargeAmount         DECIMAL(18,2) NOT NULL,
        InsurancePayment     DECIMAL(18,2) NOT NULL,
        PatientPayment       DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL,
        PeriodDate           DATE NULL,
        PY                   INT NULL,
        PM                   INT NULL,
        DedupeKey            NVARCHAR(220) COLLATE DATABASE_DEFAULT NULL   -- NULL for a blank AccessionNumber
    );

    IF @IsLis = 0
        INSERT INTO #xC (ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
                         ReferringProvider, SalesRepname, BillStatus, ClaimStatus, BS, CS,
                         ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments,
                         InsuranceBalance, PatientBalance, PeriodDate, PY, PM, DedupeKey)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))),
            CONVERT(NVARCHAR(200), c.AccessionNumber),
            d.Dos, d.Fbd,
            c.PayerName_Raw, c.Panelname, c.ClinicName, c.ReferringProvider, c.SalesRepname,
            c.BillStatus, c.ClaimStatus,
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.BillStatus), N''))),
            ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.ClaimStatus))), N''),
            ISNULL(TRY_CAST(c.ChargeAmount         AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.InsurancePayment     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.PatientPayment       AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.InsuranceAdjustments AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.PatientAdjustments   AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.InsuranceBalance     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(c.PatientBalance       AS DECIMAL(18,2)), 0),
            p.PeriodDate, YEAR(p.PeriodDate), MONTH(p.PeriodDate),
            NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.AccessionNumber))), N'')
                + CASE WHEN @DedupeByMonth = 1 THEN N'|' + CONVERT(NVARCHAR(6), YEAR(p.PeriodDate) * 100 + MONTH(p.PeriodDate)) ELSE N'' END
        FROM dbo.ClaimLevelData c
        CROSS APPLY (SELECT TRY_CAST(c.DateofService AS DATE) AS Dos, TRY_CAST(c.FirstBilledDate AS DATE) AS Fbd) d
        CROSS APPLY (SELECT CASE WHEN @UseBilledDate = 1 THEN d.Fbd ELSE d.Dos END AS PeriodDate) p
        -- The snapshot has no base filter: blank accessions are counted by its row counts, and claims
        -- with no valid DOS only reach the (0,0) Grand Total.
        WHERE (p.PeriodDate IS NOT NULL OR (@HasFilter = 0 AND @Year = 0))
          AND (@HasFilter = 0 OR NULLIF(LTRIM(RTRIM(c.AccessionNumber)), N'') IS NOT NULL)
          AND (@Year  = 0 OR YEAR(p.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(p.PeriodDate) = @Month)
          AND (@UseBilledDate = 1 OR (
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
          AND (@HasRep      = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(c.SalesRepname,      N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Reps      + N',') COLLATE DATABASE_DEFAULT) > 0)
        OPTION (RECOMPILE);

    -- Row codes each claim counts towards (only the codes this cell needs).
    -- BB = Billed claims for the filtered PMS I; ADJ = the filtered AA denominator.
    DECLARE @Need TABLE (RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY);
    IF @IsLis = 0 AND @IsFormula = 0
        INSERT INTO @Need VALUES (@RowCode);
    ELSE IF @RowCode = N'I'
        INSERT INTO @Need VALUES (CASE WHEN @HasFilter = 0 THEN N'F' ELSE N'BB' END);
    ELSE IF @Category = 'Avg'
        INSERT INTO @Need SELECT v.RowCode
        FROM (VALUES (N'S'), (N'W'), (N'V'), (N'F'), (N'J'), (N'M'), (N'K'), (N'L'), (N'N'), (N'O'), (N'P.1'), (N'P.2'), (N'ADJ')) v(RowCode);

    CREATE TABLE #xHit (RowId INT NOT NULL, RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (RowCode, RowId));
    INSERT INTO #xHit (RowId, RowCode)
    SELECT c.RowId, r.RowCode
    FROM #xC c
    CROSS APPLY (VALUES
        (N'F',   CASE WHEN c.BS = N'Billed' AND c.CS NOT IN (N'Billed Amount 0', N'Unbilled')
                       AND (@HasFilter = 1 OR c.CS <> N'Unbilled - PB') THEN 1 ELSE 0 END),
        (N'G',   CASE WHEN c.CS IN (N'Unbilled', N'Unbilled - PB')
                        OR (@HasFilter = 0 AND c.CS IN (N'Billed Amount 0', N'Billed Amoutn 0')) THEN 1 ELSE 0 END),
        (N'H',   CASE WHEN c.CS = N'Voided' THEN 1 ELSE 0 END),
        (N'J',   CASE WHEN c.CS = N'Fully Paid' AND (@HasFilter = 0 OR c.BS = N'Billed') THEN 1 ELSE 0 END),
        (N'K',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Patient Responsibility' THEN 1 ELSE 0 END),
        (N'L',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Patient Payment' THEN 1 ELSE 0 END),
        (N'M',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Fully Adjusted' THEN 1 ELSE 0 END),
        (N'N',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Partially Adjusted' THEN 1 ELSE 0 END),
        (N'O',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Partially Paid' THEN 1 ELSE 0 END),
        (N'P',   CASE WHEN c.BS = N'Billed' AND c.CS IN (N'Denied', N'No Response', N'Partially Denied') THEN 1 ELSE 0 END),
        (N'P.1', CASE WHEN c.BS = N'Billed' AND c.CS = N'Denied' THEN 1 ELSE 0 END),
        (N'P.2', CASE WHEN c.BS = N'Billed' AND (c.CS = N'Partially Denied' OR (@HasFilter = 1 AND c.CS = N'Partially Adjusted')) THEN 1 ELSE 0 END),
        (N'P.3', CASE WHEN c.BS = N'Billed' AND c.CS = N'No Response' THEN 1 ELSE 0 END),
        (N'Q',   CASE WHEN c.BS = N'Billed' AND c.CS NOT IN (N'Unbilled', N'Billed Amount 0')
                       AND (@HasFilter = 1 OR c.CS <> N'Unbilled - PB') THEN 1 ELSE 0 END),
        (N'R',   CASE WHEN c.CS = N'Unbilled'
                        OR (@HasFilter = 0 AND c.CS IN (N'Unbilled PB', N'Unbilled - PB', N'Billed Amount 0', N'Billed Amoutn 0')) THEN 1 ELSE 0 END),
        (N'S',   CASE WHEN c.CS = N'Fully Paid' AND (@HasFilter = 0 OR c.BS = N'Billed') THEN 1 ELSE 0 END),
        (N'T',   CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'U',   CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'V',   CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'W',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Partially Paid' THEN 1 ELSE 0 END),
        (N'X',   CASE WHEN c.BS = N'Billed' AND c.CS NOT IN (N'Unbilled', N'Billed Amount 0')
                       AND (@HasFilter = 1 OR c.CS <> N'Billed Amoutn 0') THEN 1 ELSE 0 END),
        (N'X.1', CASE WHEN c.BS = N'Billed' AND c.CS = N'Denied' THEN 1 ELSE 0 END),
        (N'X.2', CASE WHEN c.BS = N'Billed' AND c.CS IN (N'Partially Denied', N'Partially Paid', N'Partially Adjusted', N'Patient Responsibility') THEN 1 ELSE 0 END),
        (N'X.3', CASE WHEN c.BS = N'Billed' AND c.CS = N'No Response' THEN 1 ELSE 0 END),
        (N'BB',  CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'ADJ', CASE WHEN c.BS = N'Billed' AND c.CS IN (N'Fully Paid', N'Fully Adjusted', N'Patient Responsibility', N'Partially Paid', N'Fully Denied', N'Partially Denied')
                      THEN 1 ELSE 0 END)
    ) r(RowCode, Hit)
    WHERE r.Hit = 1
      AND r.RowCode IN (SELECT RowCode FROM @Need);

    /* ---- LIS rows in scope (LIS cells, and the LIS side of PMS I) ----------- */
    -- LIS section : @LisMode rules above.
    -- PMS I       : no filter -> LIS C on the snapshot rules; filtered -> the read SP's #LisBilled
    --               (BilledDate in Billed Date mode, else DateOfCollection with the Year / Month
    --               range), with the Panel / Clinic / Provider / Rep filters.
    DECLARE @NeedLis BIT = CASE WHEN @IsLis = 1 OR @RowCode = N'I' THEN 1 ELSE 0 END;
    DECLARE @LisRow NVARCHAR(20) = CASE WHEN @IsLis = 0 THEN N'C' WHEN @PanelVal IS NOT NULL THEN N'B.*' ELSE @RowCode END;
    DECLARE @LisPeriodBilled BIT, @LisApplyYM BIT, @LisApplyDosMonth BIT, @LisApplyBilledBounds BIT, @LisApplyDims BIT, @LisUsePanelName BIT;
    IF @IsLis = 1
        SELECT @LisPeriodBilled      = CASE WHEN @LisMode = 2 THEN @UseBilledDate ELSE 0 END,
               @LisApplyYM           = CASE WHEN @LisMode = 1 THEN 1 ELSE 0 END,
               @LisApplyDosMonth     = CASE WHEN @LisMode = 1 THEN 1 ELSE 0 END,
               @LisApplyBilledBounds = CASE WHEN @LisMode = 2 THEN @UseBilledDate ELSE 0 END,
               @LisApplyDims         = CASE WHEN @LisMode = 2 THEN 1 ELSE 0 END,
               @LisUsePanelName      = 1;
    ELSE
        SELECT @LisPeriodBilled      = CASE WHEN @HasFilter = 1 THEN @UseBilledDate ELSE 0 END,
               @LisApplyYM           = CASE WHEN @HasFilter = 1 AND @UseBilledDate = 0 THEN 1 ELSE 0 END,
               @LisApplyDosMonth     = 0,
               @LisApplyBilledBounds = CASE WHEN @HasFilter = 1 THEN @UseBilledDate ELSE 0 END,
               @LisApplyDims         = @HasFilter,
               @LisUsePanelName      = 1;

    CREATE TABLE #xL
    (
        RowRef                   INT IDENTITY(1,1) PRIMARY KEY,
        Accession                NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        DateOfCollection         DATE NULL,
        BilledDate               DATE NULL,
        NewStatus                NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
        BillCategory             NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
        SubStatus                NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        ResultStatus             NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
        Panel                    NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        PanelName                NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        FacilityName             NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        PhysicianName            NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        SaleRepName              NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        PrimaryInsuranceProvider NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        PeriodDate               DATE NOT NULL,
        PY                       INT NOT NULL,
        PM                       INT NOT NULL,
        DedupeKey                NVARCHAR(120) COLLATE DATABASE_DEFAULT NOT NULL
    );

    IF @NeedLis = 1
        INSERT INTO #xL (Accession, DateOfCollection, BilledDate, NewStatus, BillCategory, SubStatus, ResultStatus,
                         Panel, PanelName, FacilityName, PhysicianName, SaleRepName, PrimaryInsuranceProvider,
                         PeriodDate, PY, PM, DedupeKey)
        SELECT
            k.Acc, k.Doc, k.Bd,
            CONVERT(NVARCHAR(100), l.NewStatus), CONVERT(NVARCHAR(100), l.BillCategory), CONVERT(NVARCHAR(200), l.SubStatus),
            CONVERT(NVARCHAR(100), l.ResultStatus),
            CONVERT(NVARCHAR(300), l.Panel), CONVERT(NVARCHAR(300), l.PanelName), CONVERT(NVARCHAR(300), l.FacilityName),
            CONVERT(NVARCHAR(300), l.PhysicianName), CONVERT(NVARCHAR(300), l.SaleRepName), CONVERT(NVARCHAR(300), l.PrimaryInsuranceProvider),
            p.PeriodDate, YEAR(p.PeriodDate), MONTH(p.PeriodDate),
            k.Acc + CASE WHEN @DedupeByMonth = 1 THEN N'|' + CONVERT(NVARCHAR(6), YEAR(p.PeriodDate) * 100 + MONTH(p.PeriodDate)) ELSE N'' END
        FROM dbo.LIMSMaster l
        CROSS APPLY (
            SELECT LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.Accession), N'')))          AS Acc,
                   TRY_CAST(l.DateOfCollection AS DATE)                                   AS Doc,
                   TRY_CAST(l.BilledDate AS DATE)                                         AS Bd,
                   LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.NewStatus), N'')))         AS NS,
                   LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.BillCategory), N'')))      AS BC,
                   LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.ResultStatus), N'')))      AS RS,
                   LTRIM(RTRIM(ISNULL(CASE WHEN @LisUsePanelName = 1 THEN CONVERT(NVARCHAR(300), l.PanelName)
                                           ELSE CONVERT(NVARCHAR(300), l.Panel) END, N''))) AS PN
        ) k
        CROSS APPLY (SELECT CASE WHEN @LisPeriodBilled = 1 THEN k.Bd ELSE k.Doc END AS PeriodDate) p
        -- The snapshot reads every LIMSMaster row; the live scans need an Accession.
        WHERE (@LisLive = 0 OR k.Acc <> N'')
          AND p.PeriodDate IS NOT NULL
          AND (@Year  = 0 OR YEAR(p.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(p.PeriodDate) = @Month)
          AND (@LisApplyYM = 0 OR (
                   (@YearFrom  IS NULL OR YEAR(p.PeriodDate)  >= @YearFrom)
               AND (@YearTo    IS NULL OR YEAR(p.PeriodDate)  <= @YearTo)
               AND (@MonthFrom IS NULL OR MONTH(p.PeriodDate) >= @MonthFrom)
               AND (@MonthTo   IS NULL OR MONTH(p.PeriodDate) <= @MonthTo)))
          AND (@LisApplyDosMonth = 0 OR (
                   (@DosFrom IS NULL OR YEAR(p.PeriodDate) * 100 + MONTH(p.PeriodDate) >= YEAR(@DosFrom) * 100 + MONTH(@DosFrom))
               AND (@DosTo   IS NULL OR YEAR(p.PeriodDate) * 100 + MONTH(p.PeriodDate) <= YEAR(@DosTo)   * 100 + MONTH(@DosTo))))
          AND (@LisApplyBilledBounds = 0 OR (
                   (@BilledFrom IS NULL OR p.PeriodDate >= @BilledFrom)
               AND (@BilledTo   IS NULL OR p.PeriodDate <= @BilledTo)))
          AND (@LisApplyDims = 0 OR (
                   (@HasPanel    = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.PanelName),     N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Panels    + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasClinic   = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.FacilityName),  N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Clinics   + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasProvider = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.PhysicianName), N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Providers + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasRep      = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.SaleRepName),   N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Reps      + N',') COLLATE DATABASE_DEFAULT) > 0)))
          AND (   @LisRow = N'A'
               OR (@LisRow = N'B'   AND k.NS = N'Billable')
               OR (@LisRow = N'B.*' AND k.NS = N'Billable' AND k.PN <> N'' AND k.PN = @PanelVal)
               OR (@LisRow = N'C'   AND k.NS = N'Billable' AND k.BC = N'Billed')
               OR (@LisRow = N'D'   AND k.NS = N'Billable' AND k.BC = N'Not Billed')
               OR (@LisRow = N'D.1' AND k.NS = N'Billable' AND k.BC = N'Not Billed' AND k.RS = N'Resulted')
               OR (@LisRow = N'E'   AND k.NS <> N'Billable')
               OR (@LisRow = N'E.1' AND k.NS = N'Client Bill')
               OR (@LisRow = N'E.2' AND k.NS = N'Self Pay')
               OR (@LisRow = N'E.3' AND k.NS = N'System Test')
               OR (@LisRow = N'E.4' AND k.NS = N'Deleted/Rejected')
               OR (@LisRow = N'E.5' AND k.NS = N'CIP/Pending')
               OR (@LisRow = N'E.6' AND k.NS = N'Yet to be validated'))
        OPTION (RECOMPILE);

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

        IF @RowCode = N'I'
        BEGIN
            -- Per month present in the claim rows, as the grid's I rows; Year / Grand Totals add the months.
            DECLARE @Mon TABLE (PY INT NOT NULL, PM INT NOT NULL, Billed INT NOT NULL, Lis INT NOT NULL, PRIMARY KEY (PY, PM));
            INSERT INTO @Mon (PY, PM, Billed, Lis)
            SELECT m.PY, m.PM,
                   ISNULL((SELECT COUNT(DISTINCT c.DedupeKey) FROM #xC c JOIN #xHit h ON h.RowId = c.RowId
                           WHERE c.PY = m.PY AND c.PM = m.PM), 0),
                   -- LIS C on the snapshot counts rows; the filtered #LisBilled counts distinct accessions.
                   ISNULL((SELECT CASE WHEN @LisLive = 1 THEN COUNT(DISTINCT l.Accession) ELSE COUNT(*) END
                           FROM #xL l WHERE l.PY = m.PY AND l.PM = m.PM), 0)
            FROM (SELECT DISTINCT PY, PM FROM #xC WHERE PY IS NOT NULL) m;

            DECLARE @BilledSum INT = ISNULL((SELECT SUM(Billed) FROM @Mon), 0);
            DECLARE @LisSum    INT = ISNULL((SELECT SUM(Lis) FROM @Mon), 0);
            SET @Result = ISNULL((SELECT SUM(CASE WHEN @HasFilter = 0 AND Billed - Lis < 0 THEN 0 ELSE Billed - Lis END) FROM @Mon), 0);

            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  CASE WHEN @HasFilter = 0 THEN 'PMS' END, CASE WHEN @HasFilter = 0 THEN N'F' END,
                    CASE WHEN @HasFilter = 0 THEN N'No. of Billed Claims' ELSE N'Billed claims (BillStatus = Billed, any ClaimStatus)' END,
                    @BilledSum, 0, 0),
                (2, N'Calculation', N'-', CASE WHEN @HasFilter = 0 THEN 'LIS' END, CASE WHEN @HasFilter = 0 THEN N'C' END,
                    CASE WHEN @HasFilter = 0 THEN N'LIS Billed' ELSE N'LIS Billed samples (NewStatus = Billable AND BillCategory = Billed)' END,
                    @LisSum, 0, 0),
                (9, N'Result', N'=', 'PMS', N'I', N'Billed Mismatches - LIS Accession Cannot be Matched', @Result, 0, 1);

            SET @Calc = CASE WHEN (SELECT COUNT(*) FROM @Mon) <= 1 AND @HasFilter = 0
                             THEN N'MAX(' + FORMAT(@BilledSum, 'N0') + N' - ' + FORMAT(@LisSum, 'N0') + N', 0) = ' + FORMAT(@Result, 'N0')
                             WHEN (SELECT COUNT(*) FROM @Mon) <= 1
                             THEN FORMAT(@BilledSum, 'N0') + N' - ' + FORMAT(@LisSum, 'N0') + N' = ' + FORMAT(@Result, 'N0')
                             ELSE N'Sum of the monthly ' + CASE WHEN @HasFilter = 0 THEN N'MAX(F - C, 0)' ELSE N'Billed - LIS Billed' END
                                  + N' values = ' + FORMAT(@Result, 'N0') END;
        END
        ELSE IF @HasFilter = 1 AND @Year <> 0 AND @Month = 0
        BEGIN
            -- Filtered Avg rows have no year value, so the grid's Year Total adds the monthly
            -- averages (each returned at 2 decimals).
            DECLARE @AvgMon TABLE (PY INT NOT NULL, PM INT NOT NULL, Num DECIMAL(38,2) NOT NULL, Den INT NOT NULL, PRIMARY KEY (PY, PM));
            INSERT INTO @AvgMon (PY, PM, Num, Den)
            SELECT m.PY, m.PM,
                   ISNULL((SELECT SUM(c.InsurancePayment) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId
                           WHERE c.PY = m.PY AND c.PM = m.PM
                             AND h.RowCode IN (N'S', CASE WHEN @RowCode IN (N'Y', N'AA') THEN N'W' END)), 0)
                 + ISNULL((SELECT SUM(c.PatientPayment) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId
                           WHERE c.PY = m.PY AND c.PM = m.PM AND @RowCode = N'AA' AND h.RowCode = N'V'), 0),
                   ISNULL((SELECT COUNT(DISTINCT c.DedupeKey) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId
                           WHERE c.PY = m.PY AND c.PM = m.PM
                             AND h.RowCode = CASE @RowCode WHEN N'Y' THEN N'F' WHEN N'Z' THEN N'J' ELSE N'ADJ' END), 0)
            FROM (SELECT DISTINCT PY, PM FROM #xC WHERE PY IS NOT NULL) m;

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT ROW_NUMBER() OVER (ORDER BY PM), N'Calculation',
                   CASE WHEN ROW_NUMBER() OVER (ORDER BY PM) = 1 THEN N'' ELSE N'+' END, NULL, NULL,
                   DATENAME(MONTH, DATEFROMPARTS(PY, PM, 1)) + N' ' + CAST(PY AS NVARCHAR(4)) + N' average ($'
                       + FORMAT(Num, 'N2') + N' / ' + FORMAT(Den, 'N0') + N')',
                   CASE WHEN Den > 0 THEN CONVERT(DECIMAL(18,2), Num / Den) ELSE 0 END, 1, 0
            FROM @AvgMon;

            SET @Result = ISNULL((SELECT SUM(CASE WHEN Den > 0 THEN CONVERT(DECIMAL(18,2), Num / Den) ELSE 0 END) FROM @AvgMon), 0);

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 999, N'Result', N'=', 'Avg', @RowCode, d.Description, @Result, 1, 1
            FROM @Def d WHERE d.Category = 'Avg' AND d.RowCode = @RowCode;

            SET @Calc = N'Sum of the monthly averages (the grid''s Year Total adds them) = $' + FORMAT(@Result, 'N2');
        END
        ELSE
        BEGIN
            -- Avg: component values over the cell scope (counts once per accession, or once per
            -- accession and month for an unfiltered Year Total, as the snapshot adds its months).
            DECLARE @Val TABLE (RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY, Value DECIMAL(18,2) NOT NULL);
            INSERT INTO @Val (RowCode, Value)
            SELECT n.RowCode,
                   ISNULL(CASE WHEN d.AmountCol IS NULL AND @HasFilter = 0 AND n.RowCode NOT IN (N'F', N'J')
                               THEN (SELECT CAST(COUNT(c.AccessionNumber) AS DECIMAL(18,2))
                                     FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.RowCode = n.RowCode)
                               WHEN d.AmountCol IS NULL
                               THEN (SELECT CAST(COUNT(DISTINCT c.DedupeKey) AS DECIMAL(18,2))
                                     FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.RowCode = n.RowCode)
                               WHEN d.AmountCol = N'PatientPayment'
                               THEN (SELECT SUM(c.PatientPayment)
                                     FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.RowCode = n.RowCode)
                               ELSE (SELECT SUM(c.InsurancePayment)
                                     FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.RowCode = n.RowCode) END, 0)
            FROM @Need n
            LEFT JOIN @Def d ON d.RowCode = n.RowCode AND d.Category IN ('PMS', 'Cash');

            DECLARE @Num TABLE (Seq INT, RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT);
            DECLARE @Den TABLE (Seq INT, RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT);
            INSERT INTO @Num VALUES (1, N'S');
            IF @RowCode IN (N'Y', N'AA') INSERT INTO @Num VALUES (2, N'W');
            IF @RowCode = N'AA'          INSERT INTO @Num VALUES (3, N'V');
            IF @RowCode = N'Y'  INSERT INTO @Den VALUES (11, N'F');
            IF @RowCode = N'Z'  INSERT INTO @Den VALUES (11, N'J');
            IF @RowCode = N'AA' AND @HasFilter = 0
                INSERT INTO @Den VALUES (11, N'J'), (12, N'M'), (13, N'K'), (14, N'L'), (15, N'N'), (16, N'O'), (17, N'P.1'), (18, N'P.2');
            IF @RowCode = N'AA' AND @HasFilter = 1
                INSERT INTO @Den VALUES (11, N'ADJ');

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT x.Seq, N'Numerator', CASE WHEN x.Seq = 1 THEN N'' ELSE N'+' END, 'Cash', x.RowCode, d.Description, v.Value, 1, 0
            FROM @Num x JOIN @Val v ON v.RowCode = x.RowCode JOIN @Def d ON d.Category = 'Cash' AND d.RowCode = x.RowCode;
            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 4, N'Numerator', N'=', NULL, NULL, N'Total Payments ($)', SUM(v.Value), 1, 1
            FROM @Num x JOIN @Val v ON v.RowCode = x.RowCode;

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT x.Seq, N'Denominator', CASE WHEN x.Seq = 11 THEN N'' ELSE N'+' END,
                   CASE WHEN x.RowCode = N'ADJ' THEN NULL ELSE 'PMS' END,
                   CASE WHEN x.RowCode = N'ADJ' THEN NULL ELSE x.RowCode END,
                   ISNULL(d.Description, N'Adjudicated claims (distinct accessions)'), v.Value, 0, 0
            FROM @Den x JOIN @Val v ON v.RowCode = x.RowCode
            LEFT JOIN @Def d ON d.Category = 'PMS' AND d.RowCode = x.RowCode;
            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 19, N'Denominator', N'=', NULL, NULL,
                   CASE @RowCode WHEN N'Y' THEN N'Billed claims' WHEN N'Z' THEN N'Paid claims' ELSE N'Adjudicated claims' END,
                   SUM(v.Value), 0, 1
            FROM @Den x JOIN @Val v ON v.RowCode = x.RowCode;

            DECLARE @NumTotal DECIMAL(18,2) = (SELECT Value FROM @Comp WHERE Section = N'Numerator' AND IsTotal = 1);
            DECLARE @DenTotal DECIMAL(18,2) = (SELECT Value FROM @Comp WHERE Section = N'Denominator' AND IsTotal = 1);
            SET @Result = CASE WHEN ISNULL(@DenTotal, 0) = 0 THEN 0
                               ELSE CONVERT(DECIMAL(18,2), ROUND(CONVERT(DECIMAL(38,6), @NumTotal) / CONVERT(DECIMAL(38,6), @DenTotal), 2)) END;

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 29, N'Result', N'=', 'Avg', @RowCode, d.Description, @Result, 1, 1
            FROM @Def d WHERE d.Category = 'Avg' AND d.RowCode = @RowCode;

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

    /* ---- LIS rows: one line per accession ------------------------------------ */
    IF @IsLis = 1
    BEGIN
        -- Distinct accessions on the live scans and the B.<panel> rows; one line per row otherwise.
        ;WITH k AS
        (
            SELECT *, CASE WHEN @LisLive = 1 OR @PanelVal IS NOT NULL THEN DedupeKey
                           ELSE CONVERT(NVARCHAR(20), RowRef) END AS LineKey
            FROM #xL
        ),
        r AS
        (
            SELECT *,
                   ROW_NUMBER() OVER (PARTITION BY LineKey ORDER BY PeriodDate) AS rn,
                   COUNT(*)     OVER (PARTITION BY LineKey)                     AS Records
            FROM k
        )
        SELECT Accession, DateOfCollection, BilledDate, NewStatus, BillCategory, SubStatus, ResultStatus,
               Panel, PanelName, FacilityName, PhysicianName, SaleRepName, PrimaryInsuranceProvider, Records, PeriodDate
        INTO #xLOut
        FROM r
        WHERE rn = 1;

        SELECT N'dbo.LIMSMaster' AS SourceTable,
               CASE WHEN @LisLive = 1 OR @PanelVal IS NOT NULL THEN N'Count of distinct samples' ELSE N'Count of samples' END AS Measure,
               CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #xLOut;

        SELECT Accession, DateOfCollection, BilledDate, NewStatus, BillCategory, SubStatus, ResultStatus,
               Panel, PanelName, FacilityName, PhysicianName, SaleRepName, PrimaryInsuranceProvider, Records
        FROM #xLOut
        ORDER BY PeriodDate, Accession
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- $ rows: every matching claim ---------------------------------------- */
    IF @AmountCol IS NOT NULL
    BEGIN
        SELECT c.*,
               CASE @AmountCol
                   WHEN N'ChargeAmount'         THEN c.ChargeAmount
                   WHEN N'InsurancePayment'     THEN c.InsurancePayment
                   WHEN N'PatientPayment'       THEN c.PatientPayment
                   WHEN N'PatientBalance'       THEN c.PatientBalance
                   WHEN N'InsuranceAdjustments' THEN c.InsuranceAdjustments
                   WHEN N'InsuranceBalance'     THEN c.InsuranceBalance
               END AS Amount
        INTO #xCOut
        FROM #xC c
        JOIN #xHit h ON h.RowId = c.RowId AND h.RowCode = @RowCode;

        SELECT N'dbo.ClaimLevelData' AS SourceTable, N'Sum of ' + @AmountCol AS Measure, @AmountCol AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(ISNULL(SUM(Amount), 0) AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #xCOut;

        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
               ReferringProvider, SalesRepname, BillStatus, ClaimStatus, Amount,
               ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance
        FROM #xCOut
        ORDER BY PeriodDate, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- Count rows: one line per accession, or per row for row counts ------- */
    ;WITH k AS
    (
        SELECT c.*, CASE WHEN @RowsCounted = 1 THEN CONVERT(NVARCHAR(20), c.RowId) ELSE c.DedupeKey END AS LineKey
        FROM #xC c
        JOIN #xHit h ON h.RowId = c.RowId AND h.RowCode = @RowCode
        WHERE (@RowsCounted = 1 AND c.AccessionNumber IS NOT NULL) OR (@RowsCounted = 0 AND c.DedupeKey IS NOT NULL)
    ),
    r AS
    (
        SELECT k.*,
               ROW_NUMBER() OVER (PARTITION BY k.LineKey ORDER BY k.PeriodDate, k.ClaimID) AS rn,
               COUNT(*)     OVER (PARTITION BY k.LineKey)                                 AS Claims
        FROM k
    )
    SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
           ReferringProvider, SalesRepname, BillStatus, ClaimStatus, Claims,
           ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance,
           PeriodDate
    INTO #xAcc
    FROM r
    WHERE rn = 1;

    SELECT N'dbo.ClaimLevelData' AS SourceTable,
           CASE WHEN @RowsCounted = 1 THEN N'Count of claim rows' ELSE N'Count of distinct accessions' END AS Measure,
           CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
           COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
    FROM #xAcc;

    SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
           ReferringProvider, SalesRepname, BillStatus, ClaimStatus, Claims,
           ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance
    FROM #xAcc
    ORDER BY PeriodDate, AccessionNumber
    OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
    FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
END;
GO

SET NOEXEC OFF;
GO

PRINT '23_Elixir_ExecutiveSummary_CellRows.sql completed.';
GO
