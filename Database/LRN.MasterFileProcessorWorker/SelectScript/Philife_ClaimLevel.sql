USE [PhiLife_LRN]
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelDataWithAdditionalFields
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @JsonColumns NVARCHAR(MAX);
    DECLARE @SQL NVARCHAR(MAX);

    /* ============================================================
       STEP 1
       Get all unique JSON property names from AdditionalFields.

       Exclude JSON properties that already exist as physical
       columns in dbo.ClaimLevelData.

       COLLATE fixes OPENJSON BIN2 collation conflicts.
       ============================================================ */

    SELECT @JsonColumns =
        STRING_AGG(QUOTENAME(FieldName), ',')
    FROM
    (
        SELECT DISTINCT
            J.[key] COLLATE DATABASE_DEFAULT AS FieldName
        FROM dbo.ClaimLevelData T
        CROSS APPLY OPENJSON(T.AdditionalFields) J
        WHERE ISJSON(T.AdditionalFields) = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM sys.columns C
              WHERE C.object_id = OBJECT_ID('dbo.ClaimLevelData')
                AND C.name COLLATE DATABASE_DEFAULT =
                    J.[key] COLLATE DATABASE_DEFAULT
          )
    ) AS Fields;


    /* ============================================================
       STEP 2
       If there are no JSON fields, return normal columns.
       AdditionalFields is excluded.
       ============================================================ */

    IF @JsonColumns IS NULL OR @JsonColumns = ''
    BEGIN

        SELECT
          top 200   T.[RecordId]
            ,T.[FileLogId]
            ,T.[RunId]
            ,T.[WeekFolder]
            ,T.[SourceFullPath]
            ,T.[FileName]
            ,T.[FileType]
            ,T.[RowHash]
            ,T.[LabID]
            ,T.[LabName]
            ,T.[ClaimID]
            ,T.[AccessionNumber]
            ,T.[SourceFileID]
            ,T.[IngestedOn]
            ,T.[CsvRowHash]
            ,T.[PayerName_Raw]
            ,T.[PayerName]
            ,T.[Payer_Code]
            ,T.[Payer_Common_Code]
            ,T.[Payer_Group_Code]
            ,T.[Global_Payer_ID]
            ,T.[PayerType]
            ,T.[BillingProvider]
            ,T.[ReferringProvider]
            ,T.[ClinicName]
            ,T.[SalesRepname]
            ,T.[PatientID]
            ,T.[PatientDOB]
            ,T.[DateofService]
            ,T.[ChargeEnteredDate]
            ,T.[FirstBilledDate]
            ,T.[Panelname]
            ,T.[CPTCodeXUnitsXModifier]
            ,T.[POS]
            ,T.[TOS]
            ,T.[ChargeAmount]
            ,T.[AllowedAmount]
            ,T.[InsurancePayment]
            ,T.[PatientPayment]
            ,T.[TotalPayments]
            ,T.[InsuranceAdjustments]
            ,T.[PatientAdjustments]
            ,T.[TotalAdjustments]
            ,T.[InsuranceBalance]
            ,T.[PatientBalance]
            ,T.[TotalBalance]
            ,T.[CheckDate]
            ,T.[ClaimStatus]
            ,T.[DenialCode]
            ,T.[ICDCode]
            ,T.[DaystoDOS]
            ,T.[RollingDays]
            ,T.[DaystoBill]
            ,T.[DaystoPost]
            ,T.[ICDPointer]
            ,T.[InsertedDateTime]
            ,T.[CPTCodeXUnitsXModifierOrginal]
            ,T.[BilledUnbilled]
            ,T.[Modifier]
            ,T.[AgingBucket]
            ,T.[AdjudicatedCount]
            ,T.[Days30Count]
            ,T.[Days30Amount]
            ,T.[Days60Count]
            ,T.[Days60Amount]
            ,T.[DOE_Year]
            ,T.[DOE_Month]
            ,T.[PatientName]
            ,T.[PaymentPercent]
            ,T.[Aging]
            ,T.[BilledWeek]
            ,T.[PostedWeek]
            ,T.[FullyPaidCount]
            ,T.[FullyPaidAmount]
            ,T.[AdjudicatedAmount]
            ,T.[CPTCode]
            ,T.[Units]
            ,T.[Adjudicated]
            ,T.[ClaimUID]
            ,T.[AgingDOE]
            ,T.[AgingDOS]
            ,T.[PanelNameLIS]
            ,T.[PanelNameBasedOnCPT]
            ,T.[InsuranceBalance_Decimal]

        FROM dbo.ClaimLevelData T
        ORDER BY T.RecordId;

        RETURN;
    END;


    /* ============================================================
       STEP 3
       Build dynamic SQL
       ============================================================ */

    SET @SQL = N'

    SELECT
         T.[RecordId]
        ,T.[FileLogId]
        ,T.[RunId]
        ,T.[WeekFolder]
        ,T.[SourceFullPath]
        ,T.[FileName]
        ,T.[FileType]
        ,T.[RowHash]
        ,T.[LabID]
        ,T.[LabName]
        ,T.[ClaimID]
        ,T.[AccessionNumber]
        ,T.[SourceFileID]
        ,T.[IngestedOn]
        ,T.[CsvRowHash]
        ,T.[PayerName_Raw]
        ,T.[PayerName]
        ,T.[Payer_Code]
        ,T.[Payer_Common_Code]
        ,T.[Payer_Group_Code]
        ,T.[Global_Payer_ID]
        ,T.[PayerType]
        ,T.[BillingProvider]
        ,T.[ReferringProvider]
        ,T.[ClinicName]
        ,T.[SalesRepname]
        ,T.[PatientID]
        ,T.[PatientDOB]
        ,T.[DateofService]
        ,T.[ChargeEnteredDate]
        ,T.[FirstBilledDate]
        ,T.[Panelname]
        ,T.[CPTCodeXUnitsXModifier]
        ,T.[POS]
        ,T.[TOS]
        ,T.[ChargeAmount]
        ,T.[AllowedAmount]
        ,T.[InsurancePayment]
        ,T.[PatientPayment]
        ,T.[TotalPayments]
        ,T.[InsuranceAdjustments]
        ,T.[PatientAdjustments]
        ,T.[TotalAdjustments]
        ,T.[InsuranceBalance]
        ,T.[PatientBalance]
        ,T.[TotalBalance]
        ,T.[CheckDate]
        ,T.[ClaimStatus]
        ,T.[DenialCode]
        ,T.[ICDCode]
        ,T.[DaystoDOS]
        ,T.[RollingDays]
        ,T.[DaystoBill]
        ,T.[DaystoPost]
        ,T.[ICDPointer]
        ,T.[InsertedDateTime]
        ,T.[CPTCodeXUnitsXModifierOrginal]
        ,T.[BilledUnbilled]
        ,T.[Modifier]
        ,T.[AgingBucket]
        ,T.[AdjudicatedCount]
        ,T.[Days30Count]
        ,T.[Days30Amount]
        ,T.[Days60Count]
        ,T.[Days60Amount]
        ,T.[DOE_Year]
        ,T.[DOE_Month]
        ,T.[PatientName]
        ,T.[PaymentPercent]
        ,T.[Aging]
        ,T.[BilledWeek]
        ,T.[PostedWeek]
        ,T.[FullyPaidCount]
        ,T.[FullyPaidAmount]
        ,T.[AdjudicatedAmount]
        ,T.[CPTCode]
        ,T.[Units]
        ,T.[Adjudicated]
        ,T.[ClaimUID]
        ,T.[AgingDOE]
        ,T.[AgingDOS]
        ,T.[PanelNameLIS]
        ,T.[PanelNameBasedOnCPT]
        ,T.[InsuranceBalance_Decimal]

        ,' + @JsonColumns + '

    FROM dbo.ClaimLevelData T

    LEFT JOIN
    (
        SELECT
             RecordId
            ,' + @JsonColumns + '

        FROM
        (
            SELECT
                 T.RecordId
                ,J.[key] COLLATE DATABASE_DEFAULT AS FieldName
                ,J.[value] AS FieldValue

            FROM dbo.ClaimLevelData T
            CROSS APPLY OPENJSON(T.AdditionalFields) J

            WHERE ISJSON(T.AdditionalFields) = 1
        ) AS SourceData

        PIVOT
        (
            MAX(FieldValue)
            FOR FieldName IN (' + @JsonColumns + ')
        ) AS PivotData

    ) AS P
        ON P.RecordId = T.RecordId

    ORDER BY T.RecordId;
    ';


    /* ============================================================
       STEP 4
       Execute dynamic SQL
       ============================================================ */

    EXEC sys.sp_executesql @SQL;

END
GO