-- ============================================================
-- Augustus – Executive Summary Detail (Drill-Down) SP
-- File : 18_Augustus_ExecutiveSummary_Detail.sql
-- DB   : Augustus_LRN
--
-- Mirrors Cove\18_Cove_ExecutiveSummary_Detail.sql.
--
--   @Category = 'PMS' | 'Cash'  -> dbo.ClaimLevelData
--   @Category = 'LIS'           -> dbo.LIMSMaster (date col: ReqCollectDate)
--
-- Parameters
--   @Category – 'PMS' | 'Cash' | 'LIS'
--   @RowCode  – PMS:  F,F.1,F.2,G,H,I,J,K,L,M,N,O,O.1,O.2,O.3
--               Cash: P,P.1,P.2,Q,R,S,T,U,U.1,U.2,V,W,X,X.1,X.2,X.3
--               LIS:  A,A.1,A.1.1,A.1.2,A.2,A.2.1,A.2.1*,A.2.2,
--                     B,B.1,C,C.1,D,D.1,E,E.1
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAug_ExecutiveSummary_Detail
(
    @Category NVARCHAR(10),
    @RowCode  NVARCHAR(20),
    @Year     INT = 0,
    @Month    INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    -- ════════════════════════════════════════════════════════════════════
    --  PMS / Cash  -  source: dbo.ClaimLevelData
    -- ════════════════════════════════════════════════════════════════════
    IF @Category IN ('PMS','Cash')
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
            ISNULL(LTRIM(RTRIM(BillingStatus)),  '')      AS BillStatus,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), '')      AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(PayerType)), '')        AS PayerType,
            ISNULL(LTRIM(RTRIM(Source)), '')           AS Source,
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
            b.BillStatus,
            b.ClaimStatus,
            b.PayerType,
            b.Source,
            b.ChargeAmount,
            b.InsurancePayment,
            b.PatientPayment,
            b.InsuranceBalance,
            b.PatientBalance,
            b.InsuranceAdjustments,
            b.PatientAdjustments
        FROM #Base b
        WHERE
            -- ── PMS (same predicates as usp_RefreshAug_ExecutiveSummary) ──
               (@RowCode = 'F'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'F.1'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM')
            OR (@RowCode = 'F.2'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq')
            OR (@RowCode = 'G'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') = '' AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'H'    AND b.ClaimStatus='Billed amount 0')
            OR (@RowCode = 'I'    AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'J'    AND b.ClaimStatus='Patient paid')
            OR (@RowCode = 'K'    AND b.ClaimStatus='Pat Responsibility')
            OR (@RowCode = 'L'    AND b.ClaimStatus='Partial Paid')
            OR (@RowCode = 'M'    AND b.ClaimStatus='Fully Adjusted')
            OR (@RowCode = 'N'    AND b.ClaimStatus='Partially Adjusted')
            OR (@RowCode = 'O'    AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response'))
            OR (@RowCode = 'O.1'  AND b.ClaimStatus='Fully Denied')
            OR (@RowCode = 'O.2'  AND b.ClaimStatus='Partially Denied')
            OR (@RowCode = 'O.3'  AND b.ClaimStatus='No Response')
            -- ── Cash ─────────────────────────────────────────────────────
            OR (@RowCode = 'P'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'P.1'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM')
            OR (@RowCode = 'P.2'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq')
            OR (@RowCode = 'Q'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') = '' AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'R'    AND b.InsurancePayment > 0 AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'S'    AND b.ClaimStatus='Partial Paid')
            OR (@RowCode = 'T'    AND b.PatientPayment > 0)
            OR (@RowCode = 'U'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
            OR (@RowCode = 'U.1'  AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND b.Source='Daq')
            OR (@RowCode = 'U.2'  AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND b.Source='IRCM')
            OR (@RowCode = 'V'    AND 1=1)   -- all rows contribute to adjustments
            OR (@RowCode = 'W'    AND b.InsurancePayment > 0)
            OR (@RowCode = 'X'    AND 1=1)   -- full insurance balance
            OR (@RowCode = 'X.1'  AND b.ClaimStatus='Fully Denied')
            OR (@RowCode = 'X.2'  AND b.ClaimStatus='Partially Denied')
            OR (@RowCode = 'X.3'  AND b.ClaimStatus='No Response')
            -- ── Avg (return billed rows as reference) ───────────────────
            OR (@RowCode = 'Y'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0')
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
            ClientStatus1    NVARCHAR(200) NOT NULL,
            PatientName      NVARCHAR(200) NOT NULL,
            ClientName       NVARCHAR(200) NOT NULL
        );

        IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
        BEGIN
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber, CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName, CAST(NULL AS DATE) AS ReqCollectDate,
                CAST(NULL AS NVARCHAR(200)) AS BillTo, CAST(NULL AS NVARCHAR(200)) AS BillingStatus,
                CAST(NULL AS NVARCHAR(200)) AS FinalStatus, CAST(NULL AS NVARCHAR(200)) AS ClientStatus1;
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
            PRINT 'usp_GetAug_ExecutiveSummary_Detail: required LIMSMaster columns not found.';
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber, CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName, CAST(NULL AS DATE) AS ReqCollectDate,
                CAST(NULL AS NVARCHAR(200)) AS BillTo, CAST(NULL AS NVARCHAR(200)) AS BillingStatus,
                CAST(NULL AS NVARCHAR(200)) AS FinalStatus, CAST(NULL AS NVARCHAR(200)) AS ClientStatus1;
            RETURN;
        END

        DECLARE @CS1Expr NVARCHAR(400) = CASE WHEN @ClientStatus1Col IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientStatus1Col + N']), '''')))'
            ELSE N'''''' END;
        DECLARE @PatientNameExpr NVARCHAR(300) = CASE WHEN @PatientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PatientNameCol + N']), '''')))'
            ELSE N'''''' END;
        DECLARE @ClientNameExpr NVARCHAR(300) = CASE WHEN @ClientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientNameCol + N']), '''')))'
            ELSE N'''''' END;

        DECLARE @LisSql NVARCHAR(MAX) = N'
            INSERT INTO #Lis (Accession, ReqCollectDate, BillTo, BillingStatus, FinalStatus, ClientStatus1, PatientName, ClientName)
            SELECT
                LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
                TRY_CAST([' + @DateCol + N'] AS DATE),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
                ' + @CS1Expr + N',
                ' + @PatientNameExpr + N',
                ' + @ClientNameExpr + N'
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
            l.ClientStatus1
        FROM #Lis l
        WHERE
               (@RowCode = 'A')
            OR (@RowCode = 'A.1'    AND l.BillTo='Insurance Bills' AND l.BillingStatus='Billed')
            OR (@RowCode = 'A.1.1'  AND l.BillTo='Insurance Bills' AND l.BillingStatus='Billed' AND l.FinalStatus='Claim Submitted in IRCM')
            OR (@RowCode = 'A.1.2'  AND l.BillTo='Insurance Bills' AND l.BillingStatus='Billed' AND l.FinalStatus='Claim Submitted in Daqbilling')
            OR (@RowCode = 'A.2'    AND l.BillTo='Insurance Bills' AND l.BillingStatus='Unbilled')
            OR (@RowCode = 'A.2.1'  AND l.BillTo='Insurance Bills' AND l.BillingStatus='Unbilled' AND l.FinalStatus='Resulted yet to be billed')
            OR (@RowCode = 'A.2.1*' AND l.BillTo='Insurance Bills' AND l.BillingStatus='Unbilled' AND l.FinalStatus='Resulted yet to be billed' AND l.ClientStatus1='Ready to bill')
            OR (@RowCode = 'A.2.2'  AND l.BillTo='Insurance Bills' AND l.BillingStatus='Unbilled' AND l.FinalStatus='Insurance Name Not Listed')
            OR (@RowCode = 'B'      AND l.BillTo='Yet to be Validated')
            OR (@RowCode = 'B.1'    AND l.BillTo='Yet to be Validated' AND l.BillingStatus='Billed')
            OR (@RowCode = 'C'      AND l.BillTo='Client Bills')
            OR (@RowCode = 'C.1'    AND l.BillTo='Client Bills' AND l.BillingStatus='Billed')
            OR (@RowCode = 'D'      AND l.BillTo='System Test')
            OR (@RowCode = 'D.1'    AND l.BillTo='System Test' AND l.BillingStatus='Billed')
            OR (@RowCode = 'E'      AND l.BillTo='Self pay')
            OR (@RowCode = 'E.1'    AND l.BillTo='Self pay' AND l.BillingStatus='Billed')
        ORDER BY l.ReqCollectDate, l.Accession;

        DROP TABLE IF EXISTS #Lis;
        RETURN;
    END
END;
GO

PRINT '18_Augustus_ExecutiveSummary_Detail.sql completed.';
GO
