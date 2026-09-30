/* =====================================================================
   VariantX — Claim Level: Excel column -> dbo.ClaimLevelData column

   Reference only: this script changes nothing. Each line reads
       [SQL column]  AS [Excel header it is loaded from]

   HOW A VALUE GETS FROM THE EXCEL FILE TO THE TABLE (LRN.MasterFileProcessorWorker)
     Excel "Claim Level" sheet
        |  step 1  Excel -> standard CSV
        |          Schemas/ClaimLevel.schema.json        SHARED by every lab - avoid editing.
        |              Builds the standard columns (ClaimID, PatientID, InsurancePayment, ...)
        |              from its Aliases list.
        |          Schemas/VariantX_ClaimLevel.schema.json   VariantX only.
        |              Validates the Excel headers, and can steer step 1 for VariantX:
        |                "Aliases": [ "InsurancePayment" ]  -> this header feeds that standard column
        |                "KeepRaw": true                    -> also keep this header as its own CSV column
        |          Any Excel header no standard column uses is kept in the CSV under its own name.
        v
     standard CSV
        |  step 2  CSV -> SQL
        |          Schemas/LabMappings/VariantXFieldMappings.Json   VariantX only.  <== usual place to edit
        |              "CsvHeader": the CSV column name  ->  "SqlColumn": the table column
        |              Matching ignores case, spaces and punctuation.
        |          A CSV column with no Field here is stored in [AdditionalFields] (JSON).
        v
     dbo.ClaimLevelData

   A value showing up in [AdditionalFields] means its CSV column name matches no CsvHeader:
   copy the key exactly as it appears in AdditionalFields into that field's "CsvHeader".
   ===================================================================== */
USE [VariantX_LRN]
GO

SELECT
       [ClaimID]                      AS [Visit No]
      ,[AccessionNumber]              AS [Accession No]
      ,[PanelName]                    AS [Panel type]                        -- lab alias -> standard Panelname
      ,[PlanType]                     AS [Plan Type]
      ,[PatientID]                    AS [Patient Ac No]
      ,[PatientFirstName]             AS [Patient First Name]
      ,[PatientLastName]              AS [Patient Last Name]
      ,[PatientDOB]                   AS [DOB]
      ,[DateofService]                AS [Service From Date]
      ,[AgingDOS]                     AS [Aging DOS]
      ,[EndDOS]                       AS [Service To Date]
      ,[ChargeEnteredDate]            AS [Created On]                        -- lab alias -> standard ChargeEnteredDate
      ,[AgingDOE]                     AS [Aging DOE]
      ,[Facility]                     AS [Facility]
      ,[ReferringProviderFirstName]   AS [Ordering Physician First Name]     -- KeepRaw
      ,[ReferringProviderLastName]    AS [Ordering Physician LastName]       -- KeepRaw
      ,[RendPhyFirstName]             AS [Rendering Physician FirstName]     -- KeepRaw
      ,[RendPhyLastName]              AS [Rendering Physician LastName]      -- KeepRaw
      ,[ReferringProvider]            AS [Ordering Physician LastName, First Name]    -- lab composite "Last, First"
      ,[BillingProvider]              AS [Rendering Physician LastName, FirstName]    -- lab composite "Last, First"
      ,[ServLocCode]                  AS [Service Location Code]
      ,[ServLocation]                 AS [Service Location Name]
      ,[PayerName_Raw]                AS [Primary Payer]
      ,[SubscriberId]                 AS [Primary Sub ID]
      ,[FirstBilledDate]              AS [Billed Date]
      ,[BilledWeek]                   AS [Billed Week]
      ,[ClaimLevelCPT]                AS [CPT]                               -- via CSV "CPT Code X Units X Modifier Orginal"
      ,[CheckDate]                    AS [Deposit Date]
      ,[DODWeek]                      AS [Deposit Week]
      ,[DenialDate]                   AS [Denial Date]
      ,[DeniedWeek]                   AS [Denied Week]
      ,[DenialCode]                   AS [Claim Level Denial Code]           -- or "Denial Code" when that one is blank
      ,[LineLevelDenialCode]          AS [Line Level Denial Code]
      ,[ClaimLevelDenialCode]         AS [Claim Level Denial Code]
      ,[LineLevelICD]                 AS [Line Level ICD]
      ,[ClaimLevelICD]                AS [Claim Level ICD]                   -- via CSV "ICDCode"
      ,[POS]                          AS [POS]
      ,[TOS]                          AS [TOS]
      ,[Modifier]                     AS [Modifiers]
      ,[ChargeAmount]                 AS [Total Charges]
      ,[InsurancePayment]             AS [Insurance Paid]                    -- lab alias -> standard InsurancePayment
      ,[PatientPayment]               AS [Patient Paid]                      -- lab alias -> standard PatientPayment
      ,[TotalWO]                      AS [Total WO]
      ,[InsuranceAdjustments]         AS [Carrier WO]
      ,[InsuranceBalance]             AS [Insurance Balance]
      ,[PatientBalance]               AS [Patient Balance]
      ,[AllowedAmount]                AS [Total Allowed]
      ,[PatientAdjustments]           AS [Patient WO]
      ,[BillingOption]                AS [Billing Option]
      ,[CurrentStatus]                AS [Current Status]
      ,[BatchNo]                      AS [Batch No]
      ,[CreatedBy]                    AS [Created By]
      ,[UpdatedOn]                    AS [Updated On]
      ,[UpdatedBy]                    AS [Updated By]
      ,[PaymentPercent]               AS [Payment %]
      ,[BillStatus]                   AS [Bill Status]
      ,[FullyPaidCount]               AS [Fully Paid #]
      ,[FullyPaidAmount]              AS [Fully Paid $]
      ,[AdjucticatedCount]            AS [Adjucticated #]
      ,[AdjucticatedAmount]           AS [Adjucticated $]
      ,[Bucket30Count]                AS [30 Bucket #]
      ,[Bucket30Amount]               AS [30 Bucket $]
      ,[Bucket60Count]                AS [60 Bucket #]
      ,[Bucket60Amount]               AS [60 Bucket $]
      ,[ClaimStatus]                  AS [Claim Status]

       -- Calculated by the worker, not read from the file
      ,[TotalPayments]                AS [= InsurancePayment + PatientPayment]
      ,[TotalBalance]                 AS [= InsuranceBalance + PatientBalance]
      ,[CPTCodeXUnitsXModifier]       AS [= built from CPT]
      ,[PayerName]                    AS [= insurance master (normalized payer)]
      ,[Payer_Code]                   AS [= insurance master: payer code]
      ,[Payer_Common_Code]            AS [= insurance master: common code]
      ,[Payer_Group_Code]             AS [= insurance master: group code]
      ,[Global_Payer_ID]              AS [= insurance master: global id]
      ,[DaystoDOS]                    AS [= days since DateofService]
      ,[RollingDays]                  AS [= rolling days]
      ,[DaystoBill]                   AS [= FirstBilledDate - DateofService]
      ,[DaystoPost]                   AS [= CheckDate - FirstBilledDate]
      ,[DenialCodeNormalized]         AS [= normalized DenialCode]
      ,[DenialDescription]            AS [= denial code master]

       -- Expected to stay in AdditionalFields (no column of their own in this table):
       -- "Total Paid" (TotalPayments is recalculated), TotalAdjustments, ClaimUID
      ,[AdditionalFields]
  FROM [dbo].[ClaimLevelData]

GO
