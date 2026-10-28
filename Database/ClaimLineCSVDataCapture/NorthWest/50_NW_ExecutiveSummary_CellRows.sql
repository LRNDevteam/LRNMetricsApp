/* =============================================================================
   NorthWest - Executive Summary cell rows (value click -> popup grid)
   File     : 50_NW_ExecutiveSummary_CellRows.sql
   Database : NWL_LRN
   Requires : 44_NW_ExecutiveSummary_BilledUnbilled.sql
   Object   : dbo.usp_GetNW_ExecutiveSummaryCellRows

   Returns the source rows behind one Executive Summary cell. Rows are selected with the
   grid's own definitions - fn_NW_ES_LisSamples / fn_NW_ES_Claims (page filters, period)
   and fn_NW_ES_LisRowCodes / fn_NW_ES_ClaimRowCodes (row rules) - so the row count /
   amount equals the clicked value.

   Parameters
     @Category / @RowCode   the clicked row (LIS A..F.5 and B.{PanelType}, PMS G..S.3.AP,
                            Cash T..AC.3.AP, Avg AD..AF)
     @Year / @Month         (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetNW_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured value for $ rows)
   Aria rows (S.1/S.3 .A1/.A2, AC.1/AC.3 .A1/.A2): the Fully Denied (PMS S.1) / No Response
   (PMS S.3) claims of the period, split on FirstBilledDate within 30 days of the latest
   FirstBilledDate of that cohort in the period (as usp_NW_ES_Build).
   Formula rows (PMS I, Cash Z, Avg AD / AE / AF, Aria %) return the formula and calculation in
   Rules, IsFormula = 1, TotalAmount = the grid value, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal) from the
   Executive Summary snapshot (no page filter) or usp_NW_ES_Build (page filters).

   fn_NW_ES_LisSamples gains ClinicName / ReferringProvider and fn_NW_ES_Claims gains
   PayerName_Raw / PanelType / ClinicName / ReferringProvider / SalesRepname for the popup
   grid (appended columns; the grid's build reads named columns only).
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'50_NW_ExecutiveSummary_CellRows.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* -----------------------------------------------------------------------------
   Source rows (definitions of 44, plus display columns)
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_ES_LisSamples
(
    @YearFrom  INT,           @YearTo  INT,
    @MonthFrom INT,           @MonthTo INT,
    @DosFrom   DATE,          @DosTo   DATE,
    @Panels    NVARCHAR(MAX), @Clinics NVARCHAR(MAX), @Providers NVARCHAR(MAX)
)
RETURNS TABLE
AS
RETURN
    SELECT
        l.Accession,
        ServiceDate = l.RequestCollectDate,
        ESYear      = YEAR(l.RequestCollectDate),
        ESMonth     = MONTH(l.RequestCollectDate),
        l.IncorrectDOS, l.BilledTo, l.BillStatus, l.FinalStatus,
        Source      = l.SourceSystem,
        l.ChargesNotEnteredStatus,
        l.PanelType,
        l.ClinicName,
        l.ReferringProvider
    FROM dbo.LIMSMaster l
    WHERE l.RequestCollectDate IS NOT NULL
      AND (ISNULL(@YearFrom,  0) = 0 OR YEAR(l.RequestCollectDate)  >= @YearFrom)
      AND (ISNULL(@YearTo,    0) = 0 OR YEAR(l.RequestCollectDate)  <= @YearTo)
      AND (ISNULL(@MonthFrom, 0) = 0 OR MONTH(l.RequestCollectDate) >= @MonthFrom)
      AND (ISNULL(@MonthTo,   0) = 0 OR MONTH(l.RequestCollectDate) <= @MonthTo)
      AND (@DosFrom IS NULL OR l.RequestCollectDate >= @DosFrom)
      AND (@DosTo   IS NULL OR l.RequestCollectDate <= @DosTo)
      AND (NULLIF(LTRIM(RTRIM(@Panels)), N'') IS NULL
           OR LTRIM(RTRIM(l.PanelType)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Panels, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Clinics)), N'') IS NULL
           OR LTRIM(RTRIM(l.ClinicName)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Clinics, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NULL
           OR LTRIM(RTRIM(l.ReferringProvider)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Providers, N',')));
GO

CREATE OR ALTER FUNCTION dbo.fn_NW_ES_Claims
(
    @YearFrom   INT,           @YearTo     INT,
    @MonthFrom  INT,           @MonthTo    INT,
    @DosFrom    DATE,          @DosTo      DATE,
    @BilledFrom DATE,          @BilledTo   DATE,
    @Panels     NVARCHAR(MAX), @Clinics    NVARCHAR(MAX),
    @Providers  NVARCHAR(MAX), @Reps       NVARCHAR(MAX)
)
RETURNS TABLE
AS
RETURN
    SELECT
        ClaimID         = LTRIM(RTRIM(c.ClaimID)),
        AccessionNumber = LTRIM(RTRIM(c.AccessionNumber)),
        DateofService   = d.Dos,
        FirstBilledDate = d.FirstBill,
        ESYear          = YEAR(d.Dos),
        ESMonth         = MONTH(d.Dos),
        BilledUnbilled  = LTRIM(RTRIM(ISNULL(c.BilledUnbilled, N''))),
        ClaimType       = LTRIM(RTRIM(ISNULL(CAST(c.ClaimType AS NVARCHAR(500)), N''))),
        ClaimStatus     = LTRIM(RTRIM(ISNULL(c.ClaimStatus, N''))),
        ChargeAmount         = ISNULL(TRY_CAST(c.ChargeAmount           AS DECIMAL(18,2)), 0),
        InsurancePayment     = ISNULL(TRY_CAST(c.InsurancePayment       AS DECIMAL(18,2)), 0),
        ActualPayment        = ISNULL(TRY_CAST(c.ActualPayment          AS DECIMAL(18,2)), 0),
        DuplicatePayment     = ISNULL(TRY_CAST(c.DuplicatePaymentPosted AS DECIMAL(18,2)), 0),
        PatientPayment       = ISNULL(TRY_CAST(c.PatientPayment         AS DECIMAL(18,2)), 0),
        InsuranceAdjustments = ISNULL(TRY_CAST(c.InsuranceAdjustments   AS DECIMAL(18,2)), 0),
        PatientAdjustments   = ISNULL(TRY_CAST(c.PatientAdjustments     AS DECIMAL(18,2)), 0),
        InsuranceBalance     = ISNULL(TRY_CAST(c.InsuranceBalance       AS DECIMAL(18,2)), 0),
        PatientBalance       = ISNULL(TRY_CAST(c.PatientBalance         AS DECIMAL(18,2)), 0),
        PayerName_Raw        = LTRIM(RTRIM(c.PayerName_Raw)),
        PanelType            = LTRIM(RTRIM(c.PanelType)),
        ClinicName           = LTRIM(RTRIM(c.ClinicName)),
        ReferringProvider    = LTRIM(RTRIM(c.ReferringProvider)),
        SalesRepname         = LTRIM(RTRIM(c.SalesRepname))
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        Dos       = COALESCE(TRY_CONVERT(DATE, c.DateofService,   101), TRY_CAST(c.DateofService   AS DATE)),
        FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE))) p
    CROSS APPLY (SELECT
        Dos       = CASE WHEN p.Dos       >= '19010101' THEN p.Dos       END,
        FirstBill = CASE WHEN p.FirstBill >= '19010101' THEN p.FirstBill END) d
    WHERE d.Dos IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(c.AccessionNumber)), N'') IS NOT NULL
      AND (ISNULL(@YearFrom,  0) = 0 OR YEAR(d.Dos)  >= @YearFrom)
      AND (ISNULL(@YearTo,    0) = 0 OR YEAR(d.Dos)  <= @YearTo)
      AND (ISNULL(@MonthFrom, 0) = 0 OR MONTH(d.Dos) >= @MonthFrom)
      AND (ISNULL(@MonthTo,   0) = 0 OR MONTH(d.Dos) <= @MonthTo)
      AND (@DosFrom    IS NULL OR d.Dos       >= @DosFrom)
      AND (@DosTo      IS NULL OR d.Dos       <= @DosTo)
      AND (@BilledFrom IS NULL OR d.FirstBill >= @BilledFrom)
      AND (@BilledTo   IS NULL OR d.FirstBill <= @BilledTo)
      AND (NULLIF(LTRIM(RTRIM(@Panels)), N'') IS NULL
           OR LTRIM(RTRIM(c.PanelType)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Panels, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Clinics)), N'') IS NULL
           OR LTRIM(RTRIM(c.ClinicName)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Clinics, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NULL
           OR LTRIM(RTRIM(c.ReferringProvider)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Providers, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Reps)), N'') IS NULL
           OR LTRIM(RTRIM(c.SalesRepname)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Reps, N',')));
GO

/* -----------------------------------------------------------------------------
   Cell rows
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_ExecutiveSummaryCellRows
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

    DECLARE @Desc NVARCHAR(500) =
        (SELECT LTRIM(RTRIM(Description)) FROM dbo.fn_NW_ES_RowDefs() WHERE Category = @Category AND RowCode = @RowCode);
    IF @Desc IS NULL AND @Category = 'LIS' AND @RowCode LIKE N'B.%'
        SET @Desc = SUBSTRING(@RowCode, 3, 100);
    IF @Desc IS NULL
    BEGIN
        RAISERROR(N'usp_GetNW_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCode);
        RETURN;
    END;

    /* ---- Row kind ----------------------------------------------------------- */
    DECLARE @IsLis     BIT = IIF(@Category = 'LIS', 1, 0);
    DECLARE @IsAriaPct BIT = IIF(@RowCode LIKE N'%.AP', 1, 0);
    DECLARE @IsFormula BIT = IIF(@IsAriaPct = 1 OR @RowCode IN (N'I', N'Z', N'AD', N'AE', N'AF'), 1, 0);
    -- Aria A1 / A2: cohort PMS S.1 (Fully Denied) or S.3 (No Response); 1 = submitted in the last 30 days
    DECLARE @AriaPart INT = CASE WHEN @RowCode LIKE N'%.A1' THEN 1 WHEN @RowCode LIKE N'%.A2' THEN 2 END;
    DECLARE @AriaCohort NVARCHAR(10) =
        CASE WHEN @RowCode LIKE N'S.1.%' OR @RowCode LIKE N'AC.1.%' THEN N'S.1'
             WHEN @RowCode LIKE N'S.3.%' OR @RowCode LIKE N'AC.3.%' THEN N'S.3' END;

    /* ---- Row rules (as fn_NW_ES_LisRowCodes / fn_NW_ES_ClaimRowCodes) -------- */
    DECLARE @Ok   NVARCHAR(100) = N'Incorrect DOS is blank';
    DECLARE @Ins  NVARCHAR(200) = @Ok + N' AND Bill To = Insurance Bill';
    DECLARE @C    NVARCHAR(300) = @Ins + N' AND Bill Status = Billed';
    DECLARE @D    NVARCHAR(300) = @Ins + N' AND Bill Status = Unbilled';
    DECLARE @Std  NVARCHAR(200) = N'Claim Type NOT IN (ADCS - Invoice, Test Patient Entries)';
    DECLARE @Bs   NVARCHAR(300) = N'BilledUnbilled = Billed AND Claim Type IN (Claim Submitted in Webpm, Claim Submitted in Daqbilling, Manually Pushed in Emedix)';
    DECLARE @G    NVARCHAR(400) = @Bs + N' AND Claim Status <> Billed Amount 0';
    DECLARE @H    NVARCHAR(400) = @Std + N' AND Claim Status IN (Billed Amount 0, Unbilled in Daq, Unbilled in Daq PR, Unbilled in Webpm, Unbilled in Webpm PR)';
    DECLARE @GSrc NVARCHAR(300) = N'BilledUnbilled = Billed AND Claim Status <> Billed Amount 0 AND Claim Type = ';
    DECLARE @Aria NVARCHAR(300) = N' - split on FirstBilledDate within 30 days of the latest FirstBilledDate of these claims in the period';

    DECLARE @Def TABLE (Category VARCHAR(10), RowCode NVARCHAR(20), RuleText NVARCHAR(1000), AmountCol NVARCHAR(100));
    INSERT INTO @Def (Category, RowCode, RuleText, AmountCol) VALUES
        ('LIS', N'A',      @Ok, NULL),
        ('LIS', N'B',      @Ins, NULL),
        ('LIS', N'C',      @C, NULL),
        ('LIS', N'C.1',    @C + N' AND Final Status = Claim Submitted in Webpm', NULL),
        ('LIS', N'C.2',    @C + N' AND Final Status = Claim Submitted in Daqbilling', NULL),
        ('LIS', N'C.3',    @C + N' AND Final Status = Claim Submitted in Daq & Webpm', NULL),
        ('LIS', N'C.4',    @C + N' AND Final Status = Non Billable - Excluded Organizations', NULL),
        ('LIS', N'C.5',    @C + N' AND Final Status = Manually Pushed in Emedix', NULL),
        ('LIS', N'D',      @D, NULL),
        ('LIS', N'D.1',    @D + N' AND Final Status = Charge Not Created', NULL),
        ('LIS', N'D.1.W',  @D + N' AND Final Status = Charge Not Created AND Source = Webpm', NULL),
        ('LIS', N'D.1.NC', @D + N' AND Final Status = Charge Not Created AND Source = Webpm AND Charges Not Entered Status = No Charges found in Webpm', NULL),
        ('LIS', N'D.1.UP', @D + N' AND Final Status = Charge Not Created AND Source = Webpm AND Charges Not Entered Status = Unposted Charges in Webpm', NULL),
        ('LIS', N'D.1.DQ', @D + N' AND Final Status = Charge Not Created AND Source = Daqbilling', NULL),
        ('LIS', N'D.2',    @D + N' AND Final Status = Non Billable - Excluded PAP Codes', NULL),
        ('LIS', N'D.3',    @D + N' AND Final Status = Non Billable - Excluded Validity Codes', NULL),
        ('LIS', N'D.4',    @D + N' AND Final Status = Non Billable - Excluded Organizations', NULL),
        ('LIS', N'D.5',    @D + N' AND Final Status = Charges Created and Not Submitted', NULL),
        ('LIS', N'D.5.W',  @D + N' AND Final Status = Charges Created and Not Submitted AND Source = Webpm', NULL),
        ('LIS', N'D.5.DQ', @D + N' AND Final Status = Charges Created and Not Submitted AND Source = Daqbilling', NULL),
        ('LIS', N'E',      @Ok + N' AND Bill To = ADCS Claims', NULL),
        ('LIS', N'F',      @Ok + N' AND Bill To NOT IN (Insurance Bill, ADCS Claims)', NULL),
        ('LIS', N'F.1',    @Ok + N' AND Bill To = Yet to be validate', NULL),
        ('LIS', N'F.2',    @Ok + N' AND Bill To = Self pay', NULL),
        ('LIS', N'F.3',    @Ok + N' AND Bill To = Client Bills', NULL),
        ('LIS', N'F.4',    @Ok + N' AND Bill To = Rejections', NULL),
        ('LIS', N'F.5',    @Ok + N' AND Bill To = System Test', NULL),

        ('PMS', N'G',      @G, NULL),
        ('PMS', N'G.1',    @GSrc + N'Claim Submitted in Webpm', NULL),
        ('PMS', N'G.2',    @GSrc + N'Claim Submitted in Daqbilling', NULL),
        ('PMS', N'G.3',    @GSrc + N'Manually Pushed in Emedix', NULL),
        ('PMS', N'H',      @H, NULL),
        ('PMS', N'H.1',    @Std + N' AND Claim Status = Unbilled in Webpm PR', NULL),
        ('PMS', N'H.2',    @Std + N' AND Claim Status = Unbilled in Webpm', NULL),
        ('PMS', N'H.3',    @Std + N' AND Claim Status = Unbilled in Daq', NULL),
        ('PMS', N'H.4',    @Std + N' AND Claim Status = Unbilled in Daq PR', NULL),
        ('PMS', N'H.5',    @Std + N' AND Claim Status = Billed Amount 0', NULL),
        ('PMS', N'I',      N'Formula: No. of Billed Claims (PMS G) - LIS Billed samples (LIS C), for the same period', NULL),
        ('PMS', N'J',      N'Claim Type = Test Patient Entries', NULL),
        ('PMS', N'K',      N'Claim Type = ADCS - Invoice', NULL),
        ('PMS', N'M',      @Std + N' AND Claim Status = Fully Paid', NULL),
        ('PMS', N'N',      @Std + N' AND Claim Status = Pat Responsibility', NULL),
        ('PMS', N'O',      @Std + N' AND Claim Status = Fully Adjusted', NULL),
        ('PMS', N'P',      @Std + N' AND Claim Status = Partially Adjusted', NULL),
        ('PMS', N'Q',      @Std + N' AND Claim Status = Partially Paid', NULL),
        ('PMS', N'R',      @Std + N' AND Claim Status = Patient Paid', NULL),
        ('PMS', N'S',      @Std + N' AND Claim Status IN (Fully Denied, Partially Denied, No Response)', NULL),
        ('PMS', N'S.1',    @Std + N' AND Claim Status = Fully Denied', NULL),
        ('PMS', N'S.1.A1', @Std + N' AND Claim Status = Fully Denied' + @Aria + N': billed within the 30 days', NULL),
        ('PMS', N'S.1.A2', @Std + N' AND Claim Status = Fully Denied' + @Aria + N': not billed within the 30 days', NULL),
        ('PMS', N'S.1.AP', N'Formula: Aria submitted in the last 30 days (PMS S.1.A1) / not submitted (PMS S.1.A2)', NULL),
        ('PMS', N'S.2',    @Std + N' AND Claim Status = Partially Denied', NULL),
        ('PMS', N'S.3',    @Std + N' AND Claim Status = No Response', NULL),
        ('PMS', N'S.3.A1', @Std + N' AND Claim Status = No Response' + @Aria + N': billed within the 30 days', NULL),
        ('PMS', N'S.3.A2', @Std + N' AND Claim Status = No Response' + @Aria + N': not billed within the 30 days', NULL),
        ('PMS', N'S.3.AP', N'Formula: Claims filed by ARIA in the last 30 days (PMS S.3.A1) / not filed (PMS S.3.A2)', NULL),

        ('Cash', N'T',       @G, N'ChargeAmount'),
        ('Cash', N'T.1',     @GSrc + N'Claim Submitted in Webpm', N'ChargeAmount'),
        ('Cash', N'T.2',     @GSrc + N'Claim Submitted in Daqbilling', N'ChargeAmount'),
        ('Cash', N'T.3',     @GSrc + N'Manually Pushed in Emedix', N'ChargeAmount'),
        ('Cash', N'U',       @H, N'ChargeAmount'),
        ('Cash', N'U.1',     @Std + N' AND Claim Status = Unbilled in Webpm PR', N'ChargeAmount'),
        ('Cash', N'U.2',     @Std + N' AND Claim Status = Unbilled in Webpm', N'ChargeAmount'),
        ('Cash', N'U.3',     @Std + N' AND Claim Status = Unbilled in Daq', N'ChargeAmount'),
        ('Cash', N'U.4',     @Std + N' AND Claim Status = Unbilled in Daq PR', N'ChargeAmount'),
        ('Cash', N'V',       N'Claim Type = Test Patient Entries', N'ChargeAmount'),
        ('Cash', N'W',       N'Claim Type = ADCS - Invoice', N'ChargeAmount'),
        ('Cash', N'X',       @Std + N' AND Claim Status = Fully Paid', N'InsurancePayment'),
        ('Cash', N'X.1',     @Std + N' AND Claim Status = Fully Paid', N'ActualPayment'),
        ('Cash', N'X.2',     @Std + N' AND Claim Status = Fully Paid', N'DuplicatePayment'),
        ('Cash', N'Y',       @Bs, N'PatientBalance'),
        ('Cash', N'Z',       N'Formula: Total Billed (T) - Insurance Payment (X) - Partially Paid (AA) - Patient Paid (AB) - Patient Responsibility (Y) - Insurance Balance (AC)', NULL),
        ('Cash', N'AA',      @Bs + N' AND Claim Status = Partially Paid', N'InsurancePayment'),
        ('Cash', N'AA.1',    @Bs + N' AND Claim Status = Partially Paid', N'ActualPayment (InsurancePayment when ActualPayment is 0)'),
        ('Cash', N'AA.2',    @Bs + N' AND Claim Status = Partially Paid', N'DuplicatePayment'),
        ('Cash', N'AB',      @Bs, N'PatientPayment'),
        ('Cash', N'AC',      @Bs, N'InsuranceBalance'),
        ('Cash', N'AC.1',    @Bs + N' AND Claim Status = Fully Denied', N'InsuranceBalance'),
        ('Cash', N'AC.1.A1', @Std + N' AND Claim Status = Fully Denied' + @Aria + N': billed within the 30 days', N'InsuranceBalance'),
        ('Cash', N'AC.1.A2', @Std + N' AND Claim Status = Fully Denied' + @Aria + N': not billed within the 30 days', N'InsuranceBalance'),
        ('Cash', N'AC.1.AP', N'Formula: Insurance Balance of claims filed by ARIA in the last 30 days (Cash AC.1.A1) / not filed (Cash AC.1.A2)', NULL),
        ('Cash', N'AC.2',    @Bs + N' AND Claim Status NOT IN (Fully Denied, No Response)', N'InsuranceBalance'),
        ('Cash', N'AC.3',    @Bs + N' AND Claim Status = No Response', N'InsuranceBalance'),
        ('Cash', N'AC.3.A1', @Std + N' AND Claim Status = No Response' + @Aria + N': billed within the 30 days', N'InsuranceBalance'),
        ('Cash', N'AC.3.A2', @Std + N' AND Claim Status = No Response' + @Aria + N': not billed within the 30 days', N'InsuranceBalance'),
        ('Cash', N'AC.3.AP', N'Formula: Insurance Balance of claims filed by ARIA in the last 30 days (Cash AC.3.A1) / not filed (Cash AC.3.A2)', NULL),

        ('Avg', N'AD', N'Formula: (Insurance Payment $ + Partially Paid $ + Patient Paid $) / No. of Billed Claims (PMS G)', NULL),
        ('Avg', N'AE', N'Formula: (Insurance Payment $ + Partially Paid $ + Patient Paid $) / (Fully Paid + Partially Paid + Patient Paid claims)', NULL),
        ('Avg', N'AF', N'Formula: (Insurance Payment $ + Partially Paid $) / (Fully Paid + Adjusted + Fully Denied + Partially Denied + Partially Paid + Partially Adjusted + Patient Paid + Patient Responsibility claims)', NULL);

    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100);
    SELECT @RuleText = RuleText, @AmountCol = AmountCol FROM @Def WHERE Category = @Category AND RowCode = @RowCode;
    IF @RuleText IS NULL AND @IsLis = 1 AND @RowCode LIKE N'B.%'
        SET @RuleText = @Ins + N' AND PanelType = ' + SUBSTRING(@RowCode, 3, 100);
    IF @RuleText IS NULL
    BEGIN
        RAISERROR(N'usp_GetNW_ExecutiveSummaryCellRows: no rule for row %s / %s.', 16, 1, @Category, @RowCode);
        RETURN;
    END;

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
    SELECT N'Base filter', CASE WHEN @IsLis = 1 THEN N'RequestCollectDate is a date'
                                ELSE N'DateofService is a date (12/31/1899 = blank) AND AccessionNumber not blank' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    VALUES (N'Period', CASE WHEN @IsLis = 1 THEN N'RequestCollectDate' ELSE N'DateofService' END + N' in ' + @PeriodText);
    INSERT INTO @Rules (RuleGroup, RuleText) VALUES (IIF(@IsFormula = 1, N'Formula', N'Row rule'), @RuleText);
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Measure', CASE WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol
                            WHEN @IsLis = 1 THEN N'Count of samples (rows)'
                            ELSE N'Count of claims (rows)' END
    WHERE @IsFormula = 0;

    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', v.Txt
    FROM (VALUES
        (CASE WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL
              THEN N'DOS from ' + ISNULL(CONVERT(NVARCHAR(10), @DosFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @DosTo, 101), N'(any)') END),
        (CASE WHEN @IsLis = 0 AND (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
              THEN N'FirstBilledDate from ' + ISNULL(CONVERT(NVARCHAR(10), @BilledFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @BilledTo, 101), N'(any)') END),
        (CASE WHEN ISNULL(@YearFrom, 0) <> 0 OR ISNULL(@YearTo, 0) <> 0
              THEN N'Year ' + ISNULL(CAST(NULLIF(@YearFrom, 0) AS NVARCHAR(4)), N'(any)') + N' - ' + ISNULL(CAST(NULLIF(@YearTo, 0) AS NVARCHAR(4)), N'(any)') END),
        (CASE WHEN ISNULL(@MonthFrom, 0) <> 0 OR ISNULL(@MonthTo, 0) <> 0
              THEN N'Month ' + ISNULL(CAST(NULLIF(@MonthFrom, 0) AS NVARCHAR(2)), N'(any)') + N' - ' + ISNULL(CAST(NULLIF(@MonthTo, 0) AS NVARCHAR(2)), N'(any)') END),
        (CASE WHEN NULLIF(LTRIM(RTRIM(@Panels)), N'')    IS NOT NULL THEN N'PanelType IN (' + @Panels + N')' END),
        (CASE WHEN NULLIF(LTRIM(RTRIM(@Clinics)), N'')   IS NOT NULL THEN N'ClinicName IN (' + @Clinics + N')' END),
        (CASE WHEN NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NOT NULL THEN N'ReferringProvider IN (' + @Providers + N')' END),
        (CASE WHEN @IsLis = 0 AND NULLIF(LTRIM(RTRIM(@Reps)), N'') IS NOT NULL THEN N'SalesRepname IN (' + @Reps + N')' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL;

    /* ---- Formula rows: components from the Executive Summary itself ---------- */
    IF @IsFormula = 1
    BEGIN
        DECLARE @Comp TABLE
        (
            Seq INT NOT NULL, Section NVARCHAR(20) NOT NULL, Op NVARCHAR(4) NOT NULL,
            Category VARCHAR(10) NULL, RowCode NVARCHAR(20) NULL, Label NVARCHAR(200) NULL,
            IsMoney BIT NOT NULL, IsTotal BIT NOT NULL
        );
        DECLARE @AriaBase NVARCHAR(20) = IIF(@IsAriaPct = 1, LEFT(@RowCode, LEN(@RowCode) - 2), NULL);

        IF @RowCode = N'I'
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'PMS', N'G', NULL, 0, 0),
                (2, N'Calculation', N'-', 'LIS', N'C', NULL, 0, 0),
                (9, N'Result',      N'=', 'PMS', N'I', NULL, 0, 1);
        ELSE IF @RowCode = N'Z'
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'Cash', N'T',  NULL, 1, 0),
                (2, N'Calculation', N'-', 'Cash', N'X',  NULL, 1, 0),
                (3, N'Calculation', N'-', 'Cash', N'AA', NULL, 1, 0),
                (4, N'Calculation', N'-', 'Cash', N'AB', NULL, 1, 0),
                (5, N'Calculation', N'-', 'Cash', N'Y',  NULL, 1, 0),
                (6, N'Calculation', N'-', 'Cash', N'AC', NULL, 1, 0),
                (9, N'Result',      N'=', 'Cash', N'Z',  NULL, 1, 1);
        ELSE IF @IsAriaPct = 1
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  @Category, @AriaBase + N'A1', NULL, IIF(@Category = 'Cash', 1, 0), 0),
                (2, N'Calculation', N'/', @Category, @AriaBase + N'A2', NULL, IIF(@Category = 'Cash', 1, 0), 0),
                (9, N'Result',      N'=', @Category, @RowCode,          NULL, 0, 1);
        ELSE
        BEGIN
            INSERT INTO @Comp VALUES
                (1, N'Numerator', N'',  'Cash', N'X',  NULL, 1, 0),
                (2, N'Numerator', N'+', 'Cash', N'AA', NULL, 1, 0);
            IF @RowCode <> N'AF'
                INSERT INTO @Comp VALUES (3, N'Numerator', N'+', 'Cash', N'AB', NULL, 1, 0);
            INSERT INTO @Comp VALUES (4, N'Numerator', N'=', NULL, NULL, N'Total Payments ($)', 1, 1);
            IF @RowCode = N'AD'
                INSERT INTO @Comp VALUES (11, N'Denominator', N'', 'PMS', N'G', NULL, 0, 0);
            ELSE IF @RowCode = N'AE'
                INSERT INTO @Comp VALUES
                    (11, N'Denominator', N'',  'PMS', N'M', NULL, 0, 0),
                    (12, N'Denominator', N'+', 'PMS', N'Q', NULL, 0, 0),
                    (13, N'Denominator', N'+', 'PMS', N'R', NULL, 0, 0);
            ELSE
                INSERT INTO @Comp VALUES
                    (11, N'Denominator', N'',  'PMS', N'M',   NULL, 0, 0),
                    (12, N'Denominator', N'+', 'PMS', N'O',   NULL, 0, 0),
                    (13, N'Denominator', N'+', 'PMS', N'S.1', NULL, 0, 0),
                    (14, N'Denominator', N'+', 'PMS', N'S.2', NULL, 0, 0),
                    (15, N'Denominator', N'+', 'PMS', N'Q',   NULL, 0, 0),
                    (16, N'Denominator', N'+', 'PMS', N'P',   NULL, 0, 0),
                    (17, N'Denominator', N'+', 'PMS', N'R',   NULL, 0, 0),
                    (18, N'Denominator', N'+', 'PMS', N'N',   NULL, 0, 0);
            IF @RowCode <> N'AD'
                INSERT INTO @Comp VALUES (19, N'Denominator', N'=', NULL, NULL,
                    IIF(@RowCode = N'AE', N'Paid claims', N'Adjudicated claims'), 0, 1);
            INSERT INTO @Comp VALUES (29, N'Result', N'=', 'Avg', @RowCode, NULL, 1, 1);
        END;

        -- Grid values of the same period: snapshot when unfiltered, else the live build.
        CREATE TABLE #V
        (
            Category VARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
            RowCode NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
            Description NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
            Value DECIMAL(19,6) NOT NULL
        );

        IF ISNULL(@YearFrom, 0) = 0 AND ISNULL(@YearTo, 0) = 0
           AND ISNULL(@MonthFrom, 0) = 0 AND ISNULL(@MonthTo, 0) = 0
           AND @DosFrom IS NULL AND @DosTo IS NULL AND @BilledFrom IS NULL AND @BilledTo IS NULL
           AND NULLIF(LTRIM(RTRIM(@Panels)), N'') IS NULL AND NULLIF(LTRIM(RTRIM(@Clinics)), N'') IS NULL
           AND NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NULL AND NULLIF(LTRIM(RTRIM(@Reps)), N'') IS NULL
        BEGIN
            INSERT INTO #V (Category, RowCode, Description, Value)
            SELECT 'LIS', RoleID, Description, ESMonthClaimCount FROM dbo.NW_ES_LIS
            WHERE ESYear = @Year AND ESMonth = @Month
            UNION ALL
            SELECT 'PMS', RoleID, Description, ESMonthClaimCount FROM dbo.NW_ES_PMS
            WHERE ESYear = @Year AND ESMonth = @Month
            UNION ALL
            SELECT 'Cash', RoleID, Description, ESMonthChargeAmount FROM dbo.NW_ES_Cash
            WHERE ESYear = @Year AND ESMonth = @Month
            UNION ALL
            SELECT 'Avg', RoleID, Description, ESMonthChargeAmount FROM dbo.NW_ES_Avg
            WHERE ESYear = @Year AND ESMonth = @Month;
        END
        ELSE
        BEGIN
            CREATE TABLE #B
            (
                RowCode NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
                Category NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
                Description NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
                BillYear INT NOT NULL, BillMonth INT NOT NULL,
                MetricValue DECIMAL(19,6) NOT NULL, SortOrder INT NOT NULL,
                ClaimCount BIGINT NOT NULL, Amount DECIMAL(19,6) NOT NULL
            );
            INSERT INTO #B
            EXEC dbo.usp_NW_ES_Build
                @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
                @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
                @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;

            INSERT INTO #V (Category, RowCode, Description, Value)
            SELECT Category, RowCode, Description, MetricValue
            FROM #B
            WHERE BillYear = @Year AND BillMonth = @Month;
        END;

        DROP TABLE IF EXISTS #CompV;
        SELECT c.Seq, c.Section, c.Op, c.Category, c.RowCode, c.IsMoney, c.IsTotal,
               COALESCE(c.Label, LTRIM(RTRIM(v.Description))) AS Component,
               v.Value
        INTO #CompV
        FROM @Comp c
        LEFT JOIN #V v ON v.Category = c.Category AND v.RowCode = c.RowCode;

        -- Subtotal lines = sum of their section's components.
        UPDATE t SET Value = s.Total
        FROM #CompV t
        CROSS APPLY (SELECT SUM(ISNULL(x.Value, 0)) AS Total FROM #CompV x
                     WHERE x.Section = t.Section AND x.IsTotal = 0) s
        WHERE t.IsTotal = 1 AND t.RowCode IS NULL;

        UPDATE #CompV SET Value = ISNULL(Value, 0);

        -- Aria %: A1 / A2 (the snapshot keeps the ratio with 2 decimals only).
        IF @IsAriaPct = 1
            UPDATE r SET Value = ISNULL(a1.Value / NULLIF(a2.Value, 0), 0)
            FROM #CompV r
            JOIN #CompV a1 ON a1.Seq = 1
            JOIN #CompV a2 ON a2.Seq = 2
            WHERE r.Section = N'Result';

        DECLARE @Result DECIMAL(19,6) = (SELECT Value FROM #CompV WHERE Section = N'Result');
        DECLARE @Calc NVARCHAR(1000);
        IF @RowCode = N'I'
            SELECT @Calc = FORMAT(MAX(CASE WHEN RowCode = N'G' THEN Value END), 'N0') + N' - '
                         + FORMAT(MAX(CASE WHEN RowCode = N'C' THEN Value END), 'N0') + N' = '
                         + FORMAT(@Result, 'N0')
            FROM #CompV;
        ELSE IF @RowCode = N'Z'
            SELECT @Calc = STRING_AGG(CASE WHEN Op = N'' THEN N'' ELSE Op + N' ' END + N'$' + FORMAT(Value, 'N2'), N' ')
                               WITHIN GROUP (ORDER BY Seq)
                         + N' = $' + FORMAT(@Result, 'N2')
            FROM #CompV
            WHERE Section = N'Calculation';
        ELSE IF @IsAriaPct = 1
            SELECT @Calc = IIF(@Category = 'Cash', N'$' + FORMAT(MAX(CASE WHEN Seq = 1 THEN Value END), 'N2'),
                                                   FORMAT(MAX(CASE WHEN Seq = 1 THEN Value END), 'N0'))
                         + N' / '
                         + IIF(@Category = 'Cash', N'$' + FORMAT(MAX(CASE WHEN Seq = 2 THEN Value END), 'N2'),
                                                   FORMAT(MAX(CASE WHEN Seq = 2 THEN Value END), 'N0'))
                         + N' = ' + FORMAT(@Result, '0.####')
            FROM #CompV;
        ELSE
            SELECT @Calc = N'$' + FORMAT(MAX(CASE WHEN Section = N'Numerator' AND IsTotal = 1 THEN Value END), 'N2') + N' / '
                         + FORMAT(MAX(CASE WHEN Section = N'Denominator' AND (IsTotal = 1 OR @RowCode = N'AD') THEN Value END), 'N0')
                         + N' = $' + FORMAT(@Result, 'N2')
            FROM #CompV;

        INSERT INTO @Rules (RuleGroup, RuleText) VALUES (N'Calculation', @Calc);
        SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

        SELECT CAST(NULL AS NVARCHAR(100)) AS SourceTable, N'Formula' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               0 AS TotalRows, CAST(@Result AS DECIMAL(19,6)) AS TotalAmount, CAST(1 AS BIT) AS IsFormula;

        SELECT Section, Op AS [Operator], Component, Category, RowCode, CAST(Value AS DECIMAL(19,6)) AS Value, IsMoney, IsTotal
        FROM #CompV
        ORDER BY Seq;
        RETURN;
    END;

    /* ---- LIS samples -------------------------------------------------------- */
    IF @IsLis = 1
    BEGIN
        SELECT l.Accession, RequestCollectDate = l.ServiceDate, l.IncorrectDOS, l.BilledTo, l.BillStatus,
               l.FinalStatus, l.Source, l.ChargesNotEnteredStatus, l.PanelType, l.ClinicName, l.ReferringProvider
        INTO #L
        FROM dbo.fn_NW_ES_LisSamples(@YearFrom, @YearTo, @MonthFrom, @MonthTo, @DosFrom, @DosTo,
                                     @Panels, @Clinics, @Providers) l
        WHERE (@Year  = 0 OR l.ESYear  = @Year)
          AND (@Month = 0 OR l.ESMonth = @Month)
          AND EXISTS (SELECT 1
                      FROM dbo.fn_NW_ES_LisRowCodes(l.IncorrectDOS, l.BilledTo, l.BillStatus, l.FinalStatus,
                                                    l.Source, l.ChargesNotEnteredStatus, l.PanelType) r
                      WHERE r.RowCode = @RowCode)
        OPTION (RECOMPILE);

        SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

        SELECT N'dbo.LIMSMaster' AS SourceTable, N'Count of samples' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #L;

        SELECT Accession, RequestCollectDate, IncorrectDOS, BilledTo, BillStatus, FinalStatus, Source,
               ChargesNotEnteredStatus, PanelType, ClinicName, ReferringProvider
        FROM #L
        ORDER BY RequestCollectDate, Accession
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- Claims (PMS / Cash) ------------------------------------------------ */
    DECLARE @Code NVARCHAR(20) = ISNULL(@AriaCohort, @RowCode);
    DECLARE @CodeCategory VARCHAR(10) = IIF(@AriaCohort IS NOT NULL, 'PMS', @Category);

    -- Period claims first, then the row rules (one statement is several times slower).
    SELECT *
    INTO #All
    FROM dbo.fn_NW_ES_Claims(@YearFrom, @YearTo, @MonthFrom, @MonthTo, @DosFrom, @DosTo,
                             @BilledFrom, @BilledTo, @Panels, @Clinics, @Providers, @Reps) c
    WHERE (@Year  = 0 OR c.ESYear  = @Year)
      AND (@Month = 0 OR c.ESMonth = @Month)
    OPTION (RECOMPILE);

    SELECT c.ClaimID, c.AccessionNumber, c.DateofService, c.FirstBilledDate, c.PayerName_Raw, c.PanelType,
           c.ClinicName, c.ReferringProvider, c.SalesRepname, c.BilledUnbilled, c.ClaimType, c.ClaimStatus,
           Amount = CASE WHEN @AriaCohort IS NOT NULL THEN c.InsuranceBalance ELSE r.Value END,
           c.ChargeAmount, c.InsurancePayment, c.ActualPayment, c.DuplicatePayment, c.PatientPayment,
           c.InsuranceBalance, c.PatientBalance
    INTO #C
    FROM #All c
    CROSS APPLY dbo.fn_NW_ES_ClaimRowCodes(c.BilledUnbilled, c.ClaimType, c.ClaimStatus,
                                           c.ChargeAmount, c.InsurancePayment, c.ActualPayment,
                                           c.DuplicatePayment, c.PatientPayment,
                                           c.InsuranceBalance, c.PatientBalance) r
    WHERE r.Category = @CodeCategory
      AND r.RowCode  = @Code;

    IF @AriaPart IS NOT NULL
    BEGIN
        DECLARE @AsOf DATE = (SELECT MAX(FirstBilledDate) FROM #C);
        DELETE FROM #C
        WHERE (@AriaPart = 1 AND NOT (ISNULL(DATEDIFF(DAY, FirstBilledDate, @AsOf), -1) BETWEEN 0 AND 30))
           OR (@AriaPart = 2 AND ISNULL(DATEDIFF(DAY, FirstBilledDate, @AsOf), -1) BETWEEN 0 AND 30);
        INSERT INTO @Rules (RuleGroup, RuleText) VALUES (N'Calculation', N'Latest FirstBilledDate of the cohort: '
            + ISNULL(CONVERT(NVARCHAR(10), @AsOf, 101), N'(none)'));
    END;

    SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

    DECLARE @AmountName NVARCHAR(100) = CASE WHEN @AmountCol IS NULL OR @Category = 'PMS' THEN NULL
                                             WHEN @RowCode = N'AA.1' THEN N'ActualPayment'
                                             ELSE @AmountCol END;

    SELECT N'dbo.ClaimLevelData' AS SourceTable,
           CASE WHEN @AmountName IS NULL THEN N'Count of claims' ELSE N'Sum of ' + @AmountCol END AS Measure,
           @AmountName AS AmountColumn,
           COUNT(*) AS TotalRows,
           CAST(ISNULL(SUM(CASE WHEN @AmountName IS NULL THEN 0 ELSE Amount END), 0) AS DECIMAL(18,2)) AS TotalAmount,
           CAST(0 AS BIT) AS IsFormula
    FROM #C;

    IF @AmountName IS NULL
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, PanelType, ClinicName,
               ReferringProvider, SalesRepname, BilledUnbilled, ClaimType, ClaimStatus,
               ChargeAmount, InsurancePayment, ActualPayment, DuplicatePayment, PatientPayment,
               InsuranceBalance, PatientBalance
        FROM #C
        ORDER BY DateofService, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
    ELSE
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, PanelType, ClinicName,
               ReferringProvider, SalesRepname, BilledUnbilled, ClaimType, ClaimStatus, Amount,
               ChargeAmount, InsurancePayment, ActualPayment, DuplicatePayment, PatientPayment,
               InsuranceBalance, PatientBalance
        FROM #C
        ORDER BY DateofService, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
END;
GO

SET NOEXEC OFF;
GO

PRINT '50_NW_ExecutiveSummary_CellRows.sql completed.';
GO
