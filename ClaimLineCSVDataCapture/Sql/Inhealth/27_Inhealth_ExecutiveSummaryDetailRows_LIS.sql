-- ============================================================
-- Inhealth – Executive Summary LIS Detail-Rows SP (generic name)
-- File : 27_Inhealth_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : Inhealth_LRN
--
-- Mirrors Augustus\20_Augustus_ExecutiveSummaryDetailRows_LIS.sql.
-- Uses the GENERIC procedure name dbo.usp_GetExecutiveSummaryDetail_LIS
-- (called by ExecutiveSummaryController.Detail for ANY lab's 'LIS' category).
-- Each lab DB has its own copy of this SP.
--
-- Inhealth LIS hierarchy:
--   A             Total Samples              (NA not blank)
--   B             Billable Samples           (NA=blank AND SampleStatus='Billable')
--     B1.{Panel}  panel sub-rows             (B1. + LRNPanelName)
--   C             Billed                     (Billable AND BillCategory='Billed')
--     C.1         Billed Via AMD             (+ SubStatus='Billed Via AMD')
--   D             Unbilled                   (Billable AND BillCategory='Not Billed')
--     D.1         Nexum_Claim_scrubber_Eligibility
--     D.2         Requires Review
--     D.3         Entered in AMD but not billed
--     D.4         Nexum Pre Processing Queue
--     D.5         Nexum_Claim_scrubber_AMD Output
--     D.6         Nexum_Claim_scrubber_Diagnosis Validity
--   E             Other Samples              (NA=blank AND SampleStatus='Other Samples')
--     E.1         Billed
--     E.2         Unbilled
--     E.3         Other Samples (LIS Table breakdown)
--     E.4         Self Pay                   (SampleStatus='Self Pay')
--     E.5         Deleted/Rejected           (SampleStatus='Deleted/Rejected')
--     E.6         Duplicate                  (SampleStatus='Duplicate')
--     E.7         System Test                (SampleStatus='System Test')
--
-- Column auto-detection candidate lists:
--   @OrderIDCol      : OrderID (0), OrderId, AccessionNumber, Accession, AccessionNo
--   @NACol           : NA (0), IsNA, NotApplicable, NA_Flag, NAStatus
--   @DateCol         : ReqCollectDate (0), RequestCollectDate, DateOfCollection, ...
--   @SampleStatusCol : SampleStatus (0), BillTo, Sample_Status, SampleType
--   @BillCategoryCol : BillCategory (0), BillingStatus, Bill_Category, BillingCategory
--   @SubStatusCol    : SubStatus (0), FinalStatus, Sub_Status, ClientStatus
--   @PanelNameCol    : LRNPanelName (0), LRN_PanelName, LRNPanel, PanelName, PanelType, ...
--   Extra display    : PatientName, PayerName/InsuranceName, ClinicName/ClientName, BillingProvider
--
-- @Year/@Month: 0 = all (matches (0,0) grand-total sentinel).
-- Unrecognized @RowCode -> returns every row in the period.
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
            CAST(NULL AS NVARCHAR(100)) AS OrderID,
            CAST(NULL AS DATE)          AS ReqCollectDate,
            CAST(NULL AS NVARCHAR(200)) AS SampleStatus,
            CAST(NULL AS NVARCHAR(200)) AS BillCategory,
            CAST(NULL AS NVARCHAR(200)) AS SubStatus,
            CAST(NULL AS NVARCHAR(200)) AS LRNPanelName,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    -- ── Auto-detect columns ──────────────────────────────────────────────────
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

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ReqCollectDate','Entry_DateCreated','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'ReqCollectDate' THEN 0 WHEN 'Entry_DateCreated' THEN 1 WHEN 'RequestCollectDate' THEN 2
            WHEN 'DateOfCollection' THEN 3 WHEN 'DateofService' THEN 4
            WHEN 'CollectionDate' THEN 5 WHEN 'ServiceDate' THEN 6 WHEN 'AccessionDate' THEN 7 ELSE 8 END);

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

    DECLARE @PanelNameCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('LRNPanelName','LRN_PanelName','LRNPanel','PanelName','Panelname','PanelType','PanelCategory','TestPanel','TestPanelName')
        ORDER BY CASE name
            WHEN 'LRNPanelName'  THEN 0 WHEN 'LRN_PanelName' THEN 1 WHEN 'LRNPanel'      THEN 2
            WHEN 'PanelName'     THEN 3 WHEN 'Panelname'     THEN 4 WHEN 'PanelType'     THEN 5
            WHEN 'PanelCategory' THEN 6 WHEN 'TestPanel'     THEN 7 WHEN 'TestPanelName' THEN 8 ELSE 9 END);

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
          AND name IN ('ClinicName','ClientName','Client_Name','Clinic','FacilityName','Facility')
        ORDER BY CASE name WHEN 'ClinicName' THEN 0 WHEN 'ClientName' THEN 1 WHEN 'Client_Name' THEN 2 WHEN 'Clinic' THEN 3 WHEN 'FacilityName' THEN 4 ELSE 5 END);

    DECLARE @ProviderCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillingProvider','Provider','OrderingProvider','RenderingProvider')
        ORDER BY CASE name WHEN 'BillingProvider' THEN 0 WHEN 'Provider' THEN 1 WHEN 'OrderingProvider' THEN 2 ELSE 3 END);

    IF @OrderIDCol IS NULL OR @DateCol IS NULL OR @SampleStatusCol IS NULL
       OR @BillCategoryCol IS NULL OR @SubStatusCol IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS NVARCHAR(100)) AS OrderID,
            CAST(NULL AS DATE)          AS ReqCollectDate,
            CAST(NULL AS NVARCHAR(200)) AS SampleStatus,
            CAST(NULL AS NVARCHAR(200)) AS BillCategory,
            CAST(NULL AS NVARCHAR(200)) AS SubStatus,
            CAST(NULL AS NVARCHAR(200)) AS LRNPanelName,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @OrderExpr      NVARCHAR(300) = N'LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @OrderIDCol + N'])))';
    DECLARE @DateExpr       NVARCHAR(300) = N'TRY_CAST([' + @DateCol + N'] AS DATE)';
    DECLARE @NAExpr         NVARCHAR(300) = CASE WHEN @NACol IS NOT NULL
        THEN N'ISNULL(CONVERT(NVARCHAR(50), [' + @NACol + N']), '''')'
        ELSE N'''''' END;
    DECLARE @SSExpr         NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SampleStatusCol + N']), '''')))';
    DECLARE @BCExpr         NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), '''')))';
    DECLARE @SubExpr        NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol    + N']), '''')))';
    DECLARE @PanelExpr      NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @PatientExpr    NVARCHAR(400) = CASE WHEN @PatientCol  IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PatientCol  + N']), '''')))' ELSE N'''''' END;
    DECLARE @PayerExpr      NVARCHAR(400) = CASE WHEN @PayerCol    IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PayerCol    + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClinicExpr     NVARCHAR(400) = CASE WHEN @ClinicCol   IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol   + N']), '''')))' ELSE N'''''' END;
    DECLARE @ProviderExpr   NVARCHAR(400) = CASE WHEN @ProviderCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), '''')))' ELSE N'''''' END;

    -- ── Pull matching LIMSMaster rows into temp table ────────────────────────
    DROP TABLE IF EXISTS #LisBase;
    CREATE TABLE #LisBase
    (
        OrderID         NVARCHAR(100) NOT NULL,
        ReqCollectDate  DATE          NULL,
        NAFlag          NVARCHAR(50)  NOT NULL,
        SampleStatus    NVARCHAR(200) NOT NULL,
        BillCategory    NVARCHAR(200) NOT NULL,
        SubStatus       NVARCHAR(200) NOT NULL,
        LRNPanelName    NVARCHAR(200) NOT NULL,
        PatientName     NVARCHAR(300) NOT NULL,
        PayerName       NVARCHAR(300) NOT NULL,
        ClinicName      NVARCHAR(300) NOT NULL,
        BillingProvider NVARCHAR(300) NOT NULL
    );

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #LisBase
            (OrderID, ReqCollectDate, NAFlag, SampleStatus, BillCategory, SubStatus, LRNPanelName,
             PatientName, PayerName, ClinicName, BillingProvider)
        SELECT
            ' + @OrderExpr   + N',
            ' + @DateExpr    + N',
            ' + @NAExpr      + N',
            ' + @SSExpr      + N',
            ' + @BCExpr      + N',
            ' + @SubExpr     + N',
            ' + @PanelExpr   + N',
            ' + @PatientExpr + N',
            ' + @PayerExpr   + N',
            ' + @ClinicExpr  + N',
            ' + @ProviderExpr+ N'
        FROM dbo.LIMSMaster
        WHERE ' + @DateExpr + N' IS NOT NULL
          AND NULLIF(' + @OrderExpr + N', '''') IS NOT NULL
          AND (@iYear  = 0 OR YEAR (' + @DateExpr + N') = @iYear)
          AND (@iMonth = 0 OR MONTH(' + @DateExpr + N') = @iMonth);';

    EXEC sp_executesql @LisSql, N'@iYear INT, @iMonth INT', @iYear=@Year, @iMonth=@Month;

    SELECT
        b.OrderID,
        b.ReqCollectDate,
        b.SampleStatus,
        b.BillCategory,
        b.SubStatus,
        b.LRNPanelName,
        b.PatientName,
        b.PayerName,
        b.ClinicName,
        b.BillingProvider
    FROM #LisBase b
    WHERE
        -- ── A: Total Samples (NA not blank) ──────────────────────────────────
           (@RowCode = 'A'   AND NULLIF(b.NAFlag,'') IS NOT NULL)
        -- ── B: Billable Samples ──────────────────────────────────────────────
        OR (@RowCode = 'B'   AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable')
        -- ── B1.{Panel}: panel sub-rows ───────────────────────────────────────
        OR (LEFT(@RowCode,3)='B1.' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable'
                                    AND b.LRNPanelName = SUBSTRING(@RowCode, 4, 350))
        -- ── C: Billed ────────────────────────────────────────────────────────
        OR (@RowCode = 'C'   AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable' AND b.BillCategory='Billed')
        -- ── C.1: Billed Via AMD ──────────────────────────────────────────────
        OR (@RowCode = 'C.1' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable' AND b.BillCategory='Billed' AND b.SubStatus='Billed Via AMD')
        -- ── D: Unbilled ──────────────────────────────────────────────────────
        OR (@RowCode = 'D'   AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable' AND b.BillCategory='Not Billed')
        OR (@RowCode = 'D.1' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Nexum_Claim_scrubber_Eligibility')
        OR (@RowCode = 'D.2' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Requires Review')
        OR (@RowCode = 'D.3' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Entered in AMD but not billed')
        OR (@RowCode = 'D.4' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Nexum Pre Processing Queue')
        OR (@RowCode = 'D.5' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Nexum_Claim_scrubber_AMD Output')
        OR (@RowCode = 'D.6' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Billable' AND b.BillCategory='Not Billed' AND b.SubStatus='Nexum_Claim_scrubber_Diagnosis Validity')
        -- ── E: Other / Self Pay / Deleted / Duplicate / System Test ──────────
        OR (@RowCode = 'E'   AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Other Samples')
        OR (@RowCode = 'E.1' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Other Samples' AND b.BillCategory='Billed')
        OR (@RowCode = 'E.2' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Other Samples' AND b.BillCategory='Not Billed')
        OR (@RowCode = 'E.3' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Other Samples')
        OR (@RowCode = 'E.4' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Self Pay')
        OR (@RowCode = 'E.5' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Deleted/Rejected')
        OR (@RowCode = 'E.6' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='Duplicate')
        OR (@RowCode = 'E.7' AND ISNULL(b.NAFlag,'')='' AND b.SampleStatus='System Test')
        -- ── Fallback: unrecognized RowCode -> return every row in the period ─
        OR (
            LEFT(@RowCode,3) <> 'B1.'
            AND @RowCode NOT IN (
                'A','B','C','C.1',
                'D','D.1','D.2','D.3','D.4','D.5','D.6',
                'E','E.1','E.2','E.3','E.4','E.5','E.6','E.7')
        )
    ORDER BY b.ReqCollectDate, b.OrderID;

    DROP TABLE IF EXISTS #LisBase;
END;
GO

PRINT '27_Inhealth_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO
