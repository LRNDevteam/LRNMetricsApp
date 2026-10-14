-- ============================================================
-- Inhealth – Executive Summary Read SP
-- File : 24_Inhealth_ExecutiveSummary_Read.sql
-- DB   : InHealthDTRLRN
-- PMS claim counts include blank/NULL AccessionNumber rows.
-- ============================================================

USE [InHealthDTRLRN]
GO
/****** Object:  StoredProcedure [dbo].[usp_GetInh_ExecutiveSummary]    Script Date: 7/3/2026 7:14:02 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   PROCEDURE [dbo].[usp_GetInh_ExecutiveSummary]
(
    @YearFrom     INT           = 0,
    @YearTo       INT           = 0,
    @MonthFrom    INT           = 0,
    @MonthTo      INT           = 0,
    @DosFrom      DATE          = NULL,
    @DosTo        DATE          = NULL,
    @BilledFrom   DATE          = NULL,
    @BilledTo     DATE          = NULL,
    @Panels       NVARCHAR(MAX) = NULL,
    @Clinics      NVARCHAR(MAX) = NULL,
    @Providers    NVARCHAR(MAX) = NULL,
    @Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @HasFilter BIT = CASE
        WHEN ISNULL(@YearFrom,  0) <> 0 THEN 1
        WHEN ISNULL(@YearTo,    0) <> 0 THEN 1
        WHEN ISNULL(@MonthFrom, 0) <> 0 THEN 1
        WHEN ISNULL(@MonthTo,   0) <> 0 THEN 1
        WHEN @DosFrom      IS NOT NULL THEN 1
        WHEN @DosTo        IS NOT NULL THEN 1
        WHEN @BilledFrom   IS NOT NULL THEN 1
        WHEN @BilledTo     IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL THEN 1
        ELSE 0
    END;
    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    --  NO FILTER  -  fast read from the 4 aggregate tables
    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    IF @HasFilter = 0
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
        FROM
        (
            SELECT RoleID AS RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue,
                   1 AS CatOrder, Id AS SortId
            FROM dbo.Inhealth_ES_LIS
            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
                   2, Id
            FROM dbo.Inhealth_ES_PMS
            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   3, Id
            FROM dbo.Inhealth_ES_Cash
            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   4, Id
            FROM dbo.Inhealth_ES_Avg
        ) x
        ORDER BY BillYear, BillMonth, CatOrder, SortId;
        RETURN;
    END
    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    --  FILTERED  -  live re-aggregation
    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    -- Dimension filter staging tables
    CREATE TABLE #FilterPanels   (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterClinics  (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterProviders(Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterReps     (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    IF NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL
        INSERT INTO #FilterPanels(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Panels, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL
        INSERT INTO #FilterClinics(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Clinics, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL
        INSERT INTO #FilterProviders(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Providers, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL
        INSERT INTO #FilterReps(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Reps, ',') WHERE LTRIM(RTRIM(value)) <> '';
    DECLARE @HasPanelFilter    BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterPanels)    THEN 1 ELSE 0 END;
    DECLARE @HasClinicFilter   BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterClinics)   THEN 1 ELSE 0 END;
    DECLARE @HasProviderFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterProviders) THEN 1 ELSE 0 END;
    DECLARE @HasRepFilter      BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterReps)      THEN 1 ELSE 0 END;
    -- LIS dimension filter: Panel, Clinic, and Provider apply to LIMSMaster for
    -- Inhealth (Panel->PanelType, Clinic->Account, Provider->LastName,FirstName).
    -- SalesRep is not available on LIMSMaster -> always skipped for LIS.
    DECLARE @HasLisFilter BIT = CASE
        WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
        THEN 1 ELSE 0 END;
    -- Period-bucket column choice for PMS/Cash/Avg:
    --   * If a FirstBilledDate range is selected (and no DateofService range),
    --     bucket the ClaimLevelData rows by FirstBilledDate.
    --   * Otherwise (DateofService range, or only dimension filters) bucket by
    --     DateofService â€” same default as usp_RefreshInh_ExecutiveSummary.
    -- The actual row filtering (DOS, FirstBilledDate, dimensions) is unchanged;
    -- this only decides which date drives the monthly split of the output.
    DECLARE @BucketByBilled BIT =
        CASE WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
                  AND @DosFrom IS NULL AND @DosTo IS NULL
             THEN 1 ELSE 0 END;
    -- â”€â”€ LIS: build #Lis from dbo.LIMSMaster.
    --    DateofService (Entry_DateCreated) and FirstBilledDate (BilledDate) ARE
    --    now applied to LIMSMaster, mirroring Cove's usp_GetCove_ExecutiveSummary
    --    (17_Cove_ExecutiveSummary_Read.sql): the period bucket (ESYear/ESMonth)
    --    and the date-range predicate both switch to BilledDate when
    --    @BucketByBilled = 1 (First Billed Date mode), otherwise both use
    --    Entry_DateCreated (DOS mode). This is independent of the PMS/Cash/Avg
    --    (#Base) section below â€” no cross-table bridge.
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        OrderID       NVARCHAR(100) NOT NULL,
        NAFlag        NVARCHAR(50)  NOT NULL,
        SampleStatus  NVARCHAR(200) NOT NULL,
        BillCategory  NVARCHAR(200) NOT NULL,
        SubStatus     NVARCHAR(200) NOT NULL,
        LRNPanelName  NVARCHAR(200) NOT NULL,
        ESYear        INT           NULL,
        ESMonth       INT           NULL
    );
    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        DECLARE @OrderIDCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('OrderID','OrderId','AccessionNumber','Accession','AccessionNo')
            ORDER BY CASE name WHEN 'OrderID' THEN 0 WHEN 'OrderId' THEN 1
                               WHEN 'AccessionNumber' THEN 2 WHEN 'Accession' THEN 3 WHEN 'AccessionNo' THEN 4 ELSE 5 END);
        DECLARE @NACol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('NA','IsNA','NotApplicable','NA_Flag','NAStatus')
            ORDER BY CASE name WHEN 'NA' THEN 0 WHEN 'IsNA' THEN 1 WHEN 'NotApplicable' THEN 2
                               WHEN 'NA_Flag' THEN 3 WHEN 'NAStatus' THEN 4 ELSE 5 END);
        -- DateofService for Inhealth maps to LIMSMaster.Entry_DateCreated (per spec).
        DECLARE @DateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('Entry_DateCreated','ReqCollectDate','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'Entry_DateCreated' THEN 0 WHEN 'ReqCollectDate' THEN 1 WHEN 'RequestCollectDate' THEN 2
                WHEN 'DateOfCollection' THEN 3 WHEN 'DateofService' THEN 4
                WHEN 'CollectionDate' THEN 5 WHEN 'ServiceDate' THEN 6 WHEN 'AccessionDate' THEN 7 ELSE 8 END);
        -- FirstBilledDate for Inhealth maps to LIMSMaster.BilledDate (per spec,
        -- same candidate list/priority as Cove's @BilledDateCol).
        DECLARE @BilledDateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BilledDate','FirstBilledDate','BilledOn','BillDate','FirstBillDate')
            ORDER BY CASE name
                WHEN 'BilledDate' THEN 0 WHEN 'FirstBilledDate' THEN 1
                WHEN 'BilledOn'   THEN 2 WHEN 'BillDate'        THEN 3
                WHEN 'FirstBillDate' THEN 4 ELSE 5 END);
        -- Period expression for #Lis.ESYear/ESMonth, mirrors Cove's @LisPeriodExpr:
        --   Billed mode (@BucketByBilled=1) -> BilledDate
        --   DOS mode (default)              -> Entry_DateCreated (@DateCol)
        DECLARE @LisPeriodExpr NVARCHAR(200) =
            CASE WHEN @BucketByBilled = 1 AND @BilledDateCol IS NOT NULL
                 THEN N'TRY_CAST([' + @BilledDateCol + N'] AS DATE)'
                 ELSE N'TRY_CAST([' + @DateCol + N'] AS DATE)' END;
        DECLARE @SampleStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('SampleStatus','BillTo','Sample_Status','SampleType')
            ORDER BY CASE name WHEN 'SampleStatus' THEN 0 WHEN 'BillTo' THEN 1 WHEN 'Sample_Status' THEN 2 WHEN 'SampleType' THEN 3 ELSE 4 END);
        DECLARE @BillCategoryCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillCategory','BillingStatus','Bill_Category','BillingCategory','BillStatus')
            ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'BillingStatus' THEN 1 WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3 WHEN 'BillStatus' THEN 4 ELSE 5 END);
        DECLARE @SubStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('SubStatus','FinalStatus','Sub_Status','ClientStatus')
            ORDER BY CASE name WHEN 'SubStatus' THEN 0 WHEN 'FinalStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);
        -- Panel for Inhealth maps to LIMSMaster.PanelType (per spec).
        DECLARE @PanelNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelType','LRNPanelName','LRN_PanelName','LRNPanel','PanelName','Panelname',
                           'PanelCategory','TestPanel','TestPanelName')
            ORDER BY CASE name
                WHEN 'PanelType'     THEN 0 WHEN 'LRNPanelName'  THEN 1 WHEN 'LRN_PanelName' THEN 2
                WHEN 'LRNPanel'      THEN 3 WHEN 'PanelName'     THEN 4 WHEN 'Panelname'     THEN 5
                WHEN 'PanelCategory' THEN 6 WHEN 'TestPanel'     THEN 7 WHEN 'TestPanelName' THEN 8 ELSE 9 END);
        -- ClinicName for Inhealth maps to LIMSMaster.Account (per spec).
        DECLARE @AccountCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('Account','ClinicName','Facility','FacilityName','Clinic')
            ORDER BY CASE name
                WHEN 'Account' THEN 0 WHEN 'ClinicName' THEN 1 WHEN 'Facility' THEN 2
                WHEN 'FacilityName' THEN 3 WHEN 'Clinic' THEN 4 ELSE 5 END);
        -- Provider name: two separate columns in Inhealth LIMSMaster.
        -- Both must be found for the provider filter to apply.
        DECLARE @ProvFirstNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ProviderFirstName','FirstName','ProvFirstName','PhysFirstName')
            ORDER BY CASE name
                WHEN 'ProviderFirstName' THEN 0 WHEN 'FirstName'   THEN 1
                WHEN 'ProvFirstName'     THEN 2 WHEN 'PhysFirstName' THEN 3 ELSE 4 END);
        DECLARE @ProvLastNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ProviderLastName','LastName','ProvLastName','PhysLastName')
            ORDER BY CASE name
                WHEN 'ProviderLastName' THEN 0 WHEN 'LastName'    THEN 1
                WHEN 'ProvLastName'     THEN 2 WHEN 'PhysLastName' THEN 3 ELSE 4 END);
        IF @OrderIDCol IS NOT NULL AND @DateCol IS NOT NULL AND @SampleStatusCol IS NOT NULL
           AND @BillCategoryCol IS NOT NULL AND @SubStatusCol IS NOT NULL
        BEGIN
            DECLARE @NAExpr       NVARCHAR(300) = CASE WHEN @NACol IS NOT NULL
                THEN N'ISNULL(CONVERT(NVARCHAR(50), [' + @NACol + N']), '''')'
                ELSE N'''''' END;
            DECLARE @PanelExpr    NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol + N']), '''')))'
                ELSE N'''''' END;
            -- DateofService (Entry_DateCreated) and FirstBilledDate (BilledDate) are
            -- now applied via @LisPeriodExpr for the period bucket, and as explicit
            -- range predicates below â€” mirrors Cove's usp_GetCove_ExecutiveSummary.
            -- Dimension filters (Panel, Clinic, Provider) ARE applied when
            -- @HasLisFilter = 1. SalesRep is not available for Inhealth LIS â†’ skipped.
            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (OrderID, NAFlag, SampleStatus, BillCategory, SubStatus, LRNPanelName, ESYear, ESMonth)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @OrderIDCol + N']))),
                    ' + @NAExpr + N',
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SampleStatusCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol + N']), ''''))),
                    ' + @PanelExpr + N',
                    YEAR (' + @LisPeriodExpr + N'),
                    MONTH(' + @LisPeriodExpr + N')
                FROM dbo.LIMSMaster
                WHERE ' + @LisPeriodExpr + N' IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @OrderIDCol + N']))), '''') IS NOT NULL';
            -- DateofService range â†’ Entry_DateCreated (@DateCol). Always appended;
            -- no-ops when @iDosFrom/@iDosTo are NULL (matches Cove's pattern).
            SET @LisSql += N'
                  AND (@iDosFrom IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) >= @iDosFrom)
                  AND (@iDosTo   IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) <= @iDosTo)';
            -- FirstBilledDate range â†’ BilledDate (@BilledDateCol), when the column exists.
            IF @BilledDateCol IS NOT NULL
                SET @LisSql += N'
                  AND (@iBilledFrom IS NULL OR TRY_CAST([' + @BilledDateCol + N'] AS DATE) >= @iBilledFrom)
                  AND (@iBilledTo   IS NULL OR TRY_CAST([' + @BilledDateCol + N'] AS DATE) <= @iBilledTo)';
            -- Apply LIS dimension filters when active.
            -- COLLATE DATABASE_DEFAULT on both sides of CHARINDEX prevents collation
            -- conflict errors when LIMSMaster columns have a different collation than
            -- the NVARCHAR(MAX) SP parameters.
            IF @HasLisFilter = 1
            BEGIN
                IF @HasPanelFilter = 1 AND @PanelNameCol IS NOT NULL
                    SET @LisSql += N'
                  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelNameCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iPanels + '','') COLLATE DATABASE_DEFAULT) > 0';
                -- Clinic: Account column, match against @iClinics.
                IF @HasClinicFilter = 1 AND @AccountCol IS NOT NULL
                    SET @LisSql += N'
                  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @AccountCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iClinics + '','') COLLATE DATABASE_DEFAULT) > 0';
                -- Provider: concatenate LastName + '','' + FirstName, match against @iProviders.
                -- This matches ClaimLevelData.ReferringProvider's "LastName,FirstName"
                -- format used by the filter dropdown and the PMS/Cash/Avg provider match.
                -- Both columns must exist; if either is missing the filter is skipped.
                IF @HasProviderFilter = 1 AND @ProvFirstNameCol IS NOT NULL AND @ProvLastNameCol IS NOT NULL
                    SET @LisSql += N'
                  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ProvLastNameCol + N']), '''') + '','' + ISNULL(CONVERT(NVARCHAR(200), [' + @ProvFirstNameCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iProviders + '','') COLLATE DATABASE_DEFAULT) > 0';
            END
            SET @LisSql += N';';
            EXEC sp_executesql @LisSql,
                N'@iPanels NVARCHAR(MAX), @iClinics NVARCHAR(MAX), @iProviders NVARCHAR(MAX),
                  @iDosFrom DATE, @iDosTo DATE, @iBilledFrom DATE, @iBilledTo DATE',
                @iPanels = @Panels, @iClinics = @Clinics, @iProviders = @Providers,
                @iDosFrom = @DosFrom, @iDosTo = @DosTo,
                @iBilledFrom = @BilledFrom, @iBilledTo = @BilledTo;
        END
    END
    -- â”€â”€ PMS/Cash/Avg: build #Base from dbo.ClaimLevelData, date-filtered â”€â”€â”€â”€â”€
    --    ESYear/ESMonth = the period bucket, taken from FirstBilledDate when a
    --    FirstBilledDate range drives the request, otherwise from DateofService.
    DROP TABLE IF EXISTS #Base;
    SELECT
        AccessionNumber,
        CASE WHEN @BucketByBilled = 1
             THEN YEAR (TRY_CAST(FirstBilledDate AS DATE))
             ELSE YEAR (TRY_CAST(DateofService   AS DATE)) END AS ESYear,
        CASE WHEN @BucketByBilled = 1
             THEN MONTH(TRY_CAST(FirstBilledDate AS DATE))
             ELSE MONTH(TRY_CAST(DateofService   AS DATE)) END AS ESMonth,
        ISNULL(LTRIM(RTRIM(BillStatus)),  '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND (ISNULL(@YearFrom,0)=0  OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
      AND (ISNULL(@YearTo,0)=0    OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
      AND (ISNULL(@MonthFrom,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
      AND (ISNULL(@MonthTo,0)=0   OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
      AND (@DosFrom    IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
      AND (@DosTo      IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
      AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
      AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
      -- Dimension matching uses comma-delimited TOKEN search (CHARINDEX) rather
      -- than STRING_SPLIT, because the values themselves can contain commas
      -- (e.g. ReferringProvider = 'LastName,FirstName' â†’ 'ABBOTT,JOEL').
      -- Splitting on ',' would shred those values; wrapping both the parameter
      -- and the column value in commas and substring-searching matches the
      -- whole value as a single token. CHARINDEX is used (not LIKE) so wildcard
      -- characters in the data are treated literally.
      AND (@HasPanelFilter    = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT,''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Panels    + ',') COLLATE DATABASE_DEFAULT) > 0)
      AND (@HasClinicFilter   = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Clinics   + ',') COLLATE DATABASE_DEFAULT) > 0)
      AND (@HasProviderFilter = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Providers + ',') COLLATE DATABASE_DEFAULT) > 0)
      AND (@HasRepFilter      = 0 OR CHARINDEX((',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) + ',') COLLATE DATABASE_DEFAULT, (',' + @Reps      + ',') COLLATE DATABASE_DEFAULT) > 0);
    -- â”€â”€ #Periods : distinct (ESYear, ESMonth) in #Base + (0,0) grand total â”€â”€
    --    Same period-split logic as usp_RefreshInh_ExecutiveSummary, but scoped
    --    to the selected/filtered range. When the range spans more than one
    --    month, multiple period rows are produced; a single month yields one.
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods
    FROM #Base
    WHERE ESYear IS NOT NULL AND ESMonth IS NOT NULL
    UNION ALL SELECT 0, 0;
    -- â”€â”€ #LisBilled : LIMSMaster BillCategory='Billed' counts per period
    --    (+ (0,0) grand total), used for PMS row G (Billed Mismatches).
    --    Mirrors usp_RefreshInh_ExecutiveSummary.
    DROP TABLE IF EXISTS #LisBilled;
    SELECT ESYear, ESMonth, COUNT(DISTINCT OrderID) AS BilledCount
    INTO #LisBilled
    FROM #Lis
    WHERE BillCategory = 'Billed' AND ESYear IS NOT NULL AND ESMonth IS NOT NULL
    GROUP BY ESYear, ESMonth
    UNION ALL
    SELECT 0, 0, COUNT(DISTINCT OrderID) FROM #Lis WHERE BillCategory = 'Billed';
    -- â”€â”€ #LisPeriods : distinct (ESYear, ESMonth) from #Lis + (0,0) grand total â”€
    --    LIS uses its own period table (from LIMSMaster's Entry_DateCreated /
    --    BilledDate, via @LisPeriodExpr) independent of #Periods (which comes
    --    from ClaimLevelData). #Lis is now date-filtered (DOS or FirstBilledDate,
    --    matching @BucketByBilled) at build time above, so only the months
    --    actually within the selected range are present here.
    DROP TABLE IF EXISTS #LisPeriods;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods
    FROM #Lis WHERE ESYear IS NOT NULL AND ESMonth IS NOT NULL
    UNION ALL SELECT 0, 0;
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  LIS  -  A, B, B1.{LRNPanelName}, C, C.1, D, D.1-D.6, E, E.1-E.7
    --  Split by period from #LisPeriods (mirrors how PMS uses #Periods).
    --  Grand total appears at ESYear=0, ESMonth=0.
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    ;WITH Lis AS
    (
        -- A  Total Samples (NA is blank/null).
        --    Matches the ACTUALLY DEPLOYED usp_RefreshInh_ExecutiveSummary_LIS_Alt
        --    (confirmed via OBJECT_DEFINITION): COUNT(CASE WHEN NAFlag='' OR NAFlag
        --    IS NULL ...). The "NA is not blank" condition previously here was
        --    inverted relative to production, which made Total Samples collapse to
        --    ~0 for any period once DOS filtering was correctly wired up to LIS.
        SELECT p.ESYear, p.ESMonth, 'A' AS RowCode, 'Total Samples' AS Description,
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'') = '' THEN l.OrderID END) AS DECIMAL(18,2)) AS MetricValue
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- B  Billable Samples
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- C  Billed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C', '  Billed',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Billed' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- C.1  Billed Via AMD
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C.1', '    Billed Via AMD',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Billed' AND l.SubStatus='Billed Via AMD' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- D  Unbilled
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D', '  Unbilled',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- D.1  Nexum_Claim_scrubber_Eligibility
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.1', '    Nexum_Claim_scrubber_Eligibility',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum_Claim_scrubber_Eligibility' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- D.2  Requires Review
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.2', '    Requires Review',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Requires Review' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- D.3  Entered in AMD but not billed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.3', '    Entered in AMD but not billed',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Entered in AMD but not billed' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- D.4  Nexum Pre Processing Queue
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.4', '    Nexum Pre Processing Queue',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum Pre Processing Queue' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- D.5  Nexum_Claim_scrubber_AMD Output
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.5', '    Nexum_Claim_scrubber_AMD Output',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum_Claim_scrubber_AMD Output' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- D.6  Nexum_Claim_scrubber_Diagnosis Validity
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D.6', '    Nexum_Claim_scrubber_Diagnosis Validity',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum_Claim_scrubber_Diagnosis Validity' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- E  Other Samples
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E', 'Other Samples',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- E.1  Billed (Other Samples + BillCategory=Billed)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.1', '  Billed',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples' AND l.BillCategory='Billed' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- E.2  Unbilled (Other Samples + BillCategory=Not Billed)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.2', '  Unbilled',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples' AND l.BillCategory='Not Billed' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- E.3  Other Samples (LIS Table provides Breakdown) - label row
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.3', '  Other Samples (LIS Table provides Breakdown)',
               CAST(0 AS DECIMAL(18,2))
        FROM #LisPeriods p
        GROUP BY p.ESYear, p.ESMonth
        -- E.4  Self Pay
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.4', '  Self Pay',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Self Pay' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- E.5  Deleted/Rejected
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.5', '  Deleted/Rejected',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Deleted/Rejected' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- E.6  Duplicate
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.6', '  Duplicate',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Duplicate' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- E.7  System Test
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E.7', '  System Test',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='System Test' THEN l.OrderID END) AS DECIMAL(18,2))
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ),
    -- Dynamic panel sub-rows under B (B1.{LRNPanelName}), split by period
    LisPanels AS
    (
        SELECT p.ESYear, p.ESMonth,
               'B1.' + pn.LRNPanelName AS RowCode,
               '    ' + pn.LRNPanelName AS Description,
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                        AND l.LRNPanelName = pn.LRNPanelName THEN l.OrderID END) AS DECIMAL(18,2)) AS MetricValue
        FROM #LisPeriods p
        CROSS JOIN (
            SELECT DISTINCT LRNPanelName FROM #Lis
            WHERE NULLIF(LRNPanelName, '') IS NOT NULL
              AND ISNULL(NAFlag,'') = '' AND SampleStatus = 'Billable'
        ) pn
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, pn.LRNPanelName
    ),
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  PMS  -  F, G, H, H.1, H.2, I, J, K, L, M, N, O, O.1, O.2, O.3
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    PMS AS
    (
        -- F  No. of Billed Claims
        SELECT p.ESYear, p.ESMonth, 'F' AS RowCode, 'No. of Billed Claims' AS Description,
               CAST(SUM(CASE WHEN b.BillStatus='Billed' THEN 1 ELSE 0 END) AS DECIMAL(18,2)) AS MetricValue
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- G  Billed Mismatches (PMS Billed Count - LIS BillCategory='Billed' Count)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G', 'Billed Mismatches',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
               - CAST(ISNULL(lb.BilledCount, 0) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        LEFT JOIN #LisBilled lb ON lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth
        GROUP BY p.ESYear, p.ESMonth, lb.BilledCount
        -- H  No. of UnBilled Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'No. of UnBilled Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Unbilled' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- H.1  Unbilled
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.1', '  Unbilled',
               CAST(SUM(CASE WHEN b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- H.2  Unbilled - Patient Balance
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.2', '  Unbilled - Patient Balance',
               CAST(SUM(CASE WHEN b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled - Patient Balance' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- I  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'No. of Fully Paid Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- J  No. of Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'No. of Patient Responsibility Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Patient Responsibility' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- K  No. of Fully Adjusted Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'No. of Fully Adjusted Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Complete W/O' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- L  No. of Partially Adjusted Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'L', 'No. of Partially Adjusted Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Partially Adjusted' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- M  No. of Patient Payments Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Patient Payments Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Patient Payment' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- N  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Paid Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Partially Paid' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- O  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Insurance Balance Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus IN ('FullyDenied','Partially Denied','No Response') THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- O.1  No. of Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.1', '  No. of Denied Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='FullyDenied' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- O.2  No. of Partially Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.2', '  No. of Partially Denied Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Partially Denied' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- O.3  No. of No Response from Payor Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.3', '  No. of No Response from Payor Claims',
               CAST(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='No Response' THEN 1 ELSE 0 END) AS DECIMAL(18,2))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ),
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  Cash  -  P, Q, Q.1, Q.2, R, S, T, U, V, W, W.1, W.2, W.3
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    Cash AS
    (
        -- P  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'P' AS RowCode, 'Total Billed ($)' AS Description,
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' THEN b.ChargeAmount ELSE 0 END), 0) AS MetricValue
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Q  Total Unbilled ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q', 'Total Unbilled ($)',
               ISNULL(SUM(CASE WHEN b.BillStatus='Unbilled' THEN b.ChargeAmount ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Q.1  Unbilled
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q.1', '  Unbilled',
               ISNULL(SUM(CASE WHEN b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled' THEN b.ChargeAmount ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Q.2  Unbilled - Patient Balance
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q.2', '  Unbilled - Patient Balance',
               ISNULL(SUM(CASE WHEN b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled - Patient Balance' THEN b.ChargeAmount ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- R  Insurance Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'Insurance Payment ($)',
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid' THEN b.InsurancePayment ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- S  Patient Payments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S', 'Patient Payments ($)',
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' THEN b.PatientPayment ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- T  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T', 'Partially Paid ($)',
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Partially Paid' THEN b.InsurancePayment ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- U  Patient Responsibility ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Patient Responsibility ($)',
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' THEN b.PatientBalance ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- V  Total Adjustments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Total Adjustments ($)',
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' THEN ISNULL(b.InsuranceAdjustments,0) + ISNULL(b.PatientAdjustments,0) ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- W  Insurance Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Insurance Balance ($)',
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' THEN b.InsuranceBalance ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- W.1  Denials
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W.1', '  Denials',
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='FullyDenied' THEN b.InsuranceBalance ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- W.2  Partially Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W.2', '  Partially Denied',
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Partially Denied' THEN b.InsuranceBalance ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- W.3  No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W.3', '  No Response from Payor',
               ISNULL(SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='No Response' THEN b.InsuranceBalance ELSE 0 END), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ),
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  Avg  -  X, Y, Z
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    AvgRows AS
    (
        -- X  Average Payment ($) - Total Pay/Billed Claims
        SELECT p.ESYear, p.ESMonth, 'X' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               CASE WHEN SUM(CASE WHEN b.BillStatus='Billed' THEN 1 ELSE 0 END) > 0
                    THEN SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus IN ('Fully Paid','Partially Paid')
                                  THEN b.InsurancePayment ELSE 0 END)
                         / SUM(CASE WHEN b.BillStatus='Billed' THEN 1 ELSE 0 END)
                    ELSE 0 END AS MetricValue
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Y  Average Payment ($) - Fully Paid Claim Value/Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Y', 'Average Payment ($) - Fully Paid Claim Value/Paid Claims',
               CASE WHEN SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid' THEN 1 ELSE 0 END) > 0
                    THEN SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid' THEN b.InsurancePayment ELSE 0 END)
                         / SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid' THEN 1 ELSE 0 END)
                    ELSE 0 END
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
        -- Z  Average Payment ($) - Total Pay/Adjudicated Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z', 'Average Payment ($) - Total Pay/Adjudicated Claims',
               CASE WHEN SUM(CASE WHEN b.BillStatus='Billed'
                                             AND b.ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                                                 'Partially Paid','Patient Payment','FullyDenied','Partially Denied')
                                             THEN 1 ELSE 0 END) > 0
                    THEN SUM(CASE WHEN b.BillStatus='Billed'
                                  AND b.ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                                      'Partially Paid','Patient Payment','FullyDenied','Partially Denied')
                                  THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
                         / SUM(CASE WHEN b.BillStatus='Billed'
                                               AND b.ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                                                   'Partially Paid','Patient Payment','FullyDenied','Partially Denied')
                                               THEN 1 ELSE 0 END)
                    ELSE 0 END
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    )
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM
    (
        -- LIS rows are split per month from #LisPeriods (ESYear/ESMonth) + grand total (0,0)
        SELECT RowCode, 'LIS'  AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth, MetricValue, 1 AS CatOrder FROM Lis
        UNION ALL
        SELECT RowCode, 'LIS',  Description, ESYear AS BillYear, ESMonth AS BillMonth, MetricValue, 1 FROM LisPanels
        -- PMS / Cash / Avg are split per month (ESYear/ESMonth) + grand total (0,0)
        UNION ALL
        SELECT RowCode, 'PMS',  Description, ESYear, ESMonth, MetricValue, 2 FROM PMS
        UNION ALL
        SELECT RowCode, 'Cash', Description, ESYear, ESMonth, MetricValue, 3 FROM Cash
        UNION ALL
        SELECT RowCode, 'Avg',  Description, ESYear, ESMonth, MetricValue, 4 FROM AvgRows
    ) result
    ORDER BY BillYear, BillMonth, CatOrder, RowCode;
    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #LisPeriods;
    DROP TABLE IF EXISTS #LisBilled;
    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
END;

Select Count(AccessionNumber) from ClaimLevelData where BillStatus='Billed'
and Month(DateofService)=6 and year(DateofService)=2026 -- count is 1246 but when apply the filter and the SP result is 888.. ?
</user_query>