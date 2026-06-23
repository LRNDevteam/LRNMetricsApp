-- ============================================================
-- BeechTree – Generic Executive Summary LIS Detail Rows SP
-- File : 20_BeechTree_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : BeechTree_LRN
--
-- Mirrors Augustus\20_Augustus_ExecutiveSummaryDetailRows_LIS.sql.
-- Deployed per-lab DB with BeechTree-specific LIS filter logic.
-- Called by C# ExecutiveSummaryController with (@RowCode, @Year, @Month).
--
-- RowCode → filter mapping (BeechTree LIS column: RessultedStatus, ClaimStatus,
--   BilledorNot, ClientStatus, SampleStatus, PaymentMethod, PanelType):
--
--   A            Total Samples (all in period)
--   B            Billable Samples – Resulted
--   B1.<Panel>   Panel sub-rows: Resulted AND PanelType = SUBSTRING(@RowCode,4,350)
--   B2           Billed to Insurance
--   B2.1         Billed In AMD
--   B3           Not Entered in AMD
--   B3.1-B3.5    Sub-rows by SampleStatus
--   B4           Unbilled
--   B5           Client Bill (Resulted)
--   B5.1-B5.2    Sub-rows
--   B6           Self Pay (Resulted)
--   B6.1-B6.3    Sub-rows
--   B7           Test Entries (Resulted)
--   B7.1-B7.2    Sub-rows
--   B8           Rejected Sample (Resulted)
--   B8.1-B8.2    Sub-rows
--   B9           Payment Method No Bill
--   C            Not Resulted
--   C1           No Result date on LIS but Billed
--   C2           Not Entered in AMD (Not Resulted)
--   C2.1-C2.4    Sub-rows by SampleStatus
--   C3           Client Bill (Not Resulted)
--   C4           Self Pay (Not Resulted)
--   C4.1-C4.2    Sub-rows
--   D            Test Entries (Not Resulted)
--   E            Rejected Sample (Not Resulted)
--
-- Source table columns (dynamic detection):
--   AccessionNumber, VisitNumber, OrderID, Accession
--   RequestCollectDate (priority 0), ReqCollectDate, ...
--   RessultedStatus, ResultedStatus, ...
--   ClaimStatus
--   BilledorNot, BilledStatus, BilledUnbilled
--   ClientStatus
--   SampleStatus
--   PaymentMethod
--   PanelType, PanelName, Panelname, ...
--   PatientName
--   ClientName / ClinicName
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LIS
(
    @RowCode NVARCHAR(50),
    @Year    INT = 0,
    @Month   INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        SELECT TOP 0
            CAST(NULL AS NVARCHAR(100)) AS VisitNumber,
            CAST(NULL AS NVARCHAR(200)) AS PatientName,
            CAST(NULL AS NVARCHAR(200)) AS ClientName,
            CAST(NULL AS DATE)          AS ReqCollectDate,
            CAST(NULL AS NVARCHAR(200)) AS Resulted,
            CAST(NULL AS NVARCHAR(200)) AS ClaimStatus,
            CAST(NULL AS NVARCHAR(200)) AS BilledorNot,
            CAST(NULL AS NVARCHAR(200)) AS ClientStatus,
            CAST(NULL AS NVARCHAR(200)) AS SampleStatus,
            CAST(NULL AS NVARCHAR(200)) AS PaymentMethod,
            CAST(NULL AS NVARCHAR(200)) AS PanelType;
        RETURN;
    END

    -- ── Dynamic column detection ─────────────────────────────────────────────
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','VisitNumber','OrderID','Accession','AccessionNo')
        ORDER BY CASE name
            WHEN 'AccessionNumber' THEN 0 WHEN 'VisitNumber' THEN 1
            WHEN 'OrderID' THEN 2 WHEN 'Accession' THEN 3 WHEN 'AccessionNo' THEN 4 ELSE 5 END);

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('RequestCollectDate','ReqCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'RequestCollectDate' THEN 0 WHEN 'ReqCollectDate' THEN 1
            WHEN 'DateOfCollection'   THEN 2 WHEN 'DateofService'  THEN 3
            WHEN 'CollectionDate'     THEN 4 WHEN 'ServiceDate'    THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

    DECLARE @ResultedCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('RessultedStatus','ResultedStatus','ResultedNot','Resulted_Not','IsResulted','Resulted')
        ORDER BY CASE name
            WHEN 'RessultedStatus' THEN 0 WHEN 'ResultedStatus' THEN 1
            WHEN 'ResultedNot' THEN 2 WHEN 'Resulted_Not' THEN 3
            WHEN 'IsResulted' THEN 4 WHEN 'Resulted' THEN 5 ELSE 6 END);

    DECLARE @ClaimStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClaimStatus','ClaimStatusCode')
        ORDER BY CASE name WHEN 'ClaimStatus' THEN 0 ELSE 1 END);

    DECLARE @BilledorNotCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BilledorNot','BilledStatus','BilledUnbilled','BillOrNot')
        ORDER BY CASE name WHEN 'BilledorNot' THEN 0 WHEN 'BilledStatus' THEN 1 WHEN 'BilledUnbilled' THEN 2 ELSE 3 END);

    DECLARE @ClientStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClientStatus','ClientStatus1','ClientStatusCode')
        ORDER BY CASE name WHEN 'ClientStatus' THEN 0 ELSE 1 END);

    DECLARE @SampleStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('SampleStatus','Sample_Status','SampleStatusCode')
        ORDER BY CASE name WHEN 'SampleStatus' THEN 0 ELSE 1 END);

    DECLARE @PaymentMethodCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PaymentMethod','Payment_Method','PayMethod')
        ORDER BY CASE name WHEN 'PaymentMethod' THEN 0 ELSE 1 END);

    DECLARE @PanelTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelType','PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','TestName','Test_Panel')
        ORDER BY CASE name
            WHEN 'PanelType' THEN 0 WHEN 'PanelCategory' THEN 1 WHEN 'PanelName' THEN 2
            WHEN 'Panelname' THEN 3 WHEN 'TestPanel' THEN 4 ELSE 5 END);

    DECLARE @PatientNameCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PatientName','Patient_Name','PatientFullName')
        ORDER BY CASE name WHEN 'PatientName' THEN 0 ELSE 1 END);

    DECLARE @ClientNameCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClientName','Client_Name','ClinicName','Client')
        ORDER BY CASE name WHEN 'ClientName' THEN 0 ELSE 1 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @ResultedCol IS NULL
    BEGIN
        PRINT 'usp_GetExecutiveSummaryDetail_LIS (BeechTree): required columns missing.';
        SELECT TOP 0
            CAST(NULL AS NVARCHAR(100)) AS VisitNumber,
            CAST(NULL AS NVARCHAR(200)) AS PatientName,
            CAST(NULL AS NVARCHAR(200)) AS ClientName,
            CAST(NULL AS DATE)          AS ReqCollectDate,
            CAST(NULL AS NVARCHAR(200)) AS Resulted,
            CAST(NULL AS NVARCHAR(200)) AS ClaimStatus,
            CAST(NULL AS NVARCHAR(200)) AS BilledorNot,
            CAST(NULL AS NVARCHAR(200)) AS ClientStatus,
            CAST(NULL AS NVARCHAR(200)) AS SampleStatus,
            CAST(NULL AS NVARCHAR(200)) AS PaymentMethod,
            CAST(NULL AS NVARCHAR(200)) AS PanelType;
        RETURN;
    END

    -- ── Build #Lis staging ───────────────────────────────────────────────────
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession      NVARCHAR(100) NOT NULL,
        ReqCollectDate DATE          NULL,
        Resulted       NVARCHAR(200) NOT NULL,
        ClaimStatus    NVARCHAR(200) NOT NULL,
        BilledorNot    NVARCHAR(200) NOT NULL,
        ClientStatus   NVARCHAR(200) NOT NULL,
        SampleStatus   NVARCHAR(200) NOT NULL,
        PaymentMethod  NVARCHAR(200) NOT NULL,
        PanelType      NVARCHAR(200) NOT NULL,
        PatientName    NVARCHAR(200) NOT NULL,
        ClientName     NVARCHAR(200) NOT NULL
    );

    DECLARE @CSExpr  NVARCHAR(400) = CASE WHEN @ClaimStatusCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @ClaimStatusCol + N']),'''')))'   ELSE N'''''' END;
    DECLARE @BONExpr NVARCHAR(400) = CASE WHEN @BilledorNotCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @BilledorNotCol + N']),'''')))'   ELSE N'''''' END;
    DECLARE @CLExpr  NVARCHAR(400) = CASE WHEN @ClientStatusCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @ClientStatusCol + N']),'''')))'  ELSE N'''''' END;
    DECLARE @SSExpr  NVARCHAR(400) = CASE WHEN @SampleStatusCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @SampleStatusCol + N']),'''')))'  ELSE N'''''' END;
    DECLARE @PMExpr  NVARCHAR(400) = CASE WHEN @PaymentMethodCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @PaymentMethodCol + N']),'''')))'  ELSE N'''''' END;
    DECLARE @PTExpr  NVARCHAR(400) = CASE WHEN @PanelTypeCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @PanelTypeCol + N']),'''')))'      ELSE N'''''' END;
    DECLARE @PNExpr  NVARCHAR(400) = CASE WHEN @PatientNameCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @PatientNameCol + N']),'''')))'    ELSE N'''''' END;
    DECLARE @CNExpr  NVARCHAR(400) = CASE WHEN @ClientNameCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @ClientNameCol + N']),'''')))'     ELSE N'''''' END;

    DECLARE @Sql NVARCHAR(MAX) = N'
        INSERT INTO #Lis
            (Accession, ReqCollectDate, Resulted, ClaimStatus, BilledorNot,
             ClientStatus, SampleStatus, PaymentMethod, PanelType, PatientName, ClientName)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(100),[' + @AccCol + N']))),
            TRY_CAST([' + @DateCol + N'] AS DATE),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @ResultedCol + N']),''''))),
            ' + @CSExpr  + N',
            ' + @BONExpr + N',
            ' + @CLExpr  + N',
            ' + @SSExpr  + N',
            ' + @PMExpr  + N',
            ' + @PTExpr  + N',
            ' + @PNExpr  + N',
            ' + @CNExpr  + N'
        FROM dbo.LIMSMaster
        WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),[' + @AccCol + N']))),'''') IS NOT NULL
          AND (@iYear=0  OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) = @iYear)
          AND (@iMonth=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) = @iMonth);';

    EXEC sp_executesql @Sql,
        N'@iYear INT, @iMonth INT',
        @iYear=@Year, @iMonth=@Month;

    -- ── Output ───────────────────────────────────────────────────────────────
    SELECT DISTINCT
        b.Accession    AS VisitNumber,
        b.PatientName,
        b.ClientName,
        b.ReqCollectDate,
        b.Resulted,
        b.ClaimStatus,
        b.BilledorNot,
        b.ClientStatus,
        b.SampleStatus,
        b.PaymentMethod,
        b.PanelType
    FROM #Lis b
    WHERE
        -- A: Total Samples
           (@RowCode = 'A')
        -- B: Billable Samples – Resulted
        OR (@RowCode = 'B'     AND b.Resulted='Resulted')
        -- B1.<PanelType>: panel sub-rows
        OR (LEFT(@RowCode,3) = 'B1.' AND b.Resulted='Resulted'
                                     AND b.PanelType = SUBSTRING(@RowCode, 4, 350))
        -- B2: Billed to Insurance
        OR (@RowCode = 'B2'    AND b.Resulted='Resulted' AND b.ClaimStatus='Billed' AND b.BilledorNot='Billed' AND b.ClientStatus='')
        OR (@RowCode = 'B2.1'  AND b.Resulted='Resulted' AND b.ClaimStatus='Billed' AND b.BilledorNot='Billed' AND b.ClientStatus='')
        -- B3: Not Entered in AMD (Resulted)
        OR (@RowCode = 'B3'    AND b.Resulted='Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus IN ('','Billing Review Required'))
        OR (@RowCode = 'B3.1'  AND b.Resulted='Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus IN ('','Billing Review Required') AND b.SampleStatus='Received')
        OR (@RowCode = 'B3.2'  AND b.Resulted='Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.SampleStatus='Received' AND b.ClientStatus='Billing Review Required')
        OR (@RowCode = 'B3.3'  AND b.Resulted='Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus IN ('','Billing Review Required') AND b.SampleStatus='In Transit')
        OR (@RowCode = 'B3.4'  AND b.Resulted='Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus IN ('','Billing Review Required') AND b.SampleStatus='Transferred')
        OR (@RowCode = 'B3.5'  AND b.Resulted='Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus IN ('','Billing Review Required') AND b.SampleStatus='Collected')
        -- B4: Unbilled
        OR (@RowCode = 'B4'    AND b.Resulted='Resulted' AND b.ClaimStatus='Entered' AND b.BilledorNot='UnBilled' AND b.ClientStatus='')
        -- B5: Client Bill (Resulted)
        OR (@RowCode = 'B5'    AND b.Resulted='Resulted' AND b.ClientStatus='Client Bill')
        OR (@RowCode = 'B5.1'  AND b.Resulted='Resulted' AND b.ClientStatus='Client Bill' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled')
        OR (@RowCode = 'B5.2'  AND b.Resulted='Resulted' AND b.ClientStatus='Client Bill' AND b.BilledorNot='Billed')
        -- B6: Self Pay (Resulted)
        OR (@RowCode = 'B6'    AND b.Resulted='Resulted' AND b.ClientStatus='Self Pay')
        OR (@RowCode = 'B6.1'  AND b.Resulted='Resulted' AND b.ClientStatus='Self Pay' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled')
        OR (@RowCode = 'B6.2'  AND b.Resulted='Resulted' AND b.ClientStatus='Self Pay' AND b.BilledorNot='Billed')
        OR (@RowCode = 'B6.3'  AND b.Resulted='Resulted' AND b.ClientStatus='Self Pay' AND b.ClaimStatus='Entered' AND b.BilledorNot='UnBilled')
        -- B7: Test Entries (Resulted)
        OR (@RowCode = 'B7'    AND b.Resulted='Resulted' AND b.ClientStatus='Test Entries')
        OR (@RowCode = 'B7.1'  AND b.Resulted='Resulted' AND b.ClientStatus='Test Entries' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled')
        OR (@RowCode = 'B7.2'  AND b.Resulted='Resulted' AND b.ClientStatus='Test Entries' AND b.BilledorNot='Billed')
        -- B8: Rejected Sample (Resulted)
        OR (@RowCode = 'B8'    AND b.Resulted='Resulted' AND b.ClientStatus='Rejected Sample')
        OR (@RowCode = 'B8.1'  AND b.Resulted='Resulted' AND b.ClientStatus='Rejected Sample' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled')
        OR (@RowCode = 'B8.2'  AND b.Resulted='Resulted' AND b.ClientStatus='Rejected Sample' AND b.BilledorNot='Billed')
        -- B9: Payment Method No Bill
        OR (@RowCode = 'B9'    AND b.Resulted='Resulted' AND b.PaymentMethod='No Bill')
        -- C: Not Resulted
        OR (@RowCode = 'C'     AND b.Resulted='Not Resulted')
        OR (@RowCode = 'C1'    AND b.Resulted='Not Resulted' AND b.ClaimStatus='Billed' AND b.BilledorNot='Billed' AND b.ClientStatus='')
        OR (@RowCode = 'C2'    AND b.Resulted='Not Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus='')
        OR (@RowCode = 'C2.1'  AND b.Resulted='Not Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus='' AND b.SampleStatus='Received')
        OR (@RowCode = 'C2.2'  AND b.Resulted='Not Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus='' AND b.SampleStatus='In Transit')
        OR (@RowCode = 'C2.3'  AND b.Resulted='Not Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus='' AND b.SampleStatus='Collected')
        OR (@RowCode = 'C2.4'  AND b.Resulted='Not Resulted' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled' AND b.ClientStatus='' AND b.SampleStatus='Transferred')
        OR (@RowCode = 'C3'    AND b.Resulted='Not Resulted' AND b.ClientStatus='Client Bill')
        OR (@RowCode = 'C4'    AND b.Resulted='Not Resulted' AND b.ClientStatus='Self Pay')
        OR (@RowCode = 'C4.1'  AND b.Resulted='Not Resulted' AND b.ClientStatus='Self Pay' AND b.ClaimStatus='Not Entered in AMD' AND b.BilledorNot='UnBilled')
        OR (@RowCode = 'C4.2'  AND b.Resulted='Not Resulted' AND b.ClientStatus='Self Pay' AND b.BilledorNot='Billed')
        -- D: Test Entries (Not Resulted)
        OR (@RowCode = 'D'     AND b.Resulted='Not Resulted' AND b.ClientStatus='Test Entries')
        -- E: Rejected Sample (Not Resulted)
        OR (@RowCode = 'E'     AND b.Resulted='Not Resulted' AND b.ClientStatus='Rejected Sample')
        -- Fallback: unrecognized RowCode -> return all rows in period
        OR (
            LEFT(@RowCode,3) <> 'B1.'
            AND @RowCode NOT IN (
                'A','B','B2','B2.1',
                'B3','B3.1','B3.2','B3.3','B3.4','B3.5',
                'B4',
                'B5','B5.1','B5.2',
                'B6','B6.1','B6.2','B6.3',
                'B7','B7.1','B7.2',
                'B8','B8.1','B8.2',
                'B9',
                'C','C1','C2','C2.1','C2.2','C2.3','C2.4','C3',
                'C4','C4.1','C4.2','D','E')
        )
    ORDER BY b.ReqCollectDate, b.Accession;

    DROP TABLE IF EXISTS #Lis;
END;
GO

PRINT '20_BeechTree_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO
