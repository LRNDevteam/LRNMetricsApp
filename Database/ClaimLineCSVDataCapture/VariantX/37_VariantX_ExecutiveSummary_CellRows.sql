/* =============================================================================
   VariantX - Executive Summary cell rows (value click -> popup grid)
   File     : 37_VariantX_ExecutiveSummary_CellRows.sql
   Database : VariantX_LRN (any database named VariantX%)
   Requires : 16_VariantX_ExecutiveSummary_Aggregate.sql, 17/17b_VariantX_ExecutiveSummary_Read*.sql
              (usp_GetVarX_ExecutiveSummary), 19_VariantX_ExecutiveSummary_LIS_Alt.sql
   Object   : dbo.usp_GetVarX_ExecutiveSummaryCellRows
   Caller   : SqlPhiExecutiveSummaryRepository.CellRows.cs  (usp_Get{prefix}_ExecutiveSummaryCellRows, prefix = VarX)

   Returns the source rows behind one Executive Summary cell, using the RoleID rules of
   usp_RefreshVarX_ExecutiveSummary (16), usp_RefreshVarX_ExecutiveSummary_LIS_Alt (19) and the
   page-filter behaviour of usp_GetVarX_ExecutiveSummary (17), so the row count / amount equals the
   clicked value.

   RoleIDs (client Executive Summary sheet)
     LIS  (dbo.LIMSMaster, distinct Accession, period = DateOfCollection / RequestCollectDate)
          A  Total Samples
          B  Billable Samples                 SampleStatus = Billable
          B.<TestType>                        Billable AND TestType (panel) = <TestType>
          C  Billed                           Billable AND BillCategory = Billed
          D  Other Samples                    SampleStatus <> Billable (blank excluded)
          D.<status>                          SampleStatus = <status>
     PMS  (dbo.ClaimLevelData, distinct ClaimID; population = FirstBilledDate; month = DateofService)
          F  Billed Claims                    every claim
     F.1 Claim Submitted in Cove          AccessionNumber IN CoveLRN.LIMSMaster.Accession
     F.2 Claim Submitted in Others        formula F - F.1 - F.3 (floored at 0)
     F.3 Claim Submitted in VariantX      AccessionNumber IN dbo.LIMSMaster.Accession
          G  Billed Mismatches                formula: F - LIS C (floored at 0)
          H  Fully Paid            I  Patient Responsibility      J  Fully Adjusted (Adjusted / Written Off)
          K  Partially Adjusted    L  Partially Paid              M  Patient Payment (Patient Paid)
          N  Insurance Balance Claims         Fully Denied | Denied | Partially Denied | No Response
          N.1 Fully Denied | Denied           N.2 Partially Denied   N.3 No Response
     Cash (dbo.ClaimLevelData, dollar sums)
          O  Sum ChargeAmount                 P  Sum InsurancePayment, Fully Paid
          Q  Sum PatientBalance               R  Sum PatientPayment
          S  Adjustments / Write Off          formula: O - P - Q - R - T - U
          T  Sum InsurancePayment, Partially Paid
          U  Sum InsuranceBalance             U.1 Denied | Fully Denied   U.2 Partially Denied   U.3 No Response
     Avg  (formulas)
          V  (P + T) / F      W  P / H      X  (P + T) / (H + L + J + N.1 + N.2)
   Parameters
     @Category / @RowCode   the clicked row (LIS | PMS | Cash | Avg)
     @Year / @Month         (Y, M) month, (Y, 0) year total, (0, 0) grand total
     @YearFrom .. @Reps     the page filters (same as usp_GetVarX_ExecutiveSummary)
     @Page / @PageSize      paging; @PageSize = 0 returns every row (Excel download)

   Result sets
     1. Rules   : RuleOrder, RuleGroup, RuleText
     2. Summary : SourceTable, Measure, AmountColumn, TotalRows, TotalAmount, IsFormula
     3. Rows    : one page of source rows. Every column of the source table is returned: the key
                  columns first (Amount first for $ rows), then the rest in table order.
   Count rows : TotalRows = the cell count (distinct Accession / ClaimID), TotalAmount = the same count.
   $ rows     : TotalRows = rows summed, TotalAmount = Sum(measure), Amount column on every row.
   Formula rows (PMS G / F2, Cash S, Avg V / W / X) return the formula and calculation in Rules,
   IsFormula = 1, TotalAmount = the grid value, and result set 3 = the components
   (Section, Operator, Component, Category, RowCode, Value, IsMoney, IsTotal) read from
   usp_GetVarX_ExecutiveSummary for the same period and page filters.

   Page-filter behaviour mirrors usp_GetVarX_ExecutiveSummary exactly (including its quirks):
     @HasFilter = any page filter supplied (the clicked @Year / @Month do not count).
     LIS    no filter                  : collection date, Year / Month of the clicked cell only
            Year / Month / DOS filters : collection date; Year / Month ranges and DOS bounds (month granularity)
            Panel / Clinic / Provider / Rep filter, or Billed-date mode:
                                         live scan; dimension filters; in Billed-date mode the period is
                                         BilledDate bounded by @BilledFrom / @BilledTo (Year / Month / DOS
                                         ranges are NOT applied to LIS in this mode)
     PMS / Cash  population always requires FirstBilledDate; monthwise period = DateofService
            no filter                  : DateofService month of clicked cell
            any filter, DOS mode       : DateofService, Year / Month ranges, DOS bounds, dimension filters
            any filter, Billed mode    : DateofService month; FirstBilledDate bounded by @BilledFrom / @BilledTo
   ============================================================================= */

IF DB_NAME() NOT LIKE N'VariantX%'
BEGIN
    RAISERROR(N'37_VariantX_ExecutiveSummary_CellRows.sql must run on a VariantX database (e.g. VariantX_LRN).', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_ExecutiveSummaryCellRows
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

    SET @Category = CASE UPPER(LTRIM(RTRIM(ISNULL(@Category, ''))))
                        WHEN 'LIS'  THEN 'LIS'
                        WHEN 'PMS'  THEN 'PMS'
                        WHEN 'CASH' THEN 'Cash'
                        WHEN 'AVG'  THEN 'Avg'
                        ELSE LTRIM(RTRIM(ISNULL(@Category, ''))) END;
    SET @RowCode  = LTRIM(RTRIM(ISNULL(@RowCode, N'')));
    SET @Year     = ISNULL(@Year, 0);
    SET @Month    = ISNULL(@Month, 0);
    IF ISNULL(@Page, 0) < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 0 SET @PageSize = 100;

    DECLARE @RowCodeU NVARCHAR(420) = UPPER(@RowCode);
    DECLARE @IsLis    BIT           = CASE WHEN @Category = 'LIS' THEN 1 ELSE 0 END;

    /* ---- Page-filter modes (as usp_GetVarX_ExecutiveSummary) ---------------- */
    DECLARE @HasPanel    BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Panels,    N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;
    DECLARE @HasClinic   BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Clinics,   N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;
    DECLARE @HasProvider BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Providers, N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;
    DECLARE @HasRep      BIT = CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(@Reps,      N''), N',') WHERE LTRIM(RTRIM(value)) <> N'') THEN 1 ELSE 0 END;

    DECLARE @HasFilter BIT = CASE
        WHEN @YearFrom IS NOT NULL OR @YearTo IS NOT NULL OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL
          OR @DosFrom IS NOT NULL OR @DosTo IS NOT NULL OR @BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Panels)),    N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Clinics)),   N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(@Reps)),      N'') IS NOT NULL
        THEN 1 ELSE 0 END;

    -- Billed-date mode: FirstBilledDate filter active and no DOS filter.
    DECLARE @UseBilledDate BIT = CASE WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
                                       AND @DosFrom IS NULL AND @DosTo IS NULL THEN 1 ELSE 0 END;

    DECLARE @HasLisFilter BIT = CASE WHEN @HasPanel = 1 OR @HasClinic = 1 OR @HasProvider = 1
                                       OR @HasRep = 1 OR @UseBilledDate = 1 THEN 1 ELSE 0 END;

    -- LIS mode: 0 = aggregate (no filter), 1 = aggregate re-summed by Year/Month/DOS, 2 = live LIMSMaster scan.
    DECLARE @LisMode   TINYINT = CASE WHEN @HasFilter = 0 THEN 0 WHEN @HasLisFilter = 0 THEN 1 ELSE 2 END;
    -- Claim mode: 0 = no filter, 1 = DOS mode, 2 = Billed-date mode (FirstBilledDate range).
    -- Monthwise period is always DateofService; population always requires FirstBilledDate.
    DECLARE @ClaimMode TINYINT = CASE WHEN @HasFilter = 0 THEN 0 WHEN @UseBilledDate = 0 THEN 1 ELSE 2 END;

    /* ---- dbo.LIMSMaster column detection (as files 17 / 19 / 20) ------------- */
    DECLARE @AccCol          SYSNAME = NULL;
    DECLARE @DateCol         SYSNAME = NULL;
    DECLARE @BilledDateCol   SYSNAME = NULL;
    DECLARE @NewStatusCol    SYSNAME = NULL;
    DECLARE @BillCategoryCol SYSNAME = NULL;
    DECLARE @ResultStatusCol SYSNAME = NULL;
    DECLARE @TestTypeCol     SYSNAME = NULL;   -- B.<TestType> sub-rows when not filtered (file 19 order)
    DECLARE @PanelCol        SYSNAME = NULL;   -- Panel filter column + B.<TestType> on the live scan (file 17 order)
    DECLARE @ClinicCol       SYSNAME = NULL;
    DECLARE @ProviderCol     SYSNAME = NULL;
    DECLARE @RepCol          SYSNAME = NULL;

    IF OBJECT_ID(N'dbo.LIMSMaster', N'U') IS NOT NULL
    BEGIN
        SET @AccCol = (SELECT TOP 1 name FROM sys.columns
                       WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                         AND name IN (N'AccessionNumber', N'Accession', N'AccessionNo')
                       ORDER BY CASE name WHEN N'AccessionNumber' THEN 0 WHEN N'Accession' THEN 1 WHEN N'AccessionNo' THEN 2 ELSE 3 END);

        SET @DateCol = (SELECT TOP 1 name FROM sys.columns
                        WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                          AND name IN (N'DateOfCollection', N'RequestCollectDate', N'CollectionDate', N'DateofService', N'ServiceDate', N'AccessionDate')
                        ORDER BY CASE name WHEN N'DateOfCollection' THEN 0 WHEN N'RequestCollectDate' THEN 1
                                           WHEN N'CollectionDate' THEN 2 WHEN N'DateofService' THEN 3
                                           WHEN N'ServiceDate' THEN 4 WHEN N'AccessionDate' THEN 5 ELSE 6 END);

        SET @BilledDateCol = (SELECT TOP 1 name FROM sys.columns
                              WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                                AND name IN (N'BilledDate', N'FirstBilledDate', N'BilledOn', N'BillDate', N'FirstBillDate')
                              ORDER BY CASE name WHEN N'BilledDate' THEN 0 WHEN N'FirstBilledDate' THEN 1
                                                 WHEN N'BilledOn' THEN 2 WHEN N'BillDate' THEN 3
                                                 WHEN N'FirstBillDate' THEN 4 ELSE 5 END);

        SET @NewStatusCol = (SELECT TOP 1 name FROM sys.columns
                             WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                               AND name IN (N'SampleStatus', N'NewStatus', N'Status', N'LRNSampleStatus')
                             ORDER BY CASE name WHEN N'SampleStatus' THEN 0 WHEN N'LRNSampleStatus' THEN 1
                                                WHEN N'NewStatus' THEN 2 WHEN N'Status' THEN 3 ELSE 4 END);

        SET @BillCategoryCol = (SELECT TOP 1 name FROM sys.columns
                                WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                                  AND name IN (N'BillCategory', N'Bill_Category', N'BillingCategory', N'BillStatus', N'LRNBillCategory')
                                ORDER BY CASE name WHEN N'BillCategory' THEN 0 WHEN N'LRNBillCategory' THEN 1
                                                   WHEN N'Bill_Category' THEN 2 WHEN N'BillingCategory' THEN 3
                                                   WHEN N'BillStatus' THEN 4 ELSE 5 END);

        SET @ResultStatusCol = (SELECT TOP 1 name FROM sys.columns
                                WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                                  AND name IN (N'ResultStatus', N'Result_Status', N'ResultedStatus', N'RessultedStatus', N'IsResulted')
                                ORDER BY CASE name WHEN N'ResultStatus' THEN 0 WHEN N'Result_Status' THEN 1
                                                   WHEN N'ResultedStatus' THEN 2 WHEN N'RessultedStatus' THEN 3
                                                   WHEN N'IsResulted' THEN 4 ELSE 5 END);

        SET @TestTypeCol = (SELECT TOP 1 name FROM sys.columns
                            WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                              AND name IN (N'TestType', N'Panel', N'PanelName', N'PanelType', N'TestPanel')
                            ORDER BY CASE name WHEN N'TestType' THEN 0 WHEN N'Panel' THEN 1 WHEN N'PanelName' THEN 2
                                               WHEN N'PanelType' THEN 3 WHEN N'TestPanel' THEN 4 ELSE 5 END);

        SET @PanelCol = (SELECT TOP 1 name FROM sys.columns
                         WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                           AND name IN (N'TestType', N'PanelName', N'Panel', N'PanelType', N'TestPanel')
                         ORDER BY CASE name WHEN N'TestType' THEN 0 WHEN N'PanelName' THEN 1 WHEN N'Panel' THEN 2
                                            WHEN N'PanelType' THEN 3 WHEN N'TestPanel' THEN 4 ELSE 5 END);

        SET @ClinicCol = (SELECT TOP 1 name FROM sys.columns
                          WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                            AND name IN (N'FacilityName', N'ClinicName', N'Clinic', N'FacilityID')
                          ORDER BY CASE name WHEN N'FacilityName' THEN 0 WHEN N'ClinicName' THEN 1
                                             WHEN N'Clinic' THEN 2 WHEN N'FacilityID' THEN 3 ELSE 4 END);

        SET @ProviderCol = (SELECT TOP 1 name FROM sys.columns
                            WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                              AND name IN (N'PhysicianName', N'ReferringProvider', N'ReferringPhysician', N'ProviderName')
                            ORDER BY CASE name WHEN N'PhysicianName' THEN 0 WHEN N'ReferringProvider' THEN 1
                                               WHEN N'ReferringPhysician' THEN 2 WHEN N'ProviderName' THEN 3 ELSE 4 END);

        SET @RepCol = (SELECT TOP 1 name FROM sys.columns
                       WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
                         AND name IN (N'SaleRepName', N'SalesRepName', N'SalesRep', N'Rep')
                       ORDER BY CASE name WHEN N'SaleRepName' THEN 0 WHEN N'SalesRepName' THEN 1
                                          WHEN N'SalesRep' THEN 2 WHEN N'Rep' THEN 3 ELSE 4 END);
    END;

    /* ---- dbo.ClaimLevelData column detection (as file 17 filtered path) ------ */
    DECLARE @ClPanelCol    SYSNAME = NULL;
    DECLARE @ClClinicCol   SYSNAME = NULL;
    DECLARE @ClProviderCol SYSNAME = NULL;
    DECLARE @ClRepCol      SYSNAME = NULL;

    IF OBJECT_ID(N'dbo.ClaimLevelData', N'U') IS NOT NULL
    BEGIN
        SET @ClPanelCol = (SELECT TOP 1 name FROM sys.columns
                           WHERE object_id = OBJECT_ID(N'dbo.ClaimLevelData')
                             AND name IN (N'Panelname', N'PanelName', N'PanelType')
                           ORDER BY CASE name WHEN N'Panelname' THEN 0 WHEN N'PanelName' THEN 1 ELSE 2 END);
        SET @ClClinicCol = (SELECT TOP 1 name FROM sys.columns
                            WHERE object_id = OBJECT_ID(N'dbo.ClaimLevelData')
                              AND name IN (N'ClinicName', N'Facility', N'ServiceLocationName', N'Clinic')
                            ORDER BY CASE name WHEN N'ClinicName' THEN 1 WHEN N'Facility' THEN 2 WHEN N'ServiceLocationName' THEN 3 ELSE 4 END);
        SET @ClProviderCol = (SELECT TOP 1 name FROM sys.columns
                              WHERE object_id = OBJECT_ID(N'dbo.ClaimLevelData')
                                AND name IN (N'ReferringProvider', N'ReferringPhysician', N'Provider', N'ProviderName', N'OrderingProvider', N'BillingProvider')
                              ORDER BY CASE name WHEN N'ReferringProvider' THEN 1 WHEN N'ReferringPhysician' THEN 2 WHEN N'Provider' THEN 3
                                                 WHEN N'ProviderName' THEN 4 WHEN N'OrderingProvider' THEN 5 WHEN N'BillingProvider' THEN 6 ELSE 7 END);
        SET @ClRepCol = (SELECT TOP 1 name FROM sys.columns
                         WHERE object_id = OBJECT_ID(N'dbo.ClaimLevelData')
                           AND name IN (N'SalesRepname', N'SalesRepName', N'SalesRep', N'SalesRep_Name')
                         ORDER BY CASE name WHEN N'SalesRepname' THEN 1 WHEN N'SalesRepName' THEN 2 WHEN N'SalesRep' THEN 3 ELSE 4 END);
    END;

    /* ---- LIS sub-rows: B.<TestType> / D.<SampleStatus> ----------------------- */
    DECLARE @LisSub CHAR(1)       = NULL;
    DECLARE @Suffix NVARCHAR(420) = NULL;
    IF @IsLis = 1 AND LEN(@RowCode) > 2 AND LEFT(@RowCodeU, 2) IN (N'B.', N'D.')
    BEGIN
        SET @Suffix = LTRIM(RTRIM(SUBSTRING(@RowCode, 3, 420)));
        IF @Suffix <> N'' SET @LisSub = LEFT(@RowCodeU, 1);
    END;

    /* ---- Row definitions (RoleIDs of files 16 / 19) -------------------------- */
    DECLARE @Def TABLE
    (
        Category  VARCHAR(10)    NOT NULL,
        RowCode   NVARCHAR(20)   NOT NULL,
        RuleText  NVARCHAR(1000) NOT NULL,
        AmountCol NVARCHAR(100)  NULL,      -- $ rows: the summed ClaimLevelData column
        Statuses  NVARCHAR(400)  NULL,      -- '|' list of ClaimStatus values; NULL = no ClaimStatus filter
        IsFormula BIT            NOT NULL
    );
    INSERT INTO @Def (Category, RowCode, RuleText, AmountCol, Statuses, IsFormula) VALUES
        ('LIS',  'A',   N'Every sample (no status filter)', NULL, NULL, 0),
        ('LIS',  'B',   N'SampleStatus = Billable', NULL, NULL, 0),
        ('LIS',  'C',   N'SampleStatus = Billable AND BillCategory = Billed', NULL, NULL, 0),
        ('LIS',  'D',   N'SampleStatus <> Billable (blank status excluded)', NULL, NULL, 0),
        ('PMS',  'F',   N'Billed Claims: every claim billed in the period (no ClaimStatus filter)', NULL, NULL, 0),
        ('PMS',  'F.1',  N'Billed Claims whose AccessionNumber exists in CoveLRN.dbo.LIMSMaster.Accession', NULL, NULL, 0),
        ('PMS',  'F.2',  N'Formula: Billed Claims (PMS F) - Claim Submitted in Cove (F.1) - Claim Submitted in VariantX (F.3), floored at 0', NULL, NULL, 1),
        ('PMS',  'F.3',  N'Billed Claims whose AccessionNumber exists in dbo.LIMSMaster.Accession', NULL, NULL, 0),
        ('PMS',  'G',   N'Formula: Billed Claims (PMS F) - LIS Billed samples (LIS C) for the same period, floored at 0', NULL, NULL, 1),
        ('PMS',  'H',   N'ClaimStatus = Fully Paid', NULL, N'Fully Paid', 0),
        ('PMS',  'I',   N'ClaimStatus = Patient Responsibility', NULL, N'Patient Responsibility', 0),
        ('PMS',  'J',   N'ClaimStatus = Fully Adjusted (Adjusted / Written Off)', NULL, N'Fully Adjusted', 0),
        ('PMS',  'K',   N'ClaimStatus = Partially Adjusted (Partially Adjusted / Written Off)', NULL, N'Partially Adjusted', 0),
        ('PMS',  'L',   N'ClaimStatus = Partially Paid', NULL, N'Partially Paid', 0),
        ('PMS',  'M',   N'ClaimStatus = Patient Payment (Patient Paid)', NULL, N'Patient Payment', 0),
        ('PMS',  'N',   N'ClaimStatus IN (Fully Denied, Denied, Partially Denied, No Response)', NULL, N'Fully Denied|Denied|Partially Denied|No Response', 0),
        ('PMS',  'N.1', N'ClaimStatus IN (Fully Denied, Denied)', NULL, N'Fully Denied|Denied', 0),
        ('PMS',  'N.2', N'ClaimStatus = Partially Denied', NULL, N'Partially Denied', 0),
        ('PMS',  'N.3', N'ClaimStatus = No Response', NULL, N'No Response', 0),
        ('Cash', 'O',   N'Total Billed ($): every claim billed in the period', N'ChargeAmount', NULL, 0),
        ('Cash', 'P',   N'Insurance Payment ($): ClaimStatus = Fully Paid', N'InsurancePayment', N'Fully Paid', 0),
        ('Cash', 'Q',   N'Patient Responsibility ($): every claim billed in the period', N'PatientBalance', NULL, 0),
        ('Cash', 'R',   N'Patient Payment ($): every claim billed in the period', N'PatientPayment', NULL, 0),
        ('Cash', 'S',   N'Formula: Adjustments / Write Off ($) = O - P - Q - R - T - U', NULL, NULL, 1),
        ('Cash', 'T',   N'Partially Paid ($): ClaimStatus = Partially Paid', N'InsurancePayment', N'Partially Paid', 0),
        ('Cash', 'U',   N'Insurance Balance ($): every claim billed in the period', N'InsuranceBalance', NULL, 0),
        ('Cash', 'U.1', N'Denials ($): ClaimStatus IN (Denied, Fully Denied)', N'InsuranceBalance', N'Denied|Fully Denied', 0),
        ('Cash', 'U.2', N'Partially Denied ($): Sum(InsuranceBalance) where ClaimStatus NOT IN (Denied, Fully Denied, No Response)', N'InsuranceBalance', NULL, 0),
        ('Cash', 'U.3', N'No Response from Payor ($): ClaimStatus = No Response', N'InsuranceBalance', N'No Response', 0),
        ('Avg',  'V',   N'Formula: (Insurance Payment $ + Partially Paid $) / No. of Billed Claims (PMS F)', NULL, NULL, 1),
        ('Avg',  'W',   N'Formula: Insurance Payment $ / No. of Fully Paid Claims (PMS H)', NULL, NULL, 1),
        ('Avg',  'X',   N'Formula: (Insurance Payment $ + Partially Paid $) / (Fully Paid + Partially Paid + Adjusted + Fully Denied + Partially Denied claims = H + L + J + N.1 + N.2)', NULL, NULL, 1);

    IF @LisSub = 'B'
        INSERT INTO @Def (Category, RowCode, RuleText, AmountCol, Statuses, IsFormula)
        VALUES ('LIS', N'B.*', N'SampleStatus = Billable AND TestType (panel) = ' + @Suffix, NULL, NULL, 0);
    ELSE IF @LisSub = 'D'
        INSERT INTO @Def (Category, RowCode, RuleText, AmountCol, Statuses, IsFormula)
        VALUES ('LIS', N'D.*', N'SampleStatus = ' + @Suffix + N' (not Billable)', NULL, NULL, 0);

    DECLARE @DefCode NVARCHAR(20) = CASE WHEN @LisSub IS NOT NULL THEN @LisSub + N'.*' ELSE LEFT(@RowCodeU, 20) END;
    DECLARE @RuleText NVARCHAR(1000), @AmountCol NVARCHAR(100), @Statuses NVARCHAR(400), @IsFormula BIT;
    SELECT @RuleText = RuleText, @AmountCol = AmountCol, @Statuses = Statuses, @IsFormula = IsFormula
    FROM @Def
    WHERE Category = @Category AND RowCode = @DefCode;

    IF @RuleText IS NULL
    BEGIN
        RAISERROR(N'usp_GetVarX_ExecutiveSummaryCellRows: unknown row %s / %s.', 16, 1, @Category, @RowCode);
        RETURN;
    END;

    -- LIS row token for the dynamic predicate: A, B, BX (B.<TestType>), C, D, DX (D.<status>).
    DECLARE @Lm NVARCHAR(4) = CASE WHEN @IsLis = 0 THEN N''
                                   WHEN @LisSub = 'B' THEN N'BX'
                                   WHEN @LisSub = 'D' THEN N'DX'
                                   ELSE LEFT(@RowCodeU, 4) END;

    /* ---- What the page filters do for this row (as usp_GetVarX_ExecutiveSummary) */
    DECLARE @ShowAll    BIT = @IsFormula;   -- formula rows: components are computed with every page filter
    DECLARE @ApplyRange BIT = CASE WHEN (@IsLis = 1 AND @LisMode = 1) OR (@IsLis = 0 AND @ClaimMode = 1) THEN 1 ELSE 0 END;
    DECLARE @ApplyBilled BIT = CASE WHEN (@IsLis = 1 AND @LisMode = 2 AND @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL)
                                      OR (@IsLis = 0 AND @ClaimMode = 2) THEN 1 ELSE 0 END;
    DECLARE @ApplyDims  BIT = CASE WHEN (@IsLis = 1 AND @LisMode = 2) OR (@IsLis = 0 AND @ClaimMode > 0) THEN 1 ELSE 0 END;

    DECLARE @LisPeriodCol SYSNAME = CASE WHEN @LisMode = 2 AND @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
                                         THEN @BilledDateCol ELSE @DateCol END;
    DECLARE @ClPeriodCol  SYSNAME = N'DateofService';

    DECLARE @PeriodText NVARCHAR(200) =
        CASE WHEN @Year = 0 AND @Month = 0 THEN N'all periods (Grand Total)'
             WHEN @Year = 0 THEN N'month ' + CAST(@Month AS NVARCHAR(2)) + N' of every year'
             WHEN @Month = 0 THEN N'year ' + CAST(@Year AS NVARCHAR(4)) + N' (Year Total)'
             ELSE DATENAME(MONTH, DATEFROMPARTS(@Year, @Month, 1)) + N' ' + CAST(@Year AS NVARCHAR(4)) END;

    DECLARE @Measure NVARCHAR(200) =
        CASE WHEN @IsFormula = 1 THEN N'Formula'
             WHEN @AmountCol IS NOT NULL THEN N'Sum of ' + @AmountCol
             WHEN @IsLis = 1 THEN N'Count of samples (distinct Accession)'
             ELSE N'Count of claims (distinct ClaimID)' END;

    /* ---- 1. Rules ----------------------------------------------------------- */
    DECLARE @Rules TABLE (RuleOrder INT IDENTITY(1,1), RuleGroup NVARCHAR(40), RuleText NVARCHAR(2000));

    IF @IsFormula = 1
        INSERT INTO @Rules (RuleGroup, RuleText)
        VALUES (N'Source', N'Components are read from dbo.usp_GetVarX_ExecutiveSummary with the same period and page filters');
    ELSE IF @IsLis = 1
        INSERT INTO @Rules (RuleGroup, RuleText)
        VALUES (N'Source', N'dbo.LIMSMaster - one row per distinct Accession (Accession = ' + ISNULL(@AccCol, N'?')
                         + N', SampleStatus = ' + ISNULL(@NewStatusCol, N'?') + N', BillCategory = ' + ISNULL(@BillCategoryCol, N'?') + N')');
    ELSE
        INSERT INTO @Rules (RuleGroup, RuleText)
        VALUES (N'Source', CASE WHEN @AmountCol IS NULL
                                THEN N'dbo.ClaimLevelData - one row per distinct ClaimID'
                                ELSE N'dbo.ClaimLevelData - one row per claim line row (amounts are summed, as the Executive Summary)' END);

    IF @IsFormula = 0
        INSERT INTO @Rules (RuleGroup, RuleText)
        VALUES (N'Base filter',
                CASE WHEN @IsLis = 1
                     THEN ISNULL(@LisPeriodCol, N'Date') + N' is a valid date and Accession is not blank; blank SampleStatus / BillCategory = empty text'
                     ELSE N'FirstBilledDate and DateofService are valid dates and ClaimID is not blank; blank ClaimStatus = empty text' END);

    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Period',
           CASE WHEN @IsFormula = 1 THEN N'Grid period: ' + @PeriodText
                WHEN @IsLis = 1 THEN ISNULL(@LisPeriodCol, N'Date') + CASE WHEN @LisPeriodCol = @BilledDateCol THEN N' (billed date)' ELSE N' (collection date)' END + N' in ' + @PeriodText
                ELSE N'DateofService (monthwise) in ' + @PeriodText
                     + CASE WHEN @ClaimMode = 2 THEN N'; FirstBilledDate bounded by Billed From/To'
                            WHEN @ClaimMode = 1 THEN N'; DOS / Year / Month page filters active'
                            ELSE N'; population requires FirstBilledDate' END END;

    INSERT INTO @Rules (RuleGroup, RuleText)
    VALUES (CASE WHEN @IsFormula = 1 THEN N'Formula' ELSE N'Row rule' END, @RuleText);

    IF @IsFormula = 0
    BEGIN
        INSERT INTO @Rules (RuleGroup, RuleText) VALUES (N'Measure', @Measure);
        IF @AmountCol IS NULL
            INSERT INTO @Rules (RuleGroup, RuleText)
            VALUES (N'Distinct',
                    CASE WHEN @Year = 0 AND @Month = 0 AND (@IsLis = 0 OR @HasFilter = 0)
                         THEN N'One row per distinct ' + CASE WHEN @IsLis = 1 THEN N'Accession' ELSE N'ClaimID' END + N' across the whole result'
                         ELSE N'One row per distinct ' + CASE WHEN @IsLis = 1 THEN N'Accession' ELSE N'ClaimID' END + N' per month (the grid sums month counts for year / filtered grand totals)' END);
    END;

    INSERT INTO @Rules (RuleGroup, RuleText)
    SELECT N'Page filter', LEFT(v.Txt, 1900)
    FROM (VALUES
        (CASE WHEN (@ShowAll = 1 OR @ApplyBilled = 1) AND (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
              THEN N'Billed Date from ' + ISNULL(CONVERT(NVARCHAR(10), @BilledFrom, 101), N'(any)')
                   + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @BilledTo, 101), N'(any)') END),
        (CASE WHEN (@ShowAll = 1 OR @ApplyRange = 1) AND (@DosFrom IS NOT NULL OR @DosTo IS NOT NULL)
              THEN N'DOS from ' + ISNULL(CONVERT(NVARCHAR(10), @DosFrom, 101), N'(any)')
                   + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @DosTo, 101), N'(any)')
                   + CASE WHEN @IsLis = 1 AND @ShowAll = 0 THEN N' (month granularity)' ELSE N'' END END),
        (CASE WHEN (@ShowAll = 1 OR @ApplyRange = 1) AND (@YearFrom IS NOT NULL OR @YearTo IS NOT NULL)
              THEN N'Year ' + ISNULL(CAST(@YearFrom AS NVARCHAR(4)), N'(any)') + N' - ' + ISNULL(CAST(@YearTo AS NVARCHAR(4)), N'(any)') END),
        (CASE WHEN (@ShowAll = 1 OR @ApplyRange = 1) AND (@MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
              THEN N'Month ' + ISNULL(CAST(@MonthFrom AS NVARCHAR(2)), N'(any)') + N' - ' + ISNULL(CAST(@MonthTo AS NVARCHAR(2)), N'(any)') END),
        (CASE WHEN (@ShowAll = 1 OR @ApplyDims = 1) AND @HasPanel = 1
              THEN N'Panel (' + ISNULL(CASE WHEN @IsLis = 1 THEN @PanelCol ELSE @ClPanelCol END, N'Panelname') + N') IN (' + @Panels + N')' END),
        (CASE WHEN (@ShowAll = 1 OR @ApplyDims = 1) AND @HasClinic = 1
              THEN N'Clinic (' + ISNULL(CASE WHEN @IsLis = 1 THEN @ClinicCol ELSE @ClClinicCol END, N'ClinicName') + N') IN (' + @Clinics + N')' END),
        (CASE WHEN (@ShowAll = 1 OR @ApplyDims = 1) AND @HasProvider = 1
              THEN N'Provider (' + ISNULL(CASE WHEN @IsLis = 1 THEN @ProviderCol ELSE @ClProviderCol END, N'ReferringProvider') + N') IN (' + @Providers + N')' END),
        (CASE WHEN (@ShowAll = 1 OR @ApplyDims = 1) AND @HasRep = 1
              THEN N'Sales rep (' + ISNULL(CASE WHEN @IsLis = 1 THEN @RepCol ELSE @ClRepCol END, N'SalesRepname') + N') IN (' + @Reps + N')' END),
        (CASE WHEN @ShowAll = 0 AND @ApplyRange = 0
               AND (@DosFrom IS NOT NULL OR @DosTo IS NOT NULL OR @YearFrom IS NOT NULL OR @YearTo IS NOT NULL
                    OR @MonthFrom IS NOT NULL OR @MonthTo IS NOT NULL)
              THEN N'Note: the DOS / Year / Month range filters are not applied to ' + @Category
                   + N' rows in this filter mode (same as usp_GetVarX_ExecutiveSummary)' END),
        (CASE WHEN @ShowAll = 0 AND @ApplyBilled = 0 AND (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
              THEN N'Note: the Billed Date range is not applied to ' + @Category
                   + N' rows in this filter mode (same as usp_GetVarX_ExecutiveSummary)' END)
    ) v(Txt)
    WHERE v.Txt IS NOT NULL;

    /* ======================================================================
       Formula rows: components read from usp_GetVarX_ExecutiveSummary
       ====================================================================== */
    IF @IsFormula = 1
    BEGIN
        -- #CellEs / #CellComp are named so they never collide with the temp tables that
        -- usp_GetVarX_ExecutiveSummary creates and drops (#Base, #Lis, #LisOut, ...).
        CREATE TABLE #CellEs
        (
            RowCode     NVARCHAR(420) COLLATE DATABASE_DEFAULT NOT NULL,
            Category    NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
            Description NVARCHAR(420) COLLATE DATABASE_DEFAULT NULL,
            BillYear    INT           NOT NULL,
            BillMonth   INT           NOT NULL,
            MetricValue DECIMAL(18,2) NULL
        );
        INSERT INTO #CellEs (RowCode, Category, Description, BillYear, BillMonth, MetricValue)
        EXEC dbo.usp_GetVarX_ExecutiveSummary
            @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
            @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
            @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;

        DECLARE @Comp TABLE
        (
            Seq INT NOT NULL, Section NVARCHAR(20) NOT NULL, Op NVARCHAR(4) NOT NULL,
            Category VARCHAR(10) NULL, RowCode NVARCHAR(20) NULL, Label NVARCHAR(200) NULL,
            IsMoney BIT NOT NULL, IsTotal BIT NOT NULL
        );

        IF @RowCodeU = N'G'           -- F - LIS C
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'PMS', N'F', NULL, 0, 0),
                (2, N'Calculation', N'-', 'LIS', N'C', NULL, 0, 0),
                (9, N'Result',      N'=', 'PMS', N'G', NULL, 0, 1);
        ELSE IF @RowCodeU = N'F.2'     -- F - F.1 - F.3
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'PMS', N'F',  NULL, 0, 0),
                (2, N'Calculation', N'-', 'PMS', N'F.1', NULL, 0, 0),
                (3, N'Calculation', N'-', 'PMS', N'F.3', NULL, 0, 0),
                (9, N'Result',      N'=', 'PMS', N'F.2', NULL, 0, 1);
        ELSE IF @RowCodeU = N'S'      -- O - P - Q - R - T - U
            INSERT INTO @Comp VALUES
                (1, N'Calculation', N'',  'Cash', N'O', NULL, 1, 0),
                (2, N'Calculation', N'-', 'Cash', N'P', NULL, 1, 0),
                (3, N'Calculation', N'-', 'Cash', N'Q', NULL, 1, 0),
                (4, N'Calculation', N'-', 'Cash', N'R', NULL, 1, 0),
                (5, N'Calculation', N'-', 'Cash', N'T', NULL, 1, 0),
                (6, N'Calculation', N'-', 'Cash', N'U', NULL, 1, 0),
                (9, N'Result',      N'=', 'Cash', N'S', NULL, 1, 1);
        ELSE                          -- V, W, X
        BEGIN
            IF @RowCodeU = N'W'
                INSERT INTO @Comp VALUES (1, N'Numerator', N'', 'Cash', N'P', NULL, 1, 0);
            ELSE
                INSERT INTO @Comp VALUES
                    (1, N'Numerator', N'',  'Cash', N'P', NULL, 1, 0),
                    (2, N'Numerator', N'+', 'Cash', N'T', NULL, 1, 0),
                    (4, N'Numerator', N'=', NULL, NULL, N'Total Payments ($)', 1, 1);

            IF @RowCodeU = N'V'
                INSERT INTO @Comp VALUES (11, N'Denominator', N'', 'PMS', N'F', NULL, 0, 0);
            ELSE IF @RowCodeU = N'W'
                INSERT INTO @Comp VALUES (11, N'Denominator', N'', 'PMS', N'H', NULL, 0, 0);
            ELSE
                INSERT INTO @Comp VALUES
                    (11, N'Denominator', N'',  'PMS', N'H',   NULL, 0, 0),
                    (12, N'Denominator', N'+', 'PMS', N'L',   NULL, 0, 0),
                    (13, N'Denominator', N'+', 'PMS', N'J',   NULL, 0, 0),
                    (14, N'Denominator', N'+', 'PMS', N'N.1', NULL, 0, 0),
                    (15, N'Denominator', N'+', 'PMS', N'N.2', NULL, 0, 0),
                    (19, N'Denominator', N'=', NULL, NULL, N'Adjudicated claims', 0, 1);

            INSERT INTO @Comp VALUES (29, N'Result', N'=', 'Avg', @RowCodeU, NULL, 1, 1);
        END;

        -- Year totals of count / $ rows = the sum of the month rows (the grid sums months);
        -- Avg rows have their own Year (month 0) and Grand Total (0, 0) rows.
        SELECT c.Seq, c.Section, c.Op, c.Category, c.RowCode, c.IsMoney, c.IsTotal,
               COALESCE(c.Label,
                        CASE WHEN c.Category = 'LIS' THEN N'LIS ' ELSE N'' END + LTRIM(RTRIM(d.Description))) AS Component,
               v.Value
        INTO #CellComp
        FROM @Comp c
        OUTER APPLY (SELECT TOP (1) e.Description
                     FROM #CellEs e
                     WHERE e.Category = c.Category AND e.RowCode = c.RowCode) d
        OUTER APPLY (SELECT SUM(e.MetricValue) AS Value
                     FROM #CellEs e
                     WHERE e.Category = c.Category AND e.RowCode = c.RowCode
                       AND e.BillYear = @Year
                       AND (   (@Year > 0 AND @Month = 0 AND c.Category <> 'Avg' AND e.BillMonth BETWEEN 1 AND 12)
                            OR ((@Year = 0 OR @Month > 0 OR c.Category = 'Avg') AND e.BillMonth = @Month))) v;

        -- Subtotal lines = sum of their section's components.
        UPDATE t SET Value = s.Total
        FROM #CellComp t
        CROSS APPLY (SELECT SUM(ISNULL(x.Value, 0)) AS Total
                     FROM #CellComp x
                     WHERE x.Section = t.Section AND x.IsTotal = 0) s
        WHERE t.IsTotal = 1 AND t.RowCode IS NULL;

        UPDATE #CellComp SET Value = ISNULL(Value, 0);

        DECLARE @Result DECIMAL(18,2) = ISNULL((SELECT Value FROM #CellComp WHERE Section = N'Result'), 0);
        DECLARE @Num DECIMAL(18,2) = ISNULL((SELECT SUM(Value) FROM #CellComp WHERE Section = N'Numerator'   AND IsTotal = 0), 0);
        DECLARE @Den DECIMAL(18,2) = ISNULL((SELECT SUM(Value) FROM #CellComp WHERE Section = N'Denominator' AND IsTotal = 0), 0);
        DECLARE @Calc NVARCHAR(1000);

        IF @RowCodeU IN (N'G', N'F.2', N'S')
        BEGIN
            SELECT @Calc = STRING_AGG(CAST(CASE WHEN Op = N'-' THEN N' - ' ELSE N'' END
                                           + CASE WHEN IsMoney = 1 THEN N'$' + FORMAT(Value, 'N2') ELSE FORMAT(Value, 'N0') END
                                           AS NVARCHAR(MAX)), N'') WITHIN GROUP (ORDER BY Seq)
            FROM #CellComp
            WHERE Section = N'Calculation';

            SET @Calc = @Calc + N' = ' + CASE WHEN @RowCodeU = N'S' THEN N'$' + FORMAT(@Result, 'N2') ELSE FORMAT(@Result, 'N0') END;

            IF @RowCodeU IN (N'G', N'F.2')
               AND (SELECT SUM(CASE WHEN Op = N'-' THEN -Value ELSE Value END) FROM #CellComp WHERE Section = N'Calculation') < 0
                SET @Calc = @Calc + N' (a negative difference is shown as 0)';
        END
        ELSE
            SET @Calc = N'$' + FORMAT(@Num, 'N2') + N' / ' + FORMAT(@Den, 'N0') + N' = $' + FORMAT(@Result, 'N2');

        INSERT INTO @Rules (RuleGroup, RuleText) VALUES (N'Calculation', @Calc);
        SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;

        SELECT CAST(NULL AS NVARCHAR(100)) AS SourceTable, N'Formula' AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
               0 AS TotalRows, @Result AS TotalAmount, CAST(1 AS BIT) AS IsFormula;

        SELECT Section, Op AS [Operator], Component, Category, RowCode, Value, IsMoney, IsTotal
        FROM #CellComp
        ORDER BY Seq;
        RETURN;
    END;

    /* ======================================================================
       Source rows (LIS samples / PMS-Cash claims)
       ====================================================================== */
    DECLARE @Skip INT = CASE WHEN @PageSize = 0 THEN 0 ELSE (@Page - 1) * @PageSize END;
    DECLARE @Take INT = CASE WHEN @PageSize = 0 THEN 2147483647 ELSE @PageSize END;
    DECLARE @Cols NVARCHAR(MAX), @Sql NVARCHAR(MAX), @W NVARCHAR(MAX) = N'';
    DECLARE @Lead TABLE (Ord INT NOT NULL, Name SYSNAME NOT NULL);

    -- Distinct counts: one row per Accession / ClaimID. Per month, except where the grid itself counts
    -- globally (claims Grand Total; LIS Grand Total with no page filter).
    DECLARE @PartCols NVARCHAR(100) =
        CASE WHEN @Year = 0 AND @Month = 0 AND (@IsLis = 0 OR @HasFilter = 0)
             THEN N'' ELSE N', YEAR(k.Es_Period), MONTH(k.Es_Period)' END;

    -- Dimension filter predicate (same CHARINDEX list match as usp_GetVarX_ExecutiveSummary).
    DECLARE @DimTpl NVARCHAR(MAX) =
        N' AND CHARINDEX((N'','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), {ALIAS}.{COL}), N''''))) + N'','') COLLATE DATABASE_DEFAULT, '
        + N'(N'','' + {PARAM} + N'','') COLLATE DATABASE_DEFAULT) > 0';

    DECLARE @ParamDef NVARCHAR(MAX) = N'@Year INT, @Month INT, @YearFrom INT, @YearTo INT, @MonthFrom INT, @MonthTo INT,
        @DosFrom DATE, @DosTo DATE, @BilledFrom DATE, @BilledTo DATE,
        @Panels NVARCHAR(MAX), @Clinics NVARCHAR(MAX), @Providers NVARCHAR(MAX), @Reps NVARCHAR(MAX),
        @Suffix NVARCHAR(420), @Measure NVARCHAR(200), @AmountCol NVARCHAR(100), @Skip INT, @Take INT';

    -- Clicked cell: Year / Month (0 = all).
    SET @W += N' AND (@Year = 0 OR YEAR(k.Es_Period) = @Year) AND (@Month = 0 OR MONTH(k.Es_Period) = @Month)';

    /* ---- LIS samples -------------------------------------------------------- */
    IF @IsLis = 1
    BEGIN
        IF @AccCol IS NULL OR @DateCol IS NULL OR @NewStatusCol IS NULL OR @BillCategoryCol IS NULL OR @LisPeriodCol IS NULL
        BEGIN
            INSERT INTO @Rules (RuleGroup, RuleText)
            VALUES (N'Warning', N'dbo.LIMSMaster (or its Accession / date / SampleStatus / BillCategory columns) was not found - no rows returned');
            SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;
            SELECT N'dbo.LIMSMaster' AS SourceTable, @Measure AS Measure, CAST(NULL AS NVARCHAR(100)) AS AmountColumn,
                   0 AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula;
            SELECT CAST(NULL AS NVARCHAR(100)) AS Accession WHERE 1 = 0;
            RETURN;
        END;

        -- Mode 1: aggregate re-summed by Year / Month / DOS month bounds.
        IF @LisMode = 1
            SET @W += N'
          AND (@YearFrom  IS NULL OR YEAR(k.Es_Period)  >= @YearFrom)
          AND (@YearTo    IS NULL OR YEAR(k.Es_Period)  <= @YearTo)
          AND (@MonthFrom IS NULL OR MONTH(k.Es_Period) >= @MonthFrom)
          AND (@MonthTo   IS NULL OR MONTH(k.Es_Period) <= @MonthTo)
          AND (@DosFrom IS NULL OR YEAR(k.Es_Period) > YEAR(@DosFrom)
                                OR (YEAR(k.Es_Period) = YEAR(@DosFrom) AND MONTH(k.Es_Period) >= MONTH(@DosFrom)))
          AND (@DosTo   IS NULL OR YEAR(k.Es_Period) < YEAR(@DosTo)
                                OR (YEAR(k.Es_Period) = YEAR(@DosTo)   AND MONTH(k.Es_Period) <= MONTH(@DosTo)))';

        -- Mode 2: live scan - billed-date bounds and dimension filters.
        IF @LisMode = 2
        BEGIN
            IF @ApplyBilled = 1
                SET @W += N'
          AND (@BilledFrom IS NULL OR k.Es_Period >= @BilledFrom)
          AND (@BilledTo   IS NULL OR k.Es_Period <= @BilledTo)';
            IF @HasPanel = 1 AND @PanelCol IS NOT NULL
                SET @W += REPLACE(REPLACE(REPLACE(@DimTpl, N'{ALIAS}', N'l'), N'{COL}', QUOTENAME(@PanelCol)), N'{PARAM}', N'@Panels');
            IF @HasClinic = 1 AND @ClinicCol IS NOT NULL
                SET @W += REPLACE(REPLACE(REPLACE(@DimTpl, N'{ALIAS}', N'l'), N'{COL}', QUOTENAME(@ClinicCol)), N'{PARAM}', N'@Clinics');
            IF @HasProvider = 1 AND @ProviderCol IS NOT NULL
                SET @W += REPLACE(REPLACE(REPLACE(@DimTpl, N'{ALIAS}', N'l'), N'{COL}', QUOTENAME(@ProviderCol)), N'{PARAM}', N'@Providers');
            IF @HasRep = 1 AND @RepCol IS NOT NULL
                SET @W += REPLACE(REPLACE(REPLACE(@DimTpl, N'{ALIAS}', N'l'), N'{COL}', QUOTENAME(@RepCol)), N'{PARAM}', N'@Reps');
        END;

        -- Row rule (file 19 RoleIDs).
        SET @W += CASE @Lm
            WHEN N'A'  THEN N''
            WHEN N'B'  THEN N' AND k.Es_Status = N''Billable'''
            WHEN N'BX' THEN N' AND k.Es_Status = N''Billable'' AND k.Es_TestType <> N'''' AND k.Es_TestType = @Suffix'
            WHEN N'C'  THEN N' AND k.Es_Status = N''Billable'' AND k.Es_BillCat = N''Billed'''
            WHEN N'D'  THEN N' AND k.Es_Status <> N''Billable'' AND k.Es_Status <> N'''''
            WHEN N'DX' THEN N' AND k.Es_Status <> N''Billable'' AND k.Es_Status <> N'''' AND k.Es_Status = @Suffix'
            ELSE N' AND 1 = 0' END;

        -- B.<TestType>: the live scan uses the Panel filter column (file 17), the aggregate the TestType column (file 19).
        DECLARE @SubCol SYSNAME = CASE WHEN @LisMode = 2 THEN @PanelCol ELSE @TestTypeCol END;

        SET @Sql = N'
SELECT x.*
INTO #CellL
FROM
(
    SELECT l.*, k.Es_Acc, k.Es_Period, k.Es_Status, k.Es_BillCat, k.Es_TestType,
           ROW_NUMBER() OVER (PARTITION BY k.Es_Acc' + @PartCols + N' ORDER BY k.Es_Period) AS Es_Rn
    FROM dbo.LIMSMaster l
    CROSS APPLY (SELECT
            NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), l.' + QUOTENAME(@AccCol) + N'))), N'''') AS Es_Acc,
            TRY_CAST(l.' + QUOTENAME(@LisPeriodCol) + N' AS DATE) AS Es_Period,
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.' + QUOTENAME(@NewStatusCol) + N'), N''''))) AS Es_Status,
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.' + QUOTENAME(@BillCategoryCol) + N'), N''''))) AS Es_BillCat,
            ' + CASE WHEN @SubCol IS NOT NULL
                     THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.' + QUOTENAME(@SubCol) + N'), N'''')))'
                     ELSE N'CAST(N'''' AS NVARCHAR(300))' END + N' AS Es_TestType) k
    WHERE k.Es_Acc IS NOT NULL AND k.Es_Period IS NOT NULL' + @W + N'
) x
WHERE x.Es_Rn = 1
OPTION (RECOMPILE);

SELECT N''dbo.LIMSMaster'' AS SourceTable, @Measure AS Measure, @AmountCol AS AmountColumn,
       COUNT(*) AS TotalRows, CAST(COUNT(*) AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula
FROM #CellL;
';

        -- Key columns first, then every other LIMSMaster column in table order.
        INSERT INTO @Lead (Ord, Name)
        SELECT MIN(v.Ord), v.Name
        FROM (VALUES (1, @AccCol), (2, @DateCol), (3, @BilledDateCol), (4, @NewStatusCol), (5, @BillCategoryCol),
                     (6, @ResultStatusCol), (7, @TestTypeCol), (8, @PanelCol), (9, @ClinicCol), (10, @ProviderCol),
                     (11, @RepCol), (12, N'PatientName'), (13, N'PayerName'), (14, N'PrimaryInsurance')) v(Ord, Name)
        WHERE v.Name IS NOT NULL
        GROUP BY v.Name;

        SELECT @Cols = STRING_AGG(CAST(QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ')
                       WITHIN GROUP (ORDER BY ISNULL(ld.Ord, 1000), c.column_id)
        FROM sys.columns c
        LEFT JOIN @Lead ld ON ld.Name = c.name COLLATE DATABASE_DEFAULT
        WHERE c.object_id = OBJECT_ID(N'dbo.LIMSMaster');

        SET @Sql += N'
SELECT ' + @Cols + N'
FROM #CellL
ORDER BY Es_Period, Es_Acc
OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;';

        SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;
        EXEC sys.sp_executesql @Sql, @ParamDef,
            @Year = @Year, @Month = @Month, @YearFrom = @YearFrom, @YearTo = @YearTo,
            @MonthFrom = @MonthFrom, @MonthTo = @MonthTo, @DosFrom = @DosFrom, @DosTo = @DosTo,
            @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
            @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps,
            @Suffix = @Suffix, @Measure = @Measure, @AmountCol = @AmountCol, @Skip = @Skip, @Take = @Take;
        RETURN;
    END;

    /* ---- Claims (PMS / Cash) ------------------------------------------------ */
    IF OBJECT_ID(N'dbo.ClaimLevelData', N'U') IS NULL
       OR COL_LENGTH(N'dbo.ClaimLevelData', N'ClaimID') IS NULL
       OR COL_LENGTH(N'dbo.ClaimLevelData', N'ClaimStatus') IS NULL
       OR COL_LENGTH(N'dbo.ClaimLevelData', @ClPeriodCol) IS NULL
       OR (@AmountCol IS NOT NULL AND COL_LENGTH(N'dbo.ClaimLevelData', @AmountCol) IS NULL)
    BEGIN
        INSERT INTO @Rules (RuleGroup, RuleText)
        VALUES (N'Warning', N'dbo.ClaimLevelData (or its ClaimID / ClaimStatus / ' + @ClPeriodCol + N' / amount columns) was not found - no rows returned');
        SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;
        SELECT N'dbo.ClaimLevelData' AS SourceTable, @Measure AS Measure, @AmountCol AS AmountColumn,
               0 AS TotalRows, CAST(0 AS DECIMAL(18,2)) AS TotalAmount, CAST(0 AS BIT) AS IsFormula;
        SELECT CAST(NULL AS NVARCHAR(100)) AS ClaimID WHERE 1 = 0;
        RETURN;
    END;

    CREATE TABLE #CellStatus (Val NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL);
    IF @Statuses IS NOT NULL
        INSERT INTO #CellStatus (Val)
        SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Statuses, N'|') WHERE LTRIM(RTRIM(value)) <> N'';

    -- Claim mode 1: DOS mode - Year / Month ranges and DOS bounds. Mode 2: Billed-date bounds.
    IF @ClaimMode = 1
        SET @W += N'
      AND (@YearFrom  IS NULL OR YEAR(k.Es_Period)  >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR(k.Es_Period)  <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(k.Es_Period) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(k.Es_Period) <= @MonthTo)
      AND (@DosFrom   IS NULL OR k.Es_Period >= @DosFrom)
      AND (@DosTo     IS NULL OR k.Es_Period <= @DosTo)';
    IF @ClaimMode = 2
        SET @W += N'
      AND (@BilledFrom IS NULL OR TRY_CAST(c.FirstBilledDate AS DATE) >= @BilledFrom)
      AND (@BilledTo   IS NULL OR TRY_CAST(c.FirstBilledDate AS DATE) <= @BilledTo)';
    IF @ClaimMode > 0
    BEGIN
        IF @HasPanel = 1 AND @ClPanelCol IS NOT NULL
            SET @W += REPLACE(REPLACE(REPLACE(@DimTpl, N'{ALIAS}', N'c'), N'{COL}', QUOTENAME(@ClPanelCol)), N'{PARAM}', N'@Panels');
        IF @HasClinic = 1 AND @ClClinicCol IS NOT NULL
            SET @W += REPLACE(REPLACE(REPLACE(@DimTpl, N'{ALIAS}', N'c'), N'{COL}', QUOTENAME(@ClClinicCol)), N'{PARAM}', N'@Clinics');
        IF @HasProvider = 1 AND @ClProviderCol IS NOT NULL
            SET @W += REPLACE(REPLACE(REPLACE(@DimTpl, N'{ALIAS}', N'c'), N'{COL}', QUOTENAME(@ClProviderCol)), N'{PARAM}', N'@Providers');
        IF @HasRep = 1 AND @ClRepCol IS NOT NULL
            SET @W += REPLACE(REPLACE(REPLACE(@DimTpl, N'{ALIAS}', N'c'), N'{COL}', QUOTENAME(@ClRepCol)), N'{PARAM}', N'@Reps');
    END;

    -- Row rule: ClaimStatus list (file 16).
    -- U.2 Partially Denied ($): InsuranceBalance where status is NOT Denied / Fully Denied / No Response.
    IF @RowCodeU = N'U.2'
        SET @W += N' AND k.Es_Status NOT IN (N''Denied'', N''Fully Denied'', N''No Response'')';
    ELSE IF @Statuses IS NOT NULL
        SET @W += N' AND k.Es_Status IN (SELECT Val FROM #CellStatus)';

    -- F1 / F3: AccessionNumber match against CoveLRN / local LIMSMaster.
    IF @RowCodeU = N'F.1'
    BEGIN
        IF DB_ID(N'CoveLRN') IS NULL OR OBJECT_ID(N'CoveLRN.dbo.LIMSMaster', N'U') IS NULL
            SET @W += N' AND 1 = 0';
        ELSE
            SET @W += N'
      AND NULLIF(LTRIM(RTRIM(c.AccessionNumber)), N'''') IS NOT NULL
      AND EXISTS (
            SELECT 1 FROM CoveLRN.dbo.LIMSMaster lm
            WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(300), lm.Accession))), N'''')
                  = NULLIF(LTRIM(RTRIM(c.AccessionNumber)), N'''') COLLATE DATABASE_DEFAULT)';
    END
    ELSE IF @RowCodeU = N'F.3'
    BEGIN
        IF OBJECT_ID(N'dbo.LIMSMaster', N'U') IS NULL OR COL_LENGTH(N'dbo.LIMSMaster', N'Accession') IS NULL
            SET @W += N' AND 1 = 0';
        ELSE
            SET @W += N'
      AND NULLIF(LTRIM(RTRIM(c.AccessionNumber)), N'''') IS NOT NULL
      AND EXISTS (
            SELECT 1 FROM dbo.LIMSMaster lm
            WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(300), lm.Accession))), N'''')
                  = NULLIF(LTRIM(RTRIM(c.AccessionNumber)), N'''') COLLATE DATABASE_DEFAULT)';
    END;

    SET @Sql = N'
SELECT x.*
INTO #CellC
FROM
(
    SELECT c.*, k.Es_ClaimKey, k.Es_Period, k.Es_Status, k.Es_Amount,
           ' + CASE WHEN @AmountCol IS NULL
                    THEN N'ROW_NUMBER() OVER (PARTITION BY k.Es_ClaimKey' + @PartCols + N' ORDER BY k.Es_Period)'
                    ELSE N'CAST(1 AS BIGINT)' END + N' AS Es_Rn
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
            NULLIF(LTRIM(RTRIM(c.[ClaimID])), N'''') AS Es_ClaimKey,
            TRY_CAST(c.' + QUOTENAME(@ClPeriodCol) + N' AS DATE) AS Es_Period,
            ISNULL(LTRIM(RTRIM(c.[ClaimStatus])), N'''') AS Es_Status,
            ' + CASE WHEN @AmountCol IS NULL THEN N'CAST(NULL AS DECIMAL(18,2))'
                     ELSE N'ISNULL(TRY_CAST(c.' + QUOTENAME(@AmountCol) + N' AS DECIMAL(18,2)), 0)' END + N' AS Es_Amount) k
    WHERE k.Es_ClaimKey IS NOT NULL AND k.Es_Period IS NOT NULL
      AND TRY_CAST(c.FirstBilledDate AS DATE) IS NOT NULL' + @W + N'
) x
WHERE x.Es_Rn = 1
OPTION (RECOMPILE);

SELECT N''dbo.ClaimLevelData'' AS SourceTable, @Measure AS Measure, @AmountCol AS AmountColumn,
       COUNT(*) AS TotalRows,
       CAST(CASE WHEN @AmountCol IS NULL THEN COUNT(*) ELSE ISNULL(SUM(Es_Amount), 0) END AS DECIMAL(18,2)) AS TotalAmount,
       CAST(0 AS BIT) AS IsFormula
FROM #CellC;
';

    -- Key columns first ($ rows lead with the measured Amount), then every other ClaimLevelData column in table order.
    INSERT INTO @Lead (Ord, Name) VALUES
        (1, N'ClaimID'), (2, N'AccessionNumber'), (3, N'DateofService'), (4, N'FirstBilledDate'),
        (5, N'BilledStatus'), (6, N'BillStatus'), (7, N'ClaimStatus'), (8, N'PayerName'), (9, N'PayerName_Raw'),
        (10, N'PayerType'), (11, N'Panelname'), (12, N'ClinicName'), (13, N'ReferringProvider'), (14, N'SalesRepname'),
        (15, N'ChargeAmount'), (16, N'InsurancePayment'), (17, N'PatientPayment'), (18, N'InsuranceBalance'),
        (19, N'PatientBalance'), (20, N'InsuranceAdjustments'), (21, N'PatientAdjustments');

    SELECT @Cols = STRING_AGG(CAST(QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY ISNULL(ld.Ord, 1000), c.column_id)
    FROM sys.columns c
    LEFT JOIN @Lead ld ON ld.Name = c.name COLLATE DATABASE_DEFAULT
    WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData');

    SET @Sql += N'
SELECT ' + CASE WHEN @AmountCol IS NULL THEN N'' ELSE N'Es_Amount AS Amount, ' END + @Cols + N'
FROM #CellC
ORDER BY Es_Period, Es_ClaimKey
OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;';

    SELECT RuleOrder, RuleGroup, RuleText FROM @Rules ORDER BY RuleOrder;
    EXEC sys.sp_executesql @Sql, @ParamDef,
        @Year = @Year, @Month = @Month, @YearFrom = @YearFrom, @YearTo = @YearTo,
        @MonthFrom = @MonthFrom, @MonthTo = @MonthTo, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
        @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps,
        @Suffix = @Suffix, @Measure = @Measure, @AmountCol = @AmountCol, @Skip = @Skip, @Take = @Take;
END;
GO

SET NOEXEC OFF;
GO

PRINT '37_VariantX_ExecutiveSummary_CellRows.sql completed.';
GO
