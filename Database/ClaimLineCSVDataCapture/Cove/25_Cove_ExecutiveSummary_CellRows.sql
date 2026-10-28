/* =============================================================================
   Cove - Executive Summary cell rows (value click -> popup grid)
   File     : 25_Cove_ExecutiveSummary_CellRows.sql
   Database : CoveLRN
   Object   : dbo.usp_GetCove_ExecutiveSummaryCellRows

   Returns the source rows behind one Executive Summary cell. usp_GetCove_ExecutiveSummary
   has two rule sets, so the popup follows the one that produced the clicked value:
     No page filter        -> the snapshot rules of usp_RefreshCove_ExecutiveSummary_AvgYearTotals_Core
                              (PMS / Cash / Avg), usp_RefreshCove_ExecutiveSummary (Avg year rows),
                              usp_RefreshCove_ExecutiveSummary_LIS_Alt (LIS) and
                              usp_Cove_ES_UpdatePmsBilledMismatch (PMS G).
                              LIS D.n / D.n.m / E.n codes are numbered from the data; their
                              SubStatus / PanelType / NewStatus is read from Cove_ES_LIS.Description.
     DOS filter only       -> PMS / Cash / Avg: the live rules below; LIS: the snapshot rules for
                              the months inside the DOS range (as the read SP).
     Any other filter      -> the live rules of usp_GetCove_ExecutiveSummary (distinct accession
                              counts, fixed D.1-D.20 / E.1-E.7 lists, D.5.{Panel} / D.6.{Panel}).

   Parameters
     @Category / @RowCode   the clicked row
     @Year / @Month         (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @DosFrom .. @Reps      the page filters (@YearFrom .. @MonthTo are ignored, as in the read SP)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows (Amount = the row's measured value for $ rows)
   Distinct counts list one row per counted ClaimID / Accession. Formula rows (PMS G,
   Averages V / W / X) return their components (Section, Operator, Component, Category,
   RowCode, Value, IsMoney, IsTotal).
   ============================================================================= */

IF DB_NAME() <> N'CoveLRN'
BEGIN
    RAISERROR(N'25_Cove_ExecutiveSummary_CellRows.sql must run on CoveLRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_ExecutiveSummaryCellRows
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
    SET ANSI_WARNINGS OFF;

    SET @Category = LTRIM(RTRIM(ISNULL(@Category, '')));
    SET @RowCode  = LTRIM(RTRIM(ISNULL(@RowCode, N'')));
    SET @Year     = ISNULL(@Year, 0);
    SET @Month    = ISNULL(@Month, 0);
    IF ISNULL(@Page, 0) < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 0 SET @PageSize = 100;

    /* ---- Mode (as usp_GetCove_ExecutiveSummary) ----------------------------- */
    DECLARE @HasPanel    BIT = IIF(NULLIF(LTRIM(RTRIM(@Panels)),    N'') IS NULL, 0, 1);
    DECLARE @HasClinic   BIT = IIF(NULLIF(LTRIM(RTRIM(@Clinics)),   N'') IS NULL, 0, 1);
    DECLARE @HasProvider BIT = IIF(NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NULL, 0, 1);
    DECLARE @HasRep      BIT = IIF(NULLIF(LTRIM(RTRIM(@Reps)),      N'') IS NULL, 0, 1);
    DECLARE @HasFilter   BIT = IIF(@DosFrom IS NOT NULL OR @DosTo IS NOT NULL OR @BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL
                                   OR @HasPanel = 1 OR @HasClinic = 1 OR @HasProvider = 1 OR @HasRep = 1, 1, 0);
    DECLARE @UseBilledDate BIT = IIF((@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL) AND @DosFrom IS NULL AND @DosTo IS NULL, 1, 0);
    DECLARE @HasLisFilter BIT = IIF(@HasPanel = 1 OR @HasClinic = 1 OR @HasProvider = 1 OR @HasRep = 1 OR @UseBilledDate = 1, 1, 0);
    -- Claims: S = snapshot rules, F = live rules. LIS: S = snapshot, M = snapshot months in the DOS range, F = live.
    DECLARE @Mode    CHAR(1) = IIF(@HasFilter = 1, 'F', 'S');
    DECLARE @LisMode CHAR(1) = CASE WHEN @HasFilter = 0 THEN 'S' WHEN @HasLisFilter = 0 THEN 'M' ELSE 'F' END;
    DECLARE @FromYM INT = ISNULL(YEAR(@DosFrom) * 100 + MONTH(@DosFrom), 0);
    DECLARE @ToYM   INT = ISNULL(YEAR(@DosTo)   * 100 + MONTH(@DosTo),   999999);

    DECLARE @IsLis BIT = IIF(@Category = 'LIS', 1, 0);
    DECLARE @IsFormula BIT = IIF((@Category = 'PMS' AND @RowCode = N'G') OR @Category = 'Avg', 1, 0);

    IF @Category = 'PMS' AND @RowCode = N'G' AND @Mode = 'F' AND @HasLisFilter = 0
    BEGIN
        RAISERROR(N'usp_GetCove_ExecutiveSummaryCellRows: PMS G is not computed for a DOS-only filter.', 16, 1);
        RETURN;
    END;

    /* ---- LIS row resolution ------------------------------------------------- */
    -- Kind: A, B, BP (B.{Panel}), C, D, DS (SubStatus), DSP (SubStatus + Panel), E, ES (NewStatus)
    DECLARE @LisKind VARCHAR(4), @LisSub NVARCHAR(200), @LisPanel NVARCHAR(200), @LisNew NVARCHAR(200);
    IF @IsLis = 1
    BEGIN
        IF @RowCode IN (N'A', N'B', N'C', N'D', N'E')
            SET @LisKind = @RowCode;
        ELSE IF @RowCode LIKE N'B.%'
            SELECT @LisKind = 'BP', @LisPanel = SUBSTRING(@RowCode, 3, 400);
        ELSE IF @LisMode IN ('S', 'M')
        BEGIN
            IF @RowCode LIKE N'D.[0-9]%.[0-9]%'
                SELECT @LisKind = 'DSP',
                       @LisSub   = (SELECT TOP 1 LTRIM(Description) FROM dbo.Cove_ES_LIS
                                    WHERE RoleID = LEFT(@RowCode, CHARINDEX(N'.', @RowCode, 3) - 1)),
                       @LisPanel = (SELECT TOP 1 LTRIM(Description) FROM dbo.Cove_ES_LIS WHERE RoleID = @RowCode);
            ELSE IF @RowCode LIKE N'D.[0-9]%'
                SELECT @LisKind = 'DS',
                       @LisSub = (SELECT TOP 1 LTRIM(Description) FROM dbo.Cove_ES_LIS WHERE RoleID = @RowCode);
            ELSE IF @RowCode LIKE N'E.[0-9]%'
                SELECT @LisKind = 'ES',
                       @LisNew = (SELECT TOP 1 LTRIM(Description) FROM dbo.Cove_ES_LIS WHERE RoleID = @RowCode);
        END
        ELSE
        BEGIN
            IF @RowCode LIKE N'D.5.%' AND @RowCode NOT LIKE N'D.5.[0-9]%'
                SELECT @LisKind = 'DSP', @LisSub = N'Coding exception', @LisPanel = SUBSTRING(@RowCode, 5, 400);
            ELSE IF @RowCode LIKE N'D.6.%'
                SELECT @LisKind = 'DSP', @LisSub = N'CP Exception', @LisPanel = SUBSTRING(@RowCode, 5, 400);
            ELSE IF @RowCode LIKE N'D.[0-9]%'
                SELECT @LisKind = 'DS', @LisSub = v.Sub
                FROM (VALUES
                    (N'D.1',  N'Billed Insurance In Covedx'),            (N'D.2',  N'Billed In Variantx Lab'),
                    (N'D.3',  N'Billed In Elixir Dx'),                   (N'D.4',  N'Ignored - Duplicate Accession'),
                    (N'D.5',  N'Coding exception'),                      (N'D.6',  N'CP Exception'),
                    (N'D.7',  N'In process'),                            (N'D.8',  N'Ignored - Client Response Non Billiable'),
                    (N'D.9',  N'Ready To Bill'),                         (N'D.10', N'Ignored - NGS & PGX in Cove'),
                    (N'D.11', N'CP Exception -In Review'),               (N'D.12', N'Medicaid Credentialling In Process'),
                    (N'D.13', N'Ignored - Reported in Elixir Truemed'),  (N'D.14', N'Ignored - CP Exception'),
                    (N'D.15', N'Client Bill Cases'),                     (N'D.16', N'Ignored - Client Response Pure Selfpay'),
                    (N'D.17', N'Selfpay'),                               (N'D.18', N'Ignored - Rejected Accession'),
                    (N'D.19', N'Hold-Amerihealth Lousiana'),             (N'D.20', N'Ignored - Test Cases')
                ) v(Code, Sub)
                WHERE v.Code = @RowCode;
            ELSE IF @RowCode LIKE N'E.[0-9]%'
                SELECT @LisKind = 'ES', @LisNew = v.NS
                FROM (VALUES
                    (N'E.1', N'Self Pay'), (N'E.2', N'Client Bill'), (N'E.3', N'Deleted / Rejected'), (N'E.4', N'System Test'),
                    (N'E.5', N'Ref Lab - Bill Patient'), (N'E.6', N'Missing Accession'), (N'E.7', N'Yet To Be Validated')
                ) v(Code, NS)
                WHERE v.Code = @RowCode;
        END;

        IF @LisKind IS NULL OR (@LisKind IN ('DS', 'DSP') AND @LisSub IS NULL) OR (@LisKind IN ('BP', 'DSP') AND @LisPanel IS NULL)
           OR (@LisKind = 'ES' AND @LisNew IS NULL)
        BEGIN
            RAISERROR(N'usp_GetCove_ExecutiveSummaryCellRows: unknown LIS row %s.', 16, 1, @RowCode);
            RETURN;
        END;
    END;

    /* ---- Row rules ---------------------------------------------------------- */
    DECLARE @B3 NVARCHAR(100) = N'Bill Status IN (Billed, Billed-Client, Billed - Client)';
    DECLARE @NotUnb NVARCHAR(100) = N'Claim Status NOT IN (Unbilled, Unbilled - PB)';
    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(200), @Distinct NVARCHAR(20);

    IF @IsLis = 1
    BEGIN
        DECLARE @Ins NVARCHAR(100) = N'NewStatus = Billable';
        DECLARE @Unb NVARCHAR(200) = @Ins + IIF(@LisMode = 'F', N' AND BillCategory = Not Billed', N' AND BillCategory IN (Not Billed, Unbilled)');
        SET @RuleText = CASE @LisKind
            WHEN 'A'   THEN N'Every sample'
            WHEN 'B'   THEN @Ins
            WHEN 'BP'  THEN @Ins + N' AND PanelType = ' + @LisPanel
            WHEN 'C'   THEN @Ins + N' AND BillCategory = Billed'
            WHEN 'D'   THEN @Unb
            WHEN 'DS'  THEN @Unb + N' AND SubStatus = ' + @LisSub
            WHEN 'DSP' THEN @Ins + N' AND BillCategory IN (Not Billed, Unbilled) AND SubStatus = ' + @LisSub + N' AND PanelType = ' + @LisPanel
            WHEN 'E'   THEN N'NewStatus <> Billable (blank included)'
            WHEN 'ES'  THEN N'NewStatus = ' + @LisNew END;
        SET @Distinct = IIF(@LisMode = 'F', N'Accession', NULL);
    END
    ELSE IF @Mode = 'S'
    BEGIN
        SELECT @RuleText = v.RuleText, @AmountCol = v.AmountCol, @Distinct = v.Dist
        FROM (VALUES
            ('PMS',  N'F',   @B3 + N' (blank ClaimID not counted)', NULL, NULL),
            ('PMS',  N'G',   N'Formula: No. of Billed Claims (PMS F) - LIS Billed (LIS C), 0 when negative', NULL, NULL),
            ('PMS',  N'H',   @B3 + N' AND Claim Status = Fully Paid', NULL, N'ClaimID'),
            ('PMS',  N'I',   N'Bill Status = Billed AND Claim Status = Patient Responsibility', NULL, NULL),
            ('PMS',  N'J',   N'Bill Status = Billed AND Claim Status = Fully Adjusted', NULL, NULL),
            ('PMS',  N'K',   N'Bill Status = Billed AND Claim Status = Partially Adjusted', NULL, NULL),
            ('PMS',  N'L',   N'Bill Status = Billed AND Claim Status = Partially Paid', NULL, NULL),
            ('PMS',  N'M',   @B3 + N' AND Claim Status = Patient Payment', NULL, N'ClaimID'),
            ('PMS',  N'N',   N'Bill Status = Billed AND Claim Status IN (Fully Denied, Partially Denied, No Response)', NULL, NULL),
            ('PMS',  N'N.1', N'Claim Status = Fully Denied (any Bill Status)', NULL, NULL),
            ('PMS',  N'N.2', N'Bill Status = Billed AND Claim Status = Partially Denied', NULL, NULL),
            ('PMS',  N'N.3', N'Claim Status IN (No Response, No Response-Client) (any Bill Status)', NULL, NULL),
            ('Cash', N'O',   @B3, N'ChargeAmount', NULL),
            ('Cash', N'P',   N'Claim Status IN (Fully Paid, Paid-Client) (any Bill Status)', N'InsurancePayment', NULL),
            ('Cash', N'Q',   N'Bill Status = Billed', N'PatientBalance', NULL),
            ('Cash', N'R',   @B3, N'PatientPayment', NULL),
            ('Cash', N'S',   @B3, N'InsuranceAdjustments', NULL),
            ('Cash', N'S1',  @B3, N'PatientAdjustments', NULL),
            ('Cash', N'T',   N'Claim Status = Partially Paid (any Bill Status)', N'InsurancePayment', NULL),
            ('Cash', N'U',   N'Bill Status IN (Billed, Billed - Client)', N'InsuranceBalance', NULL),
            ('Cash', N'U.1', N'Claim Status = Fully Denied (any Bill Status)', N'InsuranceBalance', NULL),
            ('Cash', N'U.2', N'Bill Status IN (Billed, Billed - Client) AND Claim Status NOT IN (Fully Denied, No Response)', N'InsuranceBalance', NULL),
            ('Cash', N'U.3', N'Claim Status IN (No Response, No Response-Client) (any Bill Status)', N'InsuranceBalance', NULL),
            ('Avg',  N'V',   N'Formula: (Insurance Payment $ + Partially Paid $) / No. of Billed Claims (PMS F)', NULL, NULL),
            ('Avg',  N'W',   N'Formula: Insurance Payment $ / No. of Fully Paid Claims (PMS H)', NULL, NULL),
            ('Avg',  N'X',   N'Formula: (Insurance Payment $ + Partially Paid $) / (Fully Paid + Adjusted + Partially Paid + Fully Denied + Partially Denied claims)', NULL, NULL)
        ) v(Category, RowCode, RuleText, AmountCol, Dist)
        WHERE v.Category = @Category AND v.RowCode = @RowCode;
    END
    ELSE
    BEGIN
        SELECT @RuleText = v.RuleText, @AmountCol = v.AmountCol, @Distinct = v.Dist
        FROM (VALUES
            ('PMS',  N'F',   @B3, NULL, N'AccessionNumber'),
            ('PMS',  N'G',   N'Formula: distinct billed accessions (PMS F) - distinct LIS Billable + Billed accessions (LIS C), 0 when negative', NULL, NULL),
            ('PMS',  N'H',   N'Claim Status IN (Fully Paid, Paid-Client)', NULL, N'AccessionNumber'),
            ('PMS',  N'I',   N'Claim Status = Patient Responsibility', NULL, N'AccessionNumber'),
            ('PMS',  N'J',   N'Claim Status = Fully Adjusted', NULL, N'AccessionNumber'),
            ('PMS',  N'K',   N'Claim Status = Partially Adjusted', NULL, N'AccessionNumber'),
            ('PMS',  N'L',   N'Claim Status = Partially Paid', NULL, N'AccessionNumber'),
            ('PMS',  N'M',   N'Claim Status = Patient Payment', NULL, N'AccessionNumber'),
            ('PMS',  N'N',   N'Claim Status IN (Fully Denied, Partially Denied, No Response, No Response-Client)', NULL, N'AccessionNumber'),
            ('PMS',  N'N.1', N'Claim Status = Fully Denied', NULL, N'AccessionNumber'),
            ('PMS',  N'N.2', N'Claim Status = Partially Denied', NULL, N'AccessionNumber'),
            ('PMS',  N'N.3', N'Claim Status IN (No Response, No Response-Client)', NULL, N'AccessionNumber'),
            ('Cash', N'O',   @B3, N'ChargeAmount', NULL),
            ('Cash', N'P',   N'Claim Status IN (Fully Paid, Paid-Client)', N'InsurancePayment', NULL),
            ('Cash', N'Q',   N'Claim Status NOT IN (Unbilled, Unbilled - PB, No Response, No Response-Client)', N'PatientBalance', NULL),
            ('Cash', N'R',   N'PatientPayment > 0', N'PatientPayment', NULL),
            ('Cash', N'S',   @NotUnb, N'InsuranceAdjustments + PatientAdjustments', NULL),
            ('Cash', N'T',   N'Claim Status = Partially Paid', N'InsurancePayment', NULL),
            ('Cash', N'U',   @NotUnb, N'InsuranceBalance', NULL),
            ('Cash', N'U.1', N'Claim Status = Fully Denied', N'InsuranceBalance', NULL),
            ('Cash', N'U.2', N'Claim Status IN (Partially Denied, Partially Adjusted, Partially Paid, Patient Payment, Patient Responsibility)', N'InsuranceBalance', NULL),
            ('Cash', N'U.3', N'Claim Status IN (No Response, No Response-Client)', N'InsuranceBalance', NULL),
            ('Avg',  N'V',   N'Formula: Sum(InsurancePayment + PatientPayment) / distinct accessions, ' + @B3, NULL, NULL),
            ('Avg',  N'W',   N'Formula: Sum(InsurancePayment + PatientPayment) / distinct accessions, Claim Status IN (Fully Paid, Paid-Client)', NULL, NULL),
            ('Avg',  N'X',   N'Formula: Sum(InsurancePayment + PatientPayment) / distinct accessions, ' + @NotUnb, NULL, NULL)
        ) v(Category, RowCode, RuleText, AmountCol, Dist)
        WHERE v.Category = @Category AND v.RowCode = @RowCode;
    END;

    IF @RuleText IS NULL
    BEGIN
        RAISERROR(N'usp_GetCove_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCode);
        RETURN;
    END;

    DECLARE @ClaimPeriodCol NVARCHAR(40) = IIF(@Mode = 'F' AND @UseBilledDate = 1, N'FirstBilledDate', N'DateofService');
    DECLARE @LisPeriodCol   NVARCHAR(40) = IIF(@LisMode = 'F' AND @UseBilledDate = 1, N'BilledDate', N'DateOfCollection');
    DECLARE @PeriodText NVARCHAR(200) =
        CASE WHEN @Year = 0 THEN N'all periods (Grand Total)'
             WHEN @Month = 0 THEN N'year ' + CAST(@Year AS NVARCHAR(4)) + N' (Year Total)'
             ELSE DATENAME(MONTH, DATEFROMPARTS(@Year, @Month, 1)) + N' ' + CAST(@Year AS NVARCHAR(4)) END;

    /* ---- 1. Rules ----------------------------------------------------------- */
    DECLARE @Rules TABLE (RuleOrder INT IDENTITY(1,1), RuleGroup NVARCHAR(40), RuleText NVARCHAR(2000));
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Source', IIF(@IsLis = 1, N'dbo.LIMSMaster - one row per sample', N'dbo.ClaimLevelData - one row per claim')
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Base filter',
           CASE WHEN @IsLis = 1 AND @LisMode = 'F' THEN N'Accession not blank'
                WHEN @IsLis = 1 THEN N'Accession not blank AND DateOfCollection is a date'
                ELSE N'AccessionNumber not blank AND ' + @ClaimPeriodCol + N' is a date' END
         + N' (' + CASE WHEN @HasFilter = 0 THEN N'no page filter - snapshot rules'
                                 WHEN @IsLis = 1 AND @LisMode = 'M' THEN N'DOS filter only - snapshot LIS rows of the months in range'
                                 ELSE N'page filter - live rules' END + N')'
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    VALUES (N'Period', IIF(@IsLis = 1, @LisPeriodCol, @ClaimPeriodCol) + N' in ' + @PeriodText);
    INSERT INTO @Rules (RuleGroup, RuleText) VALUES (IIF(@IsFormula = 1, N'Formula', N'Row rule'), @RuleText);
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Measure', CASE WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol
                            WHEN @Distinct IS NOT NULL THEN N'Count of distinct ' + @Distinct + N' (one row listed per value)'
                            WHEN @IsLis = 1 THEN N'Count of samples (rows)'
                            ELSE N'Count of claims (rows)' END
    WHERE @IsFormula = 0;
    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', v.Txt
    FROM (VALUES
        (CASE WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL
              THEN N'DOS from ' + ISNULL(CONVERT(NVARCHAR(10), @DosFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @DosTo, 101), N'(any)')
                   + IIF(@IsLis = 1 AND @LisMode = 'M', N' (whole months)', N'') END),
        (CASE WHEN @BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL
              THEN N'Billed Date from ' + ISNULL(CONVERT(NVARCHAR(10), @BilledFrom, 101), N'(any)') + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @BilledTo, 101), N'(any)') END),
        (CASE WHEN @HasPanel = 1    THEN IIF(@IsLis = 1, N'PanelType', N'PanelName') + N' IN (' + @Panels + N')' END),
        (CASE WHEN @HasClinic = 1   THEN IIF(@IsLis = 1, N'FacilityName', N'ClinicName') + N' IN (' + @Clinics + N')' END),
        (CASE WHEN @HasProvider = 1 THEN IIF(@IsLis = 1, N'PhysicianName', N'ReferringProvider') + N' IN (' + @Providers + N')' END),
        (CASE WHEN @HasRep = 1      THEN IIF(@IsLis = 1, N'SaleRepName', N'SalesRepname') + N' IN (' + @Reps + N')' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL;

    /* ---- Source rows -------------------------------------------------------- */
    DECLARE @NeedLis    BIT = IIF(@IsLis = 1 OR (@Mode = 'F' AND @Category = 'PMS' AND @RowCode = N'G'), 1, 0);
    DECLARE @NeedClaims BIT = IIF(@IsLis = 0 AND (@IsFormula = 0 OR @Mode = 'F'), 1, 0);

    CREATE TABLE #L
    (
        Accession NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        DateOfCollection DATE NULL, BilledDate DATE NULL,
        NewStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        BillCategory NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        SubStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PanelType NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        FacilityName NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        PhysicianName NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        SaleRepName NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        Y INT NOT NULL, M INT NOT NULL
    );

    IF @NeedLis = 1
        INSERT INTO #L
        SELECT n.Acc, l.DateOfCollection, l.BilledDate, n.NS, n.BC, n.SS, n.PT,
               l.FacilityName, l.PhysicianName, l.SaleRepName,
               ISNULL(YEAR(p.PeriodDate), 0), ISNULL(MONTH(p.PeriodDate), 0)
        FROM dbo.LIMSMaster l WITH (NOLOCK)
        CROSS APPLY (SELECT
            Acc = LTRIM(RTRIM(CONVERT(NVARCHAR(100), l.Accession))),
            NS  = LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.NewStatus),    N''))),
            PT  = LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.PanelType),    N''))),
            BC  = LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.BillCategory), N''))),
            SS  = LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.SubStatus),    N'')))) n
        CROSS APPLY (SELECT PeriodDate = IIF(@LisMode = 'F' AND @UseBilledDate = 1, l.BilledDate, TRY_CAST(l.DateOfCollection AS DATE))) p
        WHERE NULLIF(n.Acc, N'') IS NOT NULL
          AND (@LisMode = 'F' OR TRY_CAST(l.DateOfCollection AS DATE) IS NOT NULL)
          AND (@LisMode <> 'M' OR YEAR(p.PeriodDate) * 100 + MONTH(p.PeriodDate) BETWEEN @FromYM AND @ToYM)
          AND (@LisMode <> 'F' OR (
                  (@HasPanel    = 0 OR CHARINDEX(N',' + n.PT + N',', N',' + @Panels + N',') > 0)
              AND (@HasClinic   = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.FacilityName),  N''))) + N',', N',' + @Clinics   + N',') > 0)
              AND (@HasProvider = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.PhysicianName), N''))) + N',', N',' + @Providers + N',') > 0)
              AND (@HasRep      = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), l.SaleRepName),   N''))) + N',', N',' + @Reps      + N',') > 0)
              AND (@DosFrom    IS NULL OR TRY_CAST(l.DateOfCollection AS DATE) >= @DosFrom)
              AND (@DosTo      IS NULL OR TRY_CAST(l.DateOfCollection AS DATE) <= @DosTo)
              AND (@BilledFrom IS NULL OR l.BilledDate >= @BilledFrom)
              AND (@BilledTo   IS NULL OR l.BilledDate <= @BilledTo)))
        OPTION (RECOMPILE);

    CREATE TABLE #C
    (
        ClaimID NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
        AccessionNumber NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        DateofService DATE NULL, FirstBilledDate DATE NULL,
        PayerName_Raw NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        PanelName NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        ClinicName NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        ReferringProvider NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        SalesRepname NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        BillStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ChargeAmount DECIMAL(18,2) NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL,
        PatientPayment DECIMAL(18,2) NOT NULL, InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments DECIMAL(18,2) NOT NULL, InsuranceBalance DECIMAL(18,2) NOT NULL,
        PatientBalance DECIMAL(18,2) NOT NULL,
        Y INT NOT NULL, M INT NOT NULL
    );

    IF @NeedClaims = 1
        INSERT INTO #C
        SELECT c.ClaimID, c.AccessionNumber, d.Dos, d.FirstBill, c.PayerName_Raw, c.Panelname, c.ClinicName,
               c.ReferringProvider, c.SalesRepname, n.BS, n.CS,
               ISNULL(TRY_CAST(c.ChargeAmount         AS DECIMAL(18,2)), 0),
               ISNULL(TRY_CAST(c.InsurancePayment     AS DECIMAL(18,2)), 0),
               ISNULL(TRY_CAST(c.PatientPayment       AS DECIMAL(18,2)), 0),
               ISNULL(TRY_CAST(c.InsuranceAdjustments AS DECIMAL(18,2)), 0),
               ISNULL(TRY_CAST(c.PatientAdjustments   AS DECIMAL(18,2)), 0),
               ISNULL(TRY_CAST(c.InsuranceBalance     AS DECIMAL(18,2)), 0),
               ISNULL(TRY_CAST(c.PatientBalance       AS DECIMAL(18,2)), 0),
               YEAR(d.PeriodDate), MONTH(d.PeriodDate)
        FROM dbo.ClaimLevelData c WITH (NOLOCK)
        CROSS APPLY (SELECT Dos = TRY_CAST(c.DateofService AS DATE), FirstBill = TRY_CAST(c.FirstBilledDate AS DATE)) d0
        CROSS APPLY (SELECT d0.Dos, d0.FirstBill, PeriodDate = IIF(@Mode = 'F' AND @UseBilledDate = 1, d0.FirstBill, d0.Dos)) d
        CROSS APPLY (SELECT BS = ISNULL(LTRIM(RTRIM(c.BillStatus)), N''), CS = ISNULL(LTRIM(RTRIM(c.ClaimStatus)), N'')) n
        WHERE NULLIF(LTRIM(RTRIM(c.AccessionNumber)), N'') IS NOT NULL
          AND d.PeriodDate IS NOT NULL
          AND (@Mode = 'S' OR (
                  (@UseBilledDate = 1 OR ((@DosFrom IS NULL OR d.Dos >= @DosFrom) AND (@DosTo IS NULL OR d.Dos <= @DosTo)))
              AND (@UseBilledDate = 0 OR ((@BilledFrom IS NULL OR d.FirstBill >= @BilledFrom) AND (@BilledTo IS NULL OR d.FirstBill <= @BilledTo)))
              AND (@HasPanel    = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(c.Panelname,         N''))) + N',', N',' + @Panels    + N',') > 0)
              AND (@HasClinic   = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(c.ClinicName,        N''))) + N',', N',' + @Clinics   + N',') > 0)
              AND (@HasProvider = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(c.ReferringProvider, N''))) + N',', N',' + @Providers + N',') > 0)
              AND (@HasRep      = 0 OR CHARINDEX(N',' + LTRIM(RTRIM(ISNULL(c.SalesRepname,      N''))) + N',', N',' + @Reps      + N',') > 0)))
          AND (@Year  = 0 OR YEAR(d.PeriodDate)  = @Year)
          AND (@Month = 0 OR MONTH(d.PeriodDate) = @Month)
        OPTION (RECOMPILE);

    /* ---- Formula rows ------------------------------------------------------- */
    IF @IsFormula = 1
    BEGIN
        DECLARE @Comp TABLE
        (
            Seq INT NOT NULL, Section NVARCHAR(20) NOT NULL, Op NVARCHAR(4) NOT NULL,
            Category VARCHAR(10) NULL, RowCode NVARCHAR(20) NULL, Component NVARCHAR(300) NOT NULL,
            Value DECIMAL(19,4) NULL, IsMoney BIT NOT NULL, IsTotal BIT NOT NULL
        );
        DECLARE @Result DECIMAL(19,4), @Calc NVARCHAR(1000);

        IF @Mode = 'S'
        BEGIN
            -- Snapshot values of the period: the month, the year (sum of its months), or the grand total.
            CREATE TABLE #S (Category VARCHAR(10) NOT NULL, RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, Value DECIMAL(19,4) NOT NULL);
            INSERT INTO #S (Category, RowCode, Value)
            SELECT t.Category, t.RoleID, SUM(t.V)
            FROM (SELECT 'LIS' AS Category, RoleID, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(19,4)) AS V FROM dbo.Cove_ES_LIS WHERE RoleID = N'C'
                  UNION ALL SELECT 'PMS', RoleID, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(19,4)) FROM dbo.Cove_ES_PMS
                  UNION ALL SELECT 'Cash', RoleID, ESYear, ESMonth, CAST(ESMonthChargeAmount AS DECIMAL(19,4)) FROM dbo.Cove_ES_Cash) t
            WHERE (@Year = 0 AND t.ESYear = 0 AND t.ESMonth = 0)
               OR (@Year <> 0 AND @Month <> 0 AND t.ESYear = @Year AND t.ESMonth = @Month)
               OR (@Year <> 0 AND @Month = 0 AND t.ESYear = @Year AND t.ESMonth BETWEEN 1 AND 12)
            GROUP BY t.Category, t.RoleID;

            IF @RowCode = N'G'
            BEGIN
                INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, IsMoney, IsTotal) VALUES
                    (1, N'Calculation', N'',  'PMS', N'F', N'No. of Billed Claims', 0, 0),
                    (2, N'Calculation', N'-', 'LIS', N'C', N'LIS Billed', 0, 0),
                    (9, N'Result',      N'=', 'PMS', N'G', N'Billed Mismatches', 0, 1);
                UPDATE c SET Value = s.Value FROM @Comp c JOIN #S s ON s.Category = c.Category AND s.RowCode = c.RowCode WHERE c.Seq < 9;
                SET @Result = ISNULL((SELECT Value FROM #S WHERE Category = 'PMS' AND RowCode = N'G'), 0);
            END
            ELSE
            BEGIN
                INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, IsMoney, IsTotal) VALUES
                    (1, N'Numerator', N'', 'Cash', N'P', N'Insurance Payment ($)', 1, 0);
                IF @RowCode <> N'W'
                    INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, IsMoney, IsTotal) VALUES
                        (2, N'Numerator', N'+', 'Cash', N'T', N'Partially Paid ($)', 1, 0);
                INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, IsMoney, IsTotal) VALUES
                    (4, N'Numerator', N'=', NULL, NULL, N'Total Payments ($)', 1, 1);
                IF @RowCode = N'V'
                    INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, IsMoney, IsTotal) VALUES
                        (11, N'Denominator', N'', 'PMS', N'F', N'No. of Billed Claims', 0, 0);
                ELSE IF @RowCode = N'W'
                    INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, IsMoney, IsTotal) VALUES
                        (11, N'Denominator', N'', 'PMS', N'H', N'No. of Fully Paid Claims', 0, 0);
                ELSE
                    INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, IsMoney, IsTotal) VALUES
                        (11, N'Denominator', N'',  'PMS', N'H',   N'No. of Fully Paid Claims', 0, 0),
                        (12, N'Denominator', N'+', 'PMS', N'J',   N'No. of Adjusted/Written Off Claims', 0, 0),
                        (13, N'Denominator', N'+', 'PMS', N'L',   N'No. of Partially Paid Claims', 0, 0),
                        (14, N'Denominator', N'+', 'PMS', N'N.1', N'No. of Fully Denied Claims', 0, 0),
                        (15, N'Denominator', N'+', 'PMS', N'N.2', N'No. of Partially Denied Claims', 0, 0),
                        (19, N'Denominator', N'=', NULL, NULL, N'Adjudicated claims', 0, 1);
                INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, IsMoney, IsTotal) VALUES
                    (29, N'Result', N'=', 'Avg', @RowCode, N'Average Payment ($)', 1, 1);
                UPDATE c SET Value = s.Value FROM @Comp c JOIN #S s ON s.Category = c.Category AND s.RowCode = c.RowCode WHERE c.Seq < 29;
                SET @Result = ISNULL((SELECT TOP 1 CAST(ESMonthChargeAmount AS DECIMAL(19,4)) FROM dbo.Cove_ES_Avg
                                      WHERE RoleID = @RowCode AND ESYear = @Year AND ESMonth = @Month), 0);
            END;
        END
        ELSE
        BEGIN
            IF @RowCode = N'G'
            BEGIN
                -- Per month: max(distinct billed accessions - distinct LIS billed accessions, 0); the year
                -- total is the sum of its months (as the grid adds the month columns).
                ;WITH b AS (SELECT Y, M, Cnt = COUNT(DISTINCT CASE WHEN BillStatus IN (N'Billed', N'Billed-Client', N'Billed - Client') THEN AccessionNumber END)
                            FROM #C GROUP BY Y, M),
                      l AS (SELECT Y, M, Cnt = COUNT(DISTINCT CASE WHEN NewStatus = N'Billable' AND BillCategory = N'Billed' THEN Accession END)
                            FROM #L WHERE (@Year = 0 OR Y = @Year) AND (@Month = 0 OR M = @Month) GROUP BY Y, M)
                SELECT @Result = SUM(IIF(ISNULL(b.Cnt, 0) - ISNULL(l.Cnt, 0) > 0, ISNULL(b.Cnt, 0) - ISNULL(l.Cnt, 0), 0))
                FROM b LEFT JOIN l ON l.Y = b.Y AND l.M = b.M;

                INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
                SELECT 1, N'Calculation', N'', 'PMS', N'F', N'Distinct billed accessions',
                       COUNT(DISTINCT CASE WHEN BillStatus IN (N'Billed', N'Billed-Client', N'Billed - Client') THEN AccessionNumber END), 0, 0
                FROM #C;
                INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
                SELECT 2, N'Calculation', N'-', 'LIS', N'C', N'Distinct LIS Billable + Billed accessions',
                       COUNT(DISTINCT CASE WHEN NewStatus = N'Billable' AND BillCategory = N'Billed' THEN Accession END), 0, 0
                FROM #L WHERE (@Year = 0 OR Y = @Year) AND (@Month = 0 OR M = @Month);
                IF @Year = 0
                    SELECT @Result = IIF(SUM(IIF(Seq = 1, Value, -Value)) > 0, SUM(IIF(Seq = 1, Value, -Value)), 0) FROM @Comp;
                INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal)
                VALUES (9, N'Result', N'=', 'PMS', N'G', N'Billed Mismatches', ISNULL(@Result, 0), 0, 1);
            END
            ELSE
            BEGIN
                DECLARE @Num DECIMAL(19,4), @Den DECIMAL(19,4);
                SELECT @Num = SUM(CASE WHEN h.Hit = 1 THEN InsurancePayment + PatientPayment ELSE 0 END),
                       @Den = COUNT(DISTINCT CASE WHEN h.Hit = 1 THEN AccessionNumber END)
                FROM #C
                CROSS APPLY (SELECT Hit = CASE @RowCode
                                 WHEN N'V' THEN IIF(BillStatus IN (N'Billed', N'Billed-Client', N'Billed - Client'), 1, 0)
                                 WHEN N'W' THEN IIF(ClaimStatus IN (N'Fully Paid', N'Paid-Client'), 1, 0)
                                 ELSE IIF(ClaimStatus NOT IN (N'Unbilled', N'Unbilled - PB'), 1, 0) END) h;
                SET @Result = IIF(ISNULL(@Den, 0) > 0, CAST(ISNULL(@Num, 0) / @Den AS DECIMAL(18,2)), 0);
                INSERT INTO @Comp (Seq, Section, Op, Category, RowCode, Component, Value, IsMoney, IsTotal) VALUES
                    (1,  N'Numerator',   N'',  NULL, NULL, N'Sum of InsurancePayment + PatientPayment', ISNULL(@Num, 0), 1, 1),
                    (11, N'Denominator', N'',  NULL, NULL, N'Distinct accessions', ISNULL(@Den, 0), 0, 1),
                    (29, N'Result',      N'=', 'Avg', @RowCode, N'Average Payment ($)', @Result, 1, 1);
            END;
        END;

        UPDATE @Comp SET Value = ISNULL(Value, 0) WHERE Section <> N'Result';
        -- Snapshot subtotal lines = sum of their section's components.
        UPDATE t SET Value = s.Total
        FROM @Comp t
        CROSS APPLY (SELECT SUM(x.Value) AS Total FROM @Comp x WHERE x.Section = t.Section AND x.IsTotal = 0) s
        WHERE t.IsTotal = 1 AND t.RowCode IS NULL AND s.Total IS NOT NULL;
        UPDATE @Comp SET Value = ISNULL(@Result, 0) WHERE Section = N'Result';

        IF @RowCode = N'G'
            SELECT @Calc = FORMAT(MAX(CASE WHEN Seq = 1 THEN Value END), 'N0') + N' - ' + FORMAT(MAX(CASE WHEN Seq = 2 THEN Value END), 'N0')
                         + N' = ' + FORMAT(ISNULL(@Result, 0), 'N0')
                         + IIF(@Year <> 0 AND @Month = 0, N' (year = sum of the months, each 0 when negative)', N'')
            FROM @Comp;
        ELSE
            SELECT @Calc = N'$' + FORMAT(MAX(CASE WHEN Section = N'Numerator' AND IsTotal = 1 THEN Value END), 'N2') + N' / '
                         + FORMAT(MAX(CASE WHEN Section = N'Denominator' AND (IsTotal = 1 OR (@RowCode IN (N'V', N'W') AND @Mode = 'S')) THEN Value END), 'N0')
                         + N' = $' + FORMAT(ISNULL(@Result, 0), 'N2')
            FROM @Comp;

        INSERT INTO @Rules (RuleGroup, RuleText) VALUES (N'Calculation', @Calc);
        SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

        SELECT CAST(NULL AS NVARCHAR(100)) AS SourceTable, N'Formula' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               0 AS TotalRows, CAST(ISNULL(@Result, 0) AS DECIMAL(19,4)) AS TotalAmount, CAST(1 AS BIT) AS IsFormula;

        -- Live components are their own aggregates (no rows to open), so no RowCode on them.
        SELECT Section, Op AS [Operator], Component,
               IIF(@Mode = 'F' AND @RowCode <> N'G' AND Section <> N'Result', NULL, Category) AS Category,
               IIF(@Mode = 'F' AND @RowCode <> N'G' AND Section <> N'Result', NULL, RowCode)  AS RowCode,
               Value, IsMoney, IsTotal
        FROM @Comp
        ORDER BY Seq;
        RETURN;
    END;

    SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

    /* ---- LIS samples -------------------------------------------------------- */
    IF @IsLis = 1
    BEGIN
        SELECT l.*, Rn = ROW_NUMBER() OVER (PARTITION BY IIF(@LisMode = 'F', l.Accession, NULL)
                                            ORDER BY l.DateOfCollection, l.Accession)
        INTO #LH
        FROM #L l
        WHERE (@Year  = 0 OR l.Y = @Year)
          AND (@Month = 0 OR l.M = @Month)
          AND CASE @LisKind
                WHEN 'A'   THEN 1
                WHEN 'B'   THEN IIF(l.NewStatus = N'Billable', 1, 0)
                WHEN 'BP'  THEN IIF(l.NewStatus = N'Billable' AND l.PanelType = @LisPanel, 1, 0)
                WHEN 'C'   THEN IIF(l.NewStatus = N'Billable' AND l.BillCategory = N'Billed', 1, 0)
                WHEN 'D'   THEN IIF(l.NewStatus = N'Billable' AND (l.BillCategory = N'Not Billed' OR (@LisMode <> 'F' AND l.BillCategory = N'Unbilled')), 1, 0)
                WHEN 'DS'  THEN IIF(l.NewStatus = N'Billable' AND (l.BillCategory = N'Not Billed' OR (@LisMode <> 'F' AND l.BillCategory = N'Unbilled'))
                                    AND l.SubStatus = @LisSub, 1, 0)
                WHEN 'DSP' THEN IIF(l.NewStatus = N'Billable' AND l.BillCategory IN (N'Not Billed', N'Unbilled')
                                    AND l.SubStatus = @LisSub AND l.PanelType = @LisPanel, 1, 0)
                WHEN 'E'   THEN IIF(l.NewStatus <> N'Billable', 1, 0)
                WHEN 'ES'  THEN IIF(l.NewStatus = @LisNew, 1, 0)
              END = 1;

        DELETE FROM #LH WHERE @LisMode = 'F' AND Rn > 1;

        SELECT N'dbo.LIMSMaster' AS SourceTable,
               IIF(@LisMode = 'F', N'Count of distinct Accession', N'Count of samples') AS Measure,
               CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               COUNT(*) AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
        FROM #LH;

        SELECT Accession, DateOfCollection, BilledDate, NewStatus, BillCategory, SubStatus, PanelType,
               FacilityName, PhysicianName, SaleRepName
        FROM #LH
        ORDER BY Y, M, DateOfCollection, Accession
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
        RETURN;
    END;

    /* ---- Claims (PMS / Cash) ------------------------------------------------ */
    SELECT c.*,
           Amount = CASE WHEN @AmountCol IS NULL THEN NULL
                         WHEN @RowCode = N'O' THEN c.ChargeAmount
                         WHEN @RowCode IN (N'P', N'T') THEN c.InsurancePayment
                         WHEN @RowCode = N'Q' THEN c.PatientBalance
                         WHEN @RowCode = N'R' THEN c.PatientPayment
                         WHEN @RowCode = N'S' THEN IIF(@Mode = 'S', c.InsuranceAdjustments, c.InsuranceAdjustments + c.PatientAdjustments)
                         WHEN @RowCode = N'S1' THEN c.PatientAdjustments
                         ELSE c.InsuranceBalance END,
           DistinctKey = CASE @Distinct WHEN N'ClaimID' THEN c.ClaimID WHEN N'AccessionNumber' THEN c.AccessionNumber END
    INTO #CH
    FROM #C c
    CROSS APPLY (SELECT
        B3  = IIF(c.BillStatus IN (N'Billed', N'Billed-Client', N'Billed - Client'), 1, 0),
        B1  = IIF(c.BillStatus = N'Billed', 1, 0),
        B2  = IIF(c.BillStatus IN (N'Billed', N'Billed - Client'), 1, 0),
        CS  = c.ClaimStatus) k
    WHERE 1 = CASE WHEN @Mode = 'S' THEN CASE @RowCode
                    WHEN N'F'   THEN IIF(k.B3 = 1 AND c.ClaimID IS NOT NULL, 1, 0)
                    WHEN N'H'   THEN IIF(k.B3 = 1 AND k.CS = N'Fully Paid', 1, 0)
                    WHEN N'I'   THEN IIF(k.B1 = 1 AND k.CS = N'Patient Responsibility', 1, 0)
                    WHEN N'J'   THEN IIF(k.B1 = 1 AND k.CS = N'Fully Adjusted', 1, 0)
                    WHEN N'K'   THEN IIF(k.B1 = 1 AND k.CS = N'Partially Adjusted', 1, 0)
                    WHEN N'L'   THEN IIF(k.B1 = 1 AND k.CS = N'Partially Paid', 1, 0)
                    WHEN N'M'   THEN IIF(k.B3 = 1 AND k.CS = N'Patient Payment', 1, 0)
                    WHEN N'N'   THEN IIF(k.B1 = 1 AND k.CS IN (N'Fully Denied', N'Partially Denied', N'No Response'), 1, 0)
                    WHEN N'N.1' THEN IIF(k.CS = N'Fully Denied', 1, 0)
                    WHEN N'N.2' THEN IIF(k.B1 = 1 AND k.CS = N'Partially Denied', 1, 0)
                    WHEN N'N.3' THEN IIF(k.CS IN (N'No Response', N'No Response-Client'), 1, 0)
                    WHEN N'O'   THEN k.B3
                    WHEN N'P'   THEN IIF(k.CS IN (N'Fully Paid', N'Paid-Client'), 1, 0)
                    WHEN N'Q'   THEN k.B1
                    WHEN N'R'   THEN k.B3
                    WHEN N'S'   THEN k.B3
                    WHEN N'S1'  THEN k.B3
                    WHEN N'T'   THEN IIF(k.CS = N'Partially Paid', 1, 0)
                    WHEN N'U'   THEN k.B2
                    WHEN N'U.1' THEN IIF(k.CS = N'Fully Denied', 1, 0)
                    WHEN N'U.2' THEN IIF(k.B2 = 1 AND k.CS NOT IN (N'Fully Denied', N'No Response'), 1, 0)
                    WHEN N'U.3' THEN IIF(k.CS IN (N'No Response', N'No Response-Client'), 1, 0)
                    ELSE 0 END
                ELSE CASE @RowCode
                    WHEN N'F'   THEN k.B3
                    WHEN N'H'   THEN IIF(k.CS IN (N'Fully Paid', N'Paid-Client'), 1, 0)
                    WHEN N'I'   THEN IIF(k.CS = N'Patient Responsibility', 1, 0)
                    WHEN N'J'   THEN IIF(k.CS = N'Fully Adjusted', 1, 0)
                    WHEN N'K'   THEN IIF(k.CS = N'Partially Adjusted', 1, 0)
                    WHEN N'L'   THEN IIF(k.CS = N'Partially Paid', 1, 0)
                    WHEN N'M'   THEN IIF(k.CS = N'Patient Payment', 1, 0)
                    WHEN N'N'   THEN IIF(k.CS IN (N'Fully Denied', N'Partially Denied', N'No Response', N'No Response-Client'), 1, 0)
                    WHEN N'N.1' THEN IIF(k.CS = N'Fully Denied', 1, 0)
                    WHEN N'N.2' THEN IIF(k.CS = N'Partially Denied', 1, 0)
                    WHEN N'N.3' THEN IIF(k.CS IN (N'No Response', N'No Response-Client'), 1, 0)
                    WHEN N'O'   THEN k.B3
                    WHEN N'P'   THEN IIF(k.CS IN (N'Fully Paid', N'Paid-Client'), 1, 0)
                    WHEN N'Q'   THEN IIF(k.CS NOT IN (N'Unbilled', N'Unbilled - PB', N'No Response', N'No Response-Client'), 1, 0)
                    WHEN N'R'   THEN IIF(c.PatientPayment > 0, 1, 0)
                    WHEN N'S'   THEN IIF(k.CS NOT IN (N'Unbilled', N'Unbilled - PB'), 1, 0)
                    WHEN N'T'   THEN IIF(k.CS = N'Partially Paid', 1, 0)
                    WHEN N'U'   THEN IIF(k.CS NOT IN (N'Unbilled', N'Unbilled - PB'), 1, 0)
                    WHEN N'U.1' THEN IIF(k.CS = N'Fully Denied', 1, 0)
                    WHEN N'U.2' THEN IIF(k.CS IN (N'Partially Denied', N'Partially Adjusted', N'Partially Paid', N'Patient Payment', N'Patient Responsibility'), 1, 0)
                    WHEN N'U.3' THEN IIF(k.CS IN (N'No Response', N'No Response-Client'), 1, 0)
                    ELSE 0 END
              END;

    -- Distinct counts: one listed row per counted value (blank values are not counted).
    IF @Distinct IS NOT NULL
    BEGIN
        DELETE FROM #CH WHERE DistinctKey IS NULL;
        WITH d AS (SELECT Rn = ROW_NUMBER() OVER (PARTITION BY DistinctKey ORDER BY Y, M, DateofService, ClaimID) FROM #CH)
        DELETE FROM d WHERE Rn > 1;
    END;

    SELECT N'dbo.ClaimLevelData' AS SourceTable,
           CASE WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol
                WHEN @Distinct IS NOT NULL THEN N'Count of distinct ' + @Distinct
                ELSE N'Count of claims' END AS Measure,
           @AmountCol AS AmountColumn,
           COUNT(*) AS TotalRows,
           CAST(ISNULL(SUM(Amount), 0) AS DECIMAL(18,2)) AS TotalAmount,
           CAST(0 AS BIT) AS IsFormula
    FROM #CH;

    IF @AmountCol IS NULL
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, PanelName, ClinicName,
               ReferringProvider, SalesRepname, BillStatus, ClaimStatus,
               ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments,
               InsuranceBalance, PatientBalance
        FROM #CH
        ORDER BY Y, M, DateofService, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
    ELSE
        SELECT ClaimID, AccessionNumber, DateofService, FirstBilledDate, PayerName_Raw, PanelName, ClinicName,
               ReferringProvider, SalesRepname, BillStatus, ClaimStatus, Amount,
               ChargeAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments,
               InsuranceBalance, PatientBalance
        FROM #CH
        ORDER BY Y, M, DateofService, ClaimID
        OFFSET CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END ROWS
        FETCH NEXT CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END ROWS ONLY;
END;
GO

SET NOEXEC OFF;
GO

PRINT '25_Cove_ExecutiveSummary_CellRows.sql completed.';
GO
