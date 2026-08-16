/* =====================================================================
   InHealth — Claim/Line details SPs (lab-specific SELECT list)

   Source columns: LabMetricsDashboard/Sql/Select_Script (client expected fields).
   Deploy on THIS lab's LRN database only, after Sql/ClaimLineDetails_SPs.sql.

   To add/remove a field: edit the marked SELECT list in
     dbo.usp_GetClaimLevelDetails  and/or  dbo.usp_GetLineLevelDetails
   then re-run this file. Page headings and Excel follow the SP columns.
   ===================================================================== */
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelDetails
    @PayerName                   NVARCHAR(500) = NULL,
    @PayerTypes                  NVARCHAR(MAX) = NULL,
    @ClaimStatuses               NVARCHAR(MAX) = NULL,
    @ClinicNames                 NVARCHAR(MAX) = NULL,
    @DenialCode                  NVARCHAR(500) = NULL,
    @DenialCodeExcludeBlank      BIT           = 0,
    @PayerNames                  NVARCHAR(MAX) = NULL,
    @PayerExcludeBlank           BIT           = 0,
    @PanelNames                  NVARCHAR(MAX) = NULL,
    @PanelExcludeBlank           BIT           = 0,
    @AgingBuckets                NVARCHAR(MAX) = NULL,
    @FirstBillFrom               DATE          = NULL,
    @FirstBillTo                 DATE          = NULL,
    @FirstBillNull               BIT           = 0,
    @FirstBillExcludeBlank       BIT           = 0,
    @ChargeEnteredFrom           DATE          = NULL,
    @ChargeEnteredTo             DATE          = NULL,
    @ChargeEnteredNull           BIT           = 0,
    @ChargeEnteredExcludeBlank   BIT           = 0,
    @DosFrom                     DATE          = NULL,
    @DosTo                       DATE          = NULL,
    @DosNull                     BIT           = 0,
    @Offset                      INT           = 0,
    @PageSize                    INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerNameLike   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @DenialCodeLike  TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PayerTypeList   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @ClaimStatusList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @ClinicList      TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PayerNameList   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PanelList       TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @AgingList       TABLE (Value NVARCHAR(100) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerName)), '') IS NOT NULL
        INSERT INTO @PayerNameLike SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerName, ',') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@DenialCode)), '') IS NOT NULL
        INSERT INTO @DenialCodeLike SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@DenialCode, ',') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PayerTypes)), '') IS NOT NULL
        INSERT INTO @PayerTypeList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerTypes, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@ClaimStatuses)), '') IS NOT NULL
        INSERT INTO @ClaimStatusList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@ClaimStatuses, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@ClinicNames)), '') IS NOT NULL
        INSERT INTO @ClinicList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@ClinicNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerNameList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@AgingBuckets)), '') IS NOT NULL
        INSERT INTO @AgingList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 100)
        FROM STRING_SPLIT(@AgingBuckets, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerNameLike BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerNameLike) THEN 1 ELSE 0 END;
    DECLARE @HasDenialLike    BIT = CASE WHEN EXISTS (SELECT 1 FROM @DenialCodeLike) THEN 1 ELSE 0 END;
    DECLARE @HasPayerType     BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerTypeList) THEN 1 ELSE 0 END;
    DECLARE @HasClaimStatus   BIT = CASE WHEN EXISTS (SELECT 1 FROM @ClaimStatusList) THEN 1 ELSE 0 END;
    DECLARE @HasClinic        BIT = CASE WHEN EXISTS (SELECT 1 FROM @ClinicList) THEN 1 ELSE 0 END;
    DECLARE @HasPayerNames    BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerNameList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel         BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;
    DECLARE @HasAging         BIT = CASE WHEN EXISTS (SELECT 1 FROM @AgingList) THEN 1 ELSE 0 END;

    /* ==== InHealth ClaimLevel columns (Sql/Select_Script) — add/remove fields here ==== */
    SELECT
            [LabID],
            [LabName],
            CASE WHEN [ClaimID] LIKE '%.00' THEN LEFT([ClaimID], LEN([ClaimID])-3) ELSE ISNULL(LTRIM(RTRIM([ClaimID])),'') END AS [ClaimID],
            [AccessionNumber],
            [SourceFileID],
            [IngestedOn],
            [CsvRowHash],
            [PayerName_Raw],
            ISNULL(LTRIM(RTRIM([PayerName])),'') AS [PayerName],
            [Payer_Code],
            [Payer_Common_Code],
            [Payer_Group_Code],
            [Global_Payer_ID],
            ISNULL(LTRIM(RTRIM([PayerType])),'') AS [PayerType],
            [BillingProvider],
            [ReferringProvider],
            ISNULL(LTRIM(RTRIM([ClinicName])),'') AS [ClinicName],
            ISNULL(LTRIM(RTRIM([SalesRepname])),'') AS [SalesRepname],
            CASE WHEN [PatientID] LIKE '%.00' THEN LEFT([PatientID], LEN([PatientID])-3) ELSE ISNULL(LTRIM(RTRIM([PatientID])),'') END AS [PatientID],
            [PatientDOB],
            [DateofService],
            [ChargeEnteredDate],
            [FirstBilledDate],
            ISNULL(LTRIM(RTRIM([Panelname])),'') AS [Panelname],
            [CPTCodeXUnitsXModifier],
            [POS],
            [TOS],
            ISNULL(TRY_CAST([ChargeAmount] AS DECIMAL(18,2)), 0) AS [ChargeAmount],
            ISNULL(TRY_CAST([AllowedAmount] AS DECIMAL(18,2)), 0) AS [AllowedAmount],
            ISNULL(TRY_CAST([InsurancePayment] AS DECIMAL(18,2)), 0) AS [InsurancePayment],
            ISNULL(TRY_CAST([PatientPayment] AS DECIMAL(18,2)), 0) AS [PatientPayment],
            ISNULL(TRY_CAST([TotalPayments] AS DECIMAL(18,2)), 0) AS [TotalPayments],
            [InsuranceAdjustments],
            [PatientAdjustments],
            [TotalAdjustments],
            ISNULL(TRY_CAST([InsuranceBalance] AS DECIMAL(18,2)), 0) AS [InsuranceBalance],
            ISNULL(TRY_CAST([PatientBalance] AS DECIMAL(18,2)), 0) AS [PatientBalance],
            ISNULL(TRY_CAST([TotalBalance] AS DECIMAL(18,2)), 0) AS [TotalBalance],
            [CheckDate],
            ISNULL(LTRIM(RTRIM([ClaimStatus])),'') AS [ClaimStatus],
            [DenialCode],
            [ICDCode],
            [DaystoDOS],
            [RollingDays],
            [DaystoBill],
            [DaystoPost],
            [ICDPointer],
            [InsertedDateTime],
            [DOE_Year],
            [DOE_Month],
            [AgingBucket],
            [BilledUnbilled],
            [Modifier],
            ISNULL(LTRIM(RTRIM([CPTCode])),'') AS [CPTCode],
            [Units],
            [CPTCodeXUnitsXModifierOrginal],
            [PaymentPercent],
            [AdjudicatedCount],
            [Days30Count],
            [Days30Amount],
            [Days60Count],
            [Days60Amount],
            [FullyPaidCount],
            ISNULL(TRY_CAST([FullyPaidAmount] AS DECIMAL(18,2)), 0) AS [FullyPaidAmount],
            ISNULL(TRY_CAST([AdjudicatedAmount] AS DECIMAL(18,2)), 0) AS [AdjudicatedAmount],
            [PatientName],
            [BilledWeek],
            [PostedWeek],
            [PanelNameLIS],
            [PanelNameBasedOnCPT],
            ISNULL(TRY_CAST([TotalWO] AS DECIMAL(18,2)), 0) AS [TotalWO],
            [BillStatus],
            [AgingDOS],
            [AgingDOE],
            [ResponsibleParty],
            [SubscriberID],
            [ClientAccNum],
            [EndDOS],
            [DODWeek],
            [CheckNumber],
            [LineLevelICD],
            [Facility],
            [ClaimUID],
            ISNULL(TRY_CAST([InsuranceBalance_Decimal] AS DECIMAL(18,2)), 0) AS [InsuranceBalance_Decimal],
            [DenialDate],
            [Bucket30Count],
            ISNULL(TRY_CAST([Bucket30Amount] AS DECIMAL(18,2)), 0) AS [Bucket30Amount],
            [Bucket60Count],
            ISNULL(TRY_CAST([Bucket60Amount] AS DECIMAL(18,2)), 0) AS [Bucket60Amount]
    FROM dbo.ClaimLevelData
    WHERE (@HasPayerNameLike = 0 OR EXISTS (SELECT 1 FROM @PayerNameLike p WHERE LTRIM(RTRIM(ClaimLevelData.PayerName)) LIKE N'%' + p.Value + N'%'))
      AND (@HasPayerType = 0 OR LTRIM(RTRIM(PayerType)) IN (SELECT Value FROM @PayerTypeList))
      AND (@HasClaimStatus = 0 OR LTRIM(RTRIM(ClaimStatus)) IN (SELECT Value FROM @ClaimStatusList))
      AND (@HasClinic = 0 OR LTRIM(RTRIM(ClinicName)) IN (SELECT Value FROM @ClinicList))
      AND (@HasDenialLike = 0 OR EXISTS (SELECT 1 FROM @DenialCodeLike d WHERE LTRIM(RTRIM(ClaimLevelData.DenialCode)) LIKE N'%' + d.Value + N'%'))
      AND (@DenialCodeExcludeBlank = 0 OR (DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''))
      AND (@HasPayerNames = 0 OR LTRIM(RTRIM(PayerName)) IN (SELECT Value FROM @PayerNameList))
      AND (@PayerExcludeBlank = 0 OR (PayerName IS NOT NULL AND LTRIM(RTRIM(PayerName)) <> ''))
      AND (@HasPanel = 0 OR LTRIM(RTRIM(PanelName)) IN (SELECT Value FROM @PanelList))
      AND (@PanelExcludeBlank = 0 OR (PanelName IS NOT NULL AND LTRIM(RTRIM(PanelName)) <> ''))
      AND (@HasAging = 0 OR CASE
                WHEN TRY_CAST(DaystoDOS AS INT) IS NULL THEN 'Current'
                WHEN TRY_CAST(DaystoDOS AS INT) < 30    THEN 'Current'
                WHEN TRY_CAST(DaystoDOS AS INT) < 60    THEN '30+'
                WHEN TRY_CAST(DaystoDOS AS INT) < 90    THEN '60+'
                WHEN TRY_CAST(DaystoDOS AS INT) < 120   THEN '90+'
                ELSE '120+'
            END IN (SELECT Value FROM @AgingList))
      AND (@FirstBillExcludeBlank = 0 OR (FirstBilledDate IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> ''))
      AND (
            (@FirstBillFrom IS NULL AND @FirstBillTo IS NULL AND @FirstBillNull = 0)
         OR (@FirstBillNull = 1 AND (@FirstBillFrom IS NULL AND @FirstBillTo IS NULL)
             AND (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = ''))
         OR (@FirstBillNull = 1 AND (@FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL)
             AND ((FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
               OR ((@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
               AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo))))
         OR (@FirstBillNull = 0 AND (
                (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
            AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)))
          )
      AND (@ChargeEnteredExcludeBlank = 0 OR (ChargeEnteredDate IS NOT NULL AND LTRIM(RTRIM(ChargeEnteredDate)) <> ''))
      AND (
            (@ChargeEnteredFrom IS NULL AND @ChargeEnteredTo IS NULL AND @ChargeEnteredNull = 0)
         OR (@ChargeEnteredNull = 1 AND (@ChargeEnteredFrom IS NULL AND @ChargeEnteredTo IS NULL)
             AND (ChargeEnteredDate IS NULL OR LTRIM(RTRIM(ChargeEnteredDate)) = ''))
         OR (@ChargeEnteredNull = 1 AND (@ChargeEnteredFrom IS NOT NULL OR @ChargeEnteredTo IS NOT NULL)
             AND ((ChargeEnteredDate IS NULL OR LTRIM(RTRIM(ChargeEnteredDate)) = '')
               OR ((@ChargeEnteredFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @ChargeEnteredFrom)
               AND (@ChargeEnteredTo   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ChargeEnteredTo))))
         OR (@ChargeEnteredNull = 0 AND (
                (@ChargeEnteredFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @ChargeEnteredFrom)
            AND (@ChargeEnteredTo   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ChargeEnteredTo)))
          )
      AND (
            (@DosFrom IS NULL AND @DosTo IS NULL AND @DosNull = 0)
         OR (@DosNull = 1 AND (@DosFrom IS NULL AND @DosTo IS NULL)
             AND (DateOfService IS NULL OR LTRIM(RTRIM(DateOfService)) = ''))
         OR (@DosNull = 1 AND (@DosFrom IS NOT NULL OR @DosTo IS NOT NULL)
             AND ((DateOfService IS NULL OR LTRIM(RTRIM(DateOfService)) = '')
               OR ((@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
               AND (@DosTo   IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo))))
         OR (@DosNull = 0 AND (
                (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
            AND (@DosTo   IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)))
          )
    ORDER BY ClaimID
    OFFSET ISNULL(@Offset, 0) ROWS
    FETCH NEXT ISNULL(@PageSize, 2147483647) ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelDetails
    @PayerName       NVARCHAR(500) = NULL,
    @PayerTypes      NVARCHAR(MAX) = NULL,
    @ClaimStatuses   NVARCHAR(MAX) = NULL,
    @PayStatuses     NVARCHAR(MAX) = NULL,
    @CPTCodes        NVARCHAR(MAX) = NULL,
    @ClinicNames     NVARCHAR(MAX) = NULL,
    @DenialCode      NVARCHAR(500) = NULL,
    @Offset          INT           = 0,
    @PageSize        INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerNameLike   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @DenialCodeLike  TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PayerTypeList   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @ClaimStatusList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PayStatusList   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @CptList         TABLE (Value NVARCHAR(100) NOT NULL);
    DECLARE @ClinicList      TABLE (Value NVARCHAR(500) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerName)), '') IS NOT NULL
        INSERT INTO @PayerNameLike SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerName, ',') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@DenialCode)), '') IS NOT NULL
        INSERT INTO @DenialCodeLike SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@DenialCode, ',') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PayerTypes)), '') IS NOT NULL
        INSERT INTO @PayerTypeList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerTypes, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@ClaimStatuses)), '') IS NOT NULL
        INSERT INTO @ClaimStatusList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@ClaimStatuses, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PayStatuses)), '') IS NOT NULL
        INSERT INTO @PayStatusList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayStatuses, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@CPTCodes)), '') IS NOT NULL
        INSERT INTO @CptList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 100)
        FROM STRING_SPLIT(@CPTCodes, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@ClinicNames)), '') IS NOT NULL
        INSERT INTO @ClinicList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@ClinicNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerNameLike BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerNameLike) THEN 1 ELSE 0 END;
    DECLARE @HasDenialLike    BIT = CASE WHEN EXISTS (SELECT 1 FROM @DenialCodeLike) THEN 1 ELSE 0 END;
    DECLARE @HasPayerType     BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerTypeList) THEN 1 ELSE 0 END;
    DECLARE @HasClaimStatus   BIT = CASE WHEN EXISTS (SELECT 1 FROM @ClaimStatusList) THEN 1 ELSE 0 END;
    DECLARE @HasPayStatus     BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayStatusList) THEN 1 ELSE 0 END;
    DECLARE @HasCpt           BIT = CASE WHEN EXISTS (SELECT 1 FROM @CptList) THEN 1 ELSE 0 END;
    DECLARE @HasClinic        BIT = CASE WHEN EXISTS (SELECT 1 FROM @ClinicList) THEN 1 ELSE 0 END;

    /* ==== InHealth LineLevel columns (Sql/Select_Script) — add/remove fields here ==== */
    SELECT
            [LabID],
            [LabName],
            CASE WHEN [ClaimID] LIKE '%.00' THEN LEFT([ClaimID], LEN([ClaimID])-3) ELSE ISNULL(LTRIM(RTRIM([ClaimID])),'') END AS [ClaimID],
            [AccessionNumber],
            [SourceFileID],
            [IngestedOn],
            [CsvRowHash],
            [PayerName_Raw],
            ISNULL(LTRIM(RTRIM([PayerName])),'') AS [PayerName],
            [Payer_Code],
            [Payer_Common_Code],
            [Payer_Group_Code],
            [Global_Payer_ID],
            ISNULL(LTRIM(RTRIM([PayerType])),'') AS [PayerType],
            [BillingProvider],
            [ReferringProvider],
            ISNULL(LTRIM(RTRIM([ClinicName])),'') AS [ClinicName],
            ISNULL(LTRIM(RTRIM([SalesRepname])),'') AS [SalesRepname],
            CASE WHEN [PatientID] LIKE '%.00' THEN LEFT([PatientID], LEN([PatientID])-3) ELSE ISNULL(LTRIM(RTRIM([PatientID])),'') END AS [PatientID],
            [PatientDOB],
            [DateofService],
            [ChargeEnteredDate],
            [FirstBilledDate],
            ISNULL(LTRIM(RTRIM([Panelname])),'') AS [Panelname],
            CASE WHEN [CPTCode] LIKE '%.00' THEN LEFT([CPTCode], LEN([CPTCode])-3) ELSE ISNULL(LTRIM(RTRIM([CPTCode])),'') END AS [CPTCode],
            ISNULL(FLOOR(TRY_CAST([Units] AS DECIMAL(18,2))), 0) AS [Units],
            CASE WHEN [Modifier] LIKE '%.00' THEN LEFT([Modifier], LEN([Modifier])-3) ELSE ISNULL(LTRIM(RTRIM([Modifier])),'') END AS [Modifier],
            [POS],
            [TOS],
            ISNULL(TRY_CAST([ChargeAmount] AS DECIMAL(18,2)), 0) AS [ChargeAmount],
            ISNULL(TRY_CAST([ChargeAmountPerUnit] AS DECIMAL(18,2)), 0) AS [ChargeAmountPerUnit],
            ISNULL(TRY_CAST([AllowedAmount] AS DECIMAL(18,2)), 0) AS [AllowedAmount],
            ISNULL(TRY_CAST([AllowedAmountPerUnit] AS DECIMAL(18,2)), 0) AS [AllowedAmountPerUnit],
            ISNULL(TRY_CAST([InsurancePayment] AS DECIMAL(18,2)), 0) AS [InsurancePayment],
            ISNULL(TRY_CAST([InsurancePaymentPerUnit] AS DECIMAL(18,2)), 0) AS [InsurancePaymentPerUnit],
            ISNULL(TRY_CAST([PatientPayment] AS DECIMAL(18,2)), 0) AS [PatientPayment],
            ISNULL(TRY_CAST([PatientPaymentPerUnit] AS DECIMAL(18,2)), 0) AS [PatientPaymentPerUnit],
            ISNULL(TRY_CAST([TotalPayments] AS DECIMAL(18,2)), 0) AS [TotalPayments],
            [InsuranceAdjustments],
            [PatientAdjustments],
            [TotalAdjustments],
            ISNULL(TRY_CAST([InsuranceBalance] AS DECIMAL(18,2)), 0) AS [InsuranceBalance],
            ISNULL(TRY_CAST([PatientBalance] AS DECIMAL(18,2)), 0) AS [PatientBalance],
            ISNULL(TRY_CAST([PatientBalancePerUnit] AS DECIMAL(18,2)), 0) AS [PatientBalancePerUnit],
            ISNULL(TRY_CAST([TotalBalance] AS DECIMAL(18,2)), 0) AS [TotalBalance],
            [CheckDate],
            [PostingDate],
            ISNULL(LTRIM(RTRIM([ClaimStatus])),'') AS [ClaimStatus],
            ISNULL(LTRIM(RTRIM([PayStatus])),'') AS [PayStatus],
            [DenialCode],
            [DenialDate],
            [ICDCode],
            [DaystoDOS],
            [RollingDays],
            [DaystoBill],
            [DaystoPost],
            [ICDPointer],
            [InsertedDateTime],
            [PatientName],
            [PaymentPostedDate],
            [ResponsibleParty],
            [SubscriberID],
            [EndDOS],
            [BillOccurance],
            [EntryUser],
            [CPTUnits],
            [CPTMOD],
            [CPTs],
            [PostedWeek],
            [CPTXUnitsxMod],
            [PaymentPercent],
            [Facility],
            [ClientAccNum],
            [LineLevelUID],
            [Source],
            ISNULL(TRY_CAST([InsuranceBalance_Decimal] AS DECIMAL(18,2)), 0) AS [InsuranceBalance_Decimal]
    FROM dbo.LineLevelData
    WHERE (@HasPayerNameLike = 0 OR EXISTS (SELECT 1 FROM @PayerNameLike p WHERE LTRIM(RTRIM(LineLevelData.PayerName)) LIKE N'%' + p.Value + N'%'))
      AND (@HasPayerType = 0 OR LTRIM(RTRIM(PayerType)) IN (SELECT Value FROM @PayerTypeList))
      AND (@HasClaimStatus = 0 OR LTRIM(RTRIM(ClaimStatus)) IN (SELECT Value FROM @ClaimStatusList))
      AND (@HasPayStatus = 0 OR LTRIM(RTRIM(PayStatus)) IN (SELECT Value FROM @PayStatusList))
      AND (@HasCpt = 0 OR LTRIM(RTRIM(CPTCode)) IN (SELECT Value FROM @CptList))
      AND (@HasClinic = 0 OR LTRIM(RTRIM(ClinicName)) IN (SELECT Value FROM @ClinicList))
      AND (@HasDenialLike = 0 OR EXISTS (SELECT 1 FROM @DenialCodeLike d WHERE LTRIM(RTRIM(LineLevelData.DenialCode)) LIKE N'%' + d.Value + N'%'))
    ORDER BY ClaimID, CPTCode
    OFFSET ISNULL(@Offset, 0) ROWS
    FETCH NEXT ISNULL(@PageSize, 2147483647) ROWS ONLY;
END
GO
