USE [NWL_LRN]
GO

SELECT [RecordId]
      ,[FileLogId]
      ,[RunId]
      ,[WeekFolder]
      ,[SourceFullPath]
      ,[FileName]
      ,[FileType]
      ,[RowHash]
      ,[LabID]
      ,[LabName]
      ,[ClaimID]
      ,[AccessionNumber]
      ,[SourceFileID]
      ,[IngestedOn]
      ,[CsvRowHash]
      ,[PayerName_Raw]
      ,[PayerName]
      ,[Payer_Code]
      ,[Payer_Common_Code]
      ,[Payer_Group_Code]
      ,[Global_Payer_ID]
      ,[PayerType]
      ,[BillingProvider]
      ,[ReferringProvider]
      ,[ClinicName]
      ,[SalesRepname]
      ,[PatientID]
      ,[PatientDOB]
      ,[DateofService]
      ,[ChargeEnteredDate]
      ,[FirstBilledDate]
      ,[Panelname]
      ,[CPTCodeXUnitsXModifier]
      ,[POS]
      ,[TOS]
      ,[ChargeAmount]
      ,[AllowedAmount]
      ,[InsurancePayment]
      ,[PatientPayment]
      ,[TotalPayments]
      ,[InsuranceAdjustments]
      ,[PatientAdjustments]
      ,[TotalAdjustments]
      ,[InsuranceBalance]
      ,[PatientBalance]
      ,[TotalBalance]
      ,[CheckDate]
      ,[ClaimStatus]
      ,[DenialCode]
      ,[ICDCode]
      ,[DaystoDOS]
      ,[RollingDays]
      ,[DaystoBill]
      ,[DaystoPost]
      ,[ICDPointer]
      ,[InsertedDateTime]
      ,[InsuranceBalance_Decimal]
      ,[UID]
      ,[Aging]
      ,[PatientName]
      ,[LISPatientName]
      ,[SubscriberId]
      ,[PanelType]
      ,[EnteredWeek]
      ,[EnteredStatus]
      ,[LastActivityDate]
      ,[EmedixSubmissionDate]
      ,[ClaimType]
      ,[BilledStatus]
      ,[BilledWeek]
      ,[PostedWeek]
      ,[ModField] Mod
      ,[CheqNo]
      ,[DuplicatePaymentPosted]
      ,[ActualPayment]
      ,[ProcTotalBal] [Proc-TotalBal$]
      ,[DeniedStatus]
      ,[ScrubberEditReason]
      ,[EmedixRejectionDate]
      ,[EmedixRejection]
      ,[RejectionCategory]
      ,[TimeToPay]
      ,[PaymentPercent] [Payment%]
      ,[FullyPaidCount] [FullyPaid#]
      ,[FullyPaidAmount] [FullyPaid$]
      ,[Adjudicated]
      ,[AdjudicatedAmount] [Adjudicated$]
      ,[Bucket30] [30Bucket]
      ,[Bucket30Amount] [30Bucket$]
      ,[Bucket60]  [60Bucket]
      ,[Bucket60Amount] [60Bucket$]
      ,[ClaimUID]
      ,[AgingDOE]
      ,[AgingDOS]
      ,[PanelNameLIS]
      ,[PanelNameBasedOnCPT]
      ,[CPTCodeXUnitsXModifierOrginal]
      ,dbo.GetAdditionalField(AdditionalFields, 'Source') AS Source
  FROM [dbo].[ClaimLevelData]

GO




--ClaimID
--AccessionNumber
--SourceFileID
--IngestedOn
--RowHash
--PayerName_Raw
--PayerName
--Payer_Code
--Payer_Common_Code
--Payer_Group_Code
--Global_Payer_ID
--PayerType
--BillingProvider
--ReferringProvider
--ClinicName
----SalesRepname
----PatientID
----PatientDOB
----DateofService
----ChargeEnteredDate
----FirstBilledDate
--POS
--TOS
--ChargeAmount
--AllowedAmount
--InsurancePayment
--PatientPayment
--TotalPayments
--InsuranceAdjustments
--PatientAdjustments
--TotalAdjustments
--InsuranceBalance
--PatientBalance
--TotalBalance
--CheckDate
--ClaimStatus
--DenialCode
--ICDCode
--DaystoDOS
--RollingDays
--DaystoBill
--DaystoPost
--ICDPointer
