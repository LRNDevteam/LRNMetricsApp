-- ============================================================
-- PhiLife – Executive Summary LIS Detail-Rows SP (generic name)
-- File : 20_PhiLife_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : PhiLife_LRN
--
-- REWRITE (v2): mirrors 19_PhiLife_ExecutiveSummary_LIS_Alt.sql
-- (usp_RefreshPhi_ExecutiveSummary_LIS_Alt), which now sources the LIS
-- Breakdown from dbo.LIMSMaster using RoleIDs A..P plus 'B.<PanelName>'
-- sub-rows (see file 19 header for the full RoleID -> predicate map).
-- This SP must use the SAME auto-detected columns and SAME predicates so
-- that drilling into any LIS Breakdown cell returns the LIMSMaster rows
-- that were counted for that cell — previously this SP still queried
-- dbo.ClaimLevelData with the old IsResulted/PayerType logic, which no
-- longer matches the LIMSMaster-based aggregate (file 19) and produced
-- "No records found for this selection." for every LIS drill-down.
--
-- Uses the GENERIC (non lab-prefixed) procedure name
-- dbo.usp_GetExecutiveSummaryDetail_LIS, called by
-- ExecutiveSummaryController.Detail for ANY lab's 'LIS' category, with
-- @RowCode = the RoleID stored on the clicked Phi_ES_LIS /
-- Phi_ES_LIS_Panel row (e.g. 'A','B','C','C.1','D','D.1'...'P', or
-- 'B.<PanelName>').
--
-- RoleID -> filter map (mirrors file 19's #Lis population/predicates):
--   A      Total Samples            -> no filter
--   B      Billable Samples-Resulted-> ResultedNot='Resulted'
--   C      Billed to Insurance      -> B + ClaimStat='Billed' AND ClientStat=''
--   C.1      Billed In AMD            -> same as C
--   D      Not Entered in AMD       -> B + ClaimStat='Not Entered in AMD' AND ClientStat IN ('Billing Review Required','') AND PayMethod='Insurance'
--   D.1      Received                 -> D narrowed to ClientStat='Billing Review Required'
--   D.2      Billing Review Required -> D.1 + SampleStat='Received'
--   D.3      Collected                -> D narrowed to ClientStat='' AND SampleStat='Collected'
--   E      Unbilled                  -> B + ClientStat='' AND ClaimStat='Entered'
--   F      Client Bill               -> B + ClientStat='Client Bill'
--   F.1      Not Entered in AMD        -> F + ClaimStat='Not Entered in AMD'
--   F.2      Billed                    -> F + ClaimStat='Billed'
--   G      Self Pay                  -> B + ClientStat='Self Pay'
--   G.1      Billed                    -> G + ClaimStat='Billed'
--   G.2      Not Entered in AMD        -> G + ClaimStat='Not Entered in AMD'
--   H      Test Entries              -> B + ClientStat='Test Entries' AND PayMethod<>'No Bill'
--   H.1      Not Entered in AMD        -> H + ClaimStat='Not Entered in AMD'
--   H.2      Billed                    -> H + ClaimStat='Billed'
--   I      Rejected Sample           -> B + ClientStat='Rejected Sample'
--   I.1      Not Entered in AMD        -> I + ClaimStat='Not Entered in AMD'
--   I.2      Billed                    -> I + ClaimStat='Billed'
--   J      PaymentMethod No Bill     -> B + PayMethod='No Bill'
--   K      Not Resulted              -> ResultedNot='Not Resulted'
--   L      Not Entered in AMD        -> K + ClaimStat='Not Entered in AMD' AND ClientStat='' AND PayMethod='Insurance'
--   L.1      Received                 -> L + SampleStat='Received'
--   L.2      Collected                -> L + SampleStat='Collected'
--   M      Client Bill               -> K + ClientStat='Client Bill'
--   N      Test Entries              -> K + ClientStat='Test Entries' AND PayMethod='Insurance'
--   O      Rejected Sample           -> K + ClientStat='Rejected Sample' AND PayMethod='Insurance'
--   P      PaymentMethod No Bill     -> K + PayMethod='No Bill'
--   B.<PanelName>  Resulted, panel-specific -> ResultedNot='Resulted' AND PanelName=<PanelName>
--
-- Column auto-detection is identical to file 19 (@AccCol/@DateCol/
-- @ResultedCol/@ClaimStatusCol/@ClientStatusCol/@PaymentMethodCol/
-- @SampleStatusCol/@PanelCol), plus a few extra display-only columns
-- (PatientName/PayerName/ClinicName/BillingProvider) auto-detected the
-- same way as PCRLOA's 20_PCRLOA_ExecutiveSummaryDetailRows_LIS.sql,
-- falling back to '' if not present.
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
            CAST(NULL AS NVARCHAR(100)) AS ResultedStatus,
            CAST(NULL AS NVARCHAR(100)) AS ClaimStatus,
            CAST(NULL AS NVARCHAR(100)) AS ClientStatus,
            CAST(NULL AS NVARCHAR(100)) AS PaymentMethod,
            CAST(NULL AS NVARCHAR(100)) AS SampleStatus,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    -- ───────────────────────────────────────────────────────────────────────
    --  Auto-detect dbo.LIMSMaster column names for each logical field
    --  (identical candidate lists/order to 19_PhiLife_ExecutiveSummary_LIS_Alt.sql).
    -- ───────────────────────────────────────────────────────────────────────
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','Accession')
        ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 ELSE 2 END);

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('RequestCollectDate','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'RequestCollectDate' THEN 0 WHEN 'DateofService' THEN 1
            WHEN 'CollectionDate' THEN 2 WHEN 'ServiceDate' THEN 3
            WHEN 'AccessionDate' THEN 4 ELSE 5 END);

    DECLARE @ResultedCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('RessultedStatus','ResultedStatus','ResultStatus','IsResulted')
        ORDER BY CASE name
            WHEN 'RessultedStatus' THEN 0 WHEN 'ResultedStatus' THEN 1
            WHEN 'ResultStatus' THEN 2 WHEN 'IsResulted' THEN 3 ELSE 4 END);

    DECLARE @ClaimStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'ClaimStatus');

    DECLARE @ClientStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClientStatus','Client_Status','Client')
        ORDER BY CASE name WHEN 'ClientStatus' THEN 0 WHEN 'Client_Status' THEN 1 WHEN 'Client' THEN 2 ELSE 3 END);

    DECLARE @PaymentMethodCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PaymentMethod','PayerType','PaymentType','BilledorNot')
        ORDER BY CASE name
            WHEN 'PaymentMethod' THEN 0 WHEN 'PayerType' THEN 1
            WHEN 'PaymentType' THEN 2 WHEN 'BilledorNot' THEN 3 ELSE 4 END);

    DECLARE @SampleStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('SampleStatus','Sample_Status')
        ORDER BY CASE name WHEN 'SampleStatus' THEN 0 WHEN 'Sample_Status' THEN 1 ELSE 2 END);

    DECLARE @PanelCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2
            WHEN 'TestPanelName' THEN 3 WHEN 'TestPanelname' THEN 4 WHEN 'TestPanel' THEN 5
            WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8 ELSE 9 END);

    -- Extra display-only columns (auto-detected, fall back to '').
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

    IF @AccCol IS NULL OR @DateCol IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS NVARCHAR(100)) AS Accession,
            CAST(NULL AS DATE)          AS DateOfService,
            CAST(NULL AS NVARCHAR(300)) AS PanelName,
            CAST(NULL AS NVARCHAR(100)) AS ResultedStatus,
            CAST(NULL AS NVARCHAR(100)) AS ClaimStatus,
            CAST(NULL AS NVARCHAR(100)) AS ClientStatus,
            CAST(NULL AS NVARCHAR(100)) AS PaymentMethod,
            CAST(NULL AS NVARCHAR(100)) AS SampleStatus,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @AccExpr           NVARCHAR(300) = N'LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N'])))';
    DECLARE @DateExpr          NVARCHAR(300) = N'TRY_CAST([' + @DateCol + N'] AS DATE)';
    DECLARE @ResultedExpr      NVARCHAR(300) = CASE WHEN @ResultedCol      IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ResultedCol      + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClaimStatusExpr   NVARCHAR(300) = CASE WHEN @ClaimStatusCol   IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ClaimStatusCol   + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClientStatusExpr  NVARCHAR(300) = CASE WHEN @ClientStatusCol  IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ClientStatusCol  + N']), '''')))' ELSE N'''''' END;
    DECLARE @PaymentMethodExpr NVARCHAR(300) = CASE WHEN @PaymentMethodCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @PaymentMethodCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @SampleStatusExpr  NVARCHAR(300) = CASE WHEN @SampleStatusCol  IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @SampleStatusCol  + N']), '''')))' ELSE N'''''' END;
    DECLARE @PanelExpr         NVARCHAR(400) = CASE WHEN @PanelCol         IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol        + N']), '''')))' ELSE N'''''' END;
    DECLARE @PatientExpr       NVARCHAR(400) = CASE WHEN @PatientCol       IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PatientCol      + N']), '''')))' ELSE N'''''' END;
    DECLARE @PayerExpr         NVARCHAR(400) = CASE WHEN @PayerCol         IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PayerCol        + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClinicExpr        NVARCHAR(400) = CASE WHEN @ClinicCol        IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol       + N']), '''')))' ELSE N'''''' END;
    DECLARE @ProviderExpr      NVARCHAR(400) = CASE WHEN @ProviderCol      IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol     + N']), '''')))' ELSE N'''''' END;

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
        ResultedNot     NVARCHAR(100) NOT NULL,
        ClaimStat       NVARCHAR(100) NOT NULL,
        ClientStat      NVARCHAR(100) NOT NULL,
        PayMethod       NVARCHAR(100) NOT NULL,
        SampleStat      NVARCHAR(100) NOT NULL,
        PatientName     NVARCHAR(300) NOT NULL,
        PayerName       NVARCHAR(300) NOT NULL,
        ClinicName      NVARCHAR(300) NOT NULL,
        BillingProvider NVARCHAR(300) NOT NULL,
        ESYear          INT           NOT NULL,
        ESMonth         INT           NOT NULL
    );

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #LisBase
            (Accession, DateOfService, PanelName, ResultedNot, ClaimStat, ClientStat, PayMethod, SampleStat,
             PatientName, PayerName, ClinicName, BillingProvider, ESYear, ESMonth)
        SELECT
            ' + @AccExpr      + N',
            ' + @DateExpr     + N',
            ' + @PanelExpr    + N',
            ' + @ResultedExpr + N',
            ' + @ClaimStatusExpr   + N',
            ' + @ClientStatusExpr  + N',
            ' + @PaymentMethodExpr + N',
            ' + @SampleStatusExpr  + N',
            ' + @PatientExpr  + N',
            ' + @PayerExpr    + N',
            ' + @ClinicExpr   + N',
            ' + @ProviderExpr + N',
            YEAR (' + @DateExpr + N'),
            MONTH(' + @DateExpr + N')
        FROM dbo.LIMSMaster
        WHERE ' + @DateExpr + N' IS NOT NULL
          AND NULLIF(' + @AccExpr + N', '''') IS NOT NULL
          AND (@iYear  = 0 OR YEAR (' + @DateExpr + N') = @iYear)
          AND (@iMonth = 0 OR MONTH(' + @DateExpr + N') = @iMonth);';

    EXEC sp_executesql @LisSql, N'@iYear INT, @iMonth INT', @iYear = @Year, @iMonth = @Month;

    -- 'B.<PanelName>' RowCodes drill into the panel sub-rows of 'B' (Resulted).
    DECLARE @PanelFilter NVARCHAR(300) = NULL;
    IF @RowCode LIKE 'B.%'
        SET @PanelFilter = SUBSTRING(@RowCode, 3, 300);

    SELECT
        b.Accession        AS Accession,
        b.DateOfService     AS DateOfService,
        b.PanelName         AS PanelName,
        b.ResultedNot       AS ResultedStatus,
        b.ClaimStat         AS ClaimStatus,
        b.ClientStat        AS ClientStatus,
        b.PayMethod         AS PaymentMethod,
        b.SampleStat        AS SampleStatus,
        b.PatientName       AS PatientName,
        b.PayerName         AS PayerName,
        b.ClinicName        AS ClinicName,
        b.BillingProvider   AS BillingProvider
    FROM #LisBase b
    WHERE
        -- A  Total Samples
        (@RowCode = 'A')
     OR -- B  Billable Samples - Resulted
        (@RowCode = 'B'   AND b.ResultedNot = 'Resulted')
     OR -- B.<PanelName>  Resulted, by panel
        (@PanelFilter IS NOT NULL AND b.ResultedNot = 'Resulted' AND b.PanelName COLLATE DATABASE_DEFAULT = @PanelFilter COLLATE DATABASE_DEFAULT)
     OR -- C / C.1  Billed to Insurance / Billed In AMD
        (@RowCode IN ('C','C.1') AND b.ResultedNot = 'Resulted' AND b.ClaimStat = 'Billed' AND b.ClientStat = '')
     OR -- D  Not Entered in AMD
        (@RowCode = 'D'   AND b.ResultedNot = 'Resulted' AND b.ClaimStat = 'Not Entered in AMD' AND b.ClientStat IN ('Billing Review Required','') AND b.PayMethod = 'Insurance')
     OR -- D.1  Received
        (@RowCode = 'D.1' AND b.ResultedNot = 'Resulted' AND b.ClaimStat = 'Not Entered in AMD' AND b.ClientStat = 'Billing Review Required' AND b.PayMethod = 'Insurance')
     OR -- D.2  Billing Review Required
        (@RowCode = 'D.2' AND b.ResultedNot = 'Resulted' AND b.ClaimStat = 'Not Entered in AMD' AND b.ClientStat = 'Billing Review Required' AND b.PayMethod = 'Insurance' AND b.SampleStat = 'Received')
     OR -- D.3  Collected
        (@RowCode = 'D.3' AND b.ResultedNot = 'Resulted' AND b.ClaimStat = 'Not Entered in AMD' AND b.ClientStat = '' AND b.PayMethod = 'Insurance' AND b.SampleStat = 'Collected')
     OR -- E  Unbilled
        (@RowCode = 'E'   AND b.ResultedNot = 'Resulted' AND b.ClientStat = '' AND b.ClaimStat = 'Entered')
     OR -- F  Client Bill
        (@RowCode = 'F'   AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Client Bill')
     OR -- F.1  Client Bill - Not Entered in AMD
        (@RowCode = 'F.1' AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Client Bill' AND b.ClaimStat = 'Not Entered in AMD')
     OR -- F.2  Client Bill - Billed
        (@RowCode = 'F.2' AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Client Bill' AND b.ClaimStat = 'Billed')
     OR -- G  Self Pay
        (@RowCode = 'G'   AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Self Pay')
     OR -- G.1  Self Pay - Billed
        (@RowCode = 'G.1' AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Self Pay' AND b.ClaimStat = 'Billed')
     OR -- G.2  Self Pay - Not Entered in AMD
        (@RowCode = 'G.2' AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Self Pay' AND b.ClaimStat = 'Not Entered in AMD')
     OR -- H  Test Entries
        (@RowCode = 'H'   AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Test Entries' AND b.PayMethod <> 'No Bill')
     OR -- H.1  Test Entries - Not Entered in AMD
        (@RowCode = 'H.1' AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Test Entries' AND b.PayMethod <> 'No Bill' AND b.ClaimStat = 'Not Entered in AMD')
     OR -- H.2  Test Entries - Billed
        (@RowCode = 'H.2' AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Test Entries' AND b.PayMethod <> 'No Bill' AND b.ClaimStat = 'Billed')
     OR -- I  Rejected Sample
        (@RowCode = 'I'   AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Rejected Sample')
     OR -- I.1  Rejected Sample - Not Entered in AMD
        (@RowCode = 'I.1' AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Rejected Sample' AND b.ClaimStat = 'Not Entered in AMD')
     OR -- I.2  Rejected Sample - Billed
        (@RowCode = 'I.2' AND b.ResultedNot = 'Resulted' AND b.ClientStat = 'Rejected Sample' AND b.ClaimStat = 'Billed')
     OR -- J  PaymentMethod No Bill
        (@RowCode = 'J'   AND b.ResultedNot = 'Resulted' AND b.PayMethod = 'No Bill')
     OR -- K  Not Resulted
        (@RowCode = 'K'   AND b.ResultedNot = 'Not Resulted')
     OR -- L  Not Entered in AMD
        (@RowCode = 'L'   AND b.ResultedNot = 'Not Resulted' AND b.ClaimStat = 'Not Entered in AMD' AND b.ClientStat = '' AND b.PayMethod = 'Insurance')
     OR -- L.1  Received
        (@RowCode = 'L.1' AND b.ResultedNot = 'Not Resulted' AND b.ClaimStat = 'Not Entered in AMD' AND b.ClientStat = '' AND b.PayMethod = 'Insurance' AND b.SampleStat = 'Received')
     OR -- L.2  Collected
        (@RowCode = 'L.2' AND b.ResultedNot = 'Not Resulted' AND b.ClaimStat = 'Not Entered in AMD' AND b.ClientStat = '' AND b.PayMethod = 'Insurance' AND b.SampleStat = 'Collected')
     OR -- M  Client Bill
        (@RowCode = 'M'   AND b.ResultedNot = 'Not Resulted' AND b.ClientStat = 'Client Bill')
     OR -- N  Test Entries
        (@RowCode = 'N'   AND b.ResultedNot = 'Not Resulted' AND b.ClientStat = 'Test Entries' AND b.PayMethod = 'Insurance')
     OR -- O  Rejected Sample
        (@RowCode = 'O'   AND b.ResultedNot = 'Not Resulted' AND b.ClientStat = 'Rejected Sample' AND b.PayMethod = 'Insurance')
     OR -- P  PaymentMethod No Bill
        (@RowCode = 'P'   AND b.ResultedNot = 'Not Resulted' AND b.PayMethod = 'No Bill')
     OR -- Fallback: unrecognized RowCode -> return everything in the period
        (@RowCode NOT IN ('A','B','C','C.1','D','D.1','D.2','D.3','E','F','F.1','F.2','G','G.1','G.2','H','H.1','H.2','I','I.1','I.2','J','K','L','L.1','L.2','M','N','O','P')
         AND @PanelFilter IS NULL)
    ORDER BY b.DateOfService, b.Accession;

    DROP TABLE IF EXISTS #LisBase;
END;
GO

PRINT '20_PhiLife_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO
