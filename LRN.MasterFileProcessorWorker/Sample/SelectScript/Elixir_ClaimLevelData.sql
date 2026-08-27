CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelData
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DynamicColumns NVARCHAR(MAX);
    DECLARE @SQL NVARCHAR(MAX);

    /* Get every unique JSON property from AdditionalFields */
    SELECT @DynamicColumns =
        STRING_AGG(
            'MAX(CASE WHEN J.[key] = N''' +
            REPLACE([key], '''', '''''') +
            ''' THEN J.[value] END) AS ' +
            QUOTENAME([key]),
            ','
        )
    FROM
    (
        SELECT DISTINCT J.[key]
        FROM dbo.ClaimLevelData T
        CROSS APPLY OPENJSON(T.AdditionalFields) J
        WHERE ISJSON(T.AdditionalFields) = 1
    ) X;


    /* If no AdditionalFields exist */
    IF @DynamicColumns IS NULL
    BEGIN
        SELECT *
        FROM dbo.ClaimLevelData;

        RETURN;
    END;


    SET @SQL = N'
        SELECT
            T.*,
            ' + @DynamicColumns + '
        FROM dbo.ClaimLevelData T
        OUTER APPLY
        (
            SELECT
                J.[key],
                J.[value]
            FROM OPENJSON(T.AdditionalFields) J
        ) J
        GROUP BY
            T.RecordId,
            T.FileLogId,
            T.RunId,
            T.WeekFolder,
            T.SourceFullPath,
            T.FileName,
            T.FileType,
            T.RowHash,
            T.LabID,
            T.LabName,
            T.ClaimID,
            T.AccessionNumber,
            T.SourceFileID,
            T.IngestedOn,
            T.CsvRowHash,
            T.PayerName_Raw,
            T.PayerName,
            T.Payer_Code,
            T.Payer_Common_Code,
            T.Payer_Group_Code,
            T.Global_Payer_ID,
            T.PayerType,
            T.BillingProvider,
            T.ReferringProvider,
            T.ClinicName,
            T.SalesRepname,
            T.PatientID,
            T.PatientDOB,
            T.DateofService,
            T.ChargeEnteredDate,
            T.FirstBilledDate,
            T.Panelname,
            T.CPTCodeXUnitsXModifier,
            T.POS,
            T.TOS,
            T.ChargeAmount,
            T.AllowedAmount,
            T.InsurancePayment,
            T.PatientPayment,
            T.TotalPayments,
            T.InsuranceAdjustments,
            T.PatientAdjustments,
            T.TotalAdjustments,
            T.InsuranceBalance,
            T.PatientBalance,
            T.TotalBalance,
            T.CheckDate,
            T.ClaimStatus,
            T.DenialCode,
            T.ICDCode,
            T.DaystoDOS,
            T.RollingDays,
            T.DaystoBill,
            T.DaystoPost,
            T.ICDPointer,
            T.InsertedDateTime,
            T.CPTCodeXUnitsXModifierOrginal,
            T.T_F,
            T.PatientFirstName,
            T.PatientLastName,
            T.PatientAddress,
            T.Coverage,
            T.AgingDOS,
            T.ServiceToDate,
            T.AgingDOE,
            T.Facility,
            T.ServiceLocationCode,
            T.ServiceLocationName,
            T.PrimarySubId,
            T.ICDField,
            T.DODWeek,
            T.BilledWeek,
            T.DenialReason,
            T.BillingOption,
            T.CurrentStatus,
            T.BatchNo,
            T.CreatedOn,
            T.CreatedBy,
            T.UpdatedOn,
            T.UpdatedBy,
            T.BillStatus,
            T.PaymentPercent,
            T.FullyPaidCount,
            T.FullyPaidAmount,
            T.AdjucticatedCount,
            T.AdjucticatedAmount,
            T.Bucket30Count,
            T.Bucket30Amount,
            T.Bucket60Count,
            T.Bucket60Amount,
            T.ClaimUID,
            T.PanelNameLIS,
            T.PanelNameBasedOnCPT,
            T.InsuranceBalance_Decimal,
			T.AdditionalFields
        ORDER BY T.RecordId;
    ';

    EXEC sys.sp_executesql @SQL;
END;
GO