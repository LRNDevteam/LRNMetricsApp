-- ============================================================
-- Cove – Executive Summary LIS Detail-Rows SP (generic name)
-- File : 20_Cove_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : Cove_LRN
--
-- Mirrors Elixir\20_Elixir_ExecutiveSummaryDetailRows_LIS.sql, adapted to
-- Cove's RoleID scheme (A, B+B.<PanelType>, C, D+D.1-D.20 incl.
-- D.5.<PanelType> / D.6.<PanelType> nested PanelType sub-rows, E+E.1-E.7) as
-- implemented in 19_Cove_ExecutiveSummary_LIS_Alt.sql /
-- 17_Cove_ExecutiveSummary_Read.sql / 18_Cove_ExecutiveSummary_Detail.sql.
-- This SP must use the SAME auto-detected dbo.LIMSMaster columns and SAME
-- predicates so that drilling into any LIS Breakdown cell returns the rows
-- counted for that cell.
--
-- The B.<PanelType> / D.5.<PanelType> / D.6.<PanelType> sub-rows are NOT a
-- fixed/hardcoded list - one exists per DISTINCT LIMSMaster.PanelType value
-- (see #PanelTypes in file 19). @RowCode for these is matched dynamically by
-- extracting the panel name from the RowCode suffix.
--
-- Uses the GENERIC (non lab-prefixed) procedure name
-- dbo.usp_GetExecutiveSummaryDetail_LIS, called by
-- ExecutiveSummaryController.Detail for ANY lab's 'LIS' category, with
-- @RowCode = the RoleID stored on the clicked Cove_ES_LIS row.
--
-- Column auto-detection (identical candidate lists/order to file 19):
--   @AccCol          : AccessionNumber, Accession, AccessionNo
--   @DateCol         : DateOfCollection, RequestCollectDate, DateofService,
--                       CollectionDate, ServiceDate, AccessionDate
--   @NewStatusCol    : NewStatus, Status
--   @PanelTypeCol    : PanelType, PanelCategory, PanelName, Panelname,
--                       TestPanel, TestPanelName, Panel, PanelDescription,
--                       TestName, Test_Panel, TestPanelname
--   @BillCategoryCol : BillCategory, Bill_Category, BillingCategory,
--                       BilledorNot, BillStatus
--   @SubStatusCol    : SubStatus, Sub_Status, ClientStatus, FinalStatus
-- Extra display-only columns (best-effort, '' if not found):
--   @PatientNameCol, @PayerNameCol, @ClinicNameCol, @ProviderCol
--
-- @Year/@Month: 0 = all years / all months (matches the (0,0) grand-total
-- sentinel period used by file 19).
--
-- Unrecognized @RowCode -> returns every row for the period (same fallback
-- convention as Elixir's file 20).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LIS
(
    @RowCode NVARCHAR(350),
    @Year    INT = 0,
    @Month   INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS NVARCHAR(100)) AS Accession,
            CAST(NULL AS DATE)          AS DateOfCollection,
            CAST(NULL AS NVARCHAR(300)) AS PanelType,
            CAST(NULL AS NVARCHAR(100)) AS NewStatus,
            CAST(NULL AS NVARCHAR(100)) AS BillCategory,
            CAST(NULL AS NVARCHAR(100)) AS SubStatus,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    -- ───────────────────────────────────────────────────────────────────────
    --  Auto-detect dbo.LIMSMaster column names (identical candidate
    --  lists/order to 19_Cove_ExecutiveSummary_LIS_Alt.sql).
    -- ───────────────────────────────────────────────────────────────────────
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','Accession','AccessionNo')
        ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('DateOfCollection','RequestCollectDate','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'DateOfCollection' THEN 0 WHEN 'RequestCollectDate' THEN 1
            WHEN 'DateofService' THEN 2 WHEN 'CollectionDate' THEN 3
            WHEN 'ServiceDate' THEN 4 WHEN 'AccessionDate' THEN 5 ELSE 6 END);

    DECLARE @NewStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('NewStatus','Status')
        ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 ELSE 2 END);

    DECLARE @PanelTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelType','PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelType' THEN 0 WHEN 'PanelCategory' THEN 1 WHEN 'PanelName' THEN 2
            WHEN 'Panelname' THEN 3 WHEN 'TestPanel' THEN 4 WHEN 'TestPanelName' THEN 5
            WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8
            WHEN 'Test_Panel' THEN 9 WHEN 'TestPanelname' THEN 10 ELSE 11 END);

    DECLARE @BillCategoryCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
        ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BilledorNot' THEN 3 WHEN 'BillStatus' THEN 4 ELSE 5 END);

    DECLARE @SubStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('SubStatus','Sub_Status','ClientStatus','FinalStatus')
        ORDER BY CASE name WHEN 'SubStatus' THEN 0 WHEN 'Sub_Status' THEN 1 WHEN 'ClientStatus' THEN 2 WHEN 'FinalStatus' THEN 3 ELSE 4 END);

    -- Extra display-only columns (best-effort; '' if not found).
    DECLARE @PatientCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PatientName','Patient_Name','Patient','PatientFullName')
        ORDER BY CASE name WHEN 'PatientName' THEN 0 WHEN 'Patient_Name' THEN 1 WHEN 'PatientFullName' THEN 2 WHEN 'Patient' THEN 3 ELSE 4 END);

    DECLARE @PayerCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PayerName','InsuranceName','Payer','PrimaryPayer','InsurancePayer','InsuranceCategory')
        ORDER BY CASE name WHEN 'PayerName' THEN 0 WHEN 'InsuranceName' THEN 1 WHEN 'Payer' THEN 2 WHEN 'PrimaryPayer' THEN 3 WHEN 'InsurancePayer' THEN 4 ELSE 5 END);

    DECLARE @ClinicCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClinicName','Client_Name','ClientName','Clinic','FacilityName','Facility')
        ORDER BY CASE name WHEN 'ClinicName' THEN 0 WHEN 'ClientName' THEN 1 WHEN 'Client_Name' THEN 2 WHEN 'Clinic' THEN 3 WHEN 'FacilityName' THEN 4 ELSE 5 END);

    DECLARE @ProviderCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillingProvider','Provider','OrderingProvider','RenderingProvider')
        ORDER BY CASE name WHEN 'BillingProvider' THEN 0 WHEN 'Provider' THEN 1 WHEN 'OrderingProvider' THEN 2 ELSE 3 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @NewStatusCol IS NULL OR @PanelTypeCol IS NULL OR @BillCategoryCol IS NULL OR @SubStatusCol IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS NVARCHAR(100)) AS Accession,
            CAST(NULL AS DATE)          AS DateOfCollection,
            CAST(NULL AS NVARCHAR(300)) AS PanelType,
            CAST(NULL AS NVARCHAR(100)) AS NewStatus,
            CAST(NULL AS NVARCHAR(100)) AS BillCategory,
            CAST(NULL AS NVARCHAR(100)) AS SubStatus,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @AccExpr          NVARCHAR(300) = N'LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N'])))';
    DECLARE @DateExpr         NVARCHAR(300) = N'TRY_CAST([' + @DateCol + N'] AS DATE)';
    DECLARE @NewStatusExpr    NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @NewStatusCol    + N']), '''')))';
    DECLARE @PanelTypeExpr    NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelTypeCol    + N']), '''')))';
    DECLARE @BillCategoryExpr NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), '''')))';
    DECLARE @SubStatusExpr    NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol    + N']), '''')))';

    DECLARE @PatientExpr  NVARCHAR(400) = CASE WHEN @PatientCol  IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PatientCol  + N']), '''')))' ELSE N'''''' END;
    DECLARE @PayerExpr    NVARCHAR(400) = CASE WHEN @PayerCol    IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PayerCol    + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClinicExpr   NVARCHAR(400) = CASE WHEN @ClinicCol   IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol   + N']), '''')))' ELSE N'''''' END;
    DECLARE @ProviderExpr NVARCHAR(400) = CASE WHEN @ProviderCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), '''')))' ELSE N'''''' END;

    -- ───────────────────────────────────────────────────────────────────────
    --  Pull the matching LIMSMaster rows for the requested period into a
    --  real temp table (must be CREATE TABLE, not SELECT...INTO inside
    --  sp_executesql, so it survives past the EXEC call).
    -- ───────────────────────────────────────────────────────────────────────
    DROP TABLE IF EXISTS #LisBase;
    CREATE TABLE #LisBase
    (
        Accession        NVARCHAR(100) NOT NULL,
        DateOfCollection DATE          NULL,
        PanelType        NVARCHAR(200) NOT NULL,
        NewStatus        NVARCHAR(200) NOT NULL,
        BillCategory     NVARCHAR(200) NOT NULL,
        SubStatus        NVARCHAR(200) NOT NULL,
        PatientName      NVARCHAR(300) NOT NULL,
        PayerName        NVARCHAR(300) NOT NULL,
        ClinicName       NVARCHAR(300) NOT NULL,
        BillingProvider  NVARCHAR(300) NOT NULL
    );

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #LisBase
            (Accession, DateOfCollection, PanelType, NewStatus, BillCategory, SubStatus,
             PatientName, PayerName, ClinicName, BillingProvider)
        SELECT
            ' + @AccExpr          + N',
            ' + @DateExpr         + N',
            ' + @PanelTypeExpr    + N',
            ' + @NewStatusExpr    + N',
            ' + @BillCategoryExpr + N',
            ' + @SubStatusExpr    + N',
            ' + @PatientExpr      + N',
            ' + @PayerExpr        + N',
            ' + @ClinicExpr       + N',
            ' + @ProviderExpr     + N'
        FROM dbo.LIMSMaster
        WHERE ' + @DateExpr + N' IS NOT NULL
          AND NULLIF(' + @AccExpr + N', '''') IS NOT NULL
          AND (@iYear  = 0 OR YEAR (' + @DateExpr + N') = @iYear)
          AND (@iMonth = 0 OR MONTH(' + @DateExpr + N') = @iMonth);';

    EXEC sp_executesql @LisSql, N'@iYear INT, @iMonth INT', @iYear = @Year, @iMonth = @Month;

    -- Dynamic B.<PanelType> / D.5.<PanelType> / D.6.<PanelType> sub-row
    -- match: extract the panel name from the RowCode suffix.
    DECLARE @PanelFilter NVARCHAR(300) = NULL;
    IF @RowCode LIKE 'B.%'
        SET @PanelFilter = SUBSTRING(@RowCode, 3, 300);
    ELSE IF @RowCode LIKE 'D.5.%' OR @RowCode LIKE 'D.6.%'
        SET @PanelFilter = SUBSTRING(@RowCode, 5, 300);

    SELECT
        b.Accession,
        b.DateOfCollection,
        b.PanelType,
        b.NewStatus,
        b.BillCategory,
        b.SubStatus,
        b.PatientName,
        b.PayerName,
        b.ClinicName,
        b.BillingProvider
    FROM #LisBase b
    WHERE
           (@RowCode = 'A')
        OR (@RowCode = 'B'      AND b.NewStatus='Billable')
        OR (@PanelFilter IS NOT NULL AND @RowCode LIKE 'B.%' AND b.NewStatus='Billable' AND b.PanelType = @PanelFilter COLLATE DATABASE_DEFAULT)
        OR (@RowCode = 'C'      AND b.NewStatus='Billable' AND b.BillCategory='Billed')
        OR (@RowCode = 'D'      AND b.NewStatus='Billable' AND b.BillCategory='Not Billed')
        OR (@RowCode = 'D.1'    AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Billed Insurance In Covedx')
        OR (@RowCode = 'D.2'    AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Billed In Variantx Lab')
        OR (@RowCode = 'D.3'    AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Billed In Elixir Dx')
        OR (@RowCode = 'D.4'    AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Ignored - Duplicate Accession')
        OR (@RowCode = 'D.5'    AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Coding exception')
        OR (@PanelFilter IS NOT NULL AND @RowCode LIKE 'D.5.%' AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Coding exception' AND b.PanelType = @PanelFilter COLLATE DATABASE_DEFAULT)
        OR (@RowCode = 'D.6'    AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='CP Exception')
        OR (@PanelFilter IS NOT NULL AND @RowCode LIKE 'D.6.%' AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='CP Exception' AND b.PanelType = @PanelFilter COLLATE DATABASE_DEFAULT)
        OR (@RowCode = 'D.7'    AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='In process')
        OR (@RowCode = 'D.8'    AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Ignored - Client Response Non Billiable')
        OR (@RowCode = 'D.9'    AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Ready To Bill')
        OR (@RowCode = 'D.10'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Ignored - NGS & PGX in Cove')
        OR (@RowCode = 'D.11'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='CP Exception -In Review')
        OR (@RowCode = 'D.12'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Medicaid Credentialling In Process')
        OR (@RowCode = 'D.13'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Ignored - Reported in Elixir Truemed')
        OR (@RowCode = 'D.14'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Ignored - CP Exception')
        OR (@RowCode = 'D.15'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Client Bill Cases')
        OR (@RowCode = 'D.16'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Ignored - Client Response Pure Selfpay')
        OR (@RowCode = 'D.17'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Selfpay')
        OR (@RowCode = 'D.18'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Ignored - Rejected Accession')
        OR (@RowCode = 'D.19'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Hold-Amerihealth Lousiana')
        OR (@RowCode = 'D.20'   AND b.NewStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Ignored - Test Cases')
        OR (@RowCode = 'E'      AND b.NewStatus<>'Billable')
        OR (@RowCode = 'E.1'    AND b.NewStatus='Self Pay')
        OR (@RowCode = 'E.2'    AND b.NewStatus='Client Bill')
        OR (@RowCode = 'E.3'    AND b.NewStatus='Deleted / Rejected')
        OR (@RowCode = 'E.4'    AND b.NewStatus='System Test')
        OR (@RowCode = 'E.5'    AND b.NewStatus='Ref Lab - Bill Patient')
        OR (@RowCode = 'E.6'    AND b.NewStatus='Missing Accession')
        OR (@RowCode = 'E.7'    AND b.NewStatus='Yet To Be Validated')
        -- Fallback: unrecognized RowCode -> return everything in the period.
        -- The dynamic B.<PanelType> / D.5.<PanelType> / D.6.<PanelType> codes
        -- are excluded from this fallback via the LIKE checks (they're
        -- handled by @PanelFilter above, even if PanelType didn't match any
        -- row in #LisBase).
        OR (@RowCode NOT IN (
            'A','B','C','D','D.1','D.2','D.3','D.4','D.5','D.6',
            'D.7','D.8','D.9','D.10','D.11','D.12','D.13','D.14','D.15','D.16','D.17','D.18','D.19','D.20',
            'E','E.1','E.2','E.3','E.4','E.5','E.6','E.7')
            AND @RowCode NOT LIKE 'B.%'
            AND @RowCode NOT LIKE 'D.5.%'
            AND @RowCode NOT LIKE 'D.6.%')
    ORDER BY b.DateOfCollection, b.Accession;

    DROP TABLE IF EXISTS #LisBase;
END;
GO

PRINT '20_Cove_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO
