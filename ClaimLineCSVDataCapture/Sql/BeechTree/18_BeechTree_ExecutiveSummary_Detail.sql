-- ============================================================
-- BeechTree – Executive Summary Detail (Drill-Down) SP
-- File : 18_BeechTree_ExecutiveSummary_Detail.sql
-- DB   : BeechTree_LRN
--
-- Mirrors Augustus\18_Augustus_ExecutiveSummary_Detail.sql.
--
--   @Category = 'PMS' | 'Cash' | 'Avg' -> dbo.ClaimLevelData (BilledUnbilled, ClaimID)
--   @Category = 'LIS'                   -> dbo.LIMSMaster     (RequestCollectDate)
--
-- Parameters
--   @Category – 'PMS' | 'Cash' | 'Avg' | 'LIS'
--   @RowCode  – PMS:  R,S,T,U,V,W,X,Y,Z,Z.1,Z.2,Z.3
--               Cash: AA,AB,AC,AD,AE,AF,AG,AH,AI,AJ
--               Avg:  AK,AL,AM
--               LIS:  A,B,B1.<PanelType>,B2,B2.1,B3,B3.1-B3.5,B4,
--                     B5,B5.1,B5.2,B6,B6.1-B6.3,B7,B7.1-B7.2,
--                     B8,B8.1-B8.2,B9,
--                     C,C1,C2,C2.1-C2.4,C3,C4,C4.1,C4.2,D,E
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetBT_ExecutiveSummary_Detail
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
    --  PMS / Cash / Avg  -  source: dbo.ClaimLevelData
    -- ════════════════════════════════════════════════════════════════════
    IF @Category IN ('PMS','Cash','Avg')
    BEGIN
        DROP TABLE IF EXISTS #Base;

        SELECT
            ClaimID,
            LTRIM(RTRIM(ISNULL(PatientName,     '')))  AS PatientName,
            LTRIM(RTRIM(ISNULL(PayerName,       '')))  AS PayerName,
            ISNULL(LTRIM(RTRIM(Panelname)), '')        AS Panelname,
            LTRIM(RTRIM(ISNULL(ClinicName,      '')))  AS ClinicName,
            LTRIM(RTRIM(ISNULL(BillingProvider, '')))  AS BillingProvider,
            DateofService,
            FirstBilledDate,
            ISNULL(LTRIM(RTRIM(BilledUnbilled)), '')   AS BillStatus,
            ISNULL(LTRIM(RTRIM(ClaimStatus)),    '')   AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(PayerType)),      '')   AS PayerType,
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance,
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments
        INTO #Base
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND NULLIF(CONVERT(NVARCHAR(50), ClaimID), '') IS NOT NULL
          AND (@Year=0  OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
          AND (@Month=0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);

        SELECT DISTINCT
            b.ClaimID        AS ClaimNumber,
            b.PatientName,
            b.PayerName,
            b.Panelname      AS PanelName,
            b.ClinicName,
            b.BillingProvider,
            b.DateofService,
            b.FirstBilledDate,
            b.BillStatus,
            b.ClaimStatus,
            b.PayerType,
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
               (@RowCode = 'R'    AND b.BillStatus='Billed')
            OR (@RowCode = 'S'    AND b.BillStatus='Billed' AND b.ClaimStatus='Billed amount 0')
            OR (@RowCode = 'T'    AND b.BillStatus='UnBilled')
            OR (@RowCode = 'U'    AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'V'    AND b.ClaimStatus='Fully Adjusted')
            OR (@RowCode = 'W'    AND b.ClaimStatus='Pat Responsibility')
            OR (@RowCode = 'X'    AND b.ClaimStatus='Partial Paid')
            OR (@RowCode = 'Y'    AND b.PatientPayment > 0)
            OR (@RowCode = 'Z'    AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied'))
            OR (@RowCode = 'Z.1'  AND b.ClaimStatus='Fully Denied')
            OR (@RowCode = 'Z.2'  AND b.ClaimStatus='No Response')
            OR (@RowCode = 'Z.3'  AND b.ClaimStatus='Partially Denied')
            -- ── Cash ─────────────────────────────────────────────────────
            OR (@RowCode = 'AA'   AND b.BillStatus='Billed')
            OR (@RowCode = 'AB'   AND b.BillStatus='UnBilled')
            OR (@RowCode = 'AC'   AND b.ClaimStatus='Fully Paid' AND b.InsurancePayment>0)
            OR (@RowCode = 'AD'   AND b.ClaimStatus='Partial Paid')
            OR (@RowCode = 'AE'   AND b.PatientPayment>0)
            OR (@RowCode = 'AF'   AND b.ClaimStatus='Fully Adjusted')
            OR (@RowCode = 'AG'   AND b.InsuranceAdjustments>0)
            OR (@RowCode = 'AH'   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
            OR (@RowCode = 'AI'   AND b.PatientAdjustments>0)
            OR (@RowCode = 'AJ'   AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied'))
            -- ── Avg (return billed/paid/adjudicated rows as reference) ───
            OR (@RowCode = 'AK'   AND b.BillStatus='Billed')
            OR (@RowCode = 'AL'   AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'AM'   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
        ORDER BY b.DateofService, b.ClaimID;

        DROP TABLE IF EXISTS #Base;
        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  LIS  -  source: dbo.LIMSMaster (RequestCollectDate, dynamic col detect)
    -- ════════════════════════════════════════════════════════════════════
    IF @Category = 'LIS'
    BEGIN
        DROP TABLE IF EXISTS #Lis;
        CREATE TABLE #Lis
        (
            Accession      NVARCHAR(100) NOT NULL,
            CollectDate    DATE          NULL,
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

        IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
        BEGIN
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber,
                CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName,
                CAST(NULL AS DATE)          AS CollectDate,
                CAST(NULL AS NVARCHAR(200)) AS Resulted,
                CAST(NULL AS NVARCHAR(200)) AS ClaimStatus,
                CAST(NULL AS NVARCHAR(200)) AS BilledorNot,
                CAST(NULL AS NVARCHAR(200)) AS ClientStatus,
                CAST(NULL AS NVARCHAR(200)) AS SampleStatus,
                CAST(NULL AS NVARCHAR(200)) AS PaymentMethod,
                CAST(NULL AS NVARCHAR(200)) AS PanelType;
            RETURN;
        END

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
            PRINT 'usp_GetBT_ExecutiveSummary_Detail: required LIMSMaster columns not found.';
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber,
                CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName,
                CAST(NULL AS DATE)          AS CollectDate,
                CAST(NULL AS NVARCHAR(200)) AS Resulted,
                CAST(NULL AS NVARCHAR(200)) AS ClaimStatus,
                CAST(NULL AS NVARCHAR(200)) AS BilledorNot,
                CAST(NULL AS NVARCHAR(200)) AS ClientStatus,
                CAST(NULL AS NVARCHAR(200)) AS SampleStatus,
                CAST(NULL AS NVARCHAR(200)) AS PaymentMethod,
                CAST(NULL AS NVARCHAR(200)) AS PanelType;
            RETURN;
        END

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

        DECLARE @LisSql NVARCHAR(MAX) = N'
            INSERT INTO #Lis
                (Accession, CollectDate, Resulted, ClaimStatus, BilledorNot,
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

        EXEC sp_executesql @LisSql,
            N'@iYear INT, @iMonth INT',
            @iYear=@Year, @iMonth=@Month;

        SELECT DISTINCT
            l.Accession    AS VisitNumber,
            l.PatientName,
            l.ClientName,
            l.CollectDate,
            l.Resulted,
            l.ClaimStatus,
            l.BilledorNot,
            l.ClientStatus,
            l.SampleStatus,
            l.PaymentMethod,
            l.PanelType
        FROM #Lis l
        WHERE
            -- A: Total Samples
               (@RowCode = 'A')
            -- B: Billable Samples - Resulted
            OR (@RowCode = 'B'     AND l.Resulted='Resulted')
            -- B1.<PanelType>: panel sub-rows (RoleID = 'B1.' + PanelType)
            OR (LEFT(@RowCode,3) = 'B1.' AND l.Resulted='Resulted'
                                         AND l.PanelType = SUBSTRING(@RowCode, 4, 350))
            -- B2: Billed to Insurance
            OR (@RowCode = 'B2'    AND l.Resulted='Resulted' AND l.ClaimStatus='Billed' AND l.BilledorNot='Billed' AND l.ClientStatus='')
            OR (@RowCode = 'B2.1'  AND l.Resulted='Resulted' AND l.ClaimStatus='Billed' AND l.BilledorNot='Billed' AND l.ClientStatus='')
            -- B3: Not Entered in AMD
            OR (@RowCode = 'B3'    AND l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus IN ('','Billing Review Required'))
            OR (@RowCode = 'B3.1'  AND l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus IN ('','Billing Review Required') AND l.SampleStatus='Received')
            OR (@RowCode = 'B3.2'  AND l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.SampleStatus='Received' AND l.ClientStatus='Billing Review Required')
            OR (@RowCode = 'B3.3'  AND l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus IN ('','Billing Review Required') AND l.SampleStatus='In Transit')
            OR (@RowCode = 'B3.4'  AND l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus IN ('','Billing Review Required') AND l.SampleStatus='Transferred')
            OR (@RowCode = 'B3.5'  AND l.Resulted='Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus IN ('','Billing Review Required') AND l.SampleStatus='Collected')
            -- B4: Unbilled
            OR (@RowCode = 'B4'    AND l.Resulted='Resulted' AND l.ClaimStatus='Entered' AND l.BilledorNot='UnBilled' AND l.ClientStatus='')
            -- B5: Client Bill (Resulted)
            OR (@RowCode = 'B5'    AND l.Resulted='Resulted' AND l.ClientStatus='Client Bill')
            OR (@RowCode = 'B5.1'  AND l.Resulted='Resulted' AND l.ClientStatus='Client Bill' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled')
            OR (@RowCode = 'B5.2'  AND l.Resulted='Resulted' AND l.ClientStatus='Client Bill' AND l.BilledorNot='Billed')
            -- B6: Self Pay (Resulted)
            OR (@RowCode = 'B6'    AND l.Resulted='Resulted' AND l.ClientStatus='Self Pay')
            OR (@RowCode = 'B6.1'  AND l.Resulted='Resulted' AND l.ClientStatus='Self Pay' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled')
            OR (@RowCode = 'B6.2'  AND l.Resulted='Resulted' AND l.ClientStatus='Self Pay' AND l.BilledorNot='Billed')
            OR (@RowCode = 'B6.3'  AND l.Resulted='Resulted' AND l.ClientStatus='Self Pay' AND l.ClaimStatus='Entered' AND l.BilledorNot='UnBilled')
            -- B7: Test Entries (Resulted)
            OR (@RowCode = 'B7'    AND l.Resulted='Resulted' AND l.ClientStatus='Test Entries')
            OR (@RowCode = 'B7.1'  AND l.Resulted='Resulted' AND l.ClientStatus='Test Entries' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled')
            OR (@RowCode = 'B7.2'  AND l.Resulted='Resulted' AND l.ClientStatus='Test Entries' AND l.BilledorNot='Billed')
            -- B8: Rejected Sample (Resulted)
            OR (@RowCode = 'B8'    AND l.Resulted='Resulted' AND l.ClientStatus='Rejected Sample')
            OR (@RowCode = 'B8.1'  AND l.Resulted='Resulted' AND l.ClientStatus='Rejected Sample' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled')
            OR (@RowCode = 'B8.2'  AND l.Resulted='Resulted' AND l.ClientStatus='Rejected Sample' AND l.BilledorNot='Billed')
            -- B9: Payment Method No Bill
            OR (@RowCode = 'B9'    AND l.Resulted='Resulted' AND l.PaymentMethod='No Bill')
            -- C: Not Resulted
            OR (@RowCode = 'C'     AND l.Resulted='Not Resulted')
            OR (@RowCode = 'C1'    AND l.Resulted='Not Resulted' AND l.ClaimStatus='Billed' AND l.BilledorNot='Billed' AND l.ClientStatus='')
            OR (@RowCode = 'C2'    AND l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus='')
            OR (@RowCode = 'C2.1'  AND l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus='' AND l.SampleStatus='Received')
            OR (@RowCode = 'C2.2'  AND l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus='' AND l.SampleStatus='In Transit')
            OR (@RowCode = 'C2.3'  AND l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus='' AND l.SampleStatus='Collected')
            OR (@RowCode = 'C2.4'  AND l.Resulted='Not Resulted' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled' AND l.ClientStatus='' AND l.SampleStatus='Transferred')
            OR (@RowCode = 'C3'    AND l.Resulted='Not Resulted' AND l.ClientStatus='Client Bill')
            OR (@RowCode = 'C4'    AND l.Resulted='Not Resulted' AND l.ClientStatus='Self Pay')
            OR (@RowCode = 'C4.1'  AND l.Resulted='Not Resulted' AND l.ClientStatus='Self Pay' AND l.ClaimStatus='Not Entered in AMD' AND l.BilledorNot='UnBilled')
            OR (@RowCode = 'C4.2'  AND l.Resulted='Not Resulted' AND l.ClientStatus='Self Pay' AND l.BilledorNot='Billed')
            -- D: Test Entries (Not Resulted)
            OR (@RowCode = 'D'     AND l.Resulted='Not Resulted' AND l.ClientStatus='Test Entries')
            -- E: Rejected Sample (Not Resulted)
            OR (@RowCode = 'E'     AND l.Resulted='Not Resulted' AND l.ClientStatus='Rejected Sample')
        ORDER BY l.CollectDate, l.Accession;

        DROP TABLE IF EXISTS #Lis;
        RETURN;
    END
END;
GO

PRINT '18_BeechTree_ExecutiveSummary_Detail.sql completed.';
GO
