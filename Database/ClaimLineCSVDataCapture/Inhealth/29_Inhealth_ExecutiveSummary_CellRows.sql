/* =============================================================================
   InHealth DTR - Executive Summary cell rows (value click -> popup grid)
   File     : 29_Inhealth_ExecutiveSummary_CellRows.sql
   Database : InHealthDTRLRN
   Object   : dbo.usp_GetInh_ExecutiveSummaryCellRows

   Returns the source rows behind one Executive Summary cell. The rules follow the procedures
   deployed on InHealthDTRLRN (read with OBJECT_DEFINITION on 2026-10-26), which differ from the
   repo's 23 / 24 / 26 / 40 / 42 scripts - keep this file in step with the deployed ones:
     No page filter  -> the Inhealth_ES_* snapshot:
                        LIS  = usp_RefreshInh_ExecutiveSummary_LIS_Alt (LastTest month, LRNPanelName)
                        PMS / Cash = usp_RefreshInh_ExecutiveSummary; G and Avg = usp_Inh_ES_ApplyClientCorrections
     Any page filter -> usp_GetInh_ExecutiveSummary's live path (LIS on Entry_DateCreated / BilledDate,
                        'FullyDenied' spelling, K = Complete W/O only, W.2 = Partially Denied, unrounded Avg).

   Counts: PMS rows count claim rows, so they return one line per claim. LIS A / B on the snapshot count
   rows; every other LIS count is COUNT(DISTINCT OrderID) and returns one line per OrderID and month
   (the grid's Year / Grand Totals add the months).

   Parameters
     @Category / @RowCode   the clicked row (LIS A..E.7 and B1.<LRNPanelName>, PMS F..O.3, Cash P..W.3, Avg X / Y / Z)
     @Year / @Month         the clicked column: (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetInh_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText - how the value is calculated, incl. page filters
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured column for $ rows)
   Formula rows (PMS G, Avg X / Y / Z) return the formula and the calculation in Rules,
   IsFormula = 1, TotalAmount = the result, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal).
   ============================================================================= */

IF DB_NAME() NOT LIKE N'%InHealth%'
BEGIN
    RAISERROR(N'29_Inhealth_ExecutiveSummary_CellRows.sql must run on the InHealth DTR lab database (InHealthDTRLRN).', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetInh_ExecutiveSummaryCellRows
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

    SET @Category  = LTRIM(RTRIM(ISNULL(@Category, '')));
    SET @RowCode   = LTRIM(RTRIM(ISNULL(@RowCode, N'')));
    SET @Year      = ISNULL(@Year, 0);
    SET @Month     = ISNULL(@Month, 0);
    -- The read SP treats 0 as "no Year / Month filter".
    SET @YearFrom  = NULLIF(@YearFrom, 0);
    SET @YearTo    = NULLIF(@YearTo, 0);
    SET @MonthFrom = NULLIF(@MonthFrom, 0);
    SET @MonthTo   = NULLIF(@MonthTo, 0);
    IF ISNULL(@Page, 0) < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 0 SET @PageSize = 100;

    /* ---- Page filters (as usp_GetInh_ExecutiveSummary) --------------------- */
    DECLARE @HasFilter BIT = CASE
        WHEN @YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL
          OR @DosFrom  IS NOT NULL OR @DosTo  IS NOT NULL OR @BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Panels)),    N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Clinics)),   N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Reps)),      N'') IS NOT NULL
        THEN 1 ELSE 0 END;

    DECLARE @BucketByBilled BIT = CASE WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
                                         AND @DosFrom IS NULL AND @DosTo IS NULL THEN 1 ELSE 0 END;

    DECLARE @HasPanel    BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Panels,    N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;
    DECLARE @HasClinic   BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Clinics,   N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;
    DECLARE @HasProvider BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Providers, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;
    DECLARE @HasRep      BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Reps,      N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;

    -- Live path: the denied status is spelled 'FullyDenied' there; the snapshot uses 'Fully Denied'.
    DECLARE @Denied NVARCHAR(20) = CASE WHEN @HasFilter = 1 THEN N'FullyDenied' ELSE N'Fully Denied' END;

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
        ('LIS', 'A',   N'Total Samples',         N'NA is blank', NULL, 0),
        ('LIS', 'B',   N'Billable Samples',      N'NA is blank AND SampleStatus = Billable', NULL, 0),
        ('LIS', 'C',   N'Billed',                N'NA is blank AND SampleStatus = Billable AND BillCategory = Billed', NULL, 0),
        ('LIS', 'C.1', N'Billed Via AMD',        N'NA is blank AND SampleStatus = Billable AND BillCategory = Billed AND SubStatus = Billed Via AMD', NULL, 0),
        ('LIS', 'D',   N'Unbilled',              N'NA is blank AND SampleStatus = Billable AND BillCategory = Not Billed', NULL, 0),
        ('LIS', 'D.1', N'Nexum_Claim_scrubber_Eligibility', N'NA is blank AND SampleStatus = Billable AND BillCategory = Not Billed AND SubStatus = Nexum_Claim_scrubber_Eligibility', NULL, 0),
        ('LIS', 'D.2', N'Requires Review',       N'NA is blank AND SampleStatus = Billable AND BillCategory = Not Billed AND SubStatus = Requires Review', NULL, 0),
        ('LIS', 'D.3', N'Entered in AMD but not billed', N'NA is blank AND SampleStatus = Billable AND BillCategory = Not Billed AND SubStatus = Entered in AMD but not billed', NULL, 0),
        ('LIS', 'D.4', N'Nexum Pre Processing Queue', N'NA is blank AND SampleStatus = Billable AND BillCategory = Not Billed AND SubStatus = Nexum Pre Processing Queue', NULL, 0),
        ('LIS', 'D.5', N'Nexum_Claim_scrubber_AMD Output', N'NA is blank AND SampleStatus = Billable AND BillCategory = Not Billed AND SubStatus = Nexum_Claim_scrubber_AMD Output', NULL, 0),
        ('LIS', 'D.6', N'Nexum_Claim_scrubber_Diagnosis Validity', N'NA is blank AND SampleStatus = Billable AND BillCategory = Not Billed AND SubStatus = Nexum_Claim_scrubber_Diagnosis Validity', NULL, 0),
        ('LIS', 'E',   N'Other Samples',         N'NA is blank AND SampleStatus = Other Samples', NULL, 0),
        ('LIS', 'E.1', N'Billed',                N'NA is blank AND SampleStatus = Other Samples AND BillCategory = Billed', NULL, 0),
        ('LIS', 'E.2', N'Unbilled',              N'NA is blank AND SampleStatus = Other Samples AND BillCategory = Not Billed', NULL, 0),
        ('LIS', 'E.3', N'Other Samples (LIS Table provides Breakdown)', N'Label row - always 0', NULL, 0),
        ('LIS', 'E.4', N'Self Pay',              N'NA is blank AND SampleStatus = Self Pay', NULL, 0),
        ('LIS', 'E.5', N'Deleted/Rejected',      N'NA is blank AND SampleStatus = Deleted/Rejected', NULL, 0),
        ('LIS', 'E.6', N'Duplicate',             N'NA is blank AND SampleStatus = Duplicate', NULL, 0),
        ('LIS', 'E.7', N'System Test',           N'NA is blank AND SampleStatus = System Test', NULL, 0),
        ('PMS', 'F',   N'No. of Billed Claims',  N'BillStatus = Billed', NULL, 0),
        ('PMS', 'G',   N'Billed Mismatches',
                       CASE WHEN @HasFilter = 0
                            THEN N'Formula: MAX(No. of Billed Claims (PMS F) - (LIS Billed (LIS C) + Other Samples Billed (LIS E.1)), 0) per month'
                            ELSE N'Formula: No. of Billed Claims (PMS F) - LIMSMaster samples with BillCategory = Billed (distinct OrderID, any NA / SampleStatus) per month' END,
                       NULL, 1),
        ('PMS', 'H',   N'No. of UnBilled Claims', N'BillStatus = Unbilled', NULL, 0),
        ('PMS', 'H.1', N'Unbilled',              N'BillStatus = Unbilled AND ClaimStatus = Unbilled', NULL, 0),
        ('PMS', 'H.2', N'Unbilled - Patient Balance', N'BillStatus = Unbilled AND ClaimStatus = Unbilled - Patient Balance', NULL, 0),
        ('PMS', 'I',   N'No. of Fully Paid Claims', N'BillStatus = Billed AND ClaimStatus = Fully Paid', NULL, 0),
        ('PMS', 'J',   N'No. of Patient Responsibility Claims', N'BillStatus = Billed AND ClaimStatus = Patient Responsibility', NULL, 0),
        ('PMS', 'K',   N'No. of Fully Adjusted Claims',
                       CASE WHEN @HasFilter = 0 THEN N'BillStatus = Billed AND ClaimStatus IN (Complete W/O, Fully Adjusted)'
                            ELSE N'BillStatus = Billed AND ClaimStatus = Complete W/O' END, NULL, 0),
        ('PMS', 'L',   N'No. of Partially Adjusted Claims', N'BillStatus = Billed AND ClaimStatus = Partially Adjusted', NULL, 0),
        ('PMS', 'M',   N'No. of Patient Payments Claims', N'BillStatus = Billed AND ClaimStatus = Patient Payment', NULL, 0),
        ('PMS', 'N',   N'No. of Partially Paid Claims', N'BillStatus = Billed AND ClaimStatus = Partially Paid', NULL, 0),
        ('PMS', 'O',   N'No. of Insurance Balance Claims', N'BillStatus = Billed AND ClaimStatus IN (' + @Denied + N', Partially Denied, No Response)', NULL, 0),
        ('PMS', 'O.1', N'No. of Denied Claims',  N'BillStatus = Billed AND ClaimStatus = ' + @Denied, NULL, 0),
        ('PMS', 'O.2', N'No. of Partially Denied Claims', N'BillStatus = Billed AND ClaimStatus = Partially Denied', NULL, 0),
        ('PMS', 'O.3', N'No. of No Response from Payor Claims', N'BillStatus = Billed AND ClaimStatus = No Response', NULL, 0),
        ('Cash', 'P',   N'Total Billed ($)',      N'BillStatus = Billed', N'ChargeAmount', 0),
        ('Cash', 'Q',   N'Total Unbilled ($)',    N'BillStatus = Unbilled', N'ChargeAmount', 0),
        ('Cash', 'Q.1', N'Unbilled',              N'BillStatus = Unbilled AND ClaimStatus = Unbilled', N'ChargeAmount', 0),
        ('Cash', 'Q.2', N'Unbilled - Patient Balance', N'BillStatus = Unbilled AND ClaimStatus = Unbilled - Patient Balance', N'ChargeAmount', 0),
        ('Cash', 'R',   N'Insurance Payment ($)', N'BillStatus = Billed AND ClaimStatus = Fully Paid', N'InsurancePayment', 0),
        ('Cash', 'S',   N'Patient Payments ($)',  N'BillStatus = Billed', N'PatientPayment', 0),
        ('Cash', 'T',   N'Partially Paid ($)',    N'BillStatus = Billed AND ClaimStatus = Partially Paid', N'InsurancePayment', 0),
        ('Cash', 'U',   N'Patient Responsibility ($)', N'BillStatus = Billed', N'PatientBalance', 0),
        ('Cash', 'V',   N'Total Adjustments ($)', N'BillStatus = Billed (InsuranceAdjustments + PatientAdjustments)', N'TotalAdjustments', 0),
        ('Cash', 'W',   N'Insurance Balance ($)', N'BillStatus = Billed', N'InsuranceBalance', 0),
        ('Cash', 'W.1', N'Denials',               N'BillStatus = Billed AND ClaimStatus = ' + @Denied, N'InsuranceBalance', 0),
        ('Cash', 'W.2', N'Partially Denied',
                        CASE WHEN @HasFilter = 0 THEN N'BillStatus = Billed AND ClaimStatus NOT IN (No Response, Fully Denied)'
                             ELSE N'BillStatus = Billed AND ClaimStatus = Partially Denied' END, N'InsuranceBalance', 0),
        ('Cash', 'W.3', N'No Response from Payor', N'BillStatus = Billed AND ClaimStatus = No Response', N'InsuranceBalance', 0),
        ('Avg', 'X',   N'Average Payment ($) - Total Pay/Billed Claims',
                       N'Formula: (Insurance Payment $ (Cash R) + Partially Paid $ (Cash T)) / No. of Billed Claims (PMS F)', NULL, 1),
        ('Avg', 'Y',   N'Average Payment ($) - Fully Paid Claim Value/Paid Claims',
                       N'Formula: Insurance Payment $ (Cash R) / No. of Fully Paid Claims (PMS I)', NULL, 1),
        ('Avg', 'Z',   N'Average Payment ($) - Total Pay/Adjudicated Claims',
                       CASE WHEN @HasFilter = 0
                            THEN N'Formula: (Insurance Payment $ + Patient Payments $ + Partially Paid $) / (Fully Paid + Patient Responsibility + Fully Adjusted + Partially Adjusted + Patient Payments + Denied + Partially Denied claims)'
                            ELSE N'Formula: (Insurance Payment + Patient Payment) / claims, both over Billed claims with ClaimStatus IN (Fully Paid, Complete W/O, Patient Responsibility, Partially Paid, Patient Payment, FullyDenied, Partially Denied)' END,
                       NULL, 1);

    -- LIS panel sub-rows: "B1." + LRNPanelName.
    DECLARE @PanelVal NVARCHAR(400) = NULL;
    IF @Category = 'LIS' AND @RowCode LIKE N'B1.%'
    BEGIN
        SET @PanelVal = LTRIM(RTRIM(SUBSTRING(@RowCode, 4, 400)));
        INSERT INTO @Def (Category, RowCode, Description, RuleText, AmountCol, IsFormula)
        VALUES ('LIS', N'B1.*', @PanelVal, N'NA is blank AND SampleStatus = Billable AND LRNPanelName = ' + @PanelVal, NULL, 0);
    END;

    DECLARE @DefCode NVARCHAR(20) = CASE WHEN @PanelVal IS NOT NULL THEN N'B1.*' ELSE LEFT(@RowCode, 20) END;
    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @IsFormula BIT;
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @IsFormula = IsFormula
    FROM @Def WHERE Category = @Category AND UPPER(RowCode) = UPPER(@DefCode);

    IF @RuleText IS NULL OR (LEN(@RowCode) > 20 AND @PanelVal IS NULL)
    BEGIN
        DECLARE @RowCodeMsg NVARCHAR(100) = LEFT(@RowCode, 100);
        RAISERROR(N'usp_GetInh_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCodeMsg);
        RETURN;
    END;
    IF @PanelVal IS NULL SELECT @DefCode = UPPER(@DefCode), @RowCode = UPPER(@DefCode);

    DECLARE @IsLis BIT = CASE WHEN @Category = 'LIS' THEN 1 ELSE 0 END;
    DECLARE @LisDateCol NVARCHAR(40) = CASE WHEN @HasFilter = 0 THEN N'LastTest'
                                            WHEN @BucketByBilled = 1 THEN N'BilledDate' ELSE N'Entry_DateCreated' END;
    DECLARE @ClaimDateCol NVARCHAR(40) = CASE WHEN @HasFilter = 1 AND @BucketByBilled = 1 THEN N'FirstBilledDate' ELSE N'DateofService' END;
    DECLARE @PeriodText NVARCHAR(200) =
        CASE WHEN @Year = 0 THEN N'all periods (Grand Total)'
             WHEN @Month = 0 THEN N'year ' + CAST(@Year AS NVARCHAR(4)) + N' (Year Total)'
             ELSE DATENAME(MONTH, DATEFROMPARTS(@Year, @Month, 1)) + N' ' + CAST(@Year AS NVARCHAR(4)) END;

    -- LIS counts: the snapshot's A / B count rows (non-null OrderID); every other LIS count is
    -- COUNT(DISTINCT OrderID), and the grid's Year / Grand Totals add those monthly counts.
    DECLARE @LisDistinct BIT = CASE WHEN @HasFilter = 0 AND @RowCode IN (N'A', N'B') THEN 0 ELSE 1 END;

    /* ---- 1. Rules ----------------------------------------------------------- */
    DECLARE @Rules TABLE (RuleOrder INT IDENTITY(1,1), RuleGroup NVARCHAR(40), RuleText NVARCHAR(2000));
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Source', CASE WHEN @IsLis = 1 THEN N'dbo.LIMSMaster - samples (OrderID)' ELSE N'dbo.ClaimLevelData - claim rows' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Base filter', CASE WHEN @IsLis = 1 AND @HasFilter = 0 THEN N'none - every LIMSMaster row (months from LastTest)'
                                WHEN @IsLis = 1 THEN @LisDateCol + N' is a valid date AND OrderID is not blank'
                                WHEN @HasFilter = 0 THEN N'none - every ClaimLevelData row (months from DateofService)'
                                ELSE N'DateofService is a valid date' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Period', CASE WHEN @IsLis = 1 THEN @LisDateCol ELSE @ClaimDateCol END + N' in ' + @PeriodText
                      + CASE WHEN @Year = 0 AND @IsLis = 0 THEN N' (claims with no ' + @ClaimDateCol + N' included, as in the Grand Total)' ELSE N'' END;
    INSERT INTO @Rules (RuleGroup, RuleText) VALUES (CASE WHEN @IsFormula = 1 THEN N'Formula' ELSE N'Row rule' END, @RuleText);
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Measure',
           CASE WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol + N' over every matching claim row'
                WHEN @IsLis = 1 AND @LisDistinct = 1 THEN N'Count of distinct OrderID per month - one line per OrderID and month (Records = LIMSMaster rows sharing it)'
                WHEN @IsLis = 1 THEN N'Count of rows with an OrderID - one line per LIMSMaster row'
                ELSE N'Count of claim rows - one line per row' END
    WHERE @IsFormula = 0;

    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', v.Txt
    FROM (VALUES
        (CASE WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL
              THEN CASE WHEN @IsLis = 1 THEN N'Entry_DateCreated' ELSE N'DateofService' END + N' from '
                   + ISNULL(CONVERT(NVARCHAR(10), @DosFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @DosTo, 101), N'(any)') END),
        (CASE WHEN @BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL
              THEN CASE WHEN @IsLis = 1 THEN N'BilledDate' ELSE N'FirstBilledDate' END + N' from '
                   + ISNULL(CONVERT(NVARCHAR(10), @BilledFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @BilledTo, 101), N'(any)') END),
        (CASE WHEN @IsLis = 0 AND (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL)
              THEN N'DateofService year ' + ISNULL(CAST(@YearFrom AS NVARCHAR(4)), N'(any)') + N' - ' + ISNULL(CAST(@YearTo AS NVARCHAR(4)), N'(any)') END),
        (CASE WHEN @IsLis = 0 AND (@MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
              THEN N'DateofService month ' + ISNULL(CAST(@MonthFrom AS NVARCHAR(2)), N'(any)') + N' - ' + ISNULL(CAST(@MonthTo AS NVARCHAR(2)), N'(any)') END),
        (CASE WHEN @IsLis = 1 AND (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
              THEN N'Year / Month filters do not apply to the LIS section (as on the grid)' END),
        (CASE WHEN @HasPanel = 1    THEN CASE WHEN @IsLis = 1 THEN N'LRNPanelName' ELSE N'PanelNameBasedOnCPT' END + N' IN (' + @Panels + N')' END),
        (CASE WHEN @HasClinic = 1   THEN CASE WHEN @IsLis = 1 THEN N'Account' ELSE N'ClinicName' END + N' IN (' + @Clinics + N')' END),
        (CASE WHEN @HasProvider = 1 THEN CASE WHEN @IsLis = 1 THEN N'ProviderLastName,ProviderFirstName' ELSE N'ReferringProvider' END + N' IN (' + @Providers + N')' END),
        (CASE WHEN @HasRep = 1      THEN CASE WHEN @IsLis = 1 THEN N'Sales Rep does not apply to the LIS section (as on the grid)' ELSE N'SalesRepname IN (' + @Reps + N')' END END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL;

    /* ---- Claim rows in scope ------------------------------------------------- */
    CREATE TABLE #xC
    (
        RowId                INT IDENTITY(1,1) PRIMARY KEY,
        ClaimID              NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
        AccessionNumber      NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        DateofService        DATE NULL,
        FirstBilledDate      DATE NULL,
        PayerName_Raw        NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        PanelNameBasedOnCPT  NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
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
        TotalAdjustments     DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL,
        PY                   INT NULL,
        PM                   INT NULL
    );

    IF @IsLis = 0
        INSERT INTO #xC (ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, PanelNameBasedOnCPT, ClinicName,
                         ReferringProvider, SalesRepname, BillStatus, ClaimStatus, BS, CS,
                         ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
                         InsuranceBalance, PatientBalance, PY, PM)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))),
            CONVERT(NVARCHAR(200), c.AccessionNumber),
            d.Dos, d.Fbd,
            c.PayerName_Raw, c.PanelNameBasedOnCPT, c.ClinicName, c.ReferringProvider, c.SalesRepname,
            c.BillStatus, c.ClaimStatus,
            ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.BillStatus))), N''),
            ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.ClaimStatus))), N''),
            a.ChargeAmount, a.InsurancePayment, a.PatientPayment, a.InsuranceAdjustments, a.PatientAdjustments,
            a.InsuranceAdjustments + a.PatientAdjustments,
            a.InsuranceBalance, a.PatientBalance,
            YEAR(p.PeriodDate), MONTH(p.PeriodDate)
        FROM dbo.ClaimLevelData c
        CROSS APPLY (SELECT TRY_CAST(c.DateofService AS DATE) AS Dos, TRY_CAST(c.FirstBilledDate AS DATE) AS Fbd) d
        CROSS APPLY (SELECT CASE WHEN @HasFilter = 1 AND @BucketByBilled = 1 THEN d.Fbd ELSE d.Dos END AS PeriodDate) p
        CROSS APPLY (SELECT
            ISNULL(TRY_CAST(c.ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
            ISNULL(TRY_CAST(c.InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
            ISNULL(TRY_CAST(c.PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
            ISNULL(TRY_CAST(c.InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CAST(c.PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
            ISNULL(TRY_CAST(c.InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
            ISNULL(TRY_CAST(c.PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance) a
        WHERE (@Year  = 0 OR YEAR(p.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(p.PeriodDate) = @Month)
          AND (@HasFilter = 0 OR (
                   d.Dos IS NOT NULL
               AND (@YearFrom   IS NULL OR YEAR(d.Dos)  >= @YearFrom)
               AND (@YearTo     IS NULL OR YEAR(d.Dos)  <= @YearTo)
               AND (@MonthFrom  IS NULL OR MONTH(d.Dos) >= @MonthFrom)
               AND (@MonthTo    IS NULL OR MONTH(d.Dos) <= @MonthTo)
               AND (@DosFrom    IS NULL OR d.Dos >= @DosFrom)
               AND (@DosTo      IS NULL OR d.Dos <= @DosTo)
               AND (@BilledFrom IS NULL OR d.Fbd >= @BilledFrom)
               AND (@BilledTo   IS NULL OR d.Fbd <= @BilledTo)
               AND (@HasPanel    = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(c.PanelNameBasedOnCPT, N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Panels    + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasClinic   = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(c.ClinicName,          N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Clinics   + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasProvider = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(c.ReferringProvider,   N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Providers + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasRep      = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(c.SalesRepname,        N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Reps      + N',') COLLATE DATABASE_DEFAULT) > 0)))
        OPTION (RECOMPILE);

    -- Row codes each claim row counts towards (only the codes this cell needs).
    -- ZADJ = the filtered Z's adjudicated set.
    DECLARE @Need TABLE (RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY);
    IF @IsLis = 0 AND @IsFormula = 0
        INSERT INTO @Need VALUES (@RowCode);
    ELSE IF @RowCode = N'G'
        INSERT INTO @Need VALUES (N'F');
    ELSE IF @Category = 'Avg'
        INSERT INTO @Need SELECT v.RowCode
        FROM (VALUES (N'F'), (N'I'), (N'J'), (N'K'), (N'L'), (N'M'), (N'O.1'), (N'O.2'), (N'R'), (N'S'), (N'T'), (N'ZADJ')) v(RowCode);

    CREATE TABLE #xHit (RowId INT NOT NULL, RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (RowCode, RowId));
    INSERT INTO #xHit (RowId, RowCode)
    SELECT c.RowId, r.RowCode
    FROM #xC c
    CROSS APPLY (VALUES
        (N'F',   CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'H',   CASE WHEN c.BS = N'Unbilled' THEN 1 ELSE 0 END),
        (N'H.1', CASE WHEN c.BS = N'Unbilled' AND c.CS = N'Unbilled' THEN 1 ELSE 0 END),
        (N'H.2', CASE WHEN c.BS = N'Unbilled' AND c.CS = N'Unbilled - Patient Balance' THEN 1 ELSE 0 END),
        (N'I',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Fully Paid' THEN 1 ELSE 0 END),
        (N'J',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Patient Responsibility' THEN 1 ELSE 0 END),
        (N'K',   CASE WHEN c.BS = N'Billed' AND (c.CS = N'Complete W/O' OR (@HasFilter = 0 AND c.CS = N'Fully Adjusted')) THEN 1 ELSE 0 END),
        (N'L',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Partially Adjusted' THEN 1 ELSE 0 END),
        (N'M',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Patient Payment' THEN 1 ELSE 0 END),
        (N'N',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Partially Paid' THEN 1 ELSE 0 END),
        (N'O',   CASE WHEN c.BS = N'Billed' AND c.CS IN (@Denied, N'Partially Denied', N'No Response') THEN 1 ELSE 0 END),
        (N'O.1', CASE WHEN c.BS = N'Billed' AND c.CS = @Denied THEN 1 ELSE 0 END),
        (N'O.2', CASE WHEN c.BS = N'Billed' AND c.CS = N'Partially Denied' THEN 1 ELSE 0 END),
        (N'O.3', CASE WHEN c.BS = N'Billed' AND c.CS = N'No Response' THEN 1 ELSE 0 END),
        (N'P',   CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'Q',   CASE WHEN c.BS = N'Unbilled' THEN 1 ELSE 0 END),
        (N'Q.1', CASE WHEN c.BS = N'Unbilled' AND c.CS = N'Unbilled' THEN 1 ELSE 0 END),
        (N'Q.2', CASE WHEN c.BS = N'Unbilled' AND c.CS = N'Unbilled - Patient Balance' THEN 1 ELSE 0 END),
        (N'R',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Fully Paid' THEN 1 ELSE 0 END),
        (N'S',   CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'T',   CASE WHEN c.BS = N'Billed' AND c.CS = N'Partially Paid' THEN 1 ELSE 0 END),
        (N'U',   CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'V',   CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'W',   CASE WHEN c.BS = N'Billed' THEN 1 ELSE 0 END),
        (N'W.1', CASE WHEN c.BS = N'Billed' AND c.CS = @Denied THEN 1 ELSE 0 END),
        (N'W.2', CASE WHEN c.BS = N'Billed' AND ((@HasFilter = 0 AND c.CS NOT IN (N'No Response', N'Fully Denied'))
                                              OR (@HasFilter = 1 AND c.CS = N'Partially Denied')) THEN 1 ELSE 0 END),
        (N'W.3', CASE WHEN c.BS = N'Billed' AND c.CS = N'No Response' THEN 1 ELSE 0 END),
        (N'ZADJ', CASE WHEN c.BS = N'Billed' AND c.CS IN (N'Fully Paid', N'Complete W/O', N'Patient Responsibility', N'Partially Paid',
                                                          N'Patient Payment', N'FullyDenied', N'Partially Denied') THEN 1 ELSE 0 END)
    ) r(RowCode, Hit)
    WHERE r.Hit = 1
      AND r.RowCode IN (SELECT RowCode FROM @Need);

    /* ---- LIS rows in scope (LIS cells, and the LIS side of PMS G) ----------- */
    DECLARE @NeedLis BIT = CASE WHEN @IsLis = 1 OR @RowCode = N'G' THEN 1 ELSE 0 END;

    CREATE TABLE #xL
    (
        OrderID          NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
        Accession        NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        LastTest         DATE NULL,
        Entry_DateCreated DATE NULL,
        BilledDate       DATE NULL,
        NA               NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
        SampleStatus     NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        BillCategory     NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        SubStatus        NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        LRNPanelName     NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        Account          NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        ProviderName     NVARCHAR(420) COLLATE DATABASE_DEFAULT NULL,
        PrimaryInsurance NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        NAFlagBlank      BIT NOT NULL,
        SS               NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        BC               NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        Sub              NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PN               NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PeriodDate       DATE NULL,
        PY               INT NULL,
        PM               INT NULL
    );

    IF @NeedLis = 1
        INSERT INTO #xL (OrderID, Accession, LastTest, Entry_DateCreated, BilledDate, NA, SampleStatus, BillCategory, SubStatus,
                         LRNPanelName, Account, ProviderName, PrimaryInsurance, NAFlagBlank, SS, BC, Sub, PN, PeriodDate, PY, PM)
        SELECT
            k.OrderID, CONVERT(NVARCHAR(200), l.Accession),
            TRY_CAST(l.LastTest AS DATE), TRY_CAST(l.Entry_DateCreated AS DATE), TRY_CAST(l.BilledDate AS DATE),
            CONVERT(NVARCHAR(50), l.NA), CONVERT(NVARCHAR(200), l.SampleStatus), CONVERT(NVARCHAR(200), l.BillCategory),
            CONVERT(NVARCHAR(200), l.SubStatus), CONVERT(NVARCHAR(200), l.LRNPanelName), CONVERT(NVARCHAR(300), l.Account),
            k.ProviderName, CONVERT(NVARCHAR(300), l.PrimaryInsurance),
            CASE WHEN ISNULL(CONVERT(NVARCHAR(50), l.NA), N'') = N'' THEN 1 ELSE 0 END,
            k.SS, k.BC, k.Sub, k.PN,
            p.PeriodDate, YEAR(p.PeriodDate), MONTH(p.PeriodDate)
        FROM dbo.LIMSMaster l
        CROSS APPLY (
            SELECT LTRIM(RTRIM(CONVERT(NVARCHAR(100), l.OrderID)))                       AS OrderID,
                   LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.SampleStatus), N'')))      AS SS,
                   LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.BillCategory), N'')))      AS BC,
                   LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.SubStatus), N'')))         AS Sub,
                   LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.LRNPanelName), N'')))      AS PN,
                   LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.ProviderLastName), N'') + N',' + ISNULL(CONVERT(NVARCHAR(200), l.ProviderFirstName), N''))) AS ProviderName
        ) k
        CROSS APPLY (SELECT CASE WHEN @HasFilter = 0 THEN TRY_CAST(l.LastTest AS DATE)
                                 WHEN @BucketByBilled = 1 THEN TRY_CAST(l.BilledDate AS DATE)
                                 ELSE TRY_CAST(l.Entry_DateCreated AS DATE) END AS PeriodDate) p
        WHERE (@Year  = 0 OR YEAR(p.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(p.PeriodDate) = @Month)
          AND (@Year <> 0 OR p.PeriodDate IS NOT NULL)
          AND (@HasFilter = 0 OR (
                   NULLIF(k.OrderID, N'') IS NOT NULL
               AND (@DosFrom    IS NULL OR TRY_CAST(l.Entry_DateCreated AS DATE) >= @DosFrom)
               AND (@DosTo      IS NULL OR TRY_CAST(l.Entry_DateCreated AS DATE) <= @DosTo)
               AND (@BilledFrom IS NULL OR TRY_CAST(l.BilledDate AS DATE) >= @BilledFrom)
               AND (@BilledTo   IS NULL OR TRY_CAST(l.BilledDate AS DATE) <= @BilledTo)
               AND (@HasPanel    = 0 OR CHARINDEX((N',' + k.PN + N',') COLLATE DATABASE_DEFAULT, (N',' + @Panels + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasClinic   = 0 OR CHARINDEX((N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.Account), N''))) + N',') COLLATE DATABASE_DEFAULT, (N',' + @Clinics + N',') COLLATE DATABASE_DEFAULT) > 0)
               AND (@HasProvider = 0 OR CHARINDEX((N',' + k.ProviderName + N',') COLLATE DATABASE_DEFAULT, (N',' + @Providers + N',') COLLATE DATABASE_DEFAULT) > 0)))
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

        IF @RowCode = N'G'
        BEGIN
            -- Per month present in the claim rows, as the grid's G rows; totals add the months.
            DECLARE @Mon TABLE (PY INT NOT NULL, PM INT NOT NULL, Billed INT NOT NULL, Lis INT NOT NULL, PRIMARY KEY (PY, PM));
            INSERT INTO @Mon (PY, PM, Billed, Lis)
            SELECT m.PY, m.PM,
                   (SELECT COUNT(*) FROM #xC c JOIN #xHit h ON h.RowId = c.RowId AND h.RowCode = N'F' WHERE c.PY = m.PY AND c.PM = m.PM),
                   CASE WHEN @HasFilter = 0
                        THEN (SELECT COUNT(DISTINCT l.OrderID) FROM #xL l WHERE l.PY = m.PY AND l.PM = m.PM AND l.NAFlagBlank = 1 AND l.SS = N'Billable' AND l.BC = N'Billed')
                           + (SELECT COUNT(DISTINCT l.OrderID) FROM #xL l WHERE l.PY = m.PY AND l.PM = m.PM AND l.NAFlagBlank = 1 AND l.SS = N'Other Samples' AND l.BC = N'Billed')
                        ELSE (SELECT COUNT(DISTINCT l.OrderID) FROM #xL l WHERE l.PY = m.PY AND l.PM = m.PM AND l.BC = N'Billed') END
            FROM (SELECT DISTINCT PY, PM FROM #xC WHERE PY IS NOT NULL) m;

            DECLARE @BilledSum INT = ISNULL((SELECT SUM(Billed) FROM @Mon), 0);
            DECLARE @LisSum    INT = ISNULL((SELECT SUM(Lis) FROM @Mon), 0);
            SET @Result = ISNULL((SELECT SUM(CASE WHEN @HasFilter = 0 AND Billed - Lis < 0 THEN 0 ELSE Billed - Lis END) FROM @Mon), 0);

            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'PMS', N'F', N'No. of Billed Claims', @BilledSum, 0, 0),
                (2, N'Calculation', N'-', NULL, NULL,
                    CASE WHEN @HasFilter = 0 THEN N'LIS Billed + Other Samples Billed (LIS C + E.1, distinct OrderID by LastTest month)'
                         ELSE N'LIMSMaster samples with BillCategory = Billed (distinct OrderID)' END,
                    @LisSum, 0, 0),
                (9, N'Result', N'=', 'PMS', N'G', N'Billed Mismatches', @Result, 0, 1);

            SET @Calc = CASE WHEN (SELECT COUNT(*) FROM @Mon) <= 1 AND @HasFilter = 0
                             THEN N'MAX(' + FORMAT(@BilledSum, 'N0') + N' - ' + FORMAT(@LisSum, 'N0') + N', 0) = ' + FORMAT(@Result, 'N0')
                             WHEN (SELECT COUNT(*) FROM @Mon) <= 1
                             THEN FORMAT(@BilledSum, 'N0') + N' - ' + FORMAT(@LisSum, 'N0') + N' = ' + FORMAT(@Result, 'N0')
                             ELSE N'Sum of the monthly ' + CASE WHEN @HasFilter = 0 THEN N'MAX(F - LIS Billed, 0)' ELSE N'F - LIS Billed' END
                                  + N' values = ' + FORMAT(@Result, 'N0') END;
        END
        ELSE IF @HasFilter = 1 AND @Year <> 0 AND @Month = 0
        BEGIN
            -- Filtered Avg rows have no year value, so the grid's Year Total adds the monthly averages.
            ;WITH m AS
            (
                SELECT c.PY, c.PM,
                       SUM(CASE WHEN @RowCode = N'X' AND h.RowCode IN (N'R', N'T') THEN c.InsurancePayment
                                WHEN @RowCode = N'Y' AND h.RowCode = N'R' THEN c.InsurancePayment
                                WHEN @RowCode = N'Z' AND h.RowCode = N'ZADJ' THEN c.InsurancePayment + c.PatientPayment
                                ELSE 0 END) AS Num,
                       COUNT(CASE WHEN (@RowCode = N'X' AND h.RowCode = N'F') OR (@RowCode = N'Y' AND h.RowCode = N'I')
                                    OR (@RowCode = N'Z' AND h.RowCode = N'ZADJ') THEN 1 END) AS Den
                FROM #xC c JOIN #xHit h ON h.RowId = c.RowId
                WHERE c.PY IS NOT NULL
                GROUP BY c.PY, c.PM
            )
            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT ROW_NUMBER() OVER (ORDER BY PM), N'Calculation',
                   CASE WHEN ROW_NUMBER() OVER (ORDER BY PM) = 1 THEN N'' ELSE N'+' END, NULL, NULL,
                   DATENAME(MONTH, DATEFROMPARTS(PY, PM, 1)) + N' ' + CAST(PY AS NVARCHAR(4)) + N' average ($'
                       + FORMAT(Num, 'N2') + N' / ' + FORMAT(Den, 'N0') + N')',
                   CASE WHEN Den > 0 THEN CONVERT(DECIMAL(18,2), ROUND(Num / Den, 2)) ELSE 0 END, 1, 0
            FROM m;

            SET @Result = CONVERT(DECIMAL(18,2), ROUND(ISNULL((
                -- The read SP's UNION returns each monthly average at 2 decimals; the grid adds those.
                SELECT SUM(CASE WHEN Den > 0 THEN CONVERT(DECIMAL(18,2), Num / Den) ELSE 0 END)
                FROM (SELECT c.PY, c.PM,
                             SUM(CASE WHEN @RowCode = N'X' AND h.RowCode IN (N'R', N'T') THEN c.InsurancePayment
                                      WHEN @RowCode = N'Y' AND h.RowCode = N'R' THEN c.InsurancePayment
                                      WHEN @RowCode = N'Z' AND h.RowCode = N'ZADJ' THEN c.InsurancePayment + c.PatientPayment
                                      ELSE 0 END) AS Num,
                             COUNT(CASE WHEN (@RowCode = N'X' AND h.RowCode = N'F') OR (@RowCode = N'Y' AND h.RowCode = N'I')
                                          OR (@RowCode = N'Z' AND h.RowCode = N'ZADJ') THEN 1 END) AS Den
                      FROM #xC c JOIN #xHit h ON h.RowId = c.RowId
                      WHERE c.PY IS NOT NULL
                      GROUP BY c.PY, c.PM) s), 0), 2));

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 999, N'Result', N'=', 'Avg', @RowCode, d.Description, @Result, 1, 1
            FROM @Def d WHERE d.Category = 'Avg' AND d.RowCode = @RowCode;

            SET @Calc = N'Sum of the monthly averages (the grid''s Year Total adds them) = $' + FORMAT(@Result, 'N2');
        END
        ELSE
        BEGIN
            -- Avg: components over the cell scope (Grand Total = every claim row, as the (0,0) values).
            DECLARE @Val TABLE (RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY, Cnt DECIMAL(18,2) NOT NULL, Ins DECIMAL(18,2) NOT NULL, Pat DECIMAL(18,2) NOT NULL);
            INSERT INTO @Val (RowCode, Cnt, Ins, Pat)
            SELECT n.RowCode,
                   ISNULL((SELECT COUNT(*) FROM #xHit h WHERE h.RowCode = n.RowCode), 0),
                   ISNULL((SELECT SUM(c.InsurancePayment) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.RowCode = n.RowCode), 0),
                   ISNULL((SELECT SUM(c.PatientPayment)   FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.RowCode = n.RowCode), 0)
            FROM @Need n;

            DECLARE @Parts TABLE (Seq INT, Section NVARCHAR(20), RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT, Measure CHAR(3), Label NVARCHAR(300));
            IF @RowCode IN (N'X', N'Y', N'Z') AND NOT (@RowCode = N'Z' AND @HasFilter = 1)
                INSERT INTO @Parts VALUES (1, N'Numerator', N'R', 'INS', NULL);
            IF @RowCode IN (N'X', N'Z') AND NOT (@RowCode = N'Z' AND @HasFilter = 1)
                INSERT INTO @Parts VALUES (3, N'Numerator', N'T', 'INS', NULL);
            IF @RowCode = N'Z' AND @HasFilter = 0
                INSERT INTO @Parts VALUES (2, N'Numerator', N'S', 'PAT', NULL);
            IF @RowCode = N'X' INSERT INTO @Parts VALUES (11, N'Denominator', N'F', 'CNT', NULL);
            IF @RowCode = N'Y' INSERT INTO @Parts VALUES (11, N'Denominator', N'I', 'CNT', NULL);
            IF @RowCode = N'Z' AND @HasFilter = 0
                INSERT INTO @Parts VALUES (11, N'Denominator', N'I', 'CNT', NULL), (12, N'Denominator', N'J', 'CNT', NULL),
                                          (13, N'Denominator', N'K', 'CNT', NULL), (14, N'Denominator', N'L', 'CNT', NULL),
                                          (15, N'Denominator', N'M', 'CNT', NULL), (16, N'Denominator', N'O.1', 'CNT', NULL),
                                          (17, N'Denominator', N'O.2', 'CNT', NULL);
            IF @RowCode = N'Z' AND @HasFilter = 1
                INSERT INTO @Parts VALUES (1, N'Numerator',   N'ZADJ', 'INS', N'Insurance Payment of adjudicated claims'),
                                          (2, N'Numerator',   N'ZADJ', 'PAT', N'Patient Payment of adjudicated claims'),
                                          (11, N'Denominator', N'ZADJ', 'CNT', N'Adjudicated claims');

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT x.Seq, x.Section,
                   CASE WHEN x.Seq IN (1, 11) THEN N'' ELSE N'+' END,
                   CASE WHEN x.RowCode = N'ZADJ' THEN NULL WHEN x.Measure = 'CNT' THEN 'PMS' ELSE 'Cash' END,
                   CASE WHEN x.RowCode = N'ZADJ' THEN NULL WHEN x.Measure = 'PAT' THEN N'S' ELSE x.RowCode END,
                   COALESCE(x.Label, d.Description),
                   CASE x.Measure WHEN 'CNT' THEN v.Cnt WHEN 'INS' THEN v.Ins ELSE v.Pat END,
                   CASE WHEN x.Measure = 'CNT' THEN 0 ELSE 1 END, 0
            FROM @Parts x
            JOIN @Val v ON v.RowCode = x.RowCode
            LEFT JOIN @Def d ON d.RowCode = CASE WHEN x.Measure = 'PAT' THEN N'S' ELSE x.RowCode END
                            AND d.Category = CASE WHEN x.Measure = 'CNT' THEN 'PMS' ELSE 'Cash' END;

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 9, N'Numerator', N'=', NULL, NULL, N'Total Payments ($)', SUM(Value), 1, 1 FROM @Comp WHERE Section = N'Numerator';
            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 19, N'Denominator', N'=', NULL, NULL,
                   CASE @RowCode WHEN N'X' THEN N'Billed claims' WHEN N'Y' THEN N'Paid claims' ELSE N'Adjudicated claims' END,
                   SUM(Value), 0, 1 FROM @Comp WHERE Section = N'Denominator';

            DECLARE @NumTotal DECIMAL(18,2) = (SELECT Value FROM @Comp WHERE Section = N'Numerator' AND IsTotal = 1);
            DECLARE @DenTotal DECIMAL(18,2) = (SELECT Value FROM @Comp WHERE Section = N'Denominator' AND IsTotal = 1);
            SET @Result = CASE WHEN ISNULL(@DenTotal, 0) = 0 THEN 0
                               ELSE CONVERT(DECIMAL(18,2), ROUND(CONVERT(DECIMAL(38,10), @NumTotal) / @DenTotal, 2)) END;

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

    /* ---- LIS rows ------------------------------------------------------------ */
    IF @IsLis = 1
    BEGIN
        ;WITH hit AS
        (
            SELECT l.*,
                   CASE WHEN @LisDistinct = 1 THEN ISNULL(l.OrderID, N'') + N'|' + CONVERT(NVARCHAR(6), ISNULL(l.PY, 0) * 100 + ISNULL(l.PM, 0))
                        ELSE CONVERT(NVARCHAR(40), NEWID()) END AS DedupeKey
            FROM #xL l
            WHERE l.NAFlagBlank = 1
              AND l.OrderID IS NOT NULL
              AND (   @DefCode = N'A'
                   OR (@DefCode = N'B'    AND l.SS = N'Billable')
                   OR (@DefCode = N'B1.*' AND l.SS = N'Billable' AND l.PN <> N'' AND l.PN = @PanelVal)
                   OR (@DefCode = N'C'    AND l.SS = N'Billable' AND l.BC = N'Billed')
                   OR (@DefCode = N'C.1'  AND l.SS = N'Billable' AND l.BC = N'Billed' AND l.Sub = N'Billed Via AMD')
                   OR (@DefCode = N'D'    AND l.SS = N'Billable' AND l.BC = N'Not Billed')
                   OR (@DefCode = N'D.1'  AND l.SS = N'Billable' AND l.BC = N'Not Billed' AND l.Sub = N'Nexum_Claim_scrubber_Eligibility')
                   OR (@DefCode = N'D.2'  AND l.SS = N'Billable' AND l.BC = N'Not Billed' AND l.Sub = N'Requires Review')
                   OR (@DefCode = N'D.3'  AND l.SS = N'Billable' AND l.BC = N'Not Billed' AND l.Sub = N'Entered in AMD but not billed')
                   OR (@DefCode = N'D.4'  AND l.SS = N'Billable' AND l.BC = N'Not Billed' AND l.Sub = N'Nexum Pre Processing Queue')
                   OR (@DefCode = N'D.5'  AND l.SS = N'Billable' AND l.BC = N'Not Billed' AND l.Sub = N'Nexum_Claim_scrubber_AMD Output')
                   OR (@DefCode = N'D.6'  AND l.SS = N'Billable' AND l.BC = N'Not Billed' AND l.Sub = N'Nexum_Claim_scrubber_Diagnosis Validity')
                   OR (@DefCode = N'E'    AND l.SS = N'Other Samples')
                   OR (@DefCode = N'E.1'  AND l.SS = N'Other Samples' AND l.BC = N'Billed')
                   OR (@DefCode = N'E.2'  AND l.SS = N'Other Samples' AND l.BC = N'Not Billed')
                   OR (@DefCode = N'E.4'  AND l.SS = N'Self Pay')
                   OR (@DefCode = N'E.5'  AND l.SS = N'Deleted/Rejected')
                   OR (@DefCode = N'E.6'  AND l.SS = N'Duplicate')
                   OR (@DefCode = N'E.7'  AND l.SS = N'System Test'))
        ),
        r AS
        (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY DedupeKey ORDER BY PeriodDate) AS rn,
                      COUNT(*)     OVER (PARTITION BY DedupeKey)                    AS Records
            FROM hit
        )
        SELECT OrderID, Accession, LastTest, Entry_DateCreated, BilledDate, NA, SampleStatus, BillCategory, SubStatus,
               LRNPanelName, Account, ProviderName, PrimaryInsurance, Records, PeriodDate
        INTO #xLOut
        FROM r
        WHERE rn = 1;

        SELECT N'dbo.LIMSMaster' AS SourceTable,
               CASE WHEN @LisDistinct = 1 THEN N'Count of distinct OrderID' ELSE N'Count of samples' END AS Measure,
               CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #xLOut;

        SELECT OrderID, Accession, LastTest, Entry_DateCreated, BilledDate, NA, SampleStatus, BillCategory, SubStatus,
               LRNPanelName, Account, ProviderName, PrimaryInsurance, Records
        FROM #xLOut
        ORDER BY PeriodDate, OrderID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- Claim rows: one line per claim row ---------------------------------- */
    SELECT c.*,
           CASE @AmountCol
               WHEN N'ChargeAmount'     THEN c.ChargeAmount
               WHEN N'InsurancePayment' THEN c.InsurancePayment
               WHEN N'PatientPayment'   THEN c.PatientPayment
               WHEN N'PatientBalance'   THEN c.PatientBalance
               WHEN N'TotalAdjustments' THEN c.TotalAdjustments
               WHEN N'InsuranceBalance' THEN c.InsuranceBalance
           END AS Amount
    INTO #xCOut
    FROM #xC c
    JOIN #xHit h ON h.RowId = c.RowId AND h.RowCode = @RowCode;

    SELECT N'dbo.ClaimLevelData' AS SourceTable,
           CASE WHEN @AmountCol IS NULL THEN N'Count of claim rows' ELSE N'Sum of ' + @AmountCol END AS Measure,
           @AmountCol AS AmountColumn,
           COUNT(*) AS TotalRows, CAST(ISNULL(SUM(Amount), 0) AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
    FROM #xCOut;

    IF @AmountCol IS NULL
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, PanelNameBasedOnCPT, ClinicName,
               ReferringProvider, SalesRepname, BillStatus, ClaimStatus,
               ChargeAmount, InsurancePayment, PatientPayment, TotalAdjustments, InsuranceBalance, PatientBalance
        FROM #xCOut
        ORDER BY PY, PM, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
    ELSE
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, PanelNameBasedOnCPT, ClinicName,
               ReferringProvider, SalesRepname, BillStatus, ClaimStatus, Amount,
               ChargeAmount, InsurancePayment, PatientPayment, TotalAdjustments, InsuranceBalance, PatientBalance
        FROM #xCOut
        ORDER BY PY, PM, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
END;
GO

SET NOEXEC OFF;
GO

PRINT '29_Inhealth_ExecutiveSummary_CellRows.sql completed.';
GO
