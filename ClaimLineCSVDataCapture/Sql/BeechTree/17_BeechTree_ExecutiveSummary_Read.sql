-- ============================================================
-- BeechTree – Executive Summary Read SP
-- File : 17_BeechTree_ExecutiveSummary_Read.sql
-- DB   : BeechTree_LRN
--
-- Mirrors Augustus\17_Augustus_ExecutiveSummary_Read.sql.
--
-- usp_GetBT_ExecutiveSummary(@YearFrom,@YearTo,@MonthFrom,@MonthTo)
--   @YearFrom/@YearTo/@MonthFrom/@MonthTo : INT = 0 (0 = unbounded)
--   @HasFilter = 1 if any of the four parameters is non-zero.
--
-- No-filter path (fast read): UNION ALL of the 4 aggregate tables
-- (BeechTree_ES_LIS, BeechTree_ES_PMS, BeechTree_ES_Cash, BeechTree_ES_Avg).
--
-- Filtered path (live re-aggregation): re-derives ALL RowCodes from
-- dbo.LIMSMaster (LIS, date-filtered on RequestCollectDate) and
-- dbo.ClaimLevelData (PMS/Cash/Avg, date-filtered on DateofService).
--
-- BeechTree LIS column mapping:
--   Accession   : AccessionNumber / VisitNumber / OrderID / Accession
--   Date        : RequestCollectDate (priority 0)
--   Resulted    : RessultedStatus / ResultedStatus / ...
--   ClaimStatus : ClaimStatus
--   BilledorNot : BilledorNot / BilledStatus / BilledUnbilled
--   ClientStatus: ClientStatus
--   SampleStatus: SampleStatus
--   PaymentMethod: PaymentMethod
--   PanelType   : PanelType / PanelName / Panelname / ...
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetBT_ExecutiveSummary
(
    @YearFrom     INT           = 0,
    @YearTo       INT           = 0,
    @MonthFrom    INT           = 0,
    @MonthTo      INT           = 0,
    @DosFrom      DATE          = NULL,
    @DosTo        DATE          = NULL,
    @BilledFrom   DATE          = NULL,
    @BilledTo     DATE          = NULL,
    @Panels       NVARCHAR(MAX) = NULL,
    @Clinics      NVARCHAR(MAX) = NULL,
    @Providers    NVARCHAR(MAX) = NULL,
    @Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT = CASE
        WHEN ISNULL(@YearFrom,  0) <> 0 THEN 1
        WHEN ISNULL(@YearTo,    0) <> 0 THEN 1
        WHEN ISNULL(@MonthFrom, 0) <> 0 THEN 1
        WHEN ISNULL(@MonthTo,   0) <> 0 THEN 1
        WHEN @DosFrom      IS NOT NULL THEN 1
        WHEN @DosTo        IS NOT NULL THEN 1
        WHEN @BilledFrom   IS NOT NULL THEN 1
        WHEN @BilledTo     IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL THEN 1
        ELSE 0
    END;

    -- ════════════════════════════════════════════════════════════════════
    --  NO FILTER  -  fast read from the 4 aggregate tables
    -- ════════════════════════════════════════════════════════════════════
    IF @HasFilter = 0
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
        FROM
        (
            SELECT RoleID AS RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue,
                   1 AS CatOrder, Id AS SortId
            FROM dbo.BeechTree_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
                   2, Id
            FROM dbo.BeechTree_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   3, Id
            FROM dbo.BeechTree_ES_Cash

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   4, Id
            FROM dbo.BeechTree_ES_Avg
        ) x
        ORDER BY BillYear, BillMonth, CatOrder, SortId;

        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  FILTERED  -  live re-aggregation
    -- ════════════════════════════════════════════════════════════════════

    -- Dimension filter staging tables
    CREATE TABLE #FilterPanels   (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterClinics  (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterProviders(Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterReps     (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL
        INSERT INTO #FilterPanels(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Panels, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL
        INSERT INTO #FilterClinics(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Clinics, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL
        INSERT INTO #FilterProviders(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Providers, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL
        INSERT INTO #FilterReps(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Reps, ',') WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @HasPanelFilter    BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterPanels)    THEN 1 ELSE 0 END;
    DECLARE @HasClinicFilter   BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterClinics)   THEN 1 ELSE 0 END;
    DECLARE @HasProviderFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterProviders) THEN 1 ELSE 0 END;
    DECLARE @HasRepFilter      BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterReps)      THEN 1 ELSE 0 END;

    -- ── LIS: build #Lis from dbo.LIMSMaster, date-filtered on RequestCollectDate ──
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession      NVARCHAR(100) NOT NULL,
        Resulted       NVARCHAR(200) NOT NULL,
        ClaimStatus    NVARCHAR(200) NOT NULL,
        BilledorNot    NVARCHAR(200) NOT NULL,
        ClientStatus   NVARCHAR(200) NOT NULL,
        SampleStatus   NVARCHAR(200) NOT NULL,
        PaymentMethod  NVARCHAR(200) NOT NULL,
        PanelType      NVARCHAR(200) NOT NULL
    );

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
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
                WHEN 'ResultedNot'     THEN 2 WHEN 'Resulted_Not'   THEN 3
                WHEN 'IsResulted'      THEN 4 WHEN 'Resulted'       THEN 5 ELSE 6 END);

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
                WHEN 'Panelname' THEN 3 WHEN 'TestPanel'     THEN 4 ELSE 5 END);

        IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @ResultedCol IS NOT NULL
        BEGIN
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

            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (Accession, Resulted, ClaimStatus, BilledorNot, ClientStatus, SampleStatus, PaymentMethod, PanelType)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100),[' + @AccCol + N']))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @ResultedCol + N']),''''))),
                    ' + @CSExpr + N',
                    ' + @BONExpr + N',
                    ' + @CLExpr + N',
                    ' + @SSExpr + N',
                    ' + @PMExpr + N',
                    ' + @PTExpr + N'
                FROM dbo.LIMSMaster
                WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),[' + @AccCol + N']))),'''') IS NOT NULL
                  AND (ISNULL(@iYearFrom,0)=0  OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iYearFrom)
                  AND (ISNULL(@iYearTo,0)=0    OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iYearTo)
                  AND (ISNULL(@iMonthFrom,0)=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iMonthFrom)
                  AND (ISNULL(@iMonthTo,0)=0   OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iMonthTo);';

            EXEC sp_executesql @LisSql,
                N'@iYearFrom INT,@iYearTo INT,@iMonthFrom INT,@iMonthTo INT',
                @iYearFrom=@YearFrom, @iYearTo=@YearTo, @iMonthFrom=@MonthFrom, @iMonthTo=@MonthTo;
        END
    END

    -- ── PMS/Cash/Avg: build #Base from dbo.ClaimLevelData, date-filtered ────
    DROP TABLE IF EXISTS #Base;

    SELECT
        ClaimID,
        ISNULL(LTRIM(RTRIM(BilledUnbilled)), '')             AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)),    '')             AS ClaimStatus,
        ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(CONVERT(NVARCHAR(50), ClaimID), '') IS NOT NULL
      AND (ISNULL(@YearFrom,0)=0  OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
      AND (ISNULL(@YearTo,0)=0    OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
      AND (ISNULL(@MonthFrom,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
      AND (ISNULL(@MonthTo,0)=0   OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
      AND (@DosFrom    IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
      AND (@DosTo      IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
      AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
      AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
      AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(PanelType,         ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterPanels))
      AND (@HasClinicFilter   = 0 OR LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterClinics))
      AND (@HasProviderFilter = 0 OR LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterProviders))
      AND (@HasRepFilter      = 0 OR LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterReps));

    -- ────────────────────────────────────────────────────────────────────
    --  LIS  -  A, B, B2, B2.1, B3..B9, C, C1, C2, C2.1-C2.4, C3, C4, C4.1-C4.2, D, E
    -- ────────────────────────────────────────────────────────────────────
    ;WITH Lis AS
    (
        SELECT 'A'    AS RowCode, 'Total Samples'                     AS Description,
               CAST(COUNT(DISTINCT Accession) AS DECIMAL(18,2))       AS MetricValue FROM #Lis
        UNION ALL SELECT 'B',    'Billable Samples - Resulted',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B2',   '  Billed to Insurance',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClaimStatus='Billed' AND BilledorNot='Billed' AND ClientStatus='' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B2.1', '    Billed In AMD',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClaimStatus='Billed' AND BilledorNot='Billed' AND ClientStatus='' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B3',   '  Not Entered in AMD',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B3.1', '    Received',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') AND SampleStatus='Received' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B3.2', '    Billing Review Required',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND SampleStatus='Received' AND ClientStatus='Billing Review Required' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B3.3', '    In Transit',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') AND SampleStatus='In Transit' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B3.4', '    Transferred',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') AND SampleStatus='Transferred' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B3.5', '    Collected',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus IN ('','Billing Review Required') AND SampleStatus='Collected' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B4',   '  Unbilled',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClaimStatus='Entered' AND BilledorNot='UnBilled' AND ClientStatus='' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B5',   '  Client Bill',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Client Bill' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B5.1', '    Not Entered in AMD',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Client Bill' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B5.2', '    Billed',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Client Bill' AND BilledorNot='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B6',   '  Self Pay',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Self Pay' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B6.1', '    Not Entered in AMD',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Self Pay' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B6.2', '    Billed',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Self Pay' AND BilledorNot='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B6.3', '    Entered',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Self Pay' AND ClaimStatus='Entered' AND BilledorNot='UnBilled' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B7',   '  Test Entries',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Test Entries' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B7.1', '    Not Entered in AMD',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Test Entries' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B7.2', '    Billed',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Test Entries' AND BilledorNot='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B8',   '  Rejected Sample',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Rejected Sample' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B8.1', '    Not Entered in AMD',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Rejected Sample' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B8.2', '    Billed',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND ClientStatus='Rejected Sample' AND BilledorNot='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'B9',   '  Payment Method No Bill',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Resulted' AND PaymentMethod='No Bill' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C',    'Not Resulted',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C1',   '  No Result date on LIS but Billed',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Billed' AND BilledorNot='Billed' AND ClientStatus='' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C2',   '  Not Entered in AMD',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C2.1', '    Received',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' AND SampleStatus='Received' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C2.2', '    In Transit',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' AND SampleStatus='In Transit' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C2.3', '    Collected',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' AND SampleStatus='Collected' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C2.4', '    Transferred',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' AND ClientStatus='' AND SampleStatus='Transferred' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C3',   '  Client Bill',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClientStatus='Client Bill' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C4',   '  Self Pay',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClientStatus='Self Pay' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C4.1', '    Not Entered in AMD',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClientStatus='Self Pay' AND ClaimStatus='Not Entered in AMD' AND BilledorNot='UnBilled' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'C4.2', '    Billed',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClientStatus='Self Pay' AND BilledorNot='Billed' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'D',    'Test Entries',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClientStatus='Test Entries' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
        UNION ALL SELECT 'E',    'Rejected Sample',
               CAST(COUNT(DISTINCT CASE WHEN Resulted='Not Resulted' AND ClientStatus='Rejected Sample' THEN Accession END) AS DECIMAL(18,2)) FROM #Lis
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  PMS  -  R, S, T, U, V, W, X, Y, Z, Z.1, Z.2, Z.3
    -- ────────────────────────────────────────────────────────────────────
    PMS AS
    (
        SELECT 'R'   AS RowCode, 'Billed - Includes all Claims Billed in AMD' AS Description,
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' THEN ClaimID END) AS DECIMAL(18,2)) AS MetricValue FROM #Base
        UNION ALL SELECT 'S',  'Billed Mismatches - Non Diagnose LIS Samples',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Billed amount 0' THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'T',  'Unbilled - Entered to AMD - Yet to be released to Payer',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='UnBilled' THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'U',  'Fully Paid - Insurance Pay',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'V',  'Fully Adjusted',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Adjusted' THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'W',  'Patient Responsibility',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Pat Responsibility' THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'X',  'Partially Paid',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Partial Paid' THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'Y',  'Patient Payment',
               CAST(COUNT(DISTINCT CASE WHEN PatientPayment > 0 THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'Z',  'Insurance Balance',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus IN ('Fully Denied','No Response','Partially Denied') THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'Z.1','  Fully Denied',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Denied' THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'Z.2','  No Response',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='No Response' THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'Z.3','  Partially Denied',
               CAST(COUNT(DISTINCT CASE WHEN ClaimStatus='Partially Denied' THEN ClaimID END) AS DECIMAL(18,2)) FROM #Base
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Cash  -  AA through AJ
    -- ────────────────────────────────────────────────────────────────────
    Cash AS
    (
        SELECT 'AA' AS RowCode, 'Total Billed ($)'                     AS Description,
               SUM(CASE WHEN BillStatus='Billed' THEN ChargeAmount ELSE 0 END)  AS MetricValue FROM #Base
        UNION ALL SELECT 'AB', 'Unbilled ($)',
               SUM(CASE WHEN BillStatus='UnBilled' THEN ChargeAmount ELSE 0 END) FROM #Base
        UNION ALL SELECT 'AC', 'Insurance Payment (fully paid) ($)',
               SUM(CASE WHEN ClaimStatus='Fully Paid' AND InsurancePayment>0 THEN InsurancePayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'AD', 'Partially Paid ($)',
               SUM(CASE WHEN ClaimStatus='Partial Paid' THEN InsurancePayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'AE', 'Patient Payment ($)',
               SUM(CASE WHEN PatientPayment>0 THEN PatientPayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'AF', 'Fully Adjusted (Complete W/O)',
               SUM(CASE WHEN ClaimStatus='Fully Adjusted' THEN InsuranceAdjustments+PatientAdjustments ELSE 0 END) FROM #Base
        UNION ALL SELECT 'AG', 'Contractual Obligation W/O',
               SUM(CASE WHEN InsuranceAdjustments>0 THEN InsuranceAdjustments ELSE 0 END) FROM #Base
        UNION ALL SELECT 'AH', 'Patient Balance ($)',
               SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN PatientBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'AI', 'Patient WO',
               SUM(CASE WHEN PatientAdjustments>0 THEN PatientAdjustments ELSE 0 END) FROM #Base
        UNION ALL SELECT 'AJ', 'Insurance Balance ($)',
               SUM(CASE WHEN ClaimStatus IN ('Fully Denied','No Response','Partially Denied') THEN InsuranceBalance ELSE 0 END) FROM #Base
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Avg  -  AK, AL, AM
    -- ────────────────────────────────────────────────────────────────────
    AvgRows AS
    (
        SELECT 'AK' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               CASE WHEN COUNT(DISTINCT CASE WHEN BillStatus='Billed' THEN ClaimID END) > 0
                    THEN SUM(CASE WHEN BillStatus='Billed' THEN InsurancePayment+PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN BillStatus='Billed' THEN ClaimID END)
                    ELSE 0 END AS MetricValue
        FROM #Base

        UNION ALL
        SELECT 'AL', 'Average Payment ($) - Total Pay/Paid Claims',
               CASE WHEN COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN ClaimID END) > 0
                    THEN SUM(CASE WHEN ClaimStatus='Fully Paid' THEN InsurancePayment+PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN ClaimStatus='Fully Paid' THEN ClaimID END)
                    ELSE 0 END
        FROM #Base

        UNION ALL
        SELECT 'AM', 'Average Payment ($) - Total Pay/Adjudicated Claims',
               CASE WHEN COUNT(DISTINCT CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN ClaimID END) > 0
                    THEN SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN InsurancePayment+PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN ClaimID END)
                    ELSE 0 END
        FROM #Base
    )
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM
    (
        SELECT RowCode, 'LIS'  AS Category, Description, 0 AS BillYear, 0 AS BillMonth, MetricValue, 1 AS CatOrder FROM Lis
        UNION ALL
        SELECT RowCode, 'PMS',  Description, 0, 0, MetricValue, 2 FROM PMS
        UNION ALL
        SELECT RowCode, 'Cash', Description, 0, 0, MetricValue, 3 FROM Cash
        UNION ALL
        SELECT RowCode, 'Avg',  Description, 0, 0, MetricValue, 4 FROM AvgRows
    ) result
    ORDER BY CatOrder, RowCode;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '17_BeechTree_ExecutiveSummary_Read.sql completed.';
GO
