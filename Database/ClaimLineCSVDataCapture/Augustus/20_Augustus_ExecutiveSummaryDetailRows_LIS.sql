-- ============================================================
-- Augustus – Executive Summary LIS Detail-Rows SP (generic name)
-- File : 20_Augustus_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : Augustus_LRN
--
-- Mirrors Cove\20_Cove_ExecutiveSummaryDetailRows_LIS.sql.
-- Uses the GENERIC (non lab-prefixed) procedure name
-- dbo.usp_GetExecutiveSummaryDetail_LIS, called by
-- ExecutiveSummaryController.Detail for ANY lab's 'LIS' category.
--
-- Augustus LIS hierarchy (new structure, file 30):
--   A  = Total Samples (all)
--   B  = Billable Samples (BillTo LIKE '%Insurance%')
--     B1.<PanelType> = panel sub-rows under B
--     B2.1           = Billed
--       B2.1.1       = Claim Submitted in IRCM
--       B2.1.2       = Claim Submitted in Daqbilling
--     B2.2           = Unbilled
--       B2.2.1       = Resulted yet to be billed
--       B2.2.1*      = Ready to bill
--       B2.2.2       = Insurance name not listed
--   C, C.1 = Yet to be Validated / Billed
--   D, D.1 = Client Bills / Billed
--   E, E.1 = System Test / Billed
--   F, F.1 = Self pay / Billed
--
-- Column auto-detection (same candidate lists as file 19):
--   @AccCol          : AccessionNumber, Accession, AccessionNo
--   @DateCol         : RequestCollectDate (priority 0), ReqCollectDate, DateOfCollection, ...
--   @BillToCol       : BillTo, BillCategory, Bill_Category, ...
--   @BillingStatusCol: BillingStatus, NewStatus, Status, BillStatus
--   @FinalStatusCol  : FinalStatus, SubStatus, Sub_Status, ClientStatus
--   @ClientStatus1Col: ClientStatus1, ClientStatus2, ClientFlag
--   @PanelTypeCol    : PanelType, PanelCategory, PanelName, Panelname, ...
--   Extra display    : PatientName, PayerName / InsuranceName, ClinicName / ClientName, BillingProvider
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
            CAST(NULL AS NVARCHAR(100)) AS Accession,
            CAST(NULL AS DATE)          AS ReqCollectDate,
            CAST(NULL AS NVARCHAR(200)) AS BillTo,
            CAST(NULL AS NVARCHAR(200)) AS BillingStatus,
            CAST(NULL AS NVARCHAR(200)) AS FinalStatus,
            CAST(NULL AS NVARCHAR(200)) AS ClientStatus1,
            CAST(NULL AS NVARCHAR(200)) AS PanelType,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    -- ── Auto-detect columns ──────────────────────────────────────────────────
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
          AND name IN ('ClientStatus1','ClientStatus2','ClientFlag')
        ORDER BY CASE name WHEN 'ClientStatus1' THEN 0 WHEN 'ClientStatus2' THEN 1 WHEN 'ClientFlag' THEN 2 ELSE 3 END);

    -- PanelType: same candidate list as file 19 / Cove
    DECLARE @PanelTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelType','PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelType'        THEN 0 WHEN 'PanelCategory'   THEN 1 WHEN 'PanelName'      THEN 2
            WHEN 'Panelname'        THEN 3 WHEN 'TestPanel'        THEN 4 WHEN 'TestPanelName'  THEN 5
            WHEN 'Panel'            THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'       THEN 8
            WHEN 'Test_Panel'       THEN 9 WHEN 'TestPanelname'    THEN 10 ELSE 11 END);

    -- Extra display-only columns (best-effort)
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

    IF @AccCol IS NULL OR @DateCol IS NULL OR @BillToCol IS NULL OR @BillingStatusCol IS NULL OR @FinalStatusCol IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS NVARCHAR(100)) AS Accession,
            CAST(NULL AS DATE)          AS ReqCollectDate,
            CAST(NULL AS NVARCHAR(200)) AS BillTo,
            CAST(NULL AS NVARCHAR(200)) AS BillingStatus,
            CAST(NULL AS NVARCHAR(200)) AS FinalStatus,
            CAST(NULL AS NVARCHAR(200)) AS ClientStatus1,
            CAST(NULL AS NVARCHAR(200)) AS PanelType,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @AccExpr          NVARCHAR(300) = N'LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N'])))';
    DECLARE @DateExpr         NVARCHAR(300) = N'TRY_CAST([' + @DateCol + N'] AS DATE)';
    DECLARE @BillToExpr       NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), '''')))';
    DECLARE @BillStatusExpr   NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), '''')))';
    DECLARE @FinalStatusExpr  NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), '''')))';
    DECLARE @CS1Expr          NVARCHAR(400) = CASE WHEN @ClientStatus1Col IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientStatus1Col + N']), '''')))' ELSE N'''''' END;
    DECLARE @PanelExpr        NVARCHAR(400) = CASE WHEN @PanelTypeCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelTypeCol + N']), '''')))' ELSE N'''''' END;
    DECLARE @PatientExpr  NVARCHAR(400) = CASE WHEN @PatientCol  IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PatientCol  + N']), '''')))' ELSE N'''''' END;
    DECLARE @PayerExpr    NVARCHAR(400) = CASE WHEN @PayerCol    IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PayerCol    + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClinicExpr   NVARCHAR(400) = CASE WHEN @ClinicCol   IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol   + N']), '''')))' ELSE N'''''' END;
    DECLARE @ProviderExpr NVARCHAR(400) = CASE WHEN @ProviderCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), '''')))' ELSE N'''''' END;

    -- ── Pull matching LIMSMaster rows into temp table ────────────────────────
    DROP TABLE IF EXISTS #LisBase;
    CREATE TABLE #LisBase
    (
        Accession        NVARCHAR(100) NOT NULL,
        ReqCollectDate   DATE          NULL,
        BillTo           NVARCHAR(200) NOT NULL,
        BillingStatus    NVARCHAR(200) NOT NULL,
        FinalStatus      NVARCHAR(200) NOT NULL,
        ClientStatus1    NVARCHAR(200) NOT NULL,
        PanelType        NVARCHAR(200) NOT NULL,
        PatientName      NVARCHAR(300) NOT NULL,
        PayerName        NVARCHAR(300) NOT NULL,
        ClinicName       NVARCHAR(300) NOT NULL,
        BillingProvider  NVARCHAR(300) NOT NULL
    );

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #LisBase
            (Accession, ReqCollectDate, BillTo, BillingStatus, FinalStatus, ClientStatus1, PanelType,
             PatientName, PayerName, ClinicName, BillingProvider)
        SELECT
            ' + @AccExpr         + N',
            ' + @DateExpr        + N',
            ' + @BillToExpr      + N',
            ' + @BillStatusExpr  + N',
            ' + @FinalStatusExpr + N',
            ' + @CS1Expr         + N',
            ' + @PanelExpr       + N',
            ' + @PatientExpr     + N',
            ' + @PayerExpr       + N',
            ' + @ClinicExpr      + N',
            ' + @ProviderExpr    + N'
        FROM dbo.LIMSMaster
        WHERE ' + @DateExpr + N' IS NOT NULL
          AND NULLIF(' + @AccExpr + N', '''') IS NOT NULL
          AND (@iYear  = 0 OR YEAR (' + @DateExpr + N') = @iYear)
          AND (@iMonth = 0 OR MONTH(' + @DateExpr + N') = @iMonth);';

    EXEC sp_executesql @LisSql, N'@iYear INT, @iMonth INT', @iYear = @Year, @iMonth = @Month;

    SELECT
        b.Accession,
        b.ReqCollectDate,
        b.BillTo,
        b.BillingStatus,
        b.FinalStatus,
        b.ClientStatus1,
        b.PanelType,
        b.PatientName,
        b.PayerName,
        b.ClinicName,
        b.BillingProvider
    FROM #LisBase b
    WHERE
        -- ── A: Total Samples (all rows in period) ────────────────────────────
           (@RowCode = 'A')
        -- ── B: Billable Samples (Insurance) ──────────────────────────────────
        OR (@RowCode = 'B'        AND b.BillTo LIKE '%Insurance%')
        -- ── B1.<PanelType>: panel sub-rows (RoleID = 'B1.' + PanelType) ─────
        OR (LEFT(@RowCode,3) = 'B1.' AND b.BillTo LIKE '%Insurance%'
                                      AND b.PanelType = SUBSTRING(@RowCode, 4, 350))
        -- ── B2.1: Billed ─────────────────────────────────────────────────────
        OR (@RowCode = 'B2.1'     AND b.BillTo LIKE '%Insurance%' AND b.BillingStatus='Billed')
        -- ── B2.1.1: Claim Submitted in IRCM ──────────────────────────────────
        OR (@RowCode = 'B2.1.1'   AND b.BillTo LIKE '%Insurance%' AND b.BillingStatus='Billed'
                                   AND b.FinalStatus='Claim Submitted in IRCM')
        -- ── B2.1.2: Claim Submitted in Daqbilling ────────────────────────────
        OR (@RowCode = 'B2.1.2'   AND b.BillTo LIKE '%Insurance%' AND b.BillingStatus='Billed'
                                   AND b.FinalStatus='Claim Submitted in Daqbilling')
        -- ── B2.2: Unbilled ───────────────────────────────────────────────────
        OR (@RowCode = 'B2.2'     AND b.BillTo LIKE '%Insurance%' AND b.BillingStatus='Unbilled')
        -- ── B2.2.1: Resulted yet to be billed ────────────────────────────────
        OR (@RowCode = 'B2.2.1'   AND b.BillTo LIKE '%Insurance%' AND b.BillingStatus='Unbilled'
                                   AND b.FinalStatus='Resulted yet to be billed')
        -- ── B2.2.1*: Ready to bill ───────────────────────────────────────────
        OR (@RowCode = 'B2.2.1*'  AND b.BillTo LIKE '%Insurance%' AND b.BillingStatus='Unbilled'
                                   AND b.FinalStatus='Resulted yet to be billed'
                                   AND b.ClientStatus1='Ready to bill')
        -- ── B2.2.2: Insurance name not listed ────────────────────────────────
        OR (@RowCode = 'B2.2.2'   AND b.BillTo LIKE '%Insurance%' AND b.BillingStatus='Unbilled'
                                   AND b.FinalStatus='Insurance Name Not Listed')
        -- ── C: Yet to be Validated ───────────────────────────────────────────
        OR (@RowCode = 'C'        AND b.BillTo='Yet to be Validated')
        OR (@RowCode = 'C.1'      AND b.BillTo='Yet to be Validated' AND b.BillingStatus='Billed')
        -- ── D: Client Bills ──────────────────────────────────────────────────
        OR (@RowCode = 'D'        AND b.BillTo='Client Bills')
        OR (@RowCode = 'D.1'      AND b.BillTo='Client Bills' AND b.BillingStatus='Billed')
        -- ── E: System Test ───────────────────────────────────────────────────
        OR (@RowCode = 'E'        AND b.BillTo='System Test')
        OR (@RowCode = 'E.1'      AND b.BillTo='System Test' AND b.BillingStatus='Billed')
        -- ── F: Self pay ──────────────────────────────────────────────────────
        OR (@RowCode = 'F'        AND b.BillTo='Self pay')
        OR (@RowCode = 'F.1'      AND b.BillTo='Self pay' AND b.BillingStatus='Billed')
        -- ── Fallback: unrecognized RowCode -> return every row in the period ─
        OR (
            LEFT(@RowCode,3) <> 'B1.'
            AND @RowCode NOT IN (
                'A',
                'B','B2.1','B2.1.1','B2.1.2','B2.2','B2.2.1','B2.2.1*','B2.2.2',
                'C','C.1','D','D.1','E','E.1','F','F.1')
        )
    ORDER BY b.ReqCollectDate, b.Accession;

    DROP TABLE IF EXISTS #LisBase;
END;
GO

PRINT '20_Augustus_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO
