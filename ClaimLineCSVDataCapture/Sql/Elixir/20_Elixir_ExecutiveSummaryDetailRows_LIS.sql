-- ============================================================
-- Elixir – Executive Summary LIS Detail-Rows SP (generic name)
-- File : 20_Elixir_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : Elixir_LRN
--
-- Mirrors 19_Elixir_ExecutiveSummary_LIS_Alt.sql
-- (usp_RefreshElix_ExecutiveSummary_LIS_Alt), which sources the LIS
-- Breakdown from dbo.LIMSMaster using RoleIDs A..E (plus D.1, E.1-E.6).
-- This SP must use the SAME auto-detected columns and SAME predicates so
-- that drilling into any LIS Breakdown cell returns the LIMSMaster rows
-- that were counted for that cell.
--
-- Uses the GENERIC (non lab-prefixed) procedure name
-- dbo.usp_GetExecutiveSummaryDetail_LIS, called by
-- ExecutiveSummaryController.Detail for ANY lab's 'LIS' category, with
-- @RowCode = the RoleID stored on the clicked Elix_ES_LIS row
-- (e.g. 'A','B','C','D','D.1','E','E.1'...'E.6').
--
-- RoleID -> filter map (mirrors file 19's #Lis population/predicates):
--   A    Total Samples              -> no filter
--   B    Billable Samples           -> NewStatus = 'Billable'
--   C    Billed                     -> NewStatus = 'Billable' AND BillCategory = 'Billed'
--   D    Unbilled                   -> NewStatus = 'Billable' AND BillCategory = 'Not Billed'
--   D.1    Resulted yet to be billed  -> ResultStatus = 'Resulted' AND NewStatus = 'Billable' AND BillCategory = 'Not Billed'
--   E    Other Samples              -> NewStatus <> 'Billable'
--   E.1    Client Bill                -> NewStatus = 'Client Bill'
--   E.2    Self Pay                   -> NewStatus = 'Self Pay'
--   E.3    System Test                -> NewStatus = 'System Test'
--   E.4    Deleted/Rejected            -> NewStatus = 'Deleted/Rejected'
--   E.5    CIP/Pending                 -> NewStatus = 'CIP/Pending'
--   E.6    Yet to be validated         -> NewStatus = 'Yet to be validated'
--
-- Column auto-detection is identical to file 19 (@AccCol/@DateCol/
-- @NewStatusCol/@BillCategoryCol/@ResultStatusCol), plus a few extra
-- display-only columns (PatientName/PayerName/ClinicName/BillingProvider/
-- PanelName) auto-detected the same way as PhiLife/PCRLOA's file 20,
-- falling back to '' if not present.
--
-- @DateCol priority: DateOfCollection (0) > RequestCollectDate (1) >
--   CollectionDate (2) > DateofService (3) > ServiceDate (4) >
--   AccessionDate (5).  Filter is always by the collection/service date
--   that was used to bucket rows in file 19's aggregate.
--
-- @Year/@Month: 0 = all years / all months (matches the (0,0) grand-total
-- sentinel period used by file 19).
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
            CAST(NULL AS DATE)          AS DateOfService,
            CAST(NULL AS NVARCHAR(300)) AS PanelName,
            CAST(NULL AS NVARCHAR(100)) AS NewStatus,
            CAST(NULL AS NVARCHAR(100)) AS BillCategory,
            CAST(NULL AS NVARCHAR(100)) AS ResultStatus,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    -- ───────────────────────────────────────────────────────────────────────
    --  Auto-detect dbo.LIMSMaster column names for each logical field
    --  (identical candidate lists/order to 19_Elixir_ExecutiveSummary_LIS_Alt.sql).
    -- ───────────────────────────────────────────────────────────────────────
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','Accession','AccessionNo')
        ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('DateOfCollection','RequestCollectDate','CollectionDate','DateofService','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'DateOfCollection'   THEN 0
            WHEN 'RequestCollectDate' THEN 1
            WHEN 'CollectionDate'     THEN 2
            WHEN 'DateofService'      THEN 3
            WHEN 'ServiceDate'        THEN 4
            WHEN 'AccessionDate'      THEN 5
            ELSE 6 END);

    DECLARE @NewStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('NewStatus','Status')
        ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 ELSE 2 END);

    DECLARE @BillCategoryCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus')
        ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

    DECLARE @ResultStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ResultStatus','Result_Status','ResultedStatus','RessultedStatus','IsResulted')
        ORDER BY CASE name
            WHEN 'ResultStatus' THEN 0 WHEN 'Result_Status' THEN 1
            WHEN 'ResultedStatus' THEN 2 WHEN 'RessultedStatus' THEN 3
            WHEN 'IsResulted' THEN 4 ELSE 5 END);

    -- Extra display-only columns (auto-detected, fall back to '').
    DECLARE @PanelCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2
            WHEN 'TestPanelName' THEN 3 WHEN 'TestPanelname' THEN 4 WHEN 'TestPanel' THEN 5
            WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8 ELSE 9 END);

    DECLARE @PatientCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PatientName','Patient_Name','Patient')
        ORDER BY CASE name WHEN 'PatientName' THEN 0 WHEN 'Patient_Name' THEN 1 WHEN 'Patient' THEN 2 ELSE 3 END);

    DECLARE @PayerCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PayerName','InsuranceName','Payer','PrimaryPayer','InsurancePayer','InsuranceCategory')
        ORDER BY CASE name WHEN 'PayerName' THEN 0 WHEN 'InsuranceName' THEN 1 WHEN 'Payer' THEN 2 WHEN 'PrimaryPayer' THEN 3 WHEN 'InsurancePayer' THEN 4 ELSE 5 END);

    DECLARE @ClinicCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClinicName','Clinic','FacilityName','Facility')
        ORDER BY CASE name WHEN 'ClinicName' THEN 0 WHEN 'Clinic' THEN 1 WHEN 'FacilityName' THEN 2 ELSE 3 END);

    DECLARE @ProviderCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillingProvider','Provider','OrderingProvider','RenderingProvider')
        ORDER BY CASE name WHEN 'BillingProvider' THEN 0 WHEN 'Provider' THEN 1 WHEN 'OrderingProvider' THEN 2 ELSE 3 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @NewStatusCol IS NULL OR @BillCategoryCol IS NULL OR @ResultStatusCol IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS NVARCHAR(100)) AS Accession,
            CAST(NULL AS DATE)          AS DateOfService,
            CAST(NULL AS NVARCHAR(300)) AS PanelName,
            CAST(NULL AS NVARCHAR(100)) AS NewStatus,
            CAST(NULL AS NVARCHAR(100)) AS BillCategory,
            CAST(NULL AS NVARCHAR(100)) AS ResultStatus,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @AccExpr      NVARCHAR(300) = N'LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N'])))';
    DECLARE @DateExpr     NVARCHAR(300) = N'TRY_CAST([' + @DateCol + N'] AS DATE)';
    DECLARE @NewStatusExpr    NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol    + N']), '''')))';
    DECLARE @BillCategoryExpr NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), '''')))';
    DECLARE @PanelExpr    NVARCHAR(400) = CASE WHEN @PanelCol    IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol    + N']), '''')))' ELSE N'''''' END;
    DECLARE @PatientExpr  NVARCHAR(400) = CASE WHEN @PatientCol  IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PatientCol  + N']), '''')))' ELSE N'''''' END;
    DECLARE @PayerExpr    NVARCHAR(400) = CASE WHEN @PayerCol    IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PayerCol    + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClinicExpr   NVARCHAR(400) = CASE WHEN @ClinicCol   IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol   + N']), '''')))' ELSE N'''''' END;
    DECLARE @ProviderExpr NVARCHAR(400) = CASE WHEN @ProviderCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), '''')))' ELSE N'''''' END;

    -- IsResulted is sometimes a bit/flag column rather than a status string;
    -- normalize it to 'Resulted' / 'Not Resulted' (same as file 19) so the
    -- D.1 filter (ResultStatus = 'Resulted') works regardless of type.
    DECLARE @ResultExpr NVARCHAR(400);
    IF @ResultStatusCol = 'IsResulted'
        SET @ResultExpr = N'(CASE WHEN TRY_CAST([' + @ResultStatusCol + N'] AS INT) = 1 THEN ''Resulted''
                                   WHEN CONVERT(NVARCHAR(20), [' + @ResultStatusCol + N']) IN (''Y'',''Yes'',''True'',''Resulted'') THEN ''Resulted''
                                   ELSE ''Not Resulted'' END)';
    ELSE
        SET @ResultExpr = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ResultStatusCol + N']), '''')))';

    -- ───────────────────────────────────────────────────────────────────────
    --  Pull the matching LIMSMaster rows for the requested period into a
    --  real temp table (must be CREATE TABLE, not SELECT...INTO inside
    --  sp_executesql, so it survives past the EXEC call).
    -- ───────────────────────────────────────────────────────────────────────
    DROP TABLE IF EXISTS #LisBase;
    CREATE TABLE #LisBase
    (
        Accession       NVARCHAR(100) NOT NULL,
        DateOfService   DATE          NULL,
        PanelName       NVARCHAR(300) NOT NULL,
        NewStatus       NVARCHAR(100) NOT NULL,
        BillCategory    NVARCHAR(100) NOT NULL,
        ResultStatus    NVARCHAR(100) NOT NULL,
        PatientName     NVARCHAR(300) NOT NULL,
        PayerName       NVARCHAR(300) NOT NULL,
        ClinicName      NVARCHAR(300) NOT NULL,
        BillingProvider NVARCHAR(300) NOT NULL,
        ESYear          INT           NOT NULL,
        ESMonth         INT           NOT NULL
    );

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #LisBase
            (Accession, DateOfService, PanelName, NewStatus, BillCategory, ResultStatus,
             PatientName, PayerName, ClinicName, BillingProvider, ESYear, ESMonth)
        SELECT
            ' + @AccExpr          + N',
            ' + @DateExpr         + N',
            ' + @PanelExpr        + N',
            ' + @NewStatusExpr    + N',
            ' + @BillCategoryExpr + N',
            ' + @ResultExpr       + N',
            ' + @PatientExpr      + N',
            ' + @PayerExpr        + N',
            ' + @ClinicExpr       + N',
            ' + @ProviderExpr     + N',
            YEAR (' + @DateExpr + N'),
            MONTH(' + @DateExpr + N')
        FROM dbo.LIMSMaster
        WHERE ' + @DateExpr + N' IS NOT NULL
          AND NULLIF(' + @AccExpr + N', '''') IS NOT NULL
          AND (@iYear  = 0 OR YEAR (' + @DateExpr + N') = @iYear)
          AND (@iMonth = 0 OR MONTH(' + @DateExpr + N') = @iMonth);';

    EXEC sp_executesql @LisSql, N'@iYear INT, @iMonth INT', @iYear = @Year, @iMonth = @Month;

    SELECT
        b.Accession        AS Accession,
        b.DateOfService     AS DateOfService,
        b.PanelName         AS PanelName,
        b.NewStatus         AS NewStatus,
        b.BillCategory      AS BillCategory,
        b.ResultStatus      AS ResultStatus,
        b.PatientName       AS PatientName,
        b.PayerName         AS PayerName,
        b.ClinicName        AS ClinicName,
        b.BillingProvider   AS BillingProvider
    FROM #LisBase b
    WHERE
        -- A  Total Samples
        (@RowCode = 'A')
     OR -- B  Billable Samples
        (@RowCode = 'B'   AND b.NewStatus = 'Billable')
     OR -- C  Billed
        (@RowCode = 'C'   AND b.NewStatus = 'Billable' AND b.BillCategory = 'Billed')
     OR -- D  Unbilled
        (@RowCode = 'D'   AND b.NewStatus = 'Billable' AND b.BillCategory = 'Not Billed')
     OR -- D.1  Resulted yet to be billed
        (@RowCode = 'D.1' AND b.ResultStatus = 'Resulted' AND b.NewStatus = 'Billable' AND b.BillCategory = 'Not Billed')
     OR -- E  Other Samples
        (@RowCode = 'E'   AND b.NewStatus <> 'Billable')
     OR -- E.1  Client Bill
        (@RowCode = 'E.1' AND b.NewStatus = 'Client Bill')
     OR -- E.2  Self Pay
        (@RowCode = 'E.2' AND b.NewStatus = 'Self Pay')
     OR -- E.3  System Test
        (@RowCode = 'E.3' AND b.NewStatus = 'System Test')
     OR -- E.4  Deleted/Rejected
        (@RowCode = 'E.4' AND b.NewStatus = 'Deleted/Rejected')
     OR -- E.5  CIP/Pending
        (@RowCode = 'E.5' AND b.NewStatus = 'CIP/Pending')
     OR -- E.6  Yet to be validated
        (@RowCode = 'E.6' AND b.NewStatus = 'Yet to be validated')
     OR -- Fallback: unrecognized RowCode -> return everything in the period
        (@RowCode NOT IN ('A','B','C','D','D.1','E','E.1','E.2','E.3','E.4','E.5','E.6'))
    ORDER BY b.DateOfService, b.Accession;

    DROP TABLE IF EXISTS #LisBase;
END;
GO

PRINT '20_Elixir_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO
