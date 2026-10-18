/* =====================================================================
   Standalone SPs — NorthWest Production Excel ClaimLevel / LineLevel export
   DB  : NWL_LRN

   Do NOT re-run 14_NorthWest_ReadSPs.sql. Deploy this file only.

   Used by LabMetricsDashboard / LRN.ReportWorker to stream Claim and Line
   sheets onto the Northwest Production Summary workbook.

   Bucketing column : ChargeEnteredDate
   Split logic      : total <= @Threshold  -> one ALL sheet
                      else group by year; year > @Threshold -> split by month

   Objects:
     dbo.usp_GetNW_ClaimLevelExportBuckets
     dbo.usp_GetNW_LineLevelExportBuckets
     dbo.usp_GetNW_ClaimLevelExportByRange
     dbo.usp_GetNW_LineLevelExportByRange
   ===================================================================== */
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_ClaimLevelExportBuckets
    @Threshold       INT           = 300000,
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @CEDFrom         DATE          = NULL,
    @CEDTo           DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)),'') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)),'') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    DECLARE @HasPayer BIT = CASE WHEN EXISTS(SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel BIT = CASE WHEN EXISTS(SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        TRY_CAST(ChargeEnteredDate AS DATE)                        AS CED,
        YEAR(TRY_CAST(ChargeEnteredDate AS DATE))                  AS YearNo,
        MONTH(TRY_CAST(ChargeEnteredDate AS DATE))                 AS MonthNo
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq','Unbilled in Daq - PR',
              'Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'')))), '') IS NOT NULL
      AND (@HasPayer = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown')))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo);

    DECLARE @Total BIGINT = (SELECT COUNT(*) FROM #Base);

    IF @Total = 0 OR @Total <= @Threshold
    BEGIN
        SELECT 'ALL'               AS BucketType,
               NULL                AS YearNo,
               NULL                AS MonthNo,
               CAST(MIN(CED) AS DATETIME) AS FromDate,
               CAST(MAX(CED) AS DATETIME) AS ToDate,
               CAST(@Total AS INT) AS RecordCount,
               'ClaimLevel'        AS SheetName
        FROM #Base;
        DROP TABLE #Base;
        RETURN;
    END

    SELECT YearNo, COUNT(*) AS Cnt, MIN(CED) AS YMin, MAX(CED) AS YMax
    INTO #Yr FROM #Base GROUP BY YearNo;

    SELECT b.YearNo, b.MonthNo, COUNT(*) AS Cnt, MIN(b.CED) AS MMin, MAX(b.CED) AS MMax
    INTO #Mo FROM #Base b
    JOIN #Yr y ON y.YearNo = b.YearNo AND y.Cnt > @Threshold
    GROUP BY b.YearNo, b.MonthNo;

    SELECT
        CASE WHEN y.Cnt > @Threshold THEN 'MONTH' ELSE 'YEAR' END AS BucketType,
        y.YearNo,
        NULL AS MonthNo,
        CAST(y.YMin AS DATETIME) AS FromDate,
        CAST(y.YMax AS DATETIME) AS ToDate,
        CAST(y.Cnt AS INT)       AS RecordCount,
        CAST(y.YearNo AS NVARCHAR(4)) + '_ClaimLevel' AS SheetName
    FROM #Yr y WHERE y.Cnt <= @Threshold
    UNION ALL
    SELECT
        'MONTH' AS BucketType,
        m.YearNo,
        m.MonthNo,
        CAST(m.MMin AS DATETIME) AS FromDate,
        CAST(m.MMax AS DATETIME) AS ToDate,
        CAST(m.Cnt AS INT)       AS RecordCount,
        CAST(m.YearNo AS NVARCHAR(4)) + '_' + RIGHT('0' + CAST(m.MonthNo AS NVARCHAR(2)), 2) + '_ClaimLevel' AS SheetName
    FROM #Mo m
    ORDER BY YearNo, MonthNo;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Yr;
    DROP TABLE IF EXISTS #Mo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_LineLevelExportBuckets
    @Threshold       INT           = 300000,
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @CEDFrom         DATE          = NULL,
    @CEDTo           DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)),'') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)),'') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    DECLARE @HasPayer BIT = CASE WHEN EXISTS(SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel BIT = CASE WHEN EXISTS(SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        TRY_CAST(ChargeEnteredDate AS DATE)       AS CED,
        YEAR(TRY_CAST(ChargeEnteredDate AS DATE))  AS YearNo,
        MONTH(TRY_CAST(ChargeEnteredDate AS DATE)) AS MonthNo
    INTO #Base
    FROM dbo.LineLevelData
    WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND (@HasPayer = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo);

    DECLARE @Total BIGINT = (SELECT COUNT(*) FROM #Base);

    IF @Total = 0 OR @Total <= @Threshold
    BEGIN
        SELECT 'ALL'               AS BucketType,
               NULL                AS YearNo,
               NULL                AS MonthNo,
               CAST(MIN(CED) AS DATETIME) AS FromDate,
               CAST(MAX(CED) AS DATETIME) AS ToDate,
               CAST(@Total AS INT) AS RecordCount,
               'LineLevel'         AS SheetName
        FROM #Base;
        DROP TABLE #Base;
        RETURN;
    END

    SELECT YearNo, COUNT(*) AS Cnt, MIN(CED) AS YMin, MAX(CED) AS YMax
    INTO #Yr FROM #Base GROUP BY YearNo;

    SELECT b.YearNo, b.MonthNo, COUNT(*) AS Cnt, MIN(b.CED) AS MMin, MAX(b.CED) AS MMax
    INTO #Mo FROM #Base b
    JOIN #Yr y ON y.YearNo = b.YearNo AND y.Cnt > @Threshold
    GROUP BY b.YearNo, b.MonthNo;

    SELECT
        CASE WHEN y.Cnt > @Threshold THEN 'MONTH' ELSE 'YEAR' END AS BucketType,
        y.YearNo,
        NULL AS MonthNo,
        CAST(y.YMin AS DATETIME) AS FromDate,
        CAST(y.YMax AS DATETIME) AS ToDate,
        CAST(y.Cnt AS INT)       AS RecordCount,
        CAST(y.YearNo AS NVARCHAR(4)) + '_LineLevel' AS SheetName
    FROM #Yr y WHERE y.Cnt <= @Threshold
    UNION ALL
    SELECT
        'MONTH' AS BucketType,
        m.YearNo,
        m.MonthNo,
        CAST(m.MMin AS DATETIME) AS FromDate,
        CAST(m.MMax AS DATETIME) AS ToDate,
        CAST(m.Cnt AS INT)       AS RecordCount,
        CAST(m.YearNo AS NVARCHAR(4)) + '_' + RIGHT('0' + CAST(m.MonthNo AS NVARCHAR(2)), 2) + '_LineLevel' AS SheetName
    FROM #Mo m
    ORDER BY YearNo, MonthNo;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Yr;
    DROP TABLE IF EXISTS #Mo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_ClaimLevelExportByRange
    @FromDate        DATE          = NULL,
    @ToDate          DATE          = NULL,
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @CEDFrom         DATE          = NULL,
    @CEDTo           DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)),'') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)),'') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    DECLARE @HasPayer BIT = CASE WHEN EXISTS(SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel BIT = CASE WHEN EXISTS(SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        [ClaimID],[AccessionNumber],[PayerName_Raw],[PayerName],[Payer_Code],[Payer_Common_Code],
        [Payer_Group_Code],[Global_Payer_ID],[PayerType],[BillingProvider],[ReferringProvider],[ClinicName],
        [SalesRepname],[PatientID],[PatientDOB],[DateofService],[ChargeEnteredDate],[FirstBilledDate],
        [Panelname],[CPTCodeXUnitsXModifier],[POS],[TOS],[ChargeAmount],[AllowedAmount],
        [InsurancePayment],[PatientPayment],[TotalPayments],[InsuranceAdjustments],[PatientAdjustments],[TotalAdjustments],
        [InsuranceBalance],[PatientBalance],[TotalBalance],[CheckDate],[ClaimStatus],[DenialCode],
        [ICDCode],[DaystoDOS],[RollingDays],[DaystoBill],[DaystoPost],[ICDPointer],
        [InsertedDateTime],[InsuranceBalance_Decimal],[UID],[Aging],[PatientName],[LISPatientName],
        [SubscriberId],[PanelType],[EnteredWeek],[EnteredStatus],[LastActivityDate],[EmedixSubmissionDate],
        [ClaimType],[BilledStatus],[BilledWeek],[PostedWeek],[ModField],[CheqNo],
        [DuplicatePaymentPosted],[ActualPayment],[ProcTotalBal],[DeniedStatus],[ScrubberEditReason],[EmedixRejectionDate],
        [EmedixRejection],[RejectionCategory],[TimeToPay],[PaymentPercent],[FullyPaidCount],[FullyPaidAmount],
        [Adjudicated],[AdjudicatedAmount],[Bucket30],[Bucket30Amount],[Bucket60],[Bucket60Amount],
        [ClaimUID],[AgingDOE],[AgingDOS],[PanelNameLIS],[PanelNameBasedOnCPT],[CPTCodeXUnitsXModifierOrginal]
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq','Unbilled in Daq - PR',
              'Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'')))), '') IS NOT NULL
      AND (@FromDate IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ToDate)
      AND (@HasPayer = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown')))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(ChargeEnteredDate AS DATE), ClaimID, AccessionNumber;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_LineLevelExportByRange
    @FromDate        DATE          = NULL,
    @ToDate          DATE          = NULL,
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @CEDFrom         DATE          = NULL,
    @CEDTo           DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)),'') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)),'') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    DECLARE @HasPayer BIT = CASE WHEN EXISTS(SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel BIT = CASE WHEN EXISTS(SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        [ClaimID],[AccessionNumber],[PayerName_Raw],[PayerName],[Payer_Code],[Payer_Common_Code],
        [Payer_Group_Code],[Global_Payer_ID],[PayerType],[BillingProvider],[ReferringProvider],[ClinicName],
        [SalesRepname],[PatientID],[PatientDOB],[DateofService],[ChargeEnteredDate],[FirstBilledDate],
        [Panelname],[CPTCode],[Units],[Modifier],[POS],[TOS],
        [ChargeAmount],[ChargeAmountPerUnit],[AllowedAmount],[AllowedAmountPerUnit],[InsurancePayment],[InsurancePaymentPerUnit],
        [PatientPayment],[PatientPaymentPerUnit],[TotalPayments],[InsuranceAdjustments],[PatientAdjustments],[TotalAdjustments],
        [InsuranceBalance],[PatientBalance],[PatientBalancePerUnit],[TotalBalance],[CheckDate],[PostingDate],
        [ClaimStatus],[PayStatus],[DenialCode],[DenialDate],[ICDCode],[DaystoDOS],
        [RollingDays],[DaystoBill],[DaystoPost],[ICDPointer],[InsertedDateTime],[UID],
        [T_F],[PatientName],[CombinedLineLevelICD],[SubscriberId],[ClaimAmount],[CptWithUnits],
        [Proc],[EnteredStatus],[BilledStatus],[ProcTotalBal],[UpdatedDenialCode],[CombinedLineLevelDenialCode],
        [Loc],[ProcInsLastRefiledDeniedReason],[ProcInsResponsibleCarrierOriginalFilingDate],[ProcInsStatus],[ProcInsLastRefiledDeniedDate],[LineLevelUID],
        [Source],[InsuranceBalance_Decimal]
    FROM dbo.LineLevelData
    WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND (@FromDate IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ToDate)
      AND (@HasPayer = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(ChargeEnteredDate AS DATE), ClaimID, AccessionNumber;
END
GO

PRINT 'fix_NW_ClaimLineExport.sql completed.';
GO
