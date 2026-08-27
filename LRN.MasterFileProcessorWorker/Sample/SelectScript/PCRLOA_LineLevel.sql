USE [PCRLOA_LRN]
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelDataWithAdditionalFields
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @JsonColumns NVARCHAR(MAX);
    DECLARE @SQL NVARCHAR(MAX);

    /* ============================================================
       STEP 1
       Get all unique JSON property names from AdditionalFields.

       Exclude JSON properties that already exist as physical
       columns in dbo.LineLevelData.

       COLLATE DATABASE_DEFAULT fixes:
       Latin1_General_BIN2 vs SQL_Latin1_General_CP1_CI_AS
       ============================================================ */

    SELECT @JsonColumns =
        STRING_AGG(QUOTENAME(FieldName), ',')
    FROM
    (
        SELECT DISTINCT
            J.[key] COLLATE DATABASE_DEFAULT AS FieldName
        FROM dbo.LineLevelData T
        CROSS APPLY OPENJSON(T.AdditionalFields) J
        WHERE ISJSON(T.AdditionalFields) = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM sys.columns C
              WHERE C.object_id = OBJECT_ID('dbo.LineLevelData')
                AND C.name COLLATE DATABASE_DEFAULT =
                    J.[key] COLLATE DATABASE_DEFAULT
          )
    ) AS Fields;


    /* ============================================================
       STEP 2
       No JSON fields found
       ============================================================ */

    IF @JsonColumns IS NULL OR @JsonColumns = ''
    BEGIN

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
            ,T.[CPTCode]
            ,T.[Units]
            ,T.[Modifier]
            ,T.[POS]
            ,T.[TOS]
            ,T.[ChargeAmount]
            ,T.[ChargeAmountPerUnit]
            ,T.[AllowedAmount]
            ,T.[AllowedAmountPerUnit]
            ,T.[InsurancePayment]
            ,T.[InsurancePaymentPerUnit]
            ,T.[PatientPayment]
            ,T.[PatientPaymentPerUnit]
            ,T.[TotalPayments]
            ,T.[InsuranceAdjustments]
            ,T.[PatientAdjustments]
            ,T.[TotalAdjustments]
            ,T.[InsuranceBalance]
            ,T.[PatientBalance]
            ,T.[PatientBalancePerUnit]
            ,T.[TotalBalance]
            ,T.[CheckDate]
            ,T.[PostingDate]
            ,T.[ClaimStatus]
            ,T.[PayStatus]
            ,T.[DenialCode]
            ,T.[DenialDate]
            ,T.[ICDCode]
            ,T.[DaystoDOS]
            ,T.[RollingDays]
            ,T.[DaystoBill]
            ,T.[DaystoPost]
            ,T.[ICDPointer]
            ,T.[InsertedDateTime]
            ,T.[PaymentPostedDate]
            ,T.[PatientName]
            ,T.[ResponsibleParty]
            ,T.[SubscriberId]
            ,T.[ClientAccNum]
            ,T.[EndDOS]
            ,T.[BillOccurance]
            ,T.[EntryUser]
            ,T.[CPTUnits]
            ,T.[CPTMOD]
            ,T.[CPTs]
            ,T.[PostedWeek]
            ,T.[LineLevelUID]
            ,T.[Source]
            ,T.[InsuranceBalance_Decimal]

        FROM dbo.LineLevelData T
        ORDER BY T.RecordId;

        RETURN;
    END;


    /* ============================================================
       STEP 3
       Dynamic JSON Pivot
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
        ,T.[CPTCode]
        ,T.[Units]
        ,T.[Modifier]
        ,T.[POS]
        ,T.[TOS]
        ,T.[ChargeAmount]
        ,T.[ChargeAmountPerUnit]
        ,T.[AllowedAmount]
        ,T.[AllowedAmountPerUnit]
        ,T.[InsurancePayment]
        ,T.[InsurancePaymentPerUnit]
        ,T.[PatientPayment]
        ,T.[PatientPaymentPerUnit]
        ,T.[TotalPayments]
        ,T.[InsuranceAdjustments]
        ,T.[PatientAdjustments]
        ,T.[TotalAdjustments]
        ,T.[InsuranceBalance]
        ,T.[PatientBalance]
        ,T.[PatientBalancePerUnit]
        ,T.[TotalBalance]
        ,T.[CheckDate]
        ,T.[PostingDate]
        ,T.[ClaimStatus]
        ,T.[PayStatus]
        ,T.[DenialCode]
        ,T.[DenialDate]
        ,T.[ICDCode]
        ,T.[DaystoDOS]
        ,T.[RollingDays]
        ,T.[DaystoBill]
        ,T.[DaystoPost]
        ,T.[ICDPointer]
        ,T.[InsertedDateTime]
        ,T.[PaymentPostedDate]
        ,T.[PatientName]
        ,T.[ResponsibleParty]
        ,T.[SubscriberId]
        ,T.[ClientAccNum]
        ,T.[EndDOS]
        ,T.[BillOccurance]
        ,T.[EntryUser]
        ,T.[CPTUnits]
        ,T.[CPTMOD]
        ,T.[CPTs]
        ,T.[PostedWeek]
        ,T.[LineLevelUID]
        ,T.[Source]
        ,T.[InsuranceBalance_Decimal]

        ,' + @JsonColumns + '

    FROM dbo.LineLevelData T

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

            FROM dbo.LineLevelData T
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
       Execute
       ============================================================ */

    EXEC sys.sp_executesql @SQL;

END
GO