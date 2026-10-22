-- ============================================================
-- Augustus - Executive Summary LIS Breakdown: client logic sheet
-- File : 35_Augustus_ExecutiveSummary_LIS_ClientLogic.sql
-- DB   : Augustus_LRN
--
-- Billable = BillTo 'Insurance Bills' / 'Insurance Bill'. Counts are LIMSMaster rows
-- with a valid RequestCollectDate (same basis as the LIS Summary page).
--
-- LIS Breakdown
--   A    Total Samples
--   B    Billable Samples
--     B1.<PanelName>   one row per LIMSMaster.PanelName (was PanelType)
--   C    Billed                          BillingStatus = Billed
--     C.1  Claim Submitted in IRCM         FinalStatus = Claim Submitted in IRCM
--     C.2  Claim Submitted in Daqbilling   FinalStatus = Claim Submitted in Daqbilling
--     C.3  Claim Submitted in Altumed      FinalStatus = Claim Submitted in Altumed
--   D    Unbilled                        BillingStatus = Unbilled
--     D.1  Insurance name not listed       FinalStatus = Insurance name not listed
--     D.2  Resulted yet to be Billed       FinalStatus = Resulted yet to be Billed
--     D.3  Charges Entered in Altumed      FinalStatus = Charges Entered in Altumed
--   E    Other Samples                   BillTo not Insurance Bills / Insurance Bill
--   Removed: Ready to bill, Yet to be Validated, Client Bills, System Test, Self pay (+ their Billed rows).
--
-- PMS:  F.3 No. of Claims Billed in Altumed.
-- Cash (FirstBilledDate = a date):
--   U  Patient Responsibility = SUM(PatientBalance); U.1 IRCM, U.2 Daqbilling, U.3 Altumed (by Source)
--   X  Insurance Balance      = SUM(InsuranceBalance), ClaimStatus <> Billed amount 0
--     X.1 Fully Denied, X.2 Partially Denied (not Fully Denied / No Response / Billed amount 0), X.3 No Response
--   V  Adjustment amount      = P - R - S - T - U - X
-- Avg:  AA denominator adds N (Partially Adjusted); Year Total rows (ESMonth = 0) are ratios of the year's sums.
-- Filtered path: Daq / Altumed claims (no AccessionNumber) are no longer dropped.
--
-- 1. usp_RefreshAug_ExecutiveSummary_LIS_Alt  - rebuilds dbo.Augustus_ES_LIS (unfiltered page).
-- 2. usp_GetAug_ExecutiveSummary_v2           - reads the snapshot tables; same rules on the filtered path.
-- 3. usp_RefreshAug_ExecutiveSummary          - PMS / Cash / Avg snapshot (run by ClaimLineCSVDataCapture).
-- 4. dbo.LisDrillRowDef (LabPrefix 'Aug')     - drill filters for the LIS and Cash rows.
-- 5. Runs both refreshes.
-- Re-run: safe.
-- ============================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 'B1.' + PanelName is up to 55 characters; RoleID was NVARCHAR(50).
IF COL_LENGTH('dbo.Augustus_ES_LIS', 'RoleID') < 800
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Augustus_ES_LIS') AND name = 'IX_Augustus_ES_LIS_Period')
        DROP INDEX IX_Augustus_ES_LIS_Period ON dbo.Augustus_ES_LIS;
    ALTER TABLE dbo.Augustus_ES_LIS ALTER COLUMN RoleID NVARCHAR(400) NOT NULL;
    CREATE NONCLUSTERED INDEX IX_Augustus_ES_LIS_Period ON dbo.Augustus_ES_LIS (ESYear, ESMonth, RoleID);
    PRINT 'Augustus_ES_LIS.RoleID widened to NVARCHAR(400).';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        PRINT 'usp_RefreshAug_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
        RETURN;
    END

    DROP TABLE IF EXISTS #Lis;
    SELECT
        ESYear        = YEAR (d.CollectDate),
        ESMonth       = MONTH(d.CollectDate),
        IsBillable    = CASE WHEN LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), m.BillTo), N'')))
                                  IN (N'Insurance Bills', N'Insurance Bill') THEN 1 ELSE 0 END,
        BillingStatus = LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), m.BillingStatus), N''))),
        FinalStatus   = LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), m.FinalStatus),   N''))),
        PanelName     = LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(380), m.PanelName),     N'')))
    INTO #Lis
    FROM dbo.LIMSMaster m
    CROSS APPLY (SELECT TRY_CAST(m.RequestCollectDate AS DATE) AS CollectDate) d
    WHERE d.CollectDate IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), m.Accession))), N'') IS NOT NULL;

    -- Row list in display order (panel rows sit between B and B2.1).
    DROP TABLE IF EXISTS #Def;
    CREATE TABLE #Def (SortId INT NOT NULL, RoleID NVARCHAR(400) NOT NULL, Description NVARCHAR(400) NOT NULL);
    INSERT INTO #Def (SortId, RoleID, Description) VALUES
        (1,    N'A',      N'Total Samples'),
        (2,    N'B',      N'Billable Samples'),
        (1001, N'C',   N'Billed'),
        (1002, N'C.1', N'  Claim Submitted in IRCM'),
        (1003, N'C.2', N'  Claim Submitted in Daqbilling'),
        (1004, N'C.3', N'  Claim Submitted in Altumed'),
        (1005, N'D',   N'Unbilled'),
        (1006, N'D.1', N'  Insurance name not listed'),
        (1007, N'D.2', N'  Resulted yet to be Billed'),
        (1008, N'D.3', N'  Charges Entered in Altumed'),
        (1009, N'E',   N'Other Samples');
    INSERT INTO #Def (SortId, RoleID, Description)
    SELECT 2 + ROW_NUMBER() OVER (ORDER BY PanelName), N'B1.' + PanelName, N'  ' + PanelName
    FROM (SELECT DISTINCT PanelName FROM #Lis WHERE IsBillable = 1 AND PanelName <> N'') p;

    DROP TABLE IF EXISTS #Counts;
    SELECT h.RoleID,
           ESYear  = CASE WHEN GROUPING(l.ESYear)  = 1 THEN 0 ELSE l.ESYear  END,
           ESMonth = CASE WHEN GROUPING(l.ESMonth) = 1 THEN 0 ELSE l.ESMonth END,
           Cnt     = COUNT(*)
    INTO #Counts
    FROM #Lis l
    CROSS APPLY (
        SELECT N'A'
        UNION ALL SELECT N'B'      WHERE l.IsBillable = 1
        UNION ALL SELECT N'B1.' + l.PanelName WHERE l.IsBillable = 1 AND l.PanelName <> N''
        UNION ALL SELECT N'C'   WHERE l.IsBillable = 1 AND l.BillingStatus = N'Billed'
        UNION ALL SELECT N'C.1' WHERE l.IsBillable = 1 AND l.BillingStatus = N'Billed'   AND l.FinalStatus = N'Claim Submitted in IRCM'
        UNION ALL SELECT N'C.2' WHERE l.IsBillable = 1 AND l.BillingStatus = N'Billed'   AND l.FinalStatus = N'Claim Submitted in Daqbilling'
        UNION ALL SELECT N'C.3' WHERE l.IsBillable = 1 AND l.BillingStatus = N'Billed'   AND l.FinalStatus = N'Claim Submitted in Altumed'
        UNION ALL SELECT N'D'   WHERE l.IsBillable = 1 AND l.BillingStatus = N'Unbilled'
        UNION ALL SELECT N'D.1' WHERE l.IsBillable = 1 AND l.BillingStatus = N'Unbilled' AND l.FinalStatus = N'Insurance name not listed'
        UNION ALL SELECT N'D.2' WHERE l.IsBillable = 1 AND l.BillingStatus = N'Unbilled' AND l.FinalStatus = N'Resulted yet to be Billed'
        UNION ALL SELECT N'D.3' WHERE l.IsBillable = 1 AND l.BillingStatus = N'Unbilled' AND l.FinalStatus = N'Charges Entered in Altumed'
        UNION ALL SELECT N'E'   WHERE l.IsBillable = 0
    ) h(RoleID)
    GROUP BY GROUPING SETS ((h.RoleID, l.ESYear, l.ESMonth), (h.RoleID));

    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Lis
    UNION SELECT 0, 0;

    BEGIN TRANSACTION;
        TRUNCATE TABLE dbo.Augustus_ES_LIS;
        INSERT INTO dbo.Augustus_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
        SELECT d.RoleID, d.Description, p.ESYear, p.ESMonth, ISNULL(c.Cnt, 0), 0, GETDATE()
        FROM #Def d
        CROSS JOIN #Periods p
        LEFT JOIN #Counts c ON c.RoleID = d.RoleID AND c.ESYear = p.ESYear AND c.ESMonth = p.ESMonth
        ORDER BY d.SortId, p.ESYear, p.ESMonth;
    COMMIT TRANSACTION;

    PRINT 'usp_RefreshAug_ExecutiveSummary_LIS_Alt completed (client logic: PanelName rows, Altumed rows, Other Samples).';
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAug_ExecutiveSummary_v2
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
            FROM dbo.Augustus_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
                   2, Id
            FROM dbo.Augustus_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   3, Id
            FROM dbo.Augustus_ES_Cash

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   4, Id
            FROM dbo.Augustus_ES_Avg
        ) x
        ORDER BY BillYear, BillMonth, CatOrder, SortId;

        RETURN;
    END

    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    --  FILTERED  -  live re-aggregation with month-wise breakdown
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

    -- Date mode: DOS vs FirstBilledDate are mutually exclusive in the UI (same
    -- convention as Cove/Elixir/RisingTides). @UseBilledDate = 1 â†’ FirstBilledDate
    -- filter is active (@BilledFrom/@BilledTo set, @DosFrom/@DosTo NULL) â€” LIS and
    -- PMS/Cash/Avg period basis switches from ReqCollectDate/DateofService to
    -- FirstBilledDate. @UseBilledDate = 0 â†’ DOS mode (or no date filter).
    DECLARE @UseBilledDate BIT = CASE
        WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
         AND  @DosFrom IS NULL AND @DosTo IS NULL
        THEN 1 ELSE 0 END;

    -- @HasDosFilter: 1 only when the user explicitly set a DOS range. Used below
    -- to decide whether #Base may fall back to FirstBilledDate for rows with no
    -- parseable DateofService â€” that fallback must NOT apply when an explicit DOS
    -- range was requested (a row without a real DateofService can't legitimately
    -- match a DOS range), but SHOULD apply when browsing with no date filter at
    -- all (e.g. only a Clinic/Provider/Panel/Rep filter), so that claims billed
    -- via FirstBilledDate but missing DateofService aren't silently dropped from
    -- every PMS/Cash/Avg row.
    DECLARE @HasDosFilter BIT = CASE WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1 ELSE 0 END;

    -- @HasLisFilter: 1 when any filter that applies to LIMSMaster is active.
    -- DOS date range (@DosFrom/@DosTo) applied via ReqCollectDate; FirstBilledDate
    -- range (@BilledFrom/@BilledTo, @UseBilledDate=1) applied via LIMSMaster's
    -- FirstBilledDate column. Provider filter now applied via
    -- DoctorLastName + ', ' + DoctorFirstName (see @LisProviderExpr below).
    -- SalesRep is not tracked in LIMSMaster for Augustus, so a Rep-only filter
    -- must NOT trigger a full LIMSMaster scan; the aggregate table is used instead.
    DECLARE @HasLisFilter BIT = CASE WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
                                       OR @DosFrom IS NOT NULL OR @DosTo IS NOT NULL
                                       OR @UseBilledDate = 1
                                       THEN 1 ELSE 0 END;

    -- â”€â”€ LIS: build #Lis from dbo.LIMSMaster, date-filtered on ReqCollectDate â”€â”€
    -- BillYear/BillMonth added so the filtered path produces month-wise rows.
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession     NVARCHAR(100) NOT NULL,
        BillTo        NVARCHAR(200) NOT NULL,
        BillingStatus NVARCHAR(200) NOT NULL,
        FinalStatus   NVARCHAR(200) NOT NULL,
        ClientStatus1 NVARCHAR(200) NOT NULL,
        PanelType     NVARCHAR(200) NOT NULL,
        BillYear      INT           NOT NULL,
        BillMonth     INT           NOT NULL
    );

    IF @HasLisFilter = 1 AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        DECLARE @AccCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('AccessionNumber','Accession','AccessionNo')
            ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

        DECLARE @DateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ReqCollectDate','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'ReqCollectDate' THEN 0 WHEN 'RequestCollectDate' THEN 1
                WHEN 'DateOfCollection' THEN 2 WHEN 'DateofService' THEN 3
                WHEN 'CollectionDate' THEN 4 WHEN 'ServiceDate' THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

        DECLARE @BillToCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillTo','BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
            ORDER BY CASE name WHEN 'BillTo' THEN 0 WHEN 'BillCategory' THEN 1 WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3 WHEN 'BilledorNot' THEN 4 WHEN 'BillStatus' THEN 5 ELSE 6 END);

        DECLARE @BillingStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillingStatus','NewStatus','Status','BillStatus')
            ORDER BY CASE name WHEN 'BillingStatus' THEN 0 WHEN 'NewStatus' THEN 1 WHEN 'Status' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

        DECLARE @FinalStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('FinalStatus','SubStatus','Sub_Status','ClientStatus')
            ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'SubStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);

        DECLARE @ClientStatus1Col SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClientStatus1','ClientStatus','ClientStatus2','ClientFlag')
            ORDER BY CASE name WHEN 'ClientStatus1' THEN 0 WHEN 'ClientStatus' THEN 1 WHEN 'ClientStatus2' THEN 2 WHEN 'ClientFlag' THEN 3 ELSE 4 END);

        -- LIS dimension filter columns â€” Augustus-specific mappings:
        --   Panels    -> PanelName (priority 0), then PanelType, PanelCategory ...
        --   Clinics   -> ClinicName
        --   Providers -> DoctorLastName + ', ' + DoctorFirstName (concatenated;
        --                matches the "LastName, FirstName" format used elsewhere)
        --   SalesRep  -> not available on LIMSMaster for Augustus
        DECLARE @LisPanelTypeCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelName','Panelname','PanelType','PanelCategory','TestPanel','Panel')
            ORDER BY CASE name
                WHEN 'PanelName'     THEN 0
                WHEN 'Panelname'     THEN 1
                WHEN 'PanelType'     THEN 2
                WHEN 'PanelCategory' THEN 3
                ELSE 4 END);

        DECLARE @LisClinicNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClinicName','Clinic','FacilityName','Facility')
            ORDER BY CASE name
                WHEN 'ClinicName' THEN 0 WHEN 'Clinic' THEN 1 WHEN 'FacilityName' THEN 2 ELSE 3 END);

        -- Referring Provider: fixed column pair (DoctorLastName, DoctorFirstName) â€”
        -- concatenated as 'LastName, FirstName' to match the Provider filter's format.
        DECLARE @LisDoctorLastNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'DoctorLastName');

        DECLARE @LisDoctorFirstNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'DoctorFirstName');

        -- FirstBilledDate: fixed column name on LIMSMaster (same name as ClaimLevelData's).
        DECLARE @LisBilledDateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'FirstBilledDate');

        IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @BillToCol IS NOT NULL AND @BillingStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        BEGIN
            DECLARE @CS1Expr NVARCHAR(400) = CASE WHEN @ClientStatus1Col IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientStatus1Col + N']), '''')))'
                ELSE N'''''' END;

            DECLARE @PanelTypeExpr NVARCHAR(400) = CASE WHEN @LisPanelTypeCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @LisPanelTypeCol + N']), '''')))'
                ELSE N'''''' END;

            DECLARE @LisProviderExpr NVARCHAR(500) = CASE WHEN @LisDoctorLastNameCol IS NOT NULL AND @LisDoctorFirstNameCol IS NOT NULL
                THEN N'(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @LisDoctorLastNameCol + N']), ''''))) + '', '' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @LisDoctorFirstNameCol + N']), ''''))))'
                ELSE NULL END;

            -- LIS period basis:
            --   DOS mode (default)   â†’ TRY_CAST([<ReqCollectDate col>] AS DATE)
            --   FirstBilledDate mode â†’ TRY_CAST([FirstBilledDate] AS DATE)
            DECLARE @LisPeriodExpr NVARCHAR(200) =
                CASE WHEN @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
                     THEN N'TRY_CAST([' + @LisBilledDateCol + N'] AS DATE)'
                     ELSE N'TRY_CAST([' + @DateCol + N'] AS DATE)' END;

            -- Dimension filters applied: Panelsâ†’PanelType, Clinicsâ†’ClinicName,
            -- Providersâ†’DoctorLastName+', '+DoctorFirstName. SalesRep not applied to LIS.
            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (Accession, BillTo, BillingStatus, FinalStatus, ClientStatus1, PanelType, BillYear, BillMonth)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
                    ' + @CS1Expr + N',
                    ' + @PanelTypeExpr + N',
                    ISNULL(YEAR (' + @LisPeriodExpr + N'), 0),
                    ISNULL(MONTH(' + @LisPeriodExpr + N'), 0)
                FROM dbo.LIMSMaster
                WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL';

            -- Date predicate: DOS mode filters/bounds on @DateCol (ReqCollectDate);
            -- FirstBilledDate mode filters/bounds on FirstBilledDate.
            IF @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iBilledFrom IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) >= @iBilledFrom)
                  AND (@iBilledTo   IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) <= @iBilledTo)';
            ELSE
                SET @LisSql = @LisSql + N'
                  AND (@iDosFrom IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) >= @iDosFrom)
                  AND (@iDosTo   IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) <= @iDosTo)';

            -- Panel filter: Panels -> PanelName
            IF @LisPanelTypeCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasPanelFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisPanelTypeCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iPanels + '','') > 0)';

            -- Clinic filter: Clinics â†’ ClinicName
            IF @LisClinicNameCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasClinicFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisClinicNameCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iClinics + '','') > 0)';

            -- Provider filter: Providers â†’ DoctorLastName + ', ' + DoctorFirstName
            IF @LisProviderExpr IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasProviderFilter = 0 OR CHARINDEX('','' + ' + @LisProviderExpr + N' COLLATE DATABASE_DEFAULT + '','', '','' + @iProviders + '','') > 0)';

            SET @LisSql = @LisSql + N';';

            EXEC sp_executesql @LisSql,
                N'@iHasPanelFilter    BIT,           @iPanels    NVARCHAR(MAX),
                  @iHasClinicFilter   BIT,           @iClinics   NVARCHAR(MAX),
                  @iHasProviderFilter BIT,           @iProviders NVARCHAR(MAX),
                  @iDosFrom DATE, @iDosTo DATE, @iBilledFrom DATE, @iBilledTo DATE',
                @iHasPanelFilter    = @HasPanelFilter,    @iPanels    = @Panels,
                @iHasClinicFilter   = @HasClinicFilter,   @iClinics   = @Clinics,
                @iHasProviderFilter = @HasProviderFilter, @iProviders = @Providers,
                @iDosFrom = @DosFrom, @iDosTo = @DosTo, @iBilledFrom = @BilledFrom, @iBilledTo = @BilledTo;
        END
    END

    -- â”€â”€ PMS/Cash/Avg: build #Base from dbo.ClaimLevelData, date-filtered â”€â”€â”€â”€
    -- BillYear/BillMonth added so the filtered path produces month-wise rows.
    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        AccessionNumber      NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        BillYear             INT           NOT NULL,
        BillMonth            INT           NOT NULL,
        BillStatus           NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus          NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        Source               NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        FirstBilledDate      DATE          NULL,
        ChargeAmount         DECIMAL(18,2) NOT NULL,
        InsurancePayment     DECIMAL(18,2) NOT NULL,
        PatientPayment       DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL
    );

    -- PMS/Cash/Avg period basis now follows the same DOS vs FirstBilledDate mode as
    -- LIS (@UseBilledDate). Previously BillYear/BillMonth were ALWAYS derived from
    -- DateofService even when filtering by FirstBilledDate â€” a claim billed within
    -- the selected FirstBilledDate range but with an out-of-range DateofService
    -- still got bucketed under its (unrelated) DOS year/month, showing under the
    -- wrong "DATA BASED ON BILLED DATE" column (same bug fixed for RisingTides).
    -- Fixed by branching the period expression + date bound on @UseBilledDate,
    -- mirroring Cove/Elixir/RisingTides' #Base construction.
    IF @UseBilledDate = 0
    BEGIN
        INSERT INTO #Base (AccessionNumber, BillYear, BillMonth, BillStatus, ClaimStatus, Source, FirstBilledDate,
                            ChargeAmount, InsurancePayment, PatientPayment,
                            InsuranceAdjustments, PatientAdjustments,
                            InsuranceBalance, PatientBalance)
        SELECT
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), CONVERT(NVARCHAR(100), ClaimID)),  -- Daq / Altumed claims carry no AccessionNumber
            -- Period bucket: DateofService when it's parseable; when it's not AND
            -- no explicit DOS range was requested (@HasDosFilter=0), fall back to
            -- FirstBilledDate so the row isn't lost from every PMS/Cash/Avg row.
            ISNULL(YEAR (COALESCE(TRY_CAST(DateofService AS DATE),
                                   CASE WHEN @HasDosFilter = 0 THEN TRY_CAST(FirstBilledDate AS DATE) END)), 0),
            ISNULL(MONTH(COALESCE(TRY_CAST(DateofService AS DATE),
                                   CASE WHEN @HasDosFilter = 0 THEN TRY_CAST(FirstBilledDate AS DATE) END)), 0),
            ISNULL(LTRIM(RTRIM(BillingStatus)),  ''),
            ISNULL(LTRIM(RTRIM(ClaimStatus)),    ''),
            ISNULL(LTRIM(RTRIM(Source)),         ''),
            TRY_CAST(FirstBilledDate AS DATE),
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
        FROM dbo.ClaimLevelData
        -- Base gate: a row qualifies if DateofService is parseable (as before), OR
        -- â€” only when no explicit DOS range was requested â€” if FirstBilledDate is
        -- parseable. Without this OR, a claim with a valid FirstBilledDate but a
        -- blank/unparseable DateofService was silently excluded from #Base
        -- entirely whenever any non-date filter (Clinic, Provider, Panel, Rep) was
        -- applied with no date range set, undercounting Row F/F.1/F.2/G (and every
        -- other PMS/Cash/Avg row) relative to a raw ClaimLevelData count.
        WHERE (
                TRY_CAST(DateofService AS DATE) IS NOT NULL
                OR (@HasDosFilter = 0 AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL)
              )
          AND (ISNULL(@YearFrom,0)=0  OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
          AND (ISNULL(@YearTo,0)=0    OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
          AND (ISNULL(@MonthFrom,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
          AND (ISNULL(@MonthTo,0)=0   OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
          AND (@DosFrom    IS NULL OR TRY_CAST(DateofService AS DATE) >= @DosFrom)
          AND (@DosTo      IS NULL OR TRY_CAST(DateofService AS DATE) <= @DosTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(Panelname,         ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Panels + ',') > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Clinics + ',') > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Providers + ',') > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Reps + ',') > 0);
    END
    ELSE  -- @UseBilledDate = 1 : period + filter on FirstBilledDate
    BEGIN
        -- NOTE: FirstBilledDate must be included here (it was previously omitted
        -- from this branch's column/select list, which left #Base.FirstBilledDate
        -- NULL for every row in Billed-Date mode â€” even though every row here, by
        -- definition of the WHERE clause below, has a non-null FirstBilledDate in
        -- the selected range). That gap made PMS row F "No. of Billed Claims"
        -- always read 0 and row G "No. of Unbilled Claims" always read the full
        -- claim count when filtering by Billed Date.
        INSERT INTO #Base (AccessionNumber, BillYear, BillMonth, BillStatus, ClaimStatus, Source, FirstBilledDate,
                            ChargeAmount, InsurancePayment, PatientPayment,
                            InsuranceAdjustments, PatientAdjustments,
                            InsuranceBalance, PatientBalance)
        SELECT
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), CONVERT(NVARCHAR(100), ClaimID)),  -- Daq / Altumed claims carry no AccessionNumber
            ISNULL(YEAR (TRY_CAST(FirstBilledDate AS DATE)), 0),
            ISNULL(MONTH(TRY_CAST(FirstBilledDate AS DATE)), 0),
            ISNULL(LTRIM(RTRIM(BillingStatus)),  ''),
            ISNULL(LTRIM(RTRIM(ClaimStatus)),    ''),
            ISNULL(LTRIM(RTRIM(Source)),         ''),
            TRY_CAST(FirstBilledDate AS DATE),
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
          AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(Panelname,         ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Panels + ',') > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Clinics + ',') > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Providers + ',') > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Reps + ',') > 0)
        OPTION (RECOMPILE);
    END

    -- â”€â”€ Populate #LisOut: aggregate (fast path) or live from #Lis (filtered path) â”€â”€
    -- When @HasLisFilter = 0 (SalesRep-only filter), LIMSMaster was not scanned
    -- above; LIS rows are served from the pre-built aggregate to stay responsive.
    DROP TABLE IF EXISTS #LisOut;
    CREATE TABLE #LisOut
    (
        RowCode     NVARCHAR(420) NOT NULL,
        Description NVARCHAR(420) NOT NULL,
        BillYear    INT           NOT NULL,
        BillMonth   INT           NOT NULL,
        MetricValue DECIMAL(18,2) NOT NULL
    );

    IF @HasLisFilter = 0
    BEGIN
        -- No LIS-applicable filter â€” serve directly from aggregate (fast)
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
        FROM dbo.Augustus_ES_LIS;
    END
    ELSE
    BEGIN
        -- LIS-applicable filter(s) active - build from #Lis (live LIMSMaster data).
        -- Same rows and rules as usp_RefreshAug_ExecutiveSummary_LIS_Alt.
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT h.RowCode, MAX(h.Description), l.BillYear, l.BillMonth, CAST(COUNT(*) AS DECIMAL(18,2))
        FROM #Lis l
        CROSS APPLY (SELECT CASE WHEN l.BillTo IN (N'Insurance Bills', N'Insurance Bill') THEN 1 ELSE 0 END AS IsBillable) b
        CROSS APPLY (
            SELECT N'A', N'Total Samples'
            UNION ALL SELECT N'B',      N'Billable Samples'                  WHERE b.IsBillable = 1
            UNION ALL SELECT N'B1.' + LTRIM(RTRIM(l.PanelType)), N'  ' + LTRIM(RTRIM(l.PanelType))
                                                                            WHERE b.IsBillable = 1 AND LTRIM(RTRIM(l.PanelType)) <> N''
            UNION ALL SELECT N'C',   N'Billed'                          WHERE b.IsBillable = 1 AND l.BillingStatus = N'Billed'
            UNION ALL SELECT N'C.1', N'  Claim Submitted in IRCM'       WHERE b.IsBillable = 1 AND l.BillingStatus = N'Billed'   AND l.FinalStatus = N'Claim Submitted in IRCM'
            UNION ALL SELECT N'C.2', N'  Claim Submitted in Daqbilling' WHERE b.IsBillable = 1 AND l.BillingStatus = N'Billed'   AND l.FinalStatus = N'Claim Submitted in Daqbilling'
            UNION ALL SELECT N'C.3', N'  Claim Submitted in Altumed'    WHERE b.IsBillable = 1 AND l.BillingStatus = N'Billed'   AND l.FinalStatus = N'Claim Submitted in Altumed'
            UNION ALL SELECT N'D',   N'Unbilled'                        WHERE b.IsBillable = 1 AND l.BillingStatus = N'Unbilled'
            UNION ALL SELECT N'D.1', N'  Insurance name not listed'     WHERE b.IsBillable = 1 AND l.BillingStatus = N'Unbilled' AND l.FinalStatus = N'Insurance name not listed'
            UNION ALL SELECT N'D.2', N'  Resulted yet to be Billed'     WHERE b.IsBillable = 1 AND l.BillingStatus = N'Unbilled' AND l.FinalStatus = N'Resulted yet to be Billed'
            UNION ALL SELECT N'D.3', N'  Charges Entered in Altumed'    WHERE b.IsBillable = 1 AND l.BillingStatus = N'Unbilled' AND l.FinalStatus = N'Charges Entered in Altumed'
            UNION ALL SELECT N'E',   N'Other Samples'                   WHERE b.IsBillable = 0
        ) h(RowCode, Description)
        GROUP BY h.RowCode, l.BillYear, l.BillMonth;

        -- Keep every fixed row on the grid when the filter leaves it empty.
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT d.RowCode, d.Description, p.BillYear, p.BillMonth, 0
        FROM (VALUES (N'A', N'Total Samples'), (N'B', N'Billable Samples'),
                     (N'C', N'Billed'), (N'C.1', N'  Claim Submitted in IRCM'),
                     (N'C.2', N'  Claim Submitted in Daqbilling'), (N'C.3', N'  Claim Submitted in Altumed'),
                     (N'D', N'Unbilled'), (N'D.1', N'  Insurance name not listed'),
                     (N'D.2', N'  Resulted yet to be Billed'), (N'D.3', N'  Charges Entered in Altumed'),
                     (N'E', N'Other Samples')) d(RowCode, Description)
        CROSS JOIN (SELECT DISTINCT BillYear, BillMonth FROM #Lis) p
        WHERE NOT EXISTS (SELECT 1 FROM #LisOut o
                          WHERE o.RowCode = d.RowCode AND o.BillYear = p.BillYear AND o.BillMonth = p.BillMonth);
    END

    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  PMS  -  F, F.1, F.2, G, H, I, J, K, L, M, N, O, O.1, O.2, O.3
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    ;WITH PMS AS
    (
        -- F/F.1/F.2/G determine Billed vs Unbilled from whether FirstBilledDate is
        -- populated (native DATE column on #Base) rather than the BillStatus text
        -- field. IS NOT NULL / IS NULL is used directly instead of comparing to ''
        -- (which would force an implicit, fragile empty-string-to-DATE conversion).
        SELECT 'F' AS RowCode, 'No. of Billed Claims' AS Description, BillYear, BillMonth,
               CAST(COUNT(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2)) AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'F.1', '  No. of Claims Billed in IRCM', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' AND Source='IRCM' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'F.2', '  No. of Claims Billed in Daq Billing', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' AND Source='Daq' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'F.3', '  No. of Claims Billed in Altumed', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' AND Source='Altumed' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'G', 'No. of Unbilled Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN FirstBilledDate IS NULL AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'H', 'Client bill claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'I', 'No. of Fully Paid Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'J', 'No. of Patient Paid Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Patient paid' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'K', 'No. of Patient Responsibility Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Pat Responsibility' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'L', 'No. of Partially Paid Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Partial Paid' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'M', 'No. of Adjusted/Written Off Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Fully Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'N', 'No. of Partially Adjusted/Written Off Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Partially Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O', 'No. of Insurance Balance Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied','No Response') THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O.1', '  No. of Fully Denied Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Fully Denied' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O.2', '  No. of Partially Denied Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Partially Denied' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O.3', '  No. of No Response from Payor', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='No Response' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
    ),
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  Cash  -  P, P.1, P.2, Q, R, S, T, U, U.1, U.2, V, W, X, X.1, X.2, X.3
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    Cash AS
    (
        SELECT 'P' AS RowCode, 'Total Billed ($)' AS Description, BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' THEN ChargeAmount ELSE 0 END) AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'P.1', '  Total Charge of Claims Billed (IRCM)', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' AND Source='IRCM' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'P.2', '  Total Charge of Claims Billed (Daq)', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' AND Source='Daq' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'Q', 'Total Unbilled ($)', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NULL AND ClaimStatus<>'Billed amount 0' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'R', 'Insurance Payment ($)', BillYear, BillMonth,
               SUM(CASE WHEN InsurancePayment > 0 AND ClaimStatus='Fully Paid' THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'S', 'Partially Paid ($)', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus='Partial Paid' THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'T', 'Patient Paid ($)', BillYear, BillMonth,
               SUM(CASE WHEN PatientPayment > 0 THEN PatientPayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U', 'Patient Responsibility ($)', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U.1', '  IRCM', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND Source='IRCM' THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U.2', '  Daqbilling', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND Source='Daq' THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U.3', '  Altumed', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND Source='Altumed' THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        -- V = P - R - S - T - U - X (Total Billed - Insurance Payment - Partially Paid - Patient Paid
        --     - Patient Responsibility - Insurance Balance).
        SELECT 'V', 'Adjustment amount ($)', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' THEN ChargeAmount ELSE 0 END)
             - SUM(CASE WHEN InsurancePayment > 0 AND ClaimStatus='Fully Paid' THEN InsurancePayment ELSE 0 END)
             - SUM(CASE WHEN ClaimStatus='Partial Paid' THEN InsurancePayment ELSE 0 END)
             - SUM(CASE WHEN PatientPayment > 0 THEN PatientPayment ELSE 0 END)
             - SUM(CASE WHEN FirstBilledDate IS NOT NULL THEN PatientBalance ELSE 0 END)
             - SUM(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'W', 'Total Payments ($) - Insurance', BillYear, BillMonth,
               SUM(CASE WHEN InsurancePayment > 0 THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X', 'Insurance Balance ($)', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X.1', '  Fully Denied', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus='Fully Denied' THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X.2', '  Partially Denied', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus NOT IN ('Fully Denied','No Response','Billed amount 0') THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X.3', '  No Response from Payor', BillYear, BillMonth,
               SUM(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus='No Response' THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
    ),
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  Avg  -  Y, Z, AA
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    -- Y  = W / F                                (Total Payments Insurance / No. of Billed Claims)
    -- Z  = W / I                                (Total Payments Insurance / No. of Fully Paid Claims)
    -- AA = (W + T) / (I+J+K+L+M+N+O.1+O.2)      (+ Patient Paid / adjudicated claims)
    -- Month, year (BillMonth = 0) and grand total (0,0) rows are each a ratio of their own sums.
    AvgBase AS
    (
        SELECT
            BillYear  = CASE WHEN GROUPING(BillYear)  = 1 THEN 0 ELSE BillYear  END,
            BillMonth = CASE WHEN GROUPING(BillMonth) = 1 THEN 0 ELSE BillMonth END,
            W   = SUM(CASE WHEN InsurancePayment > 0 THEN InsurancePayment ELSE 0 END),
            T   = SUM(CASE WHEN PatientPayment   > 0 THEN PatientPayment   ELSE 0 END),
            F   = COUNT(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' THEN 1 END),
            I   = COUNT(CASE WHEN ClaimStatus = 'Fully Paid' THEN 1 END),
            Adj = COUNT(CASE WHEN ClaimStatus IN ('Fully Paid','Patient paid','Pat Responsibility','Partial Paid',
                                                  'Fully Adjusted','Partially Adjusted','Fully Denied','Partially Denied') THEN 1 END)
        FROM #Base
        GROUP BY GROUPING SETS ((BillYear, BillMonth), (BillYear), ())
        HAVING NOT (GROUPING(BillYear) = 0 AND BillYear = 0)
    ),
    AvgRows AS
    (
        SELECT 'Y' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description, BillYear, BillMonth,
               CAST(CASE WHEN F > 0 THEN W / F ELSE 0 END AS DECIMAL(18,2)) AS MetricValue
        FROM AvgBase
        UNION ALL
        SELECT 'Z', 'Average Payment ($) - Total Pay/Paid Claims', BillYear, BillMonth,
               CAST(CASE WHEN I > 0 THEN W / I ELSE 0 END AS DECIMAL(18,2))
        FROM AvgBase
        UNION ALL
        SELECT 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims', BillYear, BillMonth,
               CAST(CASE WHEN Adj > 0 THEN (W + T) / Adj ELSE 0 END AS DECIMAL(18,2))
        FROM AvgBase
    )
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM
    (
        SELECT RowCode, 'LIS'  AS Category, Description, BillYear, BillMonth, MetricValue, 1 AS CatOrder FROM #LisOut
        UNION ALL
        SELECT RowCode, 'PMS',  Description, BillYear, BillMonth, MetricValue, 2 FROM PMS
        UNION ALL
        SELECT RowCode, 'Cash', Description, BillYear, BillMonth, MetricValue, 3 FROM Cash
        UNION ALL
        SELECT RowCode, 'Avg',  Description, BillYear, BillMonth, MetricValue, 4 FROM AvgRows
    ) result
    ORDER BY BillYear, BillMonth, CatOrder, RowCode;

    DROP TABLE IF EXISTS #LisOut;
    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #Base;
END;
GO

-- PMS: add F.3 No. of Claims Billed in Altumed (live refresh run by ClaimLineCSVDataCapture).
CREATE OR ALTER PROCEDURE [dbo].[usp_RefreshAug_ExecutiveSummary]
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Augustus_ES_PMS;
    TRUNCATE TABLE dbo.Augustus_ES_Cash;
    TRUNCATE TABLE dbo.Augustus_ES_Avg;

    -- -- #Base : one row per ClaimLevelData record with period bucket -------
    DROP TABLE IF EXISTS #Base;

    SELECT
        ClaimID,
        AccessionNumber,
        YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
        ISNULL(LTRIM(RTRIM(BillingStatus)),  '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Source)), '')        AS Source,
        ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), FirstBilledDate))), '') AS FirstBilledDate,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData;
    -- NOTE: DateofService / AccessionNumber filters intentionally removed
    -- so all ClaimLevelData rows (including those with no service date) are counted.
    -- Records with no DateofService land in ESYear=NULL/ESMonth=NULL and are
    -- excluded from period breakdowns but included in the (0,0) grand total.

    -- -- DEBUG: #Base row counts ----------------------------------------------
    DECLARE @n INT;
    SELECT @n = COUNT(*) FROM #Base;
    PRINT '>> #Base total rows: ' + CAST(@n AS VARCHAR);

    SELECT @n = COUNT(*) FROM #Base WHERE Source = 'Daq';
    PRINT '>> #Base Source=Daq total: ' + CAST(@n AS VARCHAR);

    SELECT @n = COUNT(*) FROM #Base WHERE Source = 'Daq' AND FirstBilledDate <> '';
    PRINT '>> #Base Source=Daq AND FirstBilledDate<> : ' + CAST(@n AS VARCHAR);

    SELECT @n = COUNT(*) FROM #Base WHERE Source = 'Daq' AND FirstBilledDate <> '' AND ClaimStatus <> 'Billed amount 0';
    PRINT '>> #Base Source=Daq AND FirstBilledDate<> AND ClaimStatus<>Billed amount 0: ' + CAST(@n AS VARCHAR);

    -- COUNT vs COUNT(DISTINCT) on ClaimID
    SELECT @n = COUNT(ClaimID) FROM #Base WHERE Source = 'Daq' AND FirstBilledDate <> '' AND ClaimStatus <> 'Billed amount 0';
    PRINT '>> COUNT(ClaimID)          Daq: ' + CAST(@n AS VARCHAR);

    SELECT @n = COUNT(DISTINCT ClaimID) FROM #Base WHERE Source = 'Daq' AND FirstBilledDate <> '' AND ClaimStatus <> 'Billed amount 0';
    PRINT '>> COUNT(DISTINCT ClaimID) Daq: ' + CAST(@n AS VARCHAR);
    -- -- END DEBUG ------------------------------------------------------------

    -- -- #Periods : distinct (ESYear, ESMonth) + (0,0) grand-total sentinel --
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
    WHERE ESYear IS NOT NULL AND ESMonth IS NOT NULL  -- exclude NULL-period rows (no DateofService)
    UNION ALL SELECT 0, 0;

    -- -- #LisBilled : LIMSMaster BillingStatus='Billed' counts per
    --    RequestCollectDate period, used for PMS row 'G' (Unbilled Mismatches).
    --    Augustus uses RequestCollectDate as the date column in LIMSMaster.
    DROP TABLE IF EXISTS #LisBilled;
    CREATE TABLE #LisBilled (ESYear INT NOT NULL, ESMonth INT NOT NULL, BilledCount INT NOT NULL);

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        -- Per-period rows (RequestCollectDate ? ESYear / ESMonth)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT
            YEAR (TRY_CAST(RequestCollectDate AS DATE)),
            MONTH(TRY_CAST(RequestCollectDate AS DATE)),
            COUNT(DISTINCT Accession)
        FROM dbo.LIMSMaster
        WHERE BillingStatus = 'Billed'
          AND TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL
        GROUP BY
            YEAR (TRY_CAST(RequestCollectDate AS DATE)),
            MONTH(TRY_CAST(RequestCollectDate AS DATE));

        -- Grand-total sentinel (ESYear=0, ESMonth=0)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT 0, 0, COUNT(DISTINCT Accession)
        FROM dbo.LIMSMaster
        WHERE BillingStatus = 'Billed'
          AND TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL;
    END

    -- --------------------------------------------------------------------
    --  Augustus_ES_PMS  -  F, F.1, F.2, G, H, I, J, K, L, M, N, O, O.1, O.2, O.3
    -- --------------------------------------------------------------------
    INSERT INTO dbo.Augustus_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- F  No. of Billed Claims
        SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'No. of Billed Claims' AS Description,
               COUNT(DISTINCT b.ClaimID) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.FirstBilledDate <> ''
                          AND b.ClaimStatus <> 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- F.1  No. of Claims Billed in IRCM
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'F.1', '  No. of Claims Billed in IRCM',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.FirstBilledDate <> ''
                          AND b.ClaimStatus <> 'Billed amount 0'
                          AND b.Source = 'IRCM'
        GROUP BY p.ESYear, p.ESMonth

        -- F.2  No. of Claims Billed in Daq Billing
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'F.2', '  No. of Claims Billed in Daq Billing',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.FirstBilledDate <> ''
                          AND b.ClaimStatus <> 'Billed amount 0'
                          AND b.Source = 'Daq'
        GROUP BY p.ESYear, p.ESMonth

        -- F.3  No. of Claims Billed in Altumed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'F.3', '  No. of Claims Billed in Altumed',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.FirstBilledDate <> ''
                          AND b.ClaimStatus <> 'Billed amount 0'
                          AND b.Source = 'Altumed'
        GROUP BY p.ESYear, p.ESMonth

        -- G  No. of Unbilled Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G', 'No. of Unbilled Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.FirstBilledDate = ''
                          AND b.ClaimStatus <> 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- H  Client bill claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'Client bill claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- I  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'No. of Fully Paid Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- J  No. of Patient Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'No. of Patient Paid Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Patient paid'
        GROUP BY p.ESYear, p.ESMonth

        -- K  No. of Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'No. of Patient Responsibility Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Pat Responsibility'
        GROUP BY p.ESYear, p.ESMonth

        -- L  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'L', 'No. of Partially Paid Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partial Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- M  No. of Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Adjusted/Written Off Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Partially Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Adjusted/Written Off Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- O  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Insurance Balance Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response')
        GROUP BY p.ESYear, p.ESMonth

        -- O.1  No. of Fully Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.1', '  No. of Fully Denied Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- O.2  No. of Partially Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.2', '  No. of Partially Denied Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- O.3  No. of No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.3', '  No. of No Response from Payor',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'No Response'
        GROUP BY p.ESYear, p.ESMonth
    ) pms;

    -- --------------------------------------------------------------------
    --  Augustus_ES_Cash  -  P, P.1, P.2, Q, R, S, T, U, U.1, U.2, V, W, X, X.1, X.2, X.3
    -- --------------------------------------------------------------------
    INSERT INTO dbo.Augustus_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeAmount, GETDATE()
    FROM
    (
        -- P  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'P' AS RoleID, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus<>'Billed amount 0' THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.1  Total Charge of Claims Billed in IRCM
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.1', '  Total Charge of Claims Billed (IRCM)',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.2  Total Charge of Claims Billed in Daq
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.2', '  Total Charge of Claims Billed (Daq)',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q  Total Unbilled ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q', 'Total Unbilled ($)',
               SUM(CASE WHEN b.FirstBilledDate = '' AND b.ClaimStatus<>'Billed amount 0' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- R  Insurance Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'Insurance Payment ($)',
               SUM(CASE WHEN b.InsurancePayment > 0 AND b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S', 'Partially Paid ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Partial Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- T  Patient Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T', 'Patient Paid ($)',
               SUM(CASE WHEN b.PatientPayment > 0 THEN b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U  Patient Responsibility ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Patient Responsibility ($)',
             -- SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.PatientBalance ELSE 0 END)
			  --SUM(CASE WHEN b.ClaimStatus  IN ('Unbilled') THEN b.PatientBalance ELSE 0 END)
			   --SUM(CASE WHEN b.BillStatus  IN ('Billed') THEN b.PatientBalance ELSE 0 END)
			   SUM(CASE WHEN b.FirstBilledDate <> '' THEN b.PatientBalance ELSE 0 END)
			   

        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.1  IRCM
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.1', '  IRCM',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.Source='IRCM' THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.2  Daqbilling
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.2', '  Daqbilling',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.Source='Daq' THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.3  Altumed
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.3', '  Altumed',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.Source='Altumed' THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- V  Adjustment amount ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Adjustment amount ($)',
               SUM(ISNULL(b.InsuranceAdjustments, 0) + ISNULL(b.PatientAdjustments, 0))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W  Total Payments ($) - Insurance
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Total Payments ($) - Insurance',
               SUM(CASE WHEN b.InsurancePayment > 0 THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X  Insurance Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X', 'Insurance Balance ($)',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus <> 'Billed amount 0' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.1  Fully Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.1', '  Fully Denied',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus = 'Fully Denied' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.2  Partially Denied (every other status except Fully Denied, No Response, Billed amount 0)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.2', '  Partially Denied',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus NOT IN ('Fully Denied','No Response','Billed amount 0') THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.3  No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.3', '  No Response from Payor',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus = 'No Response' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) cash;

    -- V  Adjustment amount ($) = P - R - S - T - U - X
    UPDATE v
    SET ESMonthChargeAmount = ISNULL(c.P, 0) - ISNULL(c.R, 0) - ISNULL(c.S, 0)
                            - ISNULL(c.T, 0) - ISNULL(c.U, 0) - ISNULL(c.X, 0)
    FROM dbo.Augustus_ES_Cash v
    JOIN (
        SELECT ESYear, ESMonth,
               P = SUM(CASE WHEN RoleID = 'P' THEN ESMonthChargeAmount END),
               R = SUM(CASE WHEN RoleID = 'R' THEN ESMonthChargeAmount END),
               S = SUM(CASE WHEN RoleID = 'S' THEN ESMonthChargeAmount END),
               T = SUM(CASE WHEN RoleID = 'T' THEN ESMonthChargeAmount END),
               U = SUM(CASE WHEN RoleID = 'U' THEN ESMonthChargeAmount END),
               X = SUM(CASE WHEN RoleID = 'X' THEN ESMonthChargeAmount END)
        FROM dbo.Augustus_ES_Cash
        GROUP BY ESYear, ESMonth
    ) c ON c.ESYear = v.ESYear AND c.ESMonth = v.ESMonth
    WHERE v.RoleID = 'V';


	
    -- --------------------------------------------------------------------
    --  Augustus_ES_Avg  -  Y, Z, AA
    --  Fetches numerator ($) from Augustus_ES_Cash and
    --  denominator (counts) from Augustus_ES_PMS already populated above.
    --
    --  Y  = W (Total Payments Insurance $)        / F  (No. of Billed Claims)
    --  Z  = W (Total Payments Insurance $)        / I  (No. of Fully Paid Claims)
    --  AA = W (Total Payments Insurance $)
    --     + T (Patient Paid $)
    --       / I+J+K+L+M+O.1+O.2  (Fully Paid + Patient Paid + Pat Responsibility +
    --                               Partially Paid + Adj/Written Off +
    --                               Fully Denied + Partially Denied)
    -- --------------------------------------------------------------------
    INSERT INTO dbo.Augustus_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT
        a.RoleID,
        a.Description,
        a.ESYear,
        a.ESMonth,
        a.ClaimCount,
        CASE WHEN a.ClaimCount > 0 THEN a.PayAmount / a.ClaimCount ELSE 0 END,
        GETDATE()
    FROM
    (
        -- -- Y  Total Payments Insurance / No. of Billed Claims ---------------
        SELECT
            'Y'                                              AS RoleID,
            'Average Payment ($) - Total Pay/Billed Claims' AS Description,
            p.ESYear, p.ESMonth,
            ISNULL(f.ESMonthClaimCount,  0)                 AS ClaimCount,
            ISNULL(w.ESMonthChargeAmount, 0)                AS PayAmount
        FROM #Periods p
        LEFT JOIN dbo.Augustus_ES_PMS  f ON f.ESYear = p.ESYear AND f.ESMonth = p.ESMonth AND f.RoleID = 'F'
        LEFT JOIN dbo.Augustus_ES_Cash w ON w.ESYear = p.ESYear AND w.ESMonth = p.ESMonth AND w.RoleID = 'W'

        -- -- Z  Total Payments Insurance / No. of Fully Paid Claims ----------
        UNION ALL
        SELECT
            'Z',
            'Average Payment ($) - Total Pay/Paid Claims',
            p.ESYear, p.ESMonth,
            ISNULL(i.ESMonthClaimCount,  0),
            ISNULL(w.ESMonthChargeAmount, 0)
        FROM #Periods p
        LEFT JOIN dbo.Augustus_ES_PMS  i ON i.ESYear = p.ESYear AND i.ESMonth = p.ESMonth AND i.RoleID = 'I'
        LEFT JOIN dbo.Augustus_ES_Cash w ON w.ESYear = p.ESYear AND w.ESMonth = p.ESMonth AND w.RoleID = 'W'

        -- -- AA  (Insurance Pay + Patient Pay) / Sum of adjudicated counts ---
        UNION ALL
        SELECT
            'AA',
            'Average Payment ($) - Total Pay/Adjudicated Claims',
            p.ESYear, p.ESMonth,
            -- Denominator: Fully Paid + Patient Paid + Pat Responsibility +
            --              Partially Paid + Adj/Written Off + Fully Denied + Partially Denied
            ISNULL(i.ESMonthClaimCount,  0) + ISNULL(j.ESMonthClaimCount,  0)
          + ISNULL(k.ESMonthClaimCount,  0) + ISNULL(l.ESMonthClaimCount,  0)
          + ISNULL(m.ESMonthClaimCount,  0) + ISNULL(n.ESMonthClaimCount,  0)
          + ISNULL(o1.ESMonthClaimCount, 0) + ISNULL(o2.ESMonthClaimCount, 0),
            -- Numerator: Total Insurance Payments + Patient Paid
            ISNULL(w.ESMonthChargeAmount, 0) + ISNULL(t.ESMonthChargeAmount, 0)
        FROM #Periods p
        LEFT JOIN dbo.Augustus_ES_PMS  i  ON i.ESYear  = p.ESYear AND i.ESMonth  = p.ESMonth AND i.RoleID  = 'I'
        LEFT JOIN dbo.Augustus_ES_PMS  j  ON j.ESYear  = p.ESYear AND j.ESMonth  = p.ESMonth AND j.RoleID  = 'J'
        LEFT JOIN dbo.Augustus_ES_PMS  k  ON k.ESYear  = p.ESYear AND k.ESMonth  = p.ESMonth AND k.RoleID  = 'K'
        LEFT JOIN dbo.Augustus_ES_PMS  l  ON l.ESYear  = p.ESYear AND l.ESMonth  = p.ESMonth AND l.RoleID  = 'L'
        LEFT JOIN dbo.Augustus_ES_PMS  m  ON m.ESYear  = p.ESYear AND m.ESMonth  = p.ESMonth AND m.RoleID  = 'M'
        LEFT JOIN dbo.Augustus_ES_PMS  n  ON n.ESYear  = p.ESYear AND n.ESMonth  = p.ESMonth AND n.RoleID  = 'N'
        LEFT JOIN dbo.Augustus_ES_PMS  o1 ON o1.ESYear = p.ESYear AND o1.ESMonth = p.ESMonth AND o1.RoleID = 'O.1'
        LEFT JOIN dbo.Augustus_ES_PMS  o2 ON o2.ESYear = p.ESYear AND o2.ESMonth = p.ESMonth AND o2.RoleID = 'O.2'
        LEFT JOIN dbo.Augustus_ES_Cash w  ON w.ESYear  = p.ESYear AND w.ESMonth  = p.ESMonth AND w.RoleID  = 'W'
        LEFT JOIN dbo.Augustus_ES_Cash t  ON t.ESYear  = p.ESYear AND t.ESMonth  = p.ESMonth AND t.RoleID  = 'T'
    ) a;

    -- Year Total (ESMonth = 0): ratio of the year's own sums, not a sum of monthly averages.
    ;WITH pmsYear AS
    (
        SELECT ESYear,
               F   = SUM(CASE WHEN RoleID = 'F' THEN ESMonthClaimCount ELSE 0 END),
               I   = SUM(CASE WHEN RoleID = 'I' THEN ESMonthClaimCount ELSE 0 END),
               Adj = SUM(CASE WHEN RoleID IN ('I','J','K','L','M','N','O.1','O.2') THEN ESMonthClaimCount ELSE 0 END)
        FROM dbo.Augustus_ES_PMS
        WHERE ESYear <> 0 AND ESMonth <> 0
        GROUP BY ESYear
    ),
    cashYear AS
    (
        SELECT ESYear,
               W = SUM(CASE WHEN RoleID = 'W' THEN ESMonthChargeAmount ELSE 0 END),
               T = SUM(CASE WHEN RoleID = 'T' THEN ESMonthChargeAmount ELSE 0 END)
        FROM dbo.Augustus_ES_Cash
        WHERE ESYear <> 0 AND ESMonth <> 0
        GROUP BY ESYear
    )
    INSERT INTO dbo.Augustus_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT v.RoleID, v.Description, py.ESYear, 0, v.Cnt,
           CASE WHEN v.Cnt > 0 THEN v.Amt / v.Cnt ELSE 0 END, GETDATE()
    FROM pmsYear py
    LEFT JOIN cashYear cy ON cy.ESYear = py.ESYear
    CROSS APPLY (VALUES
        ('Y',  'Average Payment ($) - Total Pay/Billed Claims',      py.F,   ISNULL(cy.W, 0)),
        ('Z',  'Average Payment ($) - Total Pay/Paid Claims',        py.I,   ISNULL(cy.W, 0)),
        ('AA', 'Average Payment ($) - Total Pay/Adjudicated Claims', py.Adj, ISNULL(cy.W, 0) + ISNULL(cy.T, 0))
    ) v(RoleID, Description, Cnt, Amt);
    ---- --------------------------------------------------------------------
    ----  Augustus_ES_Avg  -  Y, Z, AA
    ---- --------------------------------------------------------------------
    --INSERT INTO dbo.Augustus_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    --SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
    --       CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    --FROM
    --(
    --    -- Y  Average Payment ($) - Total Pay / Billed Claims
    --    SELECT p.ESYear, p.ESMonth, 'Y' AS RoleID, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
    --           COUNT( CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus<>'Billed amount 0' THEN b.ClaimID END) AS ClaimCount,
    --           SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus<>'Billed amount 0' THEN b.InsurancePayment + b.PatientPayment ELSE 0 END) AS PayTotal
    --    FROM #Periods p
    --    LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
    --    GROUP BY p.ESYear, p.ESMonth

    --    -- Z  Average Payment ($) - Total Pay / Paid Claims
    --    UNION ALL
    --    SELECT p.ESYear, p.ESMonth, 'Z', 'Average Payment ($) - Total Pay/Paid Claims',
    --           COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.ClaimID END),
    --           SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
    --    FROM #Periods p
    --    LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
    --    GROUP BY p.ESYear, p.ESMonth

    --    -- AA  Average Payment ($) - Total Pay / Adjudicated Claims
    --    UNION ALL
    --    SELECT p.ESYear, p.ESMonth, 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
    --           COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.ClaimID END),
    --           SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
    --    FROM #Periods p
    --    LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
    --    GROUP BY p.ESYear, p.ESMonth
    --) avgrows;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;

    PRINT 'usp_RefreshAug_ExecutiveSummary completed.';
END;
GO

-- ── 3. Drill-through filters (dbo.LisDrillRowDef) ──────────────────────────────
IF OBJECT_ID('dbo.LisDrillRowDef', 'U') IS NOT NULL
BEGIN
    DECLARE @Ins NVARCHAR(100) = N'Insurance Bills,Insurance Bill';

    BEGIN TRANSACTION;
        DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = 'Aug' AND Source = 'LIS';

        INSERT INTO dbo.LisDrillRowDef (LabPrefix, RowCode, RowTitle, DateCol, Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Source)
        VALUES
            ('Aug', 'A',      N'Total Samples',                 'RequestCollectDate', NULL,     NULL,     NULL, NULL,            NULL, NULL,       NULL,          NULL, NULL,                             'LIS'),
            ('Aug', 'B',      N'Billable Samples',              'RequestCollectDate', 'BillTo', 'IN',     @Ins, NULL,            NULL, NULL,       NULL,          NULL, NULL,                             'LIS'),
            ('Aug', 'C',      N'Billed',                        'RequestCollectDate', 'BillTo', 'IN',     @Ins, 'BillingStatus', '=',  N'Billed',   NULL,          NULL, NULL,                             'LIS'),
            ('Aug', 'C.1',    N'Claim Submitted in IRCM',       'RequestCollectDate', 'BillTo', 'IN',     @Ins, 'BillingStatus', '=',  N'Billed',   'FinalStatus', '=',  N'Claim Submitted in IRCM',       'LIS'),
            ('Aug', 'C.2',    N'Claim Submitted in Daqbilling', 'RequestCollectDate', 'BillTo', 'IN',     @Ins, 'BillingStatus', '=',  N'Billed',   'FinalStatus', '=',  N'Claim Submitted in Daqbilling', 'LIS'),
            ('Aug', 'C.3',    N'Claim Submitted in Altumed',    'RequestCollectDate', 'BillTo', 'IN',     @Ins, 'BillingStatus', '=',  N'Billed',   'FinalStatus', '=',  N'Claim Submitted in Altumed',    'LIS'),
            ('Aug', 'D',      N'Unbilled',                      'RequestCollectDate', 'BillTo', 'IN',     @Ins, 'BillingStatus', '=',  N'Unbilled', NULL,          NULL, NULL,                             'LIS'),
            ('Aug', 'D.1',    N'Insurance name not listed',     'RequestCollectDate', 'BillTo', 'IN',     @Ins, 'BillingStatus', '=',  N'Unbilled', 'FinalStatus', '=',  N'Insurance name not listed',     'LIS'),
            ('Aug', 'D.2',    N'Resulted yet to be Billed',     'RequestCollectDate', 'BillTo', 'IN',     @Ins, 'BillingStatus', '=',  N'Unbilled', 'FinalStatus', '=',  N'Resulted yet to be Billed',     'LIS'),
            ('Aug', 'D.3',    N'Charges Entered in Altumed',    'RequestCollectDate', 'BillTo', 'IN',     @Ins, 'BillingStatus', '=',  N'Unbilled', 'FinalStatus', '=',  N'Charges Entered in Altumed',    'LIS'),
            ('Aug', 'E',      N'Other Samples',                 'RequestCollectDate', 'BillTo', 'NOT IN', @Ins, NULL,            NULL, NULL,       NULL,          NULL, NULL,                             'LIS');

        -- Cash: Patient Responsibility / Insurance Balance on FirstBilledDate.
        DELETE FROM dbo.LisDrillRowDef
        WHERE LabPrefix = 'Aug' AND Source = 'Cash' AND RowCode IN ('U','U.1','U.2','U.3','X','X.1','X.2','X.3');

        INSERT INTO dbo.LisDrillRowDef (LabPrefix, RowCode, RowTitle, DateCol, Col1, Op1, Val1, Col2, Op2, Val2, Source, AmountCol)
        VALUES
            ('Aug', 'U',   N'Patient Responsibility ($)', 'DateofService', 'FirstBilledDate', '<>', N'', NULL,          NULL,     NULL,                                             'Cash', 'PatientBalance'),
            ('Aug', 'U.1', N'IRCM',                       'DateofService', 'FirstBilledDate', '<>', N'', 'Source',      '=',      N'IRCM',                                          'Cash', 'PatientBalance'),
            ('Aug', 'U.2', N'Daqbilling',                 'DateofService', 'FirstBilledDate', '<>', N'', 'Source',      '=',      N'Daq',                                           'Cash', 'PatientBalance'),
            ('Aug', 'U.3', N'Altumed',                    'DateofService', 'FirstBilledDate', '<>', N'', 'Source',      '=',      N'Altumed',                                       'Cash', 'PatientBalance'),
            ('Aug', 'X',   N'Insurance Balance ($)',      'DateofService', 'FirstBilledDate', '<>', N'', 'ClaimStatus', '<>',     N'Billed amount 0',                               'Cash', 'InsuranceBalance'),
            ('Aug', 'X.1', N'Fully Denied',               'DateofService', 'FirstBilledDate', '<>', N'', 'ClaimStatus', '=',      N'Fully Denied',                                  'Cash', 'InsuranceBalance'),
            ('Aug', 'X.2', N'Partially Denied',           'DateofService', 'FirstBilledDate', '<>', N'', 'ClaimStatus', 'NOT IN', N'Fully Denied,No Response,Billed amount 0',      'Cash', 'InsuranceBalance'),
            ('Aug', 'X.3', N'No Response from Payor',     'DateofService', 'FirstBilledDate', '<>', N'', 'ClaimStatus', '=',      N'No Response',                                   'Cash', 'InsuranceBalance');

        IF NOT EXISTS (SELECT 1 FROM dbo.LisDrillRowDef WHERE LabPrefix = 'Aug' AND RowCode = 'F.3' AND Source = 'PMS')
            INSERT INTO dbo.LisDrillRowDef (LabPrefix, RowCode, RowTitle, DateCol, Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Source)
            SELECT LabPrefix, 'F.3', N'No. of Claims Billed in Altumed', DateCol, Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, N'Altumed', Source
            FROM dbo.LisDrillRowDef
            WHERE LabPrefix = 'Aug' AND RowCode = 'F.2' AND Source = 'PMS';
    COMMIT TRANSACTION;
    PRINT 'LisDrillRowDef: Augustus LIS rows replaced; PMS F.3 added.';
END
GO

-- ── 4. Refresh ────────────────────────────────────────────────────────────────
EXEC dbo.usp_RefreshAug_ExecutiveSummary_LIS_Alt;
EXEC dbo.usp_RefreshAug_ExecutiveSummary;
GO

SELECT RoleID, Description, Total = ESMonthClaimCount
FROM dbo.Augustus_ES_LIS WHERE ESYear = 0 AND RoleID NOT LIKE 'B1.%' ORDER BY Id;
SELECT RoleID, Description, Total = ESMonthClaimCount
FROM dbo.Augustus_ES_PMS WHERE ESYear = 0 AND RoleID LIKE 'F%' ORDER BY Id;
SELECT RoleID, Description, Total = ESMonthChargeAmount
FROM dbo.Augustus_ES_Cash WHERE ESYear = 0 ORDER BY Id;
SELECT RoleID, ESYear, ESMonth, Claims = ESMonthClaimCount, Average = ESMonthChargeAmount
FROM dbo.Augustus_ES_Avg WHERE ESMonth = 0 ORDER BY RoleID, ESYear;
PRINT '35_Augustus_ExecutiveSummary_LIS_ClientLogic.sql completed.';
GO
