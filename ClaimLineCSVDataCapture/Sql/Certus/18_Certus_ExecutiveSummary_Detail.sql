-- ============================================================
-- Certus – Executive Summary Detail (Drill-Down) SP
-- File : 18_Certus_ExecutiveSummary_Detail.sql
-- DB   : Certus_LRN
--
-- Mirrors Augustus\18_Augustus_ExecutiveSummary_Detail.sql.
--
--   @Category = 'PMS' | 'Cash'  -> dbo.ClaimLevelData  (DateofService)
--   @Category = 'LIS'           -> dbo.LIMSMaster       (ReqCollectDate)
--
-- Parameters
--   @Category – 'PMS' | 'Cash' | 'LIS'
--   @RowCode  – PMS:  F,G,H,I,J,K,L,M,N,O,P,P.1,P.2
--               Cash: Q,R,S,T,U,V,W,X,X.1,X.2,X.3
--               Avg:  Y,Z,AA
--               LIS:  A,B,B1.<PanelName>,C,D,D.1,D.2,D.3,
--                     E,E.1,E.2,E.3,E.4,E.5,E.6
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCert_ExecutiveSummary_Detail
(
    @Category NVARCHAR(10),
    @RowCode  NVARCHAR(50),
    @Year     INT = 0,
    @Month    INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    -- ════════════════════════════════════════════════════════════════════
    --  PMS / Cash  -  source: dbo.ClaimLevelData
    -- ════════════════════════════════════════════════════════════════════
    IF @Category IN ('PMS','Cash','Avg')
    BEGIN
        DROP TABLE IF EXISTS #Base;

        SELECT
            AccessionNumber,
            LTRIM(RTRIM(ISNULL(PatientName,     '')))  AS PatientName,
            LTRIM(RTRIM(ISNULL(PayerName,       '')))  AS PayerName,
            ISNULL(LTRIM(RTRIM(Panelname)), '')        AS Panelname,
            LTRIM(RTRIM(ISNULL(ClinicName,      '')))  AS ClinicName,
            LTRIM(RTRIM(ISNULL(BillingProvider, '')))  AS BillingProvider,
            DateofService,
            FirstBilledDate,
            --ISNULL(LTRIM(RTRIM(BillingStatus)),  '')   AS BillStatus,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), '')       AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(PayerType)), '')         AS PayerType,
           -- ISNULL(LTRIM(RTRIM(Source)), '')            AS Source,
            ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
            ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
            ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
            ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
            ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance,
            ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments
        INTO #Base
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
          AND (@Year=0  OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
          AND (@Month=0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);

        SELECT DISTINCT
            b.AccessionNumber AS VisitNumber,
            b.PatientName,
            b.PayerName,
            b.Panelname        AS PanelName,
            b.ClinicName,
            b.BillingProvider,
            b.DateofService,
            b.FirstBilledDate,
           -- b.BillStatus,
            b.ClaimStatus,
            b.PayerType,
           -- b.Source,
            b.ChargeAmount,
            b.InsurancePayment,
            b.PatientPayment,
            b.InsuranceBalance,
            b.PatientBalance,
            b.InsuranceAdjustments,
            b.PatientAdjustments
        FROM #Base b
        WHERE
            -- ── PMS ──────────────────────────────────────────────────────
               (@RowCode = 'F'    AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'G'    AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'H'    AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'I'    AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'J'    AND b.ClaimStatus='Patient Responsibility')
            OR (@RowCode = 'K'    AND b.ClaimStatus='Patient Paid')
            OR (@RowCode = 'L'    AND b.ClaimStatus='Fully Adjusted')
            OR (@RowCode = 'M'    AND b.ClaimStatus='Test')
            OR (@RowCode = 'N'    AND b.ClaimStatus='Partially Adjusted')
            OR (@RowCode = 'O'    AND b.ClaimStatus='Partial Paid')
            OR (@RowCode = 'P'    AND b.ClaimStatus IN ('Fully Denied','No Response'))
            OR (@RowCode = 'P.1'  AND b.ClaimStatus='Fully Denied')
            OR (@RowCode = 'P.2'  AND b.ClaimStatus='No Response')
            -- ── Cash ─────────────────────────────────────────────────────
            OR (@RowCode = 'Q'    AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'R'    AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'S'    AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'T'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
            OR (@RowCode = 'U'    AND 1=1)   -- all rows contribute to adjustments
            OR (@RowCode = 'V'    AND b.PatientPayment > 0)
            OR (@RowCode = 'W'    AND b.ClaimStatus='Partial Paid')
            OR (@RowCode = 'X'    AND 1=1)   -- full insurance balance
            OR (@RowCode = 'X.1'  AND b.ClaimStatus='Fully Denied')
            OR (@RowCode = 'X.2'  AND b.ClaimStatus='Partially Denied')
            OR (@RowCode = 'X.3'  AND b.ClaimStatus='No Response')
            -- ── Avg (return billed rows as reference) ────────────────────
            OR (@RowCode = 'Y'    AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'Z'    AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'AA'   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
        ORDER BY b.DateofService, b.AccessionNumber;

        DROP TABLE IF EXISTS #Base;
        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  LIS  -  source: dbo.LIMSMaster (ReqCollectDate, dynamic col detect)
    -- ════════════════════════════════════════════════════════════════════
    IF @Category = 'LIS'
    BEGIN
        DROP TABLE IF EXISTS #Lis;
        CREATE TABLE #Lis
        (
            Accession        NVARCHAR(100) NOT NULL,
            ReqCollectDate   DATE          NULL,
            BillTo           NVARCHAR(200) NOT NULL,
            BillingStatus    NVARCHAR(200) NOT NULL,
            FinalStatus      NVARCHAR(200) NOT NULL,
            PanelName        NVARCHAR(200) NOT NULL,
            PatientName      NVARCHAR(200) NOT NULL,
            ClientName       NVARCHAR(200) NOT NULL
        );

        IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
        BEGIN
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber, CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName,  CAST(NULL AS DATE) AS ReqCollectDate,
                CAST(NULL AS NVARCHAR(200)) AS BillTo,      CAST(NULL AS NVARCHAR(200)) AS BillingStatus,
                CAST(NULL AS NVARCHAR(200)) AS FinalStatus, CAST(NULL AS NVARCHAR(200)) AS PanelName;
            RETURN;
        END

        DECLARE @AccCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('AccessionNumber','Accession','AccessionNo')
            ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

        -- ReqCollectDate is priority 0 for Certus
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

        DECLARE @PanelNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelName','Panelname','PanelType','PanelCategory','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
            ORDER BY CASE name
                WHEN 'PanelName'       THEN 0 WHEN 'Panelname'       THEN 1 WHEN 'PanelType'       THEN 2
                WHEN 'PanelCategory'   THEN 3 WHEN 'TestPanel'        THEN 4 WHEN 'TestPanelName'   THEN 5
                WHEN 'Panel'           THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'        THEN 8
                WHEN 'Test_Panel'      THEN 9 WHEN 'TestPanelname'    THEN 10 ELSE 11 END);

        DECLARE @PatientNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PatientName','Patient_Name','PatientFullName')
            ORDER BY CASE name WHEN 'PatientName' THEN 0 WHEN 'Patient_Name' THEN 1 WHEN 'PatientFullName' THEN 2 ELSE 3 END);

        DECLARE @ClientNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClientName','Client_Name','ClinicName','Client')
            ORDER BY CASE name WHEN 'ClientName' THEN 0 WHEN 'Client_Name' THEN 1 WHEN 'ClinicName' THEN 2 WHEN 'Client' THEN 3 ELSE 4 END);

        IF @AccCol IS NULL OR @DateCol IS NULL OR @BillToCol IS NULL OR @BillingStatusCol IS NULL OR @FinalStatusCol IS NULL
        BEGIN
            PRINT 'usp_GetCert_ExecutiveSummary_Detail: required LIMSMaster columns not found.';
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber, CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName,  CAST(NULL AS DATE) AS ReqCollectDate,
                CAST(NULL AS NVARCHAR(200)) AS BillTo,      CAST(NULL AS NVARCHAR(200)) AS BillingStatus,
                CAST(NULL AS NVARCHAR(200)) AS FinalStatus, CAST(NULL AS NVARCHAR(200)) AS PanelName;
            RETURN;
        END

        DECLARE @PanelExpr       NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol + N']), '''')))'
            ELSE N'''''' END;
        DECLARE @PatientNameExpr NVARCHAR(300) = CASE WHEN @PatientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PatientNameCol + N']), '''')))'
            ELSE N'''''' END;
        DECLARE @ClientNameExpr  NVARCHAR(300) = CASE WHEN @ClientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientNameCol + N']), '''')))'
            ELSE N'''''' END;

        DECLARE @LisSql NVARCHAR(MAX) = N'
            INSERT INTO #Lis (Accession, ReqCollectDate, BillTo, BillingStatus, FinalStatus, PanelName, PatientName, ClientName)
            SELECT
                LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
                TRY_CAST([' + @DateCol + N'] AS DATE),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
                ' + @PanelExpr       + N',
                ' + @PatientNameExpr + N',
                ' + @ClientNameExpr  + N'
            FROM dbo.LIMSMaster
            WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
              AND (@iYear=0  OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) = @iYear)
              AND (@iMonth=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) = @iMonth);';

        EXEC sp_executesql @LisSql,
            N'@iYear INT, @iMonth INT',
            @iYear=@Year, @iMonth=@Month;

        SELECT DISTINCT
            l.Accession        AS VisitNumber,
            l.PatientName,
            l.ClientName,
            l.ReqCollectDate,
            l.BillTo,
            l.BillingStatus,
            l.FinalStatus,
            l.PanelName
        FROM #Lis l
        WHERE
            -- ── A: Total Samples ────────────────────────────────────────────────
               (@RowCode = 'A')
            -- ── B: Billable Samples ─────────────────────────────────────────────
            OR (@RowCode = 'B'     AND l.BillTo = 'Insurance Bill')
            -- ── B1.<PanelName>: panel sub-rows ──────────────────────────────────
            OR (LEFT(@RowCode, 3) = 'B1.' AND l.BillTo = 'Insurance Bill'
                                          AND l.PanelName = SUBSTRING(@RowCode, 4, 50))
            -- ── C: Billed ───────────────────────────────────────────────────────
            OR (@RowCode = 'C'     AND l.BillTo='Insurance Bill' AND l.BillingStatus='Billed')
            -- ── D: Unbilled ─────────────────────────────────────────────────────
            OR (@RowCode = 'D'     AND l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed')
            -- ── D.1: Claim Entered in Daqbilling ────────────────────────────────
            OR (@RowCode = 'D.1'   AND l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed' AND l.FinalStatus='Claim Entered in Daqbilling')
            -- ── D.2: Resulted yet to be billed ──────────────────────────────────
            OR (@RowCode = 'D.2'   AND l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed' AND l.FinalStatus='Resulted yet to be billed')
            -- ── D.3: D/L Isomer ─────────────────────────────────────────────────
            OR (@RowCode = 'D.3'   AND l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed' AND l.FinalStatus='D/L Isomer')
            -- ── E: Other Samples ────────────────────────────────────────────────
            OR (@RowCode = 'E'     AND l.BillTo <> 'Insurance Bill')
            OR (@RowCode = 'E.1'   AND l.BillTo='Duplicate')
            OR (@RowCode = 'E.2'   AND l.BillTo='Client Bill')
            OR (@RowCode = 'E.3'   AND l.BillTo='Yet to be Validated')
            OR (@RowCode = 'E.4'   AND l.BillTo='Selfpay')
            OR (@RowCode = 'E.5'   AND l.BillTo='Rejection')
            OR (@RowCode = 'E.6'   AND l.BillTo='System Test')
        ORDER BY l.ReqCollectDate, l.Accession;

        DROP TABLE IF EXISTS #Lis;
        RETURN;
    END
END;
GO

PRINT '18_Certus_ExecutiveSummary_Detail.sql completed.';
GO
