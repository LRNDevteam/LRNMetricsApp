/* =============================================================================
   Beech Tree - Executive Summary cell rows (value click -> popup grid)
   File     : 29_BeechTree_ExecutiveSummary_CellRows.sql
   Database : BeechTree_LRN
   Object   : dbo.usp_GetBT_ExecutiveSummaryCellRows

   Returns the source rows behind one Executive Summary cell. The rules follow the procedures
   deployed on BeechTree_LRN (read with OBJECT_DEFINITION on 2026-10-26) - keep this file in step
   with them. The two grid paths use different rules (and partly different row codes):
     No page filter  -> the BeechTree_ES_* snapshot: usp_RefreshBT_ExecutiveSummary (PMS / Cash / Avg
                        AL-AN; counts = COUNT(DISTINCT ClaimID); S = R - LIS Billed; V.n = write-off
                        reasons from BTWOSummary ranked by count) and usp_RefreshBT_ExecutiveSummary_LIS_Alt
                        (LIS, RequestCollectDate month, PanelCategory panels, row counts).
     Any page filter -> usp_GetBT_ExecutiveSummary's filtered path: claim row counts, S = Billed amount 0,
                        Cash AA-AJ, Avg AK-AM (unrounded), V / V.n from BTWOSummary (A-Z order); LIS read
                        live from LIMSMaster (row counts) unless the only filter is Sales Rep.

   Count rows return one line per claim (and month) for distinct counts and one line per row for row
   counts; $ rows return every claim row; V / V.n return the BTWOSummary rows (MatchingCount each).

   Parameters
     @Category / @RowCode   the clicked row (LIS A..E and B1.<panel>, PMS R..Z.3 and V.n, Cash AA..AK3, Avg AK..AN)
     @Year / @Month         the clicked column: (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetBT_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText - how the value is calculated, incl. page filters
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured column for $ rows)
   Formula rows (snapshot PMS S, every Avg row) return the formula and the calculation in Rules,
   IsFormula = 1, TotalAmount = the result, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal).
   ============================================================================= */

IF DB_NAME() NOT LIKE N'%Beech%'
BEGIN
    RAISERROR(N'29_BeechTree_ExecutiveSummary_CellRows.sql must run on the Beech Tree lab database (BeechTree_LRN).', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetBT_ExecutiveSummaryCellRows
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

    /* ---- Page filters (as usp_GetBT_ExecutiveSummary) ---------------------- */
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

    -- LIS read live from LIMSMaster for any filter that applies to it; a Sales Rep-only filter
    -- keeps the snapshot (Sales Rep is not on LIMSMaster).
    DECLARE @LisLive BIT = CASE WHEN @HasPanel = 1 OR @HasClinic = 1 OR @HasProvider = 1
                                  OR @DosFrom IS NOT NULL OR @DosTo IS NOT NULL OR @UseBilledDate = 1
                                  OR @YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL
                                THEN 1 ELSE 0 END;

    -- Snapshot count rows are COUNT(DISTINCT ClaimID) and the grid's Year Total adds the months;
    -- the snapshot Avg Grand Total divides by distinct claims over every period.
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
        ('LIS', 'A',    N'Total Samples',               N'Every sample', NULL, 0),
        ('LIS', 'B',    N'Billable Samples - Resulted', N'Resulted', NULL, 0),
        ('LIS', 'B2',   N'Billed to Insurance',         N'Resulted AND ClaimStatus = Billed AND BilledorNot = Billed AND ClientStatus is blank', NULL, 0),
        ('LIS', 'B2.1', N'Billed In AMD',               N'Resulted AND ClaimStatus = Billed AND BilledorNot = Billed AND ClientStatus is blank', NULL, 0),
        ('LIS', 'B3',   N'Not Entered in AMD',          N'Resulted AND ClaimStatus = Not Entered in AMD AND BilledorNot = UnBilled AND ClientStatus IN (blank, Billing Review Required)', NULL, 0),
        ('LIS', 'B3.1', N'Received',                    N'Not Entered in AMD (B3) AND SampleStatus = Received', NULL, 0),
        ('LIS', 'B3.2', N'Billing Review Required',     N'Resulted AND ClaimStatus = Not Entered in AMD AND BilledorNot = UnBilled AND SampleStatus = Received AND ClientStatus = Billing Review Required', NULL, 0),
        ('LIS', 'B3.3', N'In Transit',                  N'Not Entered in AMD (B3) AND SampleStatus = In Transit', NULL, 0),
        ('LIS', 'B3.4', N'Transferred',                 N'Not Entered in AMD (B3) AND SampleStatus = Transferred', NULL, 0),
        ('LIS', 'B3.5', N'Collected',                   N'Not Entered in AMD (B3) AND SampleStatus = Collected', NULL, 0),
        ('LIS', 'B4',   N'Unbilled',                    N'Resulted AND ClaimStatus = Entered AND BilledorNot = UnBilled AND ClientStatus is blank', NULL, 0),
        ('LIS', 'B5',   N'Client Bill',                 N'Resulted AND ClientStatus = Client Bill', NULL, 0),
        ('LIS', 'B5.1', N'Not Entered in AMD',          N'Client Bill AND ClaimStatus = Not Entered in AMD, except Client bill - Insurance Updated (B5.3)', NULL, 0),
        ('LIS', 'B5.2', N'Billed',                      N'Client Bill AND BilledorNot = Billed', NULL, 0),
        ('LIS', 'B5.3', N'Client bill - Insurance Updated', N'Client Bill AND ClaimStatus = Not Entered in AMD AND PrimaryInsurance NOT IN (Client Bill, blank) AND PrimaryInsuranceID NOT IN (0, 999999)', NULL, 0),
        ('LIS', 'B5.4', N'Entered',                     N'Client Bill AND ClaimStatus = Entered AND BilledorNot = UnBilled', NULL, 0),
        ('LIS', 'B6',   N'Self Pay',                    N'Resulted AND ClientStatus = Self Pay', NULL, 0),
        ('LIS', 'B6.1', N'Not Entered in AMD',          N'Self Pay AND ClaimStatus = Not Entered in AMD AND BilledorNot = UnBilled', NULL, 0),
        ('LIS', 'B6.2', N'Billed',                      N'Self Pay AND BilledorNot = Billed', NULL, 0),
        ('LIS', 'B6.3', N'Entered',                     N'Self Pay AND ClaimStatus = Entered AND BilledorNot = UnBilled', NULL, 0),
        ('LIS', 'B7',   N'Test Entries',
                        CASE WHEN @LisLive = 0 THEN N'Resulted AND ClientStatus = Test Entries AND PaymentMethod <> No Bill'
                             ELSE N'Resulted AND ClientStatus = Test Entries' END, NULL, 0),
        ('LIS', 'B7.1', N'Not Entered in AMD',
                        CASE WHEN @LisLive = 0 THEN N'Test Entries AND ClaimStatus = Not Entered in AMD AND BilledorNot = UnBilled AND PaymentMethod <> No Bill'
                             ELSE N'Test Entries AND ClaimStatus = Not Entered in AMD AND BilledorNot = UnBilled' END, NULL, 0),
        ('LIS', 'B7.2', N'Billed',                      N'Test Entries AND BilledorNot = Billed', NULL, 0),
        ('LIS', 'B8',   N'Rejected Sample',             N'Resulted AND ClientStatus = Rejected Sample', NULL, 0),
        ('LIS', 'B8.1', N'Not Entered in AMD',          N'Rejected Sample AND ClaimStatus = Not Entered in AMD AND BilledorNot = UnBilled', NULL, 0),
        ('LIS', 'B8.2', N'Billed',                      N'Rejected Sample AND BilledorNot = Billed', NULL, 0),
        ('LIS', 'B9',   N'Payment Method No Bill',      N'Resulted AND PaymentMethod = No Bill', NULL, 0),
        ('LIS', 'C',    N'Not Resulted',                N'Not Resulted', NULL, 0),
        ('LIS', 'C1',   N'No Result date on LIS but Billed', N'Not Resulted AND ClaimStatus = Billed AND BilledorNot = Billed AND ClientStatus is blank', NULL, 0),
        ('LIS', 'C2',   N'Not Entered in AMD',          N'Not Resulted AND ClaimStatus = Not Entered in AMD AND BilledorNot = UnBilled AND ClientStatus is blank', NULL, 0),
        ('LIS', 'C2.1', N'Received',                    N'Not Entered in AMD (C2) AND SampleStatus = Received', NULL, 0),
        ('LIS', 'C2.2', N'In Transit',                  N'Not Entered in AMD (C2) AND SampleStatus = In Transit', NULL, 0),
        ('LIS', 'C2.3', N'Collected',                   N'Not Entered in AMD (C2) AND SampleStatus = Collected', NULL, 0),
        ('LIS', 'C2.4', N'Transferred',                 N'Not Entered in AMD (C2) AND SampleStatus = Transferred', NULL, 0),
        ('LIS', 'C3',   N'Client Bill',                 N'Not Resulted AND ClientStatus = Client Bill', NULL, 0),
        ('LIS', 'C4',   N'Self Pay',                    N'Not Resulted AND ClientStatus = Self Pay', NULL, 0),
        ('LIS', 'C4.1', N'Not Entered in AMD',          N'Not Resulted AND ClientStatus = Self Pay AND ClaimStatus = Not Entered in AMD AND BilledorNot = UnBilled', NULL, 0),
        ('LIS', 'C4.2', N'Billed',                      N'Not Resulted AND ClientStatus = Self Pay AND BilledorNot = Billed', NULL, 0),
        ('LIS', 'D',    N'Test Entries',                N'Not Resulted AND ClientStatus = Test Entries', NULL, 0),
        ('LIS', 'E',    N'Rejected Sample',             N'Not Resulted AND ClientStatus = Rejected Sample', NULL, 0),
        ('PMS', 'R',    N'Billed - Includes all Claims Billed in AMD', N'BilledUnbilled = Billed', NULL, 0),
        ('PMS', 'T',    N'Unbilled - Entered to AMD - Yet to be released to Payer', N'BilledUnbilled = UnBilled', NULL, 0),
        ('PMS', 'U',    N'Fully Paid - Insurance Pay',  N'ClaimStatus = Fully Paid', NULL, 0);

    IF @HasFilter = 0
        INSERT INTO @Def (Category, RowCode, Description, RuleText, AmountCol, IsFormula) VALUES
            ('PMS', 'S',   N'Billed Mismatches - Non Diagnose LIS Samples',
                           N'Formula: Billed claims (PMS R) - LIS Billed samples (LIMSMaster BilledorNot = Billed, distinct VisitNumber by RequestCollectDate month) per month', NULL, 1),
            ('PMS', 'V',   N'Fully Adjusted',             N'BilledUnbilled = Billed AND ClaimStatus = Complete W/O', NULL, 0),
            ('PMS', 'V.*', N'Write-off reason',           N'BTWOSummary rows of the month''s n-th write-off reason (ranked by count), for Billed Complete W/O claims', NULL, 0),
            ('PMS', 'W',   N'Patient Responsibility',     N'ClaimStatus IN (Pat Responsibility, Patient Responsibility)', NULL, 0),
            ('PMS', 'X',   N'Partially Paid',             N'ClaimStatus IN (Partial Paid, Partially Paid)', NULL, 0),
            ('PMS', 'Y',   N'Patient Payment',            N'ClaimStatus IN (Patient Payment, Pat Payment)', NULL, 0),
            ('PMS', 'Z',   N'Insurance Balance',          N'BilledUnbilled = Billed AND ClaimStatus IN (Fully Denied, No Response, Partially Denied, Partially Adjusted)', NULL, 0),
            ('PMS', 'Z.1', N'Fully Denied',               N'ClaimStatus = Fully Denied', NULL, 0),
            ('PMS', 'Z.2', N'No Response',                N'BilledUnbilled = Billed AND ClaimStatus = No Response', NULL, 0),
            ('PMS', 'Z.3', N'Partially Denied',           N'BilledUnbilled = Billed AND ClaimStatus IN (Partially Denied, Partially Adjusted)', NULL, 0),
            ('Cash', 'AA',  N'Total Billed ($)',          N'BilledUnbilled = Billed', N'ChargeAmount', 0),
            ('Cash', 'AB',  N'Unbilled ($)',              N'BilledUnbilled = UnBilled', N'ChargeAmount', 0),
            ('Cash', 'AC',  N'Insurance Payment (fully paid) ($)', N'ClaimStatus = Fully Paid AND InsurancePayment > 0', N'InsurancePayment', 0),
            ('Cash', 'AD',  N'Partially Paid ($)',        N'BilledUnbilled = Billed AND ClaimStatus IN (Partial Paid, Partially Paid)', N'InsurancePayment', 0),
            ('Cash', 'AE',  N'Patient Payment ($)',       N'PatientPayment > 0', N'PatientPayment', 0),
            ('Cash', 'AF',  N'Fully Adjusted (Complete W/O)', N'BilledUnbilled = Billed AND ClaimStatus = Complete W/O', N'InsuranceAdjustments', 0),
            ('Cash', 'AG',  N'Contractual Obligation W/O', N'BilledUnbilled = Billed AND ClaimStatus <> Complete W/O', N'InsuranceAdjustments', 0),
            ('Cash', 'AH',  N'Patient Balance ($)',       N'ClaimStatus NOT IN (Unbilled, Unbilled - PB)', N'PatientBalance', 0),
            ('Cash', 'AJ',  N'Patient WO',                N'BilledUnbilled = Billed', N'PatientAdjustments', 0),
            ('Cash', 'AK',  N'Insurance Balance ($)',     N'BilledUnbilled = Billed', N'InsuranceBalance', 0),
            ('Cash', 'AK1', N'Fully Denied',              N'BilledUnbilled = Billed AND ClaimStatus = Fully Denied', N'InsuranceBalance', 0),
            ('Cash', 'AK2', N'No Response',               N'BilledUnbilled = Billed AND ClaimStatus = No Response', N'InsuranceBalance', 0),
            ('Cash', 'AK3', N'Partially Denied',          N'BilledUnbilled = Billed AND ClaimStatus NOT IN (No Response, Fully Denied)', N'InsuranceBalance', 0),
            ('Avg', 'AL',  N'Average Payment ($) - Total Pay/Billed Claims',
                           N'Formula: Total Pay (Cash AC + AD + AE) / Billed claims (PMS R); Year Total = sum of the monthly averages', NULL, 1),
            ('Avg', 'AM',  N'Average Payment ($) - Total Pay/Paid Claims',
                           N'Formula: Total Pay (Cash AC + AD + AE) / (PMS U + X + Y); Year Total = sum of the monthly averages', NULL, 1),
            ('Avg', 'AN',  N'Average Payment ($) - Total Pay/Adjudicated Claims',
                           N'Formula: Total Pay (Cash AC + AD + AE) / (PMS U + V + W + X + Y + Z.1 + Z.3); Year Total = sum of the monthly averages', NULL, 1);
    ELSE
        INSERT INTO @Def (Category, RowCode, Description, RuleText, AmountCol, IsFormula) VALUES
            ('PMS', 'S',   N'Billed Mismatches - Non Diagnose LIS Samples', N'BilledUnbilled = Billed AND ClaimStatus = Billed amount 0', NULL, 0),
            ('PMS', 'V',   N'Fully Adjusted',             N'BTWOSummary rows (by their DateofService month) of the filtered claims', NULL, 0),
            ('PMS', 'V.*', N'Write-off reason',           N'BTWOSummary rows of the month''s n-th write-off reason (A-Z), for the filtered claims', NULL, 0),
            ('PMS', 'W',   N'Patient Responsibility',     N'ClaimStatus = Pat Responsibility', NULL, 0),
            ('PMS', 'X',   N'Partially Paid',             N'ClaimStatus = Partial Paid', NULL, 0),
            ('PMS', 'Y',   N'Patient Payment',            N'PatientPayment > 0', NULL, 0),
            ('PMS', 'Z',   N'Insurance Balance',          N'ClaimStatus IN (Fully Denied, No Response, Partially Denied)', NULL, 0),
            ('PMS', 'Z.1', N'Fully Denied',               N'ClaimStatus = Fully Denied', NULL, 0),
            ('PMS', 'Z.2', N'No Response',                N'ClaimStatus = No Response', NULL, 0),
            ('PMS', 'Z.3', N'Partially Denied',           N'ClaimStatus = Partially Denied', NULL, 0),
            ('Cash', 'AA',  N'Total Billed ($)',          N'BilledUnbilled = Billed', N'ChargeAmount', 0),
            ('Cash', 'AB',  N'Unbilled ($)',              N'BilledUnbilled = UnBilled', N'ChargeAmount', 0),
            ('Cash', 'AC',  N'Insurance Payment (fully paid) ($)', N'ClaimStatus = Fully Paid AND InsurancePayment > 0', N'InsurancePayment', 0),
            ('Cash', 'AD',  N'Partially Paid ($)',        N'ClaimStatus = Partial Paid', N'InsurancePayment', 0),
            ('Cash', 'AE',  N'Patient Payment ($)',       N'PatientPayment > 0', N'PatientPayment', 0),
            ('Cash', 'AF',  N'Fully Adjusted (Complete W/O)', N'ClaimStatus = Fully Adjusted (InsuranceAdjustments + PatientAdjustments)', N'TotalAdjustments', 0),
            ('Cash', 'AG',  N'Contractual Obligation W/O', N'InsuranceAdjustments > 0', N'InsuranceAdjustments', 0),
            ('Cash', 'AH',  N'Patient Balance ($)',       N'ClaimStatus NOT IN (Unbilled, Unbilled - PB)', N'PatientBalance', 0),
            ('Cash', 'AI',  N'Patient WO',                N'PatientAdjustments > 0', N'PatientAdjustments', 0),
            ('Cash', 'AJ',  N'Insurance Balance ($)',     N'ClaimStatus IN (Fully Denied, No Response, Partially Denied)', N'InsuranceBalance', 0),
            ('Avg', 'AK',  N'Average Payment ($) - Total Pay/Billed Claims',
                           N'Formula: (InsurancePayment + PatientPayment) / claims, both over BilledUnbilled = Billed; Year Total = sum of the monthly averages', NULL, 1),
            ('Avg', 'AL',  N'Average Payment ($) - Total Pay/Paid Claims',
                           N'Formula: (InsurancePayment + PatientPayment) / claims, both over ClaimStatus = Fully Paid; Year Total = sum of the monthly averages', NULL, 1),
            ('Avg', 'AM',  N'Average Payment ($) - Total Pay/Adjudicated Claims',
                           N'Formula: (InsurancePayment + PatientPayment) / claims, both over ClaimStatus NOT IN (Unbilled, Unbilled - PB); Year Total = sum of the monthly averages', NULL, 1);

    -- LIS panel sub-rows "B1.<PanelCategory>" and PMS write-off reason sub-rows "V.<n>".
    DECLARE @PanelVal NVARCHAR(400) = NULL, @WoRank INT = NULL;
    IF @Category = 'LIS' AND @RowCode LIKE N'B1.%'
    BEGIN
        SET @PanelVal = LTRIM(RTRIM(SUBSTRING(@RowCode, 4, 400)));
        INSERT INTO @Def (Category, RowCode, Description, RuleText, AmountCol, IsFormula)
        VALUES ('LIS', N'B1.*', @PanelVal, N'Resulted AND PanelCategory = ' + @PanelVal, NULL, 0);
    END;
    IF @Category = 'PMS' AND @RowCode LIKE N'V.[0-9]%'
        SET @WoRank = TRY_CAST(SUBSTRING(@RowCode, 3, 10) AS INT);

    DECLARE @DefCode NVARCHAR(20) = CASE WHEN @PanelVal IS NOT NULL THEN N'B1.*'
                                         WHEN @WoRank IS NOT NULL THEN N'V.*'
                                         ELSE UPPER(LEFT(@RowCode, 20)) END;
    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @IsFormula BIT;
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @IsFormula = IsFormula
    FROM @Def WHERE Category = @Category AND UPPER(RowCode) = @DefCode;

    IF @RuleText IS NULL OR (LEN(@RowCode) > 20 AND @PanelVal IS NULL)
    BEGIN
        DECLARE @RowCodeMsg NVARCHAR(100) = LEFT(@RowCode, 100);
        RAISERROR(N'usp_GetBT_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCodeMsg);
        RETURN;
    END;

    DECLARE @IsLis BIT = CASE WHEN @Category = 'LIS' THEN 1 ELSE 0 END;
    DECLARE @IsWo  BIT = CASE WHEN @DefCode IN (N'V.*') OR (@HasFilter = 1 AND @DefCode = N'V' AND @Category = 'PMS') THEN 1 ELSE 0 END;
    DECLARE @HitCode NVARCHAR(30) = @Category + N':' + @DefCode;
    DECLARE @LisDateCol NVARCHAR(40) = CASE WHEN @LisLive = 1 AND @UseBilledDate = 1 THEN N'AMDLBD' ELSE N'RequestCollectDate' END;
    DECLARE @ClaimDateCol NVARCHAR(40) = CASE WHEN @HasFilter = 1 AND @UseBilledDate = 1 THEN N'FirstBilledDate' ELSE N'DateofService' END;
    DECLARE @PeriodText NVARCHAR(200) =
        CASE WHEN @Year = 0 THEN N'all periods (Grand Total)'
             WHEN @Month = 0 THEN N'year ' + CAST(@Year AS NVARCHAR(4)) + N' (Year Total)'
             ELSE DATENAME(MONTH, DATEFROMPARTS(@Year, @Month, 1)) + N' ' + CAST(@Year AS NVARCHAR(4)) END;
    DECLARE @CountDistinct BIT = CASE WHEN @HasFilter = 0 THEN 1 ELSE 0 END;

    /* ---- 1. Rules ----------------------------------------------------------- */
    DECLARE @Rules TABLE (RuleOrder INT IDENTITY(1,1), RuleGroup NVARCHAR(40), RuleText NVARCHAR(2000));
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Source', CASE WHEN @IsLis = 1 THEN N'dbo.LIMSMaster - samples (VisitNumber)'
                           WHEN @IsWo = 1 THEN N'dbo.BTWOSummary - write-off transaction rows (MatchingCount each), for claims in dbo.ClaimLevelData'
                           ELSE N'dbo.ClaimLevelData - claims' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Period', CASE WHEN @IsLis = 1 THEN @LisDateCol WHEN @IsWo = 1 THEN N'BTWOSummary.DateofService' ELSE @ClaimDateCol END
                      + N' (a valid date) in ' + @PeriodText;
    INSERT INTO @Rules (RuleGroup, RuleText) VALUES (CASE WHEN @IsFormula = 1 THEN N'Formula' ELSE N'Row rule' END, @RuleText);
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Measure',
           CASE WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol + N' over every matching claim row'
                WHEN @IsWo = 1 THEN N'Sum of MatchingCount - one line per BTWOSummary row'
                WHEN @IsLis = 1 THEN N'Count of samples - one line per LIMSMaster row'
                WHEN @CountDistinct = 1 THEN N'Count of distinct ClaimID - one line per claim and month (Claims = rows sharing it)'
                ELSE N'Count of claim rows - one line per row' END
    WHERE @IsFormula = 0;

    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', v.Txt
    FROM (VALUES
        (CASE WHEN @IsLis = 0 AND @UseBilledDate = 1
              THEN N'FirstBilledDate from ' + ISNULL(CONVERT(NVARCHAR(10), @BilledFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @BilledTo, 101), N'(any)') END),
        (CASE WHEN @IsLis = 0 AND @UseBilledDate = 0 AND (@DosFrom IS NOT NULL OR @DosTo IS NOT NULL)
              THEN N'DateofService from ' + ISNULL(CONVERT(NVARCHAR(10), @DosFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @DosTo, 101), N'(any)') END),
        (CASE WHEN @IsLis = 1 AND @LisLive = 1 AND @UseBilledDate = 1
              THEN N'AMDLBD from ' + ISNULL(CONVERT(NVARCHAR(10), @BilledFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @BilledTo, 101), N'(any)') END),
        (CASE WHEN @IsLis = 1 AND @LisLive = 1 AND @UseBilledDate = 0 AND (@DosFrom IS NOT NULL OR @DosTo IS NOT NULL)
              THEN N'RequestCollectDate from ' + ISNULL(CONVERT(NVARCHAR(10), @DosFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @DosTo, 101), N'(any)') END),
        (CASE WHEN (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
                   AND NOT (@IsLis = 0 AND @UseBilledDate = 1)
              THEN CASE WHEN @IsLis = 1 THEN @LisDateCol ELSE N'DateofService' END
                   + N' year ' + ISNULL(CAST(@YearFrom AS NVARCHAR(4)), N'(any)') + N' - ' + ISNULL(CAST(@YearTo AS NVARCHAR(4)), N'(any)')
                   + N', month ' + ISNULL(CAST(@MonthFrom AS NVARCHAR(2)), N'(any)') + N' - ' + ISNULL(CAST(@MonthTo AS NVARCHAR(2)), N'(any)') END),
        (CASE WHEN @HasPanel = 1    THEN CASE WHEN @IsLis = 1 THEN N'PanelCategory' ELSE N'Panelname' END + N' IN (' + @Panels + N')' END),
        (CASE WHEN @HasClinic = 1   THEN CASE WHEN @IsLis = 1 THEN N'Facility' ELSE N'ClinicName' END + N' IN (' + @Clinics + N')' END),
        (CASE WHEN @HasProvider = 1 THEN CASE WHEN @IsLis = 1 THEN N'Provider' ELSE N'ReferringProvider' END + N' IN (' + @Providers + N')' END),
        (CASE WHEN @HasRep = 1      THEN CASE WHEN @IsLis = 1 THEN N'Sales Rep does not apply to the LIS section (as on the grid)' ELSE N'SalesRepname IN (' + @Reps + N')' END END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL;

    /* ---- Claim rows ---------------------------------------------------------- */
    -- #xAll: every claim the grid's #Base holds (all periods) - the write-off rows' claim set.
    -- #xC  : the claims in the clicked cell's period.
    CREATE TABLE #xAll
    (
        RowId                INT IDENTITY(1,1) PRIMARY KEY,
        ClaimID              NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        ClaimKey             NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
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
        TotalAdjustments     DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL,
        PY                   INT NOT NULL,
        PM                   INT NOT NULL,
        DedupeKey            NVARCHAR(520) COLLATE DATABASE_DEFAULT NULL
    );

    IF @IsLis = 0
        INSERT INTO #xAll (ClaimID, ClaimKey, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
                           ReferringProvider, SalesRepname, BilledUnbilled, ClaimStatus, BU, CS,
                           ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
                           InsuranceBalance, PatientBalance, PY, PM, DedupeKey)
        SELECT
            CONVERT(NVARCHAR(500), c.ClaimID), LTRIM(RTRIM(CONVERT(NVARCHAR(50), c.ClaimID))),
            CONVERT(NVARCHAR(200), c.AccessionNumber), d.Dos, d.Fbd,
            c.PayerName_Raw, c.Panelname, c.ClinicName, c.ReferringProvider, c.SalesRepname, c.BilledUnbilled, c.ClaimStatus,
            ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.BilledUnbilled))), N''),
            ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.ClaimStatus))), N''),
            a.ChargeAmount, a.InsurancePayment, a.PatientPayment, a.InsuranceAdjustments, a.PatientAdjustments,
            a.InsuranceAdjustments + a.PatientAdjustments, a.InsuranceBalance, a.PatientBalance,
            YEAR(p.PeriodDate), MONTH(p.PeriodDate),
            CONVERT(NVARCHAR(500), c.ClaimID)
                + CASE WHEN @DedupeByMonth = 1 THEN N'|' + CONVERT(NVARCHAR(6), YEAR(p.PeriodDate) * 100 + MONTH(p.PeriodDate)) ELSE N'' END
        FROM dbo.ClaimLevelData c
        CROSS APPLY (SELECT TRY_CAST(c.DateofService AS DATE) AS Dos, TRY_CAST(c.FirstBilledDate AS DATE) AS Fbd) d
        CROSS APPLY (SELECT CASE WHEN @HasFilter = 1 AND @UseBilledDate = 1 THEN d.Fbd ELSE d.Dos END AS PeriodDate) p
        CROSS APPLY (SELECT
            ISNULL(TRY_CAST(c.ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
            ISNULL(TRY_CAST(c.InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
            ISNULL(TRY_CAST(c.PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
            ISNULL(TRY_CAST(c.InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CAST(c.PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
            ISNULL(TRY_CAST(c.InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
            ISNULL(TRY_CAST(c.PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance) a
        WHERE p.PeriodDate IS NOT NULL
          AND (@HasFilter = 1 OR NULLIF(CONVERT(NVARCHAR(50), c.ClaimID), N'') IS NOT NULL)
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
               AND (@HasPanel    = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(c.Panelname,         N''))) COLLATE DATABASE_DEFAULT + N',', N',' + @Panels    + N',') > 0)
               AND (@HasClinic   = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(c.ClinicName,        N''))) COLLATE DATABASE_DEFAULT + N',', N',' + @Clinics   + N',') > 0)
               AND (@HasProvider = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(c.ReferringProvider, N''))) COLLATE DATABASE_DEFAULT + N',', N',' + @Providers + N',') > 0)
               AND (@HasRep      = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(c.SalesRepname,      N''))) COLLATE DATABASE_DEFAULT + N',', N',' + @Reps      + N',') > 0)))
        OPTION (RECOMPILE);

    SELECT * INTO #xC FROM #xAll
    WHERE (@Year = 0 OR PY = @Year) AND (@Month = 0 OR PM = @Month);

    DECLARE @Need TABLE (HitCode NVARCHAR(30) COLLATE DATABASE_DEFAULT PRIMARY KEY);
    IF @IsLis = 0 AND @IsWo = 0 AND @IsFormula = 0
        INSERT INTO @Need VALUES (@HitCode);
    ELSE IF @Category = 'PMS' AND @DefCode = N'S'
        INSERT INTO @Need VALUES (N'PMS:R');
    ELSE IF @Category = 'Avg'
        INSERT INTO @Need SELECT v.HitCode
        FROM (VALUES (N'PMS:R'), (N'PMS:U'), (N'PMS:V'), (N'PMS:W'), (N'PMS:X'), (N'PMS:Y'), (N'PMS:Z.1'), (N'PMS:Z.3'),
                     (N'Cash:AC'), (N'Cash:AD'), (N'Cash:AE'),
                     (N'Avg:AKF'), (N'Avg:ALF'), (N'Avg:AMF')) v(HitCode);

    -- Avg:AKF / ALF / AMF = the filtered Avg rows' claim sets.
    CREATE TABLE #xHit (RowId INT NOT NULL, HitCode NVARCHAR(30) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (HitCode, RowId));
    INSERT INTO #xHit (RowId, HitCode)
    SELECT c.RowId, r.HitCode
    FROM #xC c
    CROSS APPLY (VALUES
        (N'PMS:R',    CASE WHEN c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'PMS:S',    CASE WHEN @HasFilter = 1 AND c.BU = N'Billed' AND c.CS = N'Billed amount 0' THEN 1 ELSE 0 END),
        (N'PMS:T',    CASE WHEN c.BU = N'UnBilled' THEN 1 ELSE 0 END),
        (N'PMS:U',    CASE WHEN c.CS = N'Fully Paid' THEN 1 ELSE 0 END),
        (N'PMS:V',    CASE WHEN @HasFilter = 0 AND c.BU = N'Billed' AND c.CS = N'Complete W/O' THEN 1 ELSE 0 END),
        (N'PMS:W',    CASE WHEN c.CS = N'Pat Responsibility' OR (@HasFilter = 0 AND c.CS = N'Patient Responsibility') THEN 1 ELSE 0 END),
        (N'PMS:X',    CASE WHEN c.CS = N'Partial Paid' OR (@HasFilter = 0 AND c.CS = N'Partially Paid') THEN 1 ELSE 0 END),
        (N'PMS:Y',    CASE WHEN (@HasFilter = 0 AND c.CS IN (N'Patient Payment', N'Pat Payment'))
                             OR (@HasFilter = 1 AND c.PatientPayment > 0) THEN 1 ELSE 0 END),
        (N'PMS:Z',    CASE WHEN c.CS IN (N'Fully Denied', N'No Response', N'Partially Denied')
                             AND (@HasFilter = 1 OR c.BU = N'Billed') THEN 1
                           WHEN @HasFilter = 0 AND c.BU = N'Billed' AND c.CS = N'Partially Adjusted' THEN 1 ELSE 0 END),
        (N'PMS:Z.1',  CASE WHEN c.CS = N'Fully Denied' THEN 1 ELSE 0 END),
        (N'PMS:Z.2',  CASE WHEN c.CS = N'No Response' AND (@HasFilter = 1 OR c.BU = N'Billed') THEN 1 ELSE 0 END),
        (N'PMS:Z.3',  CASE WHEN (@HasFilter = 1 AND c.CS = N'Partially Denied')
                             OR (@HasFilter = 0 AND c.BU = N'Billed' AND c.CS IN (N'Partially Denied', N'Partially Adjusted')) THEN 1 ELSE 0 END),
        (N'Cash:AA',  CASE WHEN c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'Cash:AB',  CASE WHEN c.BU = N'UnBilled' THEN 1 ELSE 0 END),
        (N'Cash:AC',  CASE WHEN c.CS = N'Fully Paid' AND c.InsurancePayment > 0 THEN 1 ELSE 0 END),
        (N'Cash:AD',  CASE WHEN (@HasFilter = 1 AND c.CS = N'Partial Paid')
                             OR (@HasFilter = 0 AND c.BU = N'Billed' AND c.CS IN (N'Partial Paid', N'Partially Paid')) THEN 1 ELSE 0 END),
        (N'Cash:AE',  CASE WHEN c.PatientPayment > 0 THEN 1 ELSE 0 END),
        (N'Cash:AF',  CASE WHEN (@HasFilter = 1 AND c.CS = N'Fully Adjusted')
                             OR (@HasFilter = 0 AND c.BU = N'Billed' AND c.CS = N'Complete W/O') THEN 1 ELSE 0 END),
        (N'Cash:AG',  CASE WHEN (@HasFilter = 1 AND c.InsuranceAdjustments > 0)
                             OR (@HasFilter = 0 AND c.BU = N'Billed' AND c.CS <> N'Complete W/O') THEN 1 ELSE 0 END),
        (N'Cash:AH',  CASE WHEN c.CS NOT IN (N'Unbilled', N'Unbilled - PB') THEN 1 ELSE 0 END),
        (N'Cash:AI',  CASE WHEN @HasFilter = 1 AND c.PatientAdjustments > 0 THEN 1 ELSE 0 END),
        (N'Cash:AJ',  CASE WHEN (@HasFilter = 1 AND c.CS IN (N'Fully Denied', N'No Response', N'Partially Denied'))
                             OR (@HasFilter = 0 AND c.BU = N'Billed') THEN 1 ELSE 0 END),
        (N'Cash:AK',  CASE WHEN @HasFilter = 0 AND c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'Cash:AK1', CASE WHEN @HasFilter = 0 AND c.BU = N'Billed' AND c.CS = N'Fully Denied' THEN 1 ELSE 0 END),
        (N'Cash:AK2', CASE WHEN @HasFilter = 0 AND c.BU = N'Billed' AND c.CS = N'No Response' THEN 1 ELSE 0 END),
        (N'Cash:AK3', CASE WHEN @HasFilter = 0 AND c.BU = N'Billed' AND c.CS NOT IN (N'No Response', N'Fully Denied') THEN 1 ELSE 0 END),
        (N'Avg:AKF',  CASE WHEN c.BU = N'Billed' THEN 1 ELSE 0 END),
        (N'Avg:ALF',  CASE WHEN c.CS = N'Fully Paid' THEN 1 ELSE 0 END),
        (N'Avg:AMF',  CASE WHEN c.CS NOT IN (N'Unbilled', N'Unbilled - PB') THEN 1 ELSE 0 END)
    ) r(HitCode, Hit)
    WHERE r.Hit = 1
      AND r.HitCode IN (SELECT HitCode FROM @Need);

    /* ---- Write-off rows (PMS V on the filtered grid, and V.n) --------------- */
    CREATE TABLE #xWo (Id INT NULL, ClaimID NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL, DateofService DATE NULL,
                       TransactionCode NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL, TransactionCodeDesc NVARCHAR(1000) COLLATE DATABASE_DEFAULT NULL,
                       TransactionCodeCombined NVARCHAR(1000) COLLATE DATABASE_DEFAULT NULL, MatchingCount INT NOT NULL, PY INT NOT NULL, PM INT NOT NULL);
    IF @IsWo = 1
    BEGIN
        -- Snapshot: write-offs of Billed Complete W/O claims; filtered: of every filtered claim, in a #Base month.
        ;WITH claimset AS
        (
            SELECT DISTINCT ClaimKey FROM #xAll
            WHERE @HasFilter = 1 OR (BU = N'Billed' AND CS = N'Complete W/O')
        ),
        months AS (SELECT DISTINCT PY, PM FROM #xAll)
        INSERT INTO #xWo (Id, ClaimID, DateofService, TransactionCode, TransactionCodeDesc, TransactionCodeCombined, MatchingCount, PY, PM)
        SELECT w.Id, CONVERT(NVARCHAR(200), w.ClaimID), TRY_CAST(w.DateofService AS DATE),
               CONVERT(NVARCHAR(400), w.TransactionCode), CONVERT(NVARCHAR(1000), w.TransactionCodeDesc),
               CONVERT(NVARCHAR(1000), w.TransactionCodeCombined), ISNULL(w.MatchingCount, 0),
               YEAR(TRY_CAST(w.DateofService AS DATE)), MONTH(TRY_CAST(w.DateofService AS DATE))
        FROM dbo.BTWOSummary w
        JOIN claimset s ON s.ClaimKey = LTRIM(RTRIM(CAST(w.ClaimID AS NVARCHAR(50))))
        WHERE TRY_CAST(w.DateofService AS DATE) IS NOT NULL
          AND (@DefCode = N'V' OR w.TransactionCodeCombined IS NOT NULL)
          AND (@Year  = 0 OR YEAR(TRY_CAST(w.DateofService AS DATE))  = @Year)
          AND (@Month = 0 OR MONTH(TRY_CAST(w.DateofService AS DATE)) = @Month)
          AND (@HasFilter = 0 OR EXISTS (SELECT 1 FROM months m WHERE m.PY = YEAR(TRY_CAST(w.DateofService AS DATE))
                                                                  AND m.PM = MONTH(TRY_CAST(w.DateofService AS DATE))));

        -- V.n = the n-th reason of its month: by count (snapshot) or A-Z (filtered).
        IF @WoRank IS NOT NULL
        BEGIN
            ;WITH ranked AS
            (
                SELECT PY, PM, TransactionCodeCombined,
                       ROW_NUMBER() OVER (PARTITION BY PY, PM
                                          ORDER BY CASE WHEN @HasFilter = 0 THEN -SUM(MatchingCount) ELSE 0 END, TransactionCodeCombined) AS Rk
                FROM #xWo
                GROUP BY PY, PM, TransactionCodeCombined
            )
            DELETE w FROM #xWo w
            WHERE NOT EXISTS (SELECT 1 FROM ranked r WHERE r.PY = w.PY AND r.PM = w.PM
                                                        AND r.TransactionCodeCombined = w.TransactionCodeCombined AND r.Rk = @WoRank);
        END;
    END;

    /* ---- LIS rows ------------------------------------------------------------ */
    DECLARE @NeedLis BIT = CASE WHEN @IsLis = 1 OR (@Category = 'PMS' AND @DefCode = N'S' AND @HasFilter = 0) THEN 1 ELSE 0 END;
    CREATE TABLE #xL
    (
        RowRef             INT IDENTITY(1,1) PRIMARY KEY,
        VisitNumber        NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        Accession          NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        OrderID            NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        RequestCollectDate DATE NULL,
        AMDLBD             NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
        Res                NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        CS                 NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        BN                 NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        CL                 NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        SS                 NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PMt                NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        Panel              NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PI                 NVARCHAR(510) COLLATE DATABASE_DEFAULT NOT NULL,
        PII                NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        Facility           NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        Provider           NVARCHAR(300) COLLATE DATABASE_DEFAULT NULL,
        PeriodDate         DATE NOT NULL,
        PY                 INT NOT NULL,
        PMo                INT NOT NULL
    );

    IF @NeedLis = 1
        INSERT INTO #xL (VisitNumber, Accession, OrderID, RequestCollectDate, AMDLBD, Res, CS, BN, CL, SS, PMt, Panel, PI, PII,
                         Facility, Provider, PeriodDate, PY, PMo)
        SELECT k.Acc, CONVERT(NVARCHAR(200), l.Accession), CONVERT(NVARCHAR(200), l.OrderID),
               TRY_CAST(l.RequestCollectDate AS DATE), CONVERT(NVARCHAR(100), l.AMDLBD),
               LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.RessultedStatus), N''))),
               LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.ClaimStatus), N''))),
               LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.BilledorNot), N''))),
               LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.ClientStatus), N''))),
               LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.SampleStatus), N''))),
               LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.PaymentMethod), N''))),
               k.Panel,
               LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(510), l.PrimaryInsurance), N''))),
               LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.PrimaryInsuranceID), N''))),
               CONVERT(NVARCHAR(300), l.Facility), CONVERT(NVARCHAR(300), l.Provider),
               p.PeriodDate, YEAR(p.PeriodDate), MONTH(p.PeriodDate)
        FROM dbo.LIMSMaster l
        CROSS APPLY (SELECT LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.VisitNumber), N''))) AS Acc,
                            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.PanelCategory), N''))) AS Panel) k
        CROSS APPLY (SELECT CASE WHEN @IsLis = 1 AND @LisLive = 1 AND @UseBilledDate = 1 THEN TRY_CAST(l.AMDLBD AS DATE)
                                 ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate) p
        WHERE p.PeriodDate IS NOT NULL
          -- The snapshot (and the LIS Billed count behind S) needs a VisitNumber; the live scan reads every dated row.
          AND (@IsLis = 1 AND @LisLive = 1 OR k.Acc <> N'')
          AND (@Year  = 0 OR YEAR(p.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(p.PeriodDate) = @Month)
          AND (@IsLis = 0 OR @LisLive = 0 OR (
                   (@UseBilledDate = 1 OR ((@DosFrom IS NULL OR p.PeriodDate >= @DosFrom) AND (@DosTo IS NULL OR p.PeriodDate <= @DosTo)))
               AND (@UseBilledDate = 0 OR ((@BilledFrom IS NULL OR p.PeriodDate >= @BilledFrom) AND (@BilledTo IS NULL OR p.PeriodDate <= @BilledTo)))
               AND (@YearFrom  IS NULL OR YEAR(p.PeriodDate)  >= @YearFrom)
               AND (@YearTo    IS NULL OR YEAR(p.PeriodDate)  <= @YearTo)
               AND (@MonthFrom IS NULL OR MONTH(p.PeriodDate) >= @MonthFrom)
               AND (@MonthTo   IS NULL OR MONTH(p.PeriodDate) <= @MonthTo)
               AND (@HasPanel    = 0 OR CHARINDEX(N',' + k.Panel COLLATE DATABASE_DEFAULT + N',', N',' + @Panels + N',') > 0)
               AND (@HasClinic   = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.Facility), N''))) COLLATE DATABASE_DEFAULT + N',', N',' + @Clinics + N',') > 0)
               AND (@HasProvider = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.Provider), N''))) COLLATE DATABASE_DEFAULT + N',', N',' + @Providers + N',') > 0)))
        OPTION (RECOMPILE);

    CREATE TABLE #xLHit (RowRef INT NOT NULL PRIMARY KEY);
    IF @IsLis = 1
        INSERT INTO #xLHit (RowRef)
        SELECT n.RowRef
        FROM #xL n
        WHERE CASE @DefCode
                WHEN N'A'    THEN 1
                WHEN N'B'    THEN CASE WHEN n.Res = N'Resulted' THEN 1 END
                WHEN N'B1.*' THEN CASE WHEN n.Res = N'Resulted' AND n.Panel <> N'' AND n.Panel = @PanelVal THEN 1 END
                WHEN N'B2'   THEN CASE WHEN n.Res = N'Resulted' AND n.CS = N'Billed' AND n.BN = N'Billed' AND n.CL = N'' THEN 1 END
                WHEN N'B2.1' THEN CASE WHEN n.Res = N'Resulted' AND n.CS = N'Billed' AND n.BN = N'Billed' AND n.CL = N'' THEN 1 END
                WHEN N'B3'   THEN CASE WHEN n.Res = N'Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL IN (N'', N'Billing Review Required') THEN 1 END
                WHEN N'B3.1' THEN CASE WHEN n.Res = N'Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL IN (N'', N'Billing Review Required') AND n.SS = N'Received' THEN 1 END
                WHEN N'B3.2' THEN CASE WHEN n.Res = N'Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.SS = N'Received' AND n.CL = N'Billing Review Required' THEN 1 END
                WHEN N'B3.3' THEN CASE WHEN n.Res = N'Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL IN (N'', N'Billing Review Required') AND n.SS = N'In Transit' THEN 1 END
                WHEN N'B3.4' THEN CASE WHEN n.Res = N'Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL IN (N'', N'Billing Review Required') AND n.SS = N'Transferred' THEN 1 END
                WHEN N'B3.5' THEN CASE WHEN n.Res = N'Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL IN (N'', N'Billing Review Required') AND n.SS = N'Collected' THEN 1 END
                WHEN N'B4'   THEN CASE WHEN n.Res = N'Resulted' AND n.CS = N'Entered' AND n.BN = N'UnBilled' AND n.CL = N'' THEN 1 END
                WHEN N'B5'   THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Client Bill' THEN 1 END
                WHEN N'B5.1' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Client Bill' AND n.CS = N'Not Entered in AMD'
                                        AND NOT (n.PI NOT IN (N'Client Bill', N'') AND n.PII NOT IN (N'0', N'999999')) THEN 1 END
                WHEN N'B5.2' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Client Bill' AND n.BN = N'Billed' THEN 1 END
                WHEN N'B5.3' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Client Bill' AND n.CS = N'Not Entered in AMD'
                                        AND n.PI NOT IN (N'Client Bill', N'') AND n.PII NOT IN (N'0', N'999999') THEN 1 END
                WHEN N'B5.4' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Client Bill' AND n.CS = N'Entered' AND n.BN = N'UnBilled' THEN 1 END
                WHEN N'B6'   THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Self Pay' THEN 1 END
                WHEN N'B6.1' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Self Pay' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' THEN 1 END
                WHEN N'B6.2' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Self Pay' AND n.BN = N'Billed' THEN 1 END
                WHEN N'B6.3' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Self Pay' AND n.CS = N'Entered' AND n.BN = N'UnBilled' THEN 1 END
                WHEN N'B7'   THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Test Entries' AND (@LisLive = 1 OR n.PMt <> N'No Bill') THEN 1 END
                WHEN N'B7.1' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Test Entries' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled'
                                        AND (@LisLive = 1 OR n.PMt <> N'No Bill') THEN 1 END
                WHEN N'B7.2' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Test Entries' AND n.BN = N'Billed' THEN 1 END
                WHEN N'B8'   THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Rejected Sample' THEN 1 END
                WHEN N'B8.1' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Rejected Sample' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' THEN 1 END
                WHEN N'B8.2' THEN CASE WHEN n.Res = N'Resulted' AND n.CL = N'Rejected Sample' AND n.BN = N'Billed' THEN 1 END
                WHEN N'B9'   THEN CASE WHEN n.Res = N'Resulted' AND n.PMt = N'No Bill' THEN 1 END
                WHEN N'C'    THEN CASE WHEN n.Res = N'Not Resulted' THEN 1 END
                WHEN N'C1'   THEN CASE WHEN n.Res = N'Not Resulted' AND n.CS = N'Billed' AND n.BN = N'Billed' AND n.CL = N'' THEN 1 END
                WHEN N'C2'   THEN CASE WHEN n.Res = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL = N'' THEN 1 END
                WHEN N'C2.1' THEN CASE WHEN n.Res = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL = N'' AND n.SS = N'Received' THEN 1 END
                WHEN N'C2.2' THEN CASE WHEN n.Res = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL = N'' AND n.SS = N'In Transit' THEN 1 END
                WHEN N'C2.3' THEN CASE WHEN n.Res = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL = N'' AND n.SS = N'Collected' THEN 1 END
                WHEN N'C2.4' THEN CASE WHEN n.Res = N'Not Resulted' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' AND n.CL = N'' AND n.SS = N'Transferred' THEN 1 END
                WHEN N'C3'   THEN CASE WHEN n.Res = N'Not Resulted' AND n.CL = N'Client Bill' THEN 1 END
                WHEN N'C4'   THEN CASE WHEN n.Res = N'Not Resulted' AND n.CL = N'Self Pay' THEN 1 END
                WHEN N'C4.1' THEN CASE WHEN n.Res = N'Not Resulted' AND n.CL = N'Self Pay' AND n.CS = N'Not Entered in AMD' AND n.BN = N'UnBilled' THEN 1 END
                WHEN N'C4.2' THEN CASE WHEN n.Res = N'Not Resulted' AND n.CL = N'Self Pay' AND n.BN = N'Billed' THEN 1 END
                WHEN N'D'    THEN CASE WHEN n.Res = N'Not Resulted' AND n.CL = N'Test Entries' THEN 1 END
                WHEN N'E'    THEN CASE WHEN n.Res = N'Not Resulted' AND n.CL = N'Rejected Sample' THEN 1 END
              END = 1;

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
            -- Snapshot S = R - LIS Billed (LIMSMaster BilledorNot = Billed, distinct VisitNumber) per month.
            DECLARE @Mon TABLE (PY INT NOT NULL, PMo INT NOT NULL, Billed INT NOT NULL, Lis INT NOT NULL, PRIMARY KEY (PY, PMo));
            INSERT INTO @Mon (PY, PMo, Billed, Lis)
            SELECT m.PY, m.PM,
                   (SELECT COUNT(DISTINCT c.ClaimID) FROM #xC c JOIN #xHit h ON h.RowId = c.RowId AND h.HitCode = N'PMS:R' WHERE c.PY = m.PY AND c.PM = m.PM),
                   (SELECT COUNT(DISTINCT l.VisitNumber) FROM #xL l WHERE l.BN = N'Billed' AND l.PY = m.PY AND l.PMo = m.PM)
            FROM (SELECT DISTINCT PY, PM FROM #xC) m;

            DECLARE @BilledSum INT = ISNULL((SELECT SUM(Billed) FROM @Mon), 0);
            DECLARE @LisSum    INT = ISNULL((SELECT SUM(Lis) FROM @Mon), 0);
            SET @Result = @BilledSum - @LisSum;

            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'PMS', N'R', N'Billed - Includes all Claims Billed in AMD', @BilledSum, 0, 0),
                (2, N'Calculation', N'-', NULL, NULL, N'LIS Billed samples (LIMSMaster BilledorNot = Billed, distinct VisitNumber)', @LisSum, 0, 0),
                (9, N'Result', N'=', 'PMS', N'S', N'Billed Mismatches - Non Diagnose LIS Samples', @Result, 0, 1);
            SET @Calc = FORMAT(@BilledSum, 'N0') + N' - ' + FORMAT(@LisSum, 'N0') + N' = ' + FORMAT(@Result, 'N0');
        END
        ELSE IF @Year <> 0 AND @Month = 0
        BEGIN
            -- Avg rows have no year value, so the grid's Year Total adds the monthly averages
            -- at 2 decimals (snapshot values are stored that way; the filtered grid's UNION ALL with
            -- DECIMAL(38,2) legs rounds them).
            DECLARE @AvgMon TABLE (PY INT NOT NULL, PMo INT NOT NULL, Num DECIMAL(38,2) NOT NULL, Den INT NOT NULL, PRIMARY KEY (PY, PMo));
            IF @HasFilter = 0
                INSERT INTO @AvgMon (PY, PMo, Num, Den)
                SELECT m.PY, m.PM,
                       ISNULL((SELECT SUM(CASE h.HitCode WHEN N'Cash:AE' THEN c.PatientPayment ELSE c.InsurancePayment END)
                               FROM #xHit h JOIN #xC c ON c.RowId = h.RowId
                               WHERE c.PY = m.PY AND c.PM = m.PM AND h.HitCode IN (N'Cash:AC', N'Cash:AD', N'Cash:AE')), 0),
                       ISNULL((SELECT SUM(x.Cnt) FROM (
                                   SELECT h.HitCode, COUNT(DISTINCT c.ClaimID) AS Cnt
                                   FROM #xHit h JOIN #xC c ON c.RowId = h.RowId
                                   WHERE c.PY = m.PY AND c.PM = m.PM
                                     AND h.HitCode IN (SELECT v.Code FROM (VALUES
                                         (N'PMS:R', N'AL'), (N'PMS:U', N'AM'), (N'PMS:X', N'AM'), (N'PMS:Y', N'AM'),
                                         (N'PMS:U', N'AN'), (N'PMS:V', N'AN'), (N'PMS:W', N'AN'), (N'PMS:X', N'AN'),
                                         (N'PMS:Y', N'AN'), (N'PMS:Z.1', N'AN'), (N'PMS:Z.3', N'AN')) v(Code, Avg) WHERE v.Avg = @DefCode)
                                   GROUP BY h.HitCode) x), 0)
                FROM (SELECT DISTINCT PY, PM FROM #xC) m;
            ELSE
                INSERT INTO @AvgMon (PY, PMo, Num, Den)
                SELECT m.PY, m.PM,
                       ISNULL((SELECT SUM(c.InsurancePayment + c.PatientPayment) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId
                               WHERE c.PY = m.PY AND c.PM = m.PM AND h.HitCode = N'Avg:' + @DefCode + N'F'), 0),
                       ISNULL((SELECT COUNT(*) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId
                               WHERE c.PY = m.PY AND c.PM = m.PM AND h.HitCode = N'Avg:' + @DefCode + N'F'), 0)
                FROM (SELECT DISTINCT PY, PM FROM #xC) m;

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT ROW_NUMBER() OVER (ORDER BY PMo), N'Calculation',
                   CASE WHEN ROW_NUMBER() OVER (ORDER BY PMo) = 1 THEN N'' ELSE N'+' END, NULL, NULL,
                   DATENAME(MONTH, DATEFROMPARTS(PY, PMo, 1)) + N' ' + CAST(PY AS NVARCHAR(4)) + N' average ($'
                       + FORMAT(Num, 'N2') + N' / ' + FORMAT(Den, 'N0') + N')',
                   CASE WHEN Den > 0 THEN CONVERT(DECIMAL(18,2), Num / Den) ELSE 0 END, 1, 0
            FROM @AvgMon;

            SET @Result = CONVERT(DECIMAL(18,2), ISNULL((
                SELECT SUM(CASE WHEN Den = 0 THEN 0 ELSE CONVERT(DECIMAL(18,2), Num / Den) END) FROM @AvgMon), 0));

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 999, N'Result', N'=', 'Avg', d.RowCode, d.Description, @Result, 1, 1
            FROM @Def d WHERE d.Category = 'Avg' AND UPPER(d.RowCode) = @DefCode;

            SET @Calc = N'Sum of the monthly averages (the grid''s Year Total adds them) = $' + FORMAT(@Result, 'N2');
        END
        ELSE
        BEGIN
            -- Avg month (or snapshot Grand Total, distinct claims over every period).
            DECLARE @Parts TABLE (Seq INT, Section NVARCHAR(20), Category VARCHAR(10), RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT,
                                  HitCode NVARCHAR(30) COLLATE DATABASE_DEFAULT, Measure CHAR(3), Label NVARCHAR(300));
            IF @HasFilter = 0
            BEGIN
                INSERT INTO @Parts VALUES (1, N'Numerator', 'Cash', N'AC', N'Cash:AC', 'INS', NULL),
                                          (2, N'Numerator', 'Cash', N'AD', N'Cash:AD', 'INS', NULL),
                                          (3, N'Numerator', 'Cash', N'AE', N'Cash:AE', 'PAT', NULL);
                INSERT INTO @Parts SELECT v.Seq, N'Denominator', 'PMS', v.Code, N'PMS:' + v.Code, 'CNT', NULL
                FROM (VALUES (11, N'R', N'AL'), (11, N'U', N'AM'), (12, N'X', N'AM'), (13, N'Y', N'AM'),
                             (11, N'U', N'AN'), (12, N'V', N'AN'), (13, N'W', N'AN'), (14, N'X', N'AN'),
                             (15, N'Y', N'AN'), (16, N'Z.1', N'AN'), (17, N'Z.3', N'AN')) v(Seq, Code, Avg)
                WHERE v.Avg = @DefCode;
            END
            ELSE
                INSERT INTO @Parts VALUES
                    (1,  N'Numerator',   NULL, NULL, N'Avg:' + @DefCode + N'F', 'INS', N'Insurance Payment of the claims'),
                    (2,  N'Numerator',   NULL, NULL, N'Avg:' + @DefCode + N'F', 'PAT', N'Patient Payment of the claims'),
                    (11, N'Denominator', NULL, NULL, N'Avg:' + @DefCode + N'F', 'ROW', N'Claim rows');

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT x.Seq, x.Section, CASE WHEN x.Seq IN (1, 11) THEN N'' ELSE N'+' END, x.Category, x.RowCode,
                   COALESCE(x.Label, d.Description),
                   ISNULL(CASE x.Measure
                              WHEN 'INS' THEN (SELECT SUM(c.InsurancePayment) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.HitCode = x.HitCode)
                              WHEN 'PAT' THEN (SELECT SUM(c.PatientPayment)   FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.HitCode = x.HitCode)
                              WHEN 'CNT' THEN (SELECT CAST(COUNT(DISTINCT c.DedupeKey) AS DECIMAL(18,2)) FROM #xHit h JOIN #xC c ON c.RowId = h.RowId WHERE h.HitCode = x.HitCode)
                              ELSE            (SELECT CAST(COUNT(*) AS DECIMAL(18,2)) FROM #xHit h WHERE h.HitCode = x.HitCode) END, 0),
                   CASE WHEN x.Measure IN ('INS', 'PAT') THEN 1 ELSE 0 END, 0
            FROM @Parts x
            LEFT JOIN @Def d ON d.Category = x.Category AND d.RowCode = x.RowCode;

            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 9, N'Numerator', N'=', NULL, NULL, N'Total Pay ($)', SUM(Value), 1, 1 FROM @Comp WHERE Section = N'Numerator';
            INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
            SELECT 19, N'Denominator', N'=', NULL, NULL, N'Claims', SUM(Value), 0, 1 FROM @Comp WHERE Section = N'Denominator';

            DECLARE @NumTotal DECIMAL(18,2) = (SELECT Value FROM @Comp WHERE Section = N'Numerator' AND IsTotal = 1);
            DECLARE @DenTotal DECIMAL(18,2) = (SELECT Value FROM @Comp WHERE Section = N'Denominator' AND IsTotal = 1);
            SET @Result = CASE WHEN ISNULL(@DenTotal, 0) = 0 THEN 0
                               ELSE CONVERT(DECIMAL(18,2), CONVERT(DECIMAL(38,2), @NumTotal) / CONVERT(INT, @DenTotal)) END;

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

    /* ---- LIS rows: one line per LIMSMaster row -------------------------------- */
    IF @IsLis = 1
    BEGIN
        SELECT N'dbo.LIMSMaster' AS SourceTable, N'Count of samples' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #xLHit;

        SELECT l.VisitNumber, l.Accession, l.OrderID, l.RequestCollectDate, l.AMDLBD, l.Res AS ResultedStatus, l.CS AS ClaimStatus,
               l.BN AS BilledorNot, l.CL AS ClientStatus, l.SS AS SampleStatus, l.PMt AS PaymentMethod, l.Panel AS PanelCategory,
               l.Facility, l.Provider, l.PI AS PrimaryInsurance
        FROM #xL l
        JOIN #xLHit h ON h.RowRef = l.RowRef
        ORDER BY l.PeriodDate, l.VisitNumber
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- Write-off rows: one line per BTWOSummary row ------------------------ */
    IF @IsWo = 1
    BEGIN
        SELECT N'dbo.BTWOSummary' AS SourceTable, N'Sum of MatchingCount' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               ISNULL(SUM(MatchingCount), 0) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #xWo;

        SELECT ClaimID, DateofService, TransactionCodeCombined, TransactionCode, TransactionCodeDesc, MatchingCount
        FROM #xWo
        ORDER BY DateofService, ClaimID, Id
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
                   WHEN N'TotalAdjustments'     THEN c.TotalAdjustments
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

    /* ---- Count rows: one line per claim and month (snapshot) or per row ------ */
    ;WITH k AS
    (
        SELECT c.*, CASE WHEN @CountDistinct = 1 THEN c.DedupeKey ELSE CONVERT(NVARCHAR(20), c.RowId) END AS LineKey
        FROM #xC c
        JOIN #xHit h ON h.RowId = c.RowId AND h.HitCode = @HitCode
    ),
    r AS
    (
        SELECT k.*, ROW_NUMBER() OVER (PARTITION BY k.LineKey ORDER BY k.DateofService) AS KeySeq,
                    COUNT(*)     OVER (PARTITION BY k.LineKey)                         AS Claims
        FROM k
    )
    SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, Panelname, ClinicName,
           ReferringProvider, SalesRepname, BilledUnbilled, ClaimStatus, Claims,
           ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments, InsuranceBalance, PatientBalance,
           PY, PM
    INTO #xAcc
    FROM r
    WHERE KeySeq = 1;

    SELECT N'dbo.ClaimLevelData' AS SourceTable,
           CASE WHEN @CountDistinct = 1 THEN N'Count of distinct ClaimID' ELSE N'Count of claim rows' END AS Measure,
           CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
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

PRINT '29_BeechTree_ExecutiveSummary_CellRows.sql completed.';
GO
