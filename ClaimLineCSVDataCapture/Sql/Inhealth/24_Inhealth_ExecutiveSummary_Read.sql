-- ============================================================
-- Inhealth – Executive Summary Read SP
-- File : 24_Inhealth_ExecutiveSummary_Read.sql
-- DB   : Inhealth_LRN
--
-- Mirrors Augustus\17_Augustus_ExecutiveSummary_Read.sql.
--
-- usp_GetInh_ExecutiveSummary(@YearFrom,@YearTo,@MonthFrom,@MonthTo)
--   @YearFrom/@YearTo/@MonthFrom/@MonthTo : INT = 0 (0 = unbounded)
--   @HasFilter = 1 if any of the four parameters is non-zero.
--
-- No-filter path (fast read): UNION ALL of the 4 aggregate tables
-- (Inhealth_ES_LIS, Inhealth_ES_PMS, Inhealth_ES_Cash, Inhealth_ES_Avg).
--
-- Filtered path (live re-aggregation): re-derives ALL RowCodes from
-- dbo.LIMSMaster (LIS, date-filtered on ReqCollectDate) and
-- dbo.ClaimLevelData (PMS/Cash/Avg, date-filtered on DateofService).
--
-- Inhealth LIMSMaster column mapping (priority order):
--   OrderID       -> OrderID, OrderId, AccessionNumber, Accession
--   NA            -> NA, IsNA, NotApplicable, NA_Flag
--   SampleStatus  -> SampleStatus, BillTo, Sample_Status
--   BillCategory  -> BillCategory, BillingStatus, Bill_Category, BillingCategory
--   SubStatus     -> SubStatus, FinalStatus, Sub_Status, ClientStatus
--   LRNPanelName  -> LRNPanelName, LRN_PanelName, LRNPanel, PanelName, PanelType
--   ReqCollectDate -> the date column (priority 0)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetInh_ExecutiveSummary
(
    @YearFrom     INT           = 0,
    @YearTo       INT           = 0,
    @MonthFrom    INT           = 0,
    @MonthTo      INT           = 0,
    @DosFrom      DATE          = NULL,
    @DosTo        DATE          = NULL,
    @ReceivedFrom DATE          = NULL,
    @ReceivedTo   DATE          = NULL,
    @BilledFrom   DATE          = NULL,
    @BilledTo     DATE          = NULL,
    @PostedFrom   DATE          = NULL,
    @PostedTo     DATE          = NULL,
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
        WHEN @ReceivedFrom IS NOT NULL THEN 1
        WHEN @ReceivedTo   IS NOT NULL THEN 1
        WHEN @BilledFrom   IS NOT NULL THEN 1
        WHEN @BilledTo     IS NOT NULL THEN 1
        WHEN @PostedFrom   IS NOT NULL THEN 1
        WHEN @PostedTo     IS NOT NULL THEN 1
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
            FROM dbo.Inhealth_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
                   2, Id
            FROM dbo.Inhealth_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   3, Id
            FROM dbo.Inhealth_ES_Cash

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   4, Id
            FROM dbo.Inhealth_ES_Avg
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

    -- ── LIS: build #Lis from dbo.LIMSMaster, date-filtered on ReqCollectDate ─
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        OrderID       NVARCHAR(100) NOT NULL,
        NAFlag        NVARCHAR(50)  NOT NULL,
        SampleStatus  NVARCHAR(200) NOT NULL,
        BillCategory  NVARCHAR(200) NOT NULL,
        SubStatus     NVARCHAR(200) NOT NULL,
        LRNPanelName  NVARCHAR(200) NOT NULL
    );

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
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

        -- ReqCollectDate is priority 0 for Inhealth
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

        IF @OrderIDCol IS NOT NULL AND @DateCol IS NOT NULL AND @SampleStatusCol IS NOT NULL
           AND @BillCategoryCol IS NOT NULL AND @SubStatusCol IS NOT NULL
        BEGIN
            DECLARE @NAExpr       NVARCHAR(300) = CASE WHEN @NACol IS NOT NULL
                THEN N'ISNULL(CONVERT(NVARCHAR(50), [' + @NACol + N']), '''')'
                ELSE N'''''' END;
            DECLARE @PanelExpr    NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol + N']), '''')))'
                ELSE N'''''' END;

            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (OrderID, NAFlag, SampleStatus, BillCategory, SubStatus, LRNPanelName)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @OrderIDCol + N']))),
                    ' + @NAExpr + N',
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SampleStatusCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillCategoryCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @SubStatusCol + N']), ''''))),
                    ' + @PanelExpr + N'
                FROM dbo.LIMSMaster
                WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @OrderIDCol + N']))), '''') IS NOT NULL
                  AND (ISNULL(@iYearFrom,0)=0  OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iYearFrom)
                  AND (ISNULL(@iYearTo,0)=0    OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iYearTo)
                  AND (ISNULL(@iMonthFrom,0)=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) >= @iMonthFrom)
                  AND (ISNULL(@iMonthTo,0)=0   OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) <= @iMonthTo)
                  AND (@iReceivedFrom IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) >= @iReceivedFrom)
                  AND (@iReceivedTo   IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) <= @iReceivedTo);';

            EXEC sp_executesql @LisSql,
                N'@iYearFrom INT, @iYearTo INT, @iMonthFrom INT, @iMonthTo INT, @iReceivedFrom DATE, @iReceivedTo DATE',
                @iYearFrom=@YearFrom, @iYearTo=@YearTo, @iMonthFrom=@MonthFrom, @iMonthTo=@MonthTo,
                @iReceivedFrom=@ReceivedFrom, @iReceivedTo=@ReceivedTo;
        END
    END

    -- ── PMS/Cash/Avg: build #Base from dbo.ClaimLevelData, date-filtered ─────
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        ISNULL(LTRIM(RTRIM(BillStatus)),  '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
      AND (ISNULL(@YearFrom,0)=0  OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
      AND (ISNULL(@YearTo,0)=0    OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
      AND (ISNULL(@MonthFrom,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
      AND (ISNULL(@MonthTo,0)=0   OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
      AND (@DosFrom    IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
      AND (@DosTo      IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
      AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
      AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
      AND (@PostedFrom IS NULL OR TRY_CAST(PostedDate      AS DATE) >= @PostedFrom)
      AND (@PostedTo   IS NULL OR TRY_CAST(PostedDate      AS DATE) <= @PostedTo)
      AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(PanelType,         ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterPanels))
      AND (@HasClinicFilter   = 0 OR LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterClinics))
      AND (@HasProviderFilter = 0 OR LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterProviders))
      AND (@HasRepFilter      = 0 OR LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterReps));

    -- ────────────────────────────────────────────────────────────────────
    --  LIS  -  A, B, B1.{LRNPanelName}, C, C.1, D, D.1-D.6, E, E.1-E.7
    -- ────────────────────────────────────────────────────────────────────
    ;WITH Lis AS
    (
        -- A  Total Samples (NA is not blank)
        SELECT 'A' AS RowCode, 'Total Samples' AS Description,
               CAST(COUNT(DISTINCT CASE WHEN NULLIF(NAFlag,'') IS NOT NULL THEN OrderID END) AS DECIMAL(18,2)) AS MetricValue FROM #Lis

        -- B  Billable Samples
        UNION ALL SELECT 'B', 'Billable Samples',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- C  Billed
        UNION ALL SELECT 'C', '  Billed',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' AND BillCategory='Billed' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- C.1  Billed Via AMD
        UNION ALL SELECT 'C.1', '    Billed Via AMD',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' AND BillCategory='Billed' AND SubStatus='Billed Via AMD' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- D  Unbilled
        UNION ALL SELECT 'D', '  Unbilled',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' AND BillCategory='Not Billed' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- D.1  Nexum_Claim_scrubber_Eligibility
        UNION ALL SELECT 'D.1', '    Nexum_Claim_scrubber_Eligibility',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Nexum_Claim_scrubber_Eligibility' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- D.2  Requires Review
        UNION ALL SELECT 'D.2', '    Requires Review',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Requires Review' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- D.3  Entered in AMD but not billed
        UNION ALL SELECT 'D.3', '    Entered in AMD but not billed',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Entered in AMD but not billed' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- D.4  Nexum Pre Processing Queue
        UNION ALL SELECT 'D.4', '    Nexum Pre Processing Queue',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Nexum Pre Processing Queue' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- D.5  Nexum_Claim_scrubber_AMD Output
        UNION ALL SELECT 'D.5', '    Nexum_Claim_scrubber_AMD Output',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Nexum_Claim_scrubber_AMD Output' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- D.6  Nexum_Claim_scrubber_Diagnosis Validity
        UNION ALL SELECT 'D.6', '    Nexum_Claim_scrubber_Diagnosis Validity',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' AND BillCategory='Not Billed' AND SubStatus='Nexum_Claim_scrubber_Diagnosis Validity' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- E  Other Samples
        UNION ALL SELECT 'E', 'Other Samples',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Other Samples' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- E.1  Billed (Other Samples + BillCategory=Billed)
        UNION ALL SELECT 'E.1', '  Billed',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Other Samples' AND BillCategory='Billed' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- E.2  Unbilled (Other Samples + BillCategory=Not Billed)
        UNION ALL SELECT 'E.2', '  Unbilled',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Other Samples' AND BillCategory='Not Billed' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- E.3  Other Samples (LIS Table provides Breakdown) - label row
        UNION ALL SELECT 'E.3', '  Other Samples (LIS Table provides Breakdown)',
               CAST(0 AS DECIMAL(18,2)) FROM #Lis HAVING COUNT(1) >= 0

        -- E.4  Self Pay
        UNION ALL SELECT 'E.4', '  Self Pay',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Self Pay' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- E.5  Deleted/Rejected
        UNION ALL SELECT 'E.5', '  Deleted/Rejected',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Deleted/Rejected' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- E.6  Duplicate
        UNION ALL SELECT 'E.6', '  Duplicate',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Duplicate' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis

        -- E.7  System Test
        UNION ALL SELECT 'E.7', '  System Test',
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='System Test' THEN OrderID END) AS DECIMAL(18,2)) FROM #Lis
    ),
    -- Dynamic panel sub-rows under B (B1.{LRNPanelName})
    LisPanels AS
    (
        SELECT DISTINCT 'B1.' + LRNPanelName AS RowCode,
               '    ' + LRNPanelName AS Description,
               CAST(COUNT(DISTINCT CASE WHEN ISNULL(NAFlag,'')='' AND SampleStatus='Billable' THEN OrderID END) AS DECIMAL(18,2)) AS MetricValue
        FROM #Lis
        WHERE NULLIF(LRNPanelName, '') IS NOT NULL
          AND ISNULL(NAFlag,'') = ''
          AND SampleStatus = 'Billable'
        GROUP BY LRNPanelName
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  PMS  -  F, G, H, H.1, H.2, I, J, K, L, M, N, O, O.1, O.2, O.3
    -- ────────────────────────────────────────────────────────────────────
    PMS AS
    (
        SELECT 'F' AS RowCode, 'No. of Billed Claims' AS Description,
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' THEN AccessionNumber END) AS DECIMAL(18,2)) AS MetricValue FROM #Base
        UNION ALL SELECT 'G', 'Billed Mismatches',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' THEN AccessionNumber END) AS DECIMAL(18,2))
               - CAST(ISNULL((SELECT COUNT(DISTINCT OrderID) FROM #Lis WHERE BillCategory='Billed'), 0) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'H', 'No. of UnBilled Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Unbilled' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'H.1', '  Unbilled',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Unbilled' AND ClaimStatus='Unbilled' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'H.2', '  Unbilled - Patient Balance',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Unbilled' AND ClaimStatus='Unbilled - Patient Balance' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'I', 'No. of Fully Paid Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Fully Paid' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'J', 'No. of Patient Responsibility Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Patient Responsibility' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'K', 'No. of Fully Adjusted Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Complete W/O' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'L', 'No. of Partially Adjusted Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Partially Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'M', 'No. of Patient Payments Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Patient Payment' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'N', 'No. of Partially Paid Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Partially Paid' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'O', 'No. of Insurance Balance Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus IN ('FullyDenied','Partially Denied','No Response') THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'O.1', '  No. of Denied Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='FullyDenied' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'O.2', '  No. of Partially Denied Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Partially Denied' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
        UNION ALL SELECT 'O.3', '  No. of No Response from Payor Claims',
               CAST(COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='No Response' THEN AccessionNumber END) AS DECIMAL(18,2)) FROM #Base
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Cash  -  P, Q, Q.1, Q.2, R, S, T, U, V, W, W.1, W.2, W.3
    -- ────────────────────────────────────────────────────────────────────
    Cash AS
    (
        SELECT 'P' AS RowCode, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN BillStatus='Billed' THEN ChargeAmount ELSE 0 END) AS MetricValue FROM #Base
        UNION ALL SELECT 'Q', 'Total Unbilled ($)',
               SUM(CASE WHEN BillStatus='Unbilled' THEN ChargeAmount ELSE 0 END) FROM #Base
        UNION ALL SELECT 'Q.1', '  Unbilled',
               SUM(CASE WHEN BillStatus='Unbilled' AND ClaimStatus='Unbilled' THEN ChargeAmount ELSE 0 END) FROM #Base
        UNION ALL SELECT 'Q.2', '  Unbilled - Patient Balance',
               SUM(CASE WHEN BillStatus='Unbilled' AND ClaimStatus='Unbilled - Patient Balance' THEN ChargeAmount ELSE 0 END) FROM #Base
        UNION ALL SELECT 'R', 'Insurance Payment ($)',
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus='Fully Paid' THEN InsurancePayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'S', 'Patient Payments ($)',
               SUM(CASE WHEN BillStatus='Billed' THEN PatientPayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'T', 'Partially Paid ($)',
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus='Partially Paid' THEN InsurancePayment ELSE 0 END) FROM #Base
        UNION ALL SELECT 'U', 'Patient Responsibility ($)',
               SUM(CASE WHEN BillStatus='Billed' THEN PatientBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'V', 'Total Adjustments ($)',
               SUM(CASE WHEN BillStatus='Billed' THEN InsuranceAdjustments + PatientAdjustments ELSE 0 END) FROM #Base
        UNION ALL SELECT 'W', 'Insurance Balance ($)',
               SUM(CASE WHEN BillStatus='Billed' THEN InsuranceBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'W.1', '  Denials',
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus='FullyDenied' THEN InsuranceBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'W.2', '  Partially Denied',
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus='Partially Denied' THEN InsuranceBalance ELSE 0 END) FROM #Base
        UNION ALL SELECT 'W.3', '  No Response from Payor',
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus='No Response' THEN InsuranceBalance ELSE 0 END) FROM #Base
    ),
    -- ────────────────────────────────────────────────────────────────────
    --  Avg  -  X, Y, Z
    -- ────────────────────────────────────────────────────────────────────
    AvgRows AS
    (
        SELECT 'X' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               CASE WHEN COUNT(DISTINCT CASE WHEN BillStatus='Billed' THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus IN ('Fully Paid','Partially Paid')
                                  THEN InsurancePayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN BillStatus='Billed' THEN AccessionNumber END)
                    ELSE 0 END AS MetricValue
        FROM #Base

        UNION ALL
        SELECT 'Y', 'Average Payment ($) - Fully Paid Claim Value/Paid Claims',
               CASE WHEN COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Fully Paid' THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus='Fully Paid' THEN InsurancePayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN BillStatus='Billed' AND ClaimStatus='Fully Paid' THEN AccessionNumber END)
                    ELSE 0 END
        FROM #Base

        UNION ALL
        SELECT 'Z', 'Average Payment ($) - Total Pay/Adjudicated Claims',
               CASE WHEN COUNT(DISTINCT CASE WHEN BillStatus='Billed'
                                             AND ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                                                 'Partially Paid','Patient Payment','FullyDenied','Partially Denied')
                                             THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN BillStatus='Billed'
                                  AND ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                                      'Partially Paid','Patient Payment','FullyDenied','Partially Denied')
                                  THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(DISTINCT CASE WHEN BillStatus='Billed'
                                               AND ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                                                   'Partially Paid','Patient Payment','FullyDenied','Partially Denied')
                                               THEN AccessionNumber END)
                    ELSE 0 END
        FROM #Base
    )
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM
    (
        SELECT RowCode, 'LIS'  AS Category, Description, 0 AS BillYear, 0 AS BillMonth, MetricValue, 1 AS CatOrder FROM Lis
        UNION ALL
        SELECT RowCode, 'LIS',  Description, 0, 0, MetricValue, 1 FROM LisPanels
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

PRINT '24_Inhealth_ExecutiveSummary_Read.sql completed.';
GO
