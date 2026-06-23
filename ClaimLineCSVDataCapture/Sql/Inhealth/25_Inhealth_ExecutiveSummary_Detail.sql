-- ============================================================
-- Inhealth – Executive Summary Detail (Drill-Down) SP
-- File : 25_Inhealth_ExecutiveSummary_Detail.sql
-- DB   : Inhealth_LRN
--
-- Mirrors Augustus\18_Augustus_ExecutiveSummary_Detail.sql.
--
--   @Category = 'PMS' | 'Cash' | 'Avg' -> dbo.ClaimLevelData (DateofService)
--   @Category = 'LIS'                   -> dbo.LIMSMaster     (ReqCollectDate)
--
-- Parameters
--   @Category – 'PMS' | 'Cash' | 'Avg' | 'LIS'
--   @RowCode  – PMS:  F,G,H,H.1,H.2,I,J,K,L,M,N,O,O.1,O.2,O.3
--               Cash: P,Q,Q.1,Q.2,R,S,T,U,V,W,W.1,W.2,W.3
--               Avg:  X,Y,Z
--               LIS:  A,B,B1.{LRNPanelName},C,C.1,D,D.1-D.6,E,E.1-E.7
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetInh_ExecutiveSummary_Detail
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
            AccessionNumber,
            LTRIM(RTRIM(ISNULL(PatientName,     '')))  AS PatientName,
            LTRIM(RTRIM(ISNULL(PayerName,       '')))  AS PayerName,
            ISNULL(LTRIM(RTRIM(Panelname)), '')        AS Panelname,
            LTRIM(RTRIM(ISNULL(ClinicName,      '')))  AS ClinicName,
            LTRIM(RTRIM(ISNULL(BillingProvider, '')))  AS BillingProvider,
            DateofService,
            FirstBilledDate,
            ISNULL(LTRIM(RTRIM(BillStatus)),  '')      AS BillStatus,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), '')       AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(PayerType)), '')         AS PayerType,
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
               (@RowCode = 'F'    AND b.BillStatus='Billed')
            OR (@RowCode = 'G'    AND b.BillStatus='Billed')  -- PMS billed side of mismatch
            OR (@RowCode = 'H'    AND b.BillStatus='Unbilled')
            OR (@RowCode = 'H.1'  AND b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled')
            OR (@RowCode = 'H.2'  AND b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled - Patient Balance')
            OR (@RowCode = 'I'    AND b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'J'    AND b.BillStatus='Billed' AND b.ClaimStatus='Patient Responsibility')
            OR (@RowCode = 'K'    AND b.BillStatus='Billed' AND b.ClaimStatus='Complete W/O')
            OR (@RowCode = 'L'    AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Adjusted')
            OR (@RowCode = 'M'    AND b.BillStatus='Billed' AND b.ClaimStatus='Patient Payment')
            OR (@RowCode = 'N'    AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Paid')
            OR (@RowCode = 'O'    AND b.BillStatus='Billed' AND b.ClaimStatus IN ('FullyDenied','Partially Denied','No Response'))
            OR (@RowCode = 'O.1'  AND b.BillStatus='Billed' AND b.ClaimStatus='FullyDenied')
            OR (@RowCode = 'O.2'  AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Denied')
            OR (@RowCode = 'O.3'  AND b.BillStatus='Billed' AND b.ClaimStatus='No Response')
            -- ── Cash ─────────────────────────────────────────────────────
            OR (@RowCode = 'P'    AND b.BillStatus='Billed')
            OR (@RowCode = 'Q'    AND b.BillStatus='Unbilled')
            OR (@RowCode = 'Q.1'  AND b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled')
            OR (@RowCode = 'Q.2'  AND b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled - Patient Balance')
            OR (@RowCode = 'R'    AND b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'S'    AND b.BillStatus='Billed')
            OR (@RowCode = 'T'    AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Paid')
            OR (@RowCode = 'U'    AND b.BillStatus='Billed')
            OR (@RowCode = 'V'    AND b.BillStatus='Billed')
            OR (@RowCode = 'W'    AND b.BillStatus='Billed')
            OR (@RowCode = 'W.1'  AND b.BillStatus='Billed' AND b.ClaimStatus='FullyDenied')
            OR (@RowCode = 'W.2'  AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Denied')
            OR (@RowCode = 'W.3'  AND b.BillStatus='Billed' AND b.ClaimStatus='No Response')
            -- ── Avg ──────────────────────────────────────────────────────
            OR (@RowCode = 'X'    AND b.BillStatus='Billed')
            OR (@RowCode = 'Y'    AND b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'Z'    AND b.BillStatus='Billed'
                                  AND b.ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                                        'Partially Paid','Patient Payment','FullyDenied','Partially Denied'))
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
            OrderID        NVARCHAR(100) NOT NULL,
            ReqCollectDate DATE          NULL,
            NAFlag         NVARCHAR(50)  NOT NULL,
            SampleStatus   NVARCHAR(200) NOT NULL,
            BillCategory   NVARCHAR(200) NOT NULL,
            SubStatus      NVARCHAR(200) NOT NULL,
            LRNPanelName   NVARCHAR(200) NOT NULL,
            PatientName    NVARCHAR(200) NOT NULL,
            ClientName     NVARCHAR(200) NOT NULL
        );

        IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
        BEGIN
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS OrderID,      CAST(NULL AS DATE) AS ReqCollectDate,
                CAST(NULL AS NVARCHAR(200)) AS SampleStatus, CAST(NULL AS NVARCHAR(200)) AS BillCategory,
                CAST(NULL AS NVARCHAR(200)) AS SubStatus,    CAST(NULL AS NVARCHAR(200)) AS LRNPanelName,
                CAST(NULL AS NVARCHAR(200)) AS PatientName,  CAST(NULL AS NVARCHAR(200)) AS ClientName;
            RETURN;
        END

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
              AND name IN ('LRNPanelName','LRN_PanelName','LRNPanel','PanelName','Panelname','PanelType','PanelCategory')
            ORDER BY CASE name
                WHEN 'LRNPanelName' THEN 0 WHEN 'LRN_PanelName' THEN 1 WHEN 'LRNPanel'  THEN 2
                WHEN 'PanelName'    THEN 3 WHEN 'Panelname'     THEN 4 WHEN 'PanelType' THEN 5
                WHEN 'PanelCategory' THEN 6 ELSE 7 END);

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

        IF @OrderIDCol IS NULL OR @DateCol IS NULL OR @SampleStatusCol IS NULL
           OR @BillCategoryCol IS NULL OR @SubStatusCol IS NULL
        BEGIN
            PRINT 'usp_GetInh_ExecutiveSummary_Detail: required LIMSMaster columns not found.';
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS OrderID,      CAST(NULL AS DATE) AS ReqCollectDate,
                CAST(NULL AS NVARCHAR(200)) AS SampleStatus, CAST(NULL AS NVARCHAR(200)) AS BillCategory,
                CAST(NULL AS NVARCHAR(200)) AS SubStatus,    CAST(NULL AS NVARCHAR(200)) AS LRNPanelName,
                CAST(NULL AS NVARCHAR(200)) AS PatientName,  CAST(NULL AS NVARCHAR(200)) AS ClientName;
            RETURN;
        END

        DECLARE @NAExpr          NVARCHAR(300) = CASE WHEN @NACol IS NOT NULL
            THEN N'ISNULL(CONVERT(NVARCHAR(50), [' + @NACol + N']), '''')' ELSE N'''''' END;
        DECLARE @PanelExpr       NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol + N']), '''')))' ELSE N'''''' END;
        DECLARE @PatientNameExpr NVARCHAR(300) = CASE WHEN @PatientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PatientNameCol + N']), '''')))' ELSE N'''''' END;
        DECLARE @ClientNameExpr  NVARCHAR(300) = CASE WHEN @ClientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientNameCol + N']), '''')))' ELSE N'''''' END;

        DECLARE @LisSql NVARCHAR(MAX) = N'
            INSERT INTO #Lis (OrderID, ReqCollectDate, NAFlag, SampleStatus, BillCategory, SubStatus, LRNPanelName, PatientName, ClientName)
            SELECT
                LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @OrderIDCol + N']))),
                TRY_CAST([' + @DateCol + N'] AS DATE),
                ' + @NAExpr + N',
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SampleStatusCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol + N']), ''''))),
                ' + @PanelExpr       + N',
                ' + @PatientNameExpr + N',
                ' + @ClientNameExpr  + N'
            FROM dbo.LIMSMaster
            WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @OrderIDCol + N']))), '''') IS NOT NULL
              AND (@iYear=0  OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) = @iYear)
              AND (@iMonth=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) = @iMonth);';

        EXEC sp_executesql @LisSql, N'@iYear INT, @iMonth INT', @iYear=@Year, @iMonth=@Month;

        SELECT DISTINCT
            l.OrderID        AS VisitNumber,
            l.PatientName,
            l.ClientName,
            l.ReqCollectDate,
            l.SampleStatus,
            l.BillCategory,
            l.SubStatus,
            l.LRNPanelName
        FROM #Lis l
        WHERE
            -- ── A: Total Samples (NA not blank) ──────────────────────────────────
               (@RowCode = 'A'   AND NULLIF(l.NAFlag,'') IS NOT NULL)
            -- ── B: Billable Samples ──────────────────────────────────────────────
            OR (@RowCode = 'B'   AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable')
            -- ── B1.{Panel}: panel sub-rows ───────────────────────────────────────
            OR (LEFT(@RowCode,3)='B1.' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable'
                                        AND l.LRNPanelName = SUBSTRING(@RowCode, 4, 50))
            -- ── C: Billed ────────────────────────────────────────────────────────
            OR (@RowCode = 'C'   AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Billed')
            -- ── C.1: Billed Via AMD ──────────────────────────────────────────────
            OR (@RowCode = 'C.1' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Billed' AND l.SubStatus='Billed Via AMD')
            -- ── D: Unbilled ──────────────────────────────────────────────────────
            OR (@RowCode = 'D'   AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed')
            OR (@RowCode = 'D.1' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum_Claim_scrubber_Eligibility')
            OR (@RowCode = 'D.2' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Requires Review')
            OR (@RowCode = 'D.3' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Entered in AMD but not billed')
            OR (@RowCode = 'D.4' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum Pre Processing Queue')
            OR (@RowCode = 'D.5' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum_Claim_scrubber_AMD Output')
            OR (@RowCode = 'D.6' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Nexum_Claim_scrubber_Diagnosis Validity')
            -- ── E: Other Samples ─────────────────────────────────────────────────
            OR (@RowCode = 'E'   AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples')
            OR (@RowCode = 'E.1' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples' AND l.BillCategory='Billed')
            OR (@RowCode = 'E.2' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples' AND l.BillCategory='Not Billed')
            OR (@RowCode = 'E.3' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Other Samples')
            OR (@RowCode = 'E.4' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Self Pay')
            OR (@RowCode = 'E.5' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Deleted/Rejected')
            OR (@RowCode = 'E.6' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='Duplicate')
            OR (@RowCode = 'E.7' AND ISNULL(l.NAFlag,'')='' AND l.SampleStatus='System Test')
        ORDER BY l.ReqCollectDate, l.OrderID;

        DROP TABLE IF EXISTS #Lis;
        RETURN;
    END
END;
GO

PRINT '25_Inhealth_ExecutiveSummary_Detail.sql completed.';
GO
