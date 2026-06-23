-- ============================================================
-- Cove – Executive Summary Detail (Drill-Down) SP
-- File : 18_Cove_ExecutiveSummary_Detail.sql
-- DB   : Cove_LRN
--
-- Mirrors PhiLife\18_PhiLife_ExecutiveSummary_Detail.sql, but Cove has
-- TWO source tables (unlike PhiLife, which sources everything from
-- ClaimLevelData):
--   @Category = 'PMS' | 'Cash'  -> dbo.ClaimLevelData  (RowCodes F-N.3, O-U.3)
--   @Category = 'LIS'           -> dbo.LIMSMaster      (RowCodes A-E.7,
--                                    same dynamic column auto-detection as
--                                    19_Cove_ExecutiveSummary_LIS_Alt.sql /
--                                    17_Cove_ExecutiveSummary_Read.sql)
--
-- Parameters
--   @Category – 'PMS' | 'Cash' | 'LIS'
--   @RowCode  – PMS:  F,G,H,I,J,K,L,M,N,N.1,N.2,N.3
--                Cash: O,P,Q,R,S,T,U,U.1,U.2,U.3
--                LIS:  A, B(+B.<PanelType> dynamic), C, D(+D.1-D.20,
--                      D.5.<PanelType>/D.6.<PanelType> dynamic), E(+E.1-7)
--                      The B./D.5./D.6. panel sub-rows are NOT a fixed list -
--                      one exists per DISTINCT LIMSMaster.PanelType value.
--                      @RowCode = 'B.<PanelType>' / 'D.5.<PanelType>' /
--                      'D.6.<PanelType>' is matched dynamically below.
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months within the year)
--
-- 'G' (Billed Mismatches – cross-table LIS check) has no separate detail
-- set; it degenerates to the same rows as 'F' (Billed claims), same
-- documented fallback pattern as PhiLife's R->Q and Elixir's I->F.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_ExecutiveSummary_Detail
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
            ISNULL(LTRIM(RTRIM(BillStatus)),  '')      AS BillStatus,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), '')      AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(PayerType)), '')        AS PayerType,
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
               (@RowCode = 'F'    AND b.BillStatus IN ('Billed','Billed-Client'))
            OR (@RowCode = 'G'    AND b.BillStatus IN ('Billed','Billed-Client'))  -- degenerate fallback: G = F (cross-table count, not a row list)
            OR (@RowCode = 'H'    AND b.ClaimStatus IN ('Fully Paid','Paid-Client'))
            OR (@RowCode = 'I'    AND b.ClaimStatus = 'Patient Responsibility')
            OR (@RowCode = 'J'    AND b.ClaimStatus = 'Fully Adjusted')
            OR (@RowCode = 'K'    AND b.ClaimStatus = 'Partially Adjusted')
            OR (@RowCode = 'L'    AND b.ClaimStatus = 'Partially Paid')
            OR (@RowCode = 'M'    AND b.ClaimStatus = 'Patient Payment')
            OR (@RowCode = 'N'    AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response','No Response-Client'))
            OR (@RowCode = 'N.1'  AND b.ClaimStatus = 'Fully Denied')
            OR (@RowCode = 'N.2'  AND b.ClaimStatus = 'Partially Denied')
            OR (@RowCode = 'N.3'  AND b.ClaimStatus IN ('No Response','No Response-Client'))
            -- ── Cash ─────────────────────────────────────────────────────
            OR (@RowCode = 'O'    AND b.BillStatus IN ('Billed','Billed-Client'))
            OR (@RowCode = 'P'    AND b.ClaimStatus IN ('Fully Paid','Paid-Client'))
            OR (@RowCode = 'Q'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB','No Response','No Response-Client'))
            OR (@RowCode = 'R'    AND b.PatientPayment > 0)
            OR (@RowCode = 'S'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
            OR (@RowCode = 'T'    AND b.ClaimStatus = 'Partially Paid')
            OR (@RowCode = 'U'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
            OR (@RowCode = 'U.1'  AND b.ClaimStatus = 'Fully Denied')
            OR (@RowCode = 'U.2'  AND b.ClaimStatus IN ('Partially Denied','Partially Adjusted','Partially Paid','Patient Payment','Patient Responsibility'))
            OR (@RowCode = 'U.3'  AND b.ClaimStatus IN ('No Response','No Response-Client'))
        ORDER BY b.DateofService, b.AccessionNumber;

        DROP TABLE IF EXISTS #Base;
        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  LIS  -  source: dbo.LIMSMaster (dynamic column auto-detection, same
    --  candidate lists/priorities as 19_Cove_ExecutiveSummary_LIS_Alt.sql)
    -- ════════════════════════════════════════════════════════════════════
    IF @Category = 'LIS'
    BEGIN
        DROP TABLE IF EXISTS #Lis;
        CREATE TABLE #Lis
        (
            Accession        NVARCHAR(100) NOT NULL,
            DateOfCollection DATE          NULL,
            NewStatus        NVARCHAR(200) NOT NULL,
            PanelType        NVARCHAR(200) NOT NULL,
            BillCategory     NVARCHAR(200) NOT NULL,
            SubStatus        NVARCHAR(200) NOT NULL,
            PatientName      NVARCHAR(200) NOT NULL,
            ClientName       NVARCHAR(200) NOT NULL
        );

        IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
        BEGIN
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber, CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName, CAST(NULL AS DATE) AS DateOfCollection,
                CAST(NULL AS NVARCHAR(200)) AS NewStatus, CAST(NULL AS NVARCHAR(200)) AS PanelType,
                CAST(NULL AS NVARCHAR(200)) AS BillCategory, CAST(NULL AS NVARCHAR(200)) AS SubStatus;
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
              AND name IN ('DateOfCollection','RequestCollectDate','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'DateOfCollection' THEN 0 WHEN 'RequestCollectDate' THEN 1
                WHEN 'DateofService' THEN 2 WHEN 'CollectionDate' THEN 3
                WHEN 'ServiceDate' THEN 4 WHEN 'AccessionDate' THEN 5 ELSE 6 END);

        DECLARE @NewStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('NewStatus','Status')
            ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 ELSE 2 END);

        DECLARE @PanelTypeCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelType','PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
            ORDER BY CASE name
                WHEN 'PanelType' THEN 0 WHEN 'PanelCategory' THEN 1 WHEN 'PanelName' THEN 2
                WHEN 'Panelname' THEN 3 WHEN 'TestPanel' THEN 4 WHEN 'TestPanelName' THEN 5
                WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8
                WHEN 'Test_Panel' THEN 9 WHEN 'TestPanelname' THEN 10 ELSE 11 END);

        DECLARE @BillCategoryCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
            ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BilledorNot' THEN 3 WHEN 'BillStatus' THEN 4 ELSE 5 END);

        DECLARE @SubStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('SubStatus','Sub_Status','ClientStatus','FinalStatus')
            ORDER BY CASE name WHEN 'SubStatus' THEN 0 WHEN 'Sub_Status' THEN 1 WHEN 'ClientStatus' THEN 2 WHEN 'FinalStatus' THEN 3 ELSE 4 END);

        -- Optional display-only columns (best-effort; '' if not found)
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

        IF @AccCol IS NULL OR @DateCol IS NULL OR @NewStatusCol IS NULL OR @PanelTypeCol IS NULL OR @BillCategoryCol IS NULL OR @SubStatusCol IS NULL
        BEGIN
            PRINT 'usp_GetCove_ExecutiveSummary_Detail: required LIMSMaster columns not found - returning empty result.';
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber, CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName, CAST(NULL AS DATE) AS DateOfCollection,
                CAST(NULL AS NVARCHAR(200)) AS NewStatus, CAST(NULL AS NVARCHAR(200)) AS PanelType,
                CAST(NULL AS NVARCHAR(200)) AS BillCategory, CAST(NULL AS NVARCHAR(200)) AS SubStatus;
            RETURN;
        END

        DECLARE @PatientNameExpr NVARCHAR(300) = CASE WHEN @PatientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PatientNameCol + N']), '''')))'
            ELSE N'''''' END;

        DECLARE @ClientNameExpr NVARCHAR(300) = CASE WHEN @ClientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientNameCol + N']), '''')))'
            ELSE N'''''' END;

        DECLARE @LisSql NVARCHAR(MAX) = N'
            INSERT INTO #Lis (Accession, DateOfCollection, NewStatus, PanelType, BillCategory, SubStatus, PatientName, ClientName)
            SELECT
                LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
                TRY_CAST([' + @DateCol + N'] AS DATE),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @NewStatusCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelTypeCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol + N']), ''''))),
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

        -- Dynamic B.<PanelType> / D.5.<PanelType> / D.6.<PanelType> sub-rows:
        -- extract the panel name from the RowCode suffix (one row per
        -- distinct LIMSMaster.PanelType, not a fixed list).
        DECLARE @PanelFilter NVARCHAR(300) = NULL;
        IF @RowCode LIKE 'B.%'
            SET @PanelFilter = SUBSTRING(@RowCode, 3, 300);
        ELSE IF @RowCode LIKE 'D.5.%' OR @RowCode LIKE 'D.6.%'
            SET @PanelFilter = SUBSTRING(@RowCode, 5, 300);

        SELECT DISTINCT
            l.Accession        AS VisitNumber,
            l.PatientName,
            l.ClientName,
            l.DateOfCollection,
            l.NewStatus,
            l.PanelType,
            l.BillCategory,
            l.SubStatus
        FROM #Lis l
        WHERE
               (@RowCode = 'A')
            OR (@RowCode = 'B'      AND l.NewStatus='Billable')
            OR (@PanelFilter IS NOT NULL AND @RowCode LIKE 'B.%' AND l.NewStatus='Billable' AND l.PanelType = @PanelFilter COLLATE DATABASE_DEFAULT)
            OR (@RowCode = 'C'      AND l.NewStatus='Billable' AND l.BillCategory='Billed')
            OR (@RowCode = 'D'      AND l.NewStatus='Billable' AND l.BillCategory='Not Billed')
            OR (@RowCode = 'D.1'    AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Billed Insurance In Covedx')
            OR (@RowCode = 'D.2'    AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Billed In Variantx Lab')
            OR (@RowCode = 'D.3'    AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Billed In Elixir Dx')
            OR (@RowCode = 'D.4'    AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Ignored - Duplicate Accession')
            OR (@RowCode = 'D.5'    AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Coding exception')
            OR (@PanelFilter IS NOT NULL AND @RowCode LIKE 'D.5.%' AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Coding exception' AND l.PanelType = @PanelFilter COLLATE DATABASE_DEFAULT)
            OR (@RowCode = 'D.6'    AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='CP Exception')
            OR (@PanelFilter IS NOT NULL AND @RowCode LIKE 'D.6.%' AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='CP Exception' AND l.PanelType = @PanelFilter COLLATE DATABASE_DEFAULT)
            OR (@RowCode = 'D.7'    AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='In process')
            OR (@RowCode = 'D.8'    AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Ignored - Client Response Non Billiable')
            OR (@RowCode = 'D.9'    AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Ready To Bill')
            OR (@RowCode = 'D.10'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Ignored - NGS & PGX in Cove')
            OR (@RowCode = 'D.11'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='CP Exception -In Review')
            OR (@RowCode = 'D.12'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Medicaid Credentialling In Process')
            OR (@RowCode = 'D.13'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Ignored - Reported in Elixir Truemed')
            OR (@RowCode = 'D.14'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Ignored - CP Exception')
            OR (@RowCode = 'D.15'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Client Bill Cases')
            OR (@RowCode = 'D.16'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Ignored - Client Response Pure Selfpay')
            OR (@RowCode = 'D.17'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Selfpay')
            OR (@RowCode = 'D.18'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Ignored - Rejected Accession')
            OR (@RowCode = 'D.19'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Hold-Amerihealth Lousiana')
            OR (@RowCode = 'D.20'   AND l.NewStatus='Billable' AND l.BillCategory='Not Billed' AND l.SubStatus='Ignored - Test Cases')
            OR (@RowCode = 'E'      AND l.NewStatus<>'Billable')
            OR (@RowCode = 'E.1'    AND l.NewStatus='Self Pay')
            OR (@RowCode = 'E.2'    AND l.NewStatus='Client Bill')
            OR (@RowCode = 'E.3'    AND l.NewStatus='Deleted / Rejected')
            OR (@RowCode = 'E.4'    AND l.NewStatus='System Test')
            OR (@RowCode = 'E.5'    AND l.NewStatus='Ref Lab - Bill Patient')
            OR (@RowCode = 'E.6'    AND l.NewStatus='Missing Accession')
            OR (@RowCode = 'E.7'    AND l.NewStatus='Yet To Be Validated')
        ORDER BY l.DateOfCollection, l.Accession;

        DROP TABLE IF EXISTS #Lis;
        RETURN;
    END
END;
GO

PRINT '18_Cove_ExecutiveSummary_Detail.sql completed.';
GO
