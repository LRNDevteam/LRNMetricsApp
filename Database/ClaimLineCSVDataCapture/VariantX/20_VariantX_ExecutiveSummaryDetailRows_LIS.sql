/* =============================================================================
   VariantX – Executive Summary LIS Detail-Rows SP
   Mirrors 19_VariantX_ExecutiveSummary_LIS_Alt RoleIDs / SampleStatus / TestType.
   Generic name: dbo.usp_GetExecutiveSummaryDetail_LIS
   ============================================================================= */
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
            WHEN 'DateOfCollection' THEN 0 WHEN 'RequestCollectDate' THEN 1
            WHEN 'CollectionDate' THEN 2 WHEN 'DateofService' THEN 3
            WHEN 'ServiceDate' THEN 4 WHEN 'AccessionDate' THEN 5 ELSE 6 END);

    DECLARE @SampleStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('SampleStatus','NewStatus','Status','LRNSampleStatus')
        ORDER BY CASE name
            WHEN 'SampleStatus' THEN 0 WHEN 'LRNSampleStatus' THEN 1
            WHEN 'NewStatus' THEN 2 WHEN 'Status' THEN 3 ELSE 4 END);

    DECLARE @BillCategoryCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus','LRNBillCategory')
        ORDER BY CASE name
            WHEN 'BillCategory' THEN 0 WHEN 'LRNBillCategory' THEN 1
            WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3
            WHEN 'BillStatus' THEN 4 ELSE 5 END);

    DECLARE @ResultStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ResultStatus','Result_Status','ResultedStatus','RessultedStatus','IsResulted')
        ORDER BY CASE name
            WHEN 'ResultStatus' THEN 0 WHEN 'Result_Status' THEN 1
            WHEN 'ResultedStatus' THEN 2 WHEN 'RessultedStatus' THEN 3
            WHEN 'IsResulted' THEN 4 ELSE 5 END);

    DECLARE @TestTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('TestType','Panel','PanelName','PanelType','TestPanel','PanelCategory')
        ORDER BY CASE name
            WHEN 'TestType' THEN 0 WHEN 'Panel' THEN 1 WHEN 'PanelName' THEN 2
            WHEN 'PanelType' THEN 3 WHEN 'TestPanel' THEN 4 ELSE 5 END);

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
          AND name IN ('BillingProvider','Provider','OrderingProvider','RenderingProvider','PhysicianName')
        ORDER BY CASE name WHEN 'BillingProvider' THEN 0 WHEN 'Provider' THEN 1 WHEN 'OrderingProvider' THEN 2 WHEN 'PhysicianName' THEN 3 ELSE 4 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @SampleStatusCol IS NULL OR @BillCategoryCol IS NULL
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

    DECLARE @AccExpr NVARCHAR(300) = N'LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N'])))';
    DECLARE @DateExpr NVARCHAR(300) = N'TRY_CAST([' + @DateCol + N'] AS DATE)';
    DECLARE @SampleStatusExpr NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @SampleStatusCol + N']), '''')))';
    DECLARE @BillCategoryExpr NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), '''')))';
    DECLARE @TestTypeExpr NVARCHAR(400) = CASE WHEN @TestTypeCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @TestTypeCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @PatientExpr NVARCHAR(400) = CASE WHEN @PatientCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PatientCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @PayerExpr NVARCHAR(400) = CASE WHEN @PayerCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PayerCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClinicExpr NVARCHAR(400) = CASE WHEN @ClinicCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @ProviderExpr NVARCHAR(400) = CASE WHEN @ProviderCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), '''')))' ELSE N'''''' END;

    DECLARE @ResultExpr NVARCHAR(400);
    IF @ResultStatusCol IS NULL
        SET @ResultExpr = N'CAST('''' AS NVARCHAR(100))';
    ELSE IF @ResultStatusCol = 'IsResulted'
        SET @ResultExpr = N'(CASE WHEN TRY_CAST([' + @ResultStatusCol + N'] AS INT) = 1 THEN ''Resulted''
                                   WHEN CONVERT(NVARCHAR(20), [' + @ResultStatusCol + N']) IN (''Y'',''Yes'',''True'',''Resulted'') THEN ''Resulted''
                                   ELSE ''Not Resulted'' END)';
    ELSE
        SET @ResultExpr = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ResultStatusCol + N']), '''')))';

    -- Sub-row suffixes: B.{TestType} or D.{SampleStatus}
    DECLARE @Suffix NVARCHAR(300) = NULL;
    IF @RowCode LIKE 'B.%' SET @Suffix = SUBSTRING(@RowCode, 3, 300);
    IF @RowCode LIKE 'D.%' SET @Suffix = SUBSTRING(@RowCode, 3, 300);

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
            ' + @AccExpr + N',
            ' + @DateExpr + N',
            ' + @TestTypeExpr + N',
            ' + @SampleStatusExpr + N',
            ' + @BillCategoryExpr + N',
            ' + @ResultExpr + N',
            ' + @PatientExpr + N',
            ' + @PayerExpr + N',
            ' + @ClinicExpr + N',
            ' + @ProviderExpr + N',
            YEAR (' + @DateExpr + N'),
            MONTH(' + @DateExpr + N')
        FROM dbo.LIMSMaster
        WHERE ' + @DateExpr + N' IS NOT NULL
          AND NULLIF(' + @AccExpr + N', '''') IS NOT NULL
          AND (@iYear  = 0 OR YEAR (' + @DateExpr + N') = @iYear)
          AND (@iMonth = 0 OR MONTH(' + @DateExpr + N') = @iMonth);';

    EXEC sp_executesql @LisSql, N'@iYear INT, @iMonth INT', @iYear = @Year, @iMonth = @Month;

    SELECT
        b.Accession,
        b.DateOfService,
        b.PanelName,
        b.NewStatus,
        b.BillCategory,
        b.ResultStatus,
        b.PatientName,
        b.PayerName,
        b.ClinicName,
        b.BillingProvider
    FROM #LisBase b
    WHERE
           (@RowCode = 'A')
        OR (@RowCode = 'B' AND b.NewStatus = 'Billable')
        OR (@RowCode LIKE 'B.%' AND b.NewStatus = 'Billable' AND b.PanelName = @Suffix)
        OR (@RowCode = 'C' AND b.NewStatus = 'Billable' AND b.BillCategory = 'Billed')
        OR (@RowCode = 'D' AND b.NewStatus <> 'Billable' AND b.NewStatus <> '')
        OR (@RowCode LIKE 'D.%' AND b.NewStatus = @Suffix)
    ORDER BY b.DateOfService, b.Accession;

    DROP TABLE IF EXISTS #LisBase;
END;
GO

PRINT '20_VariantX_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO
