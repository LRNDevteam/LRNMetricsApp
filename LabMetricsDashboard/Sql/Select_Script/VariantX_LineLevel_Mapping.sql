/* =====================================================================
   VariantX — Line Level: Excel column -> dbo.LineLevelData column

   Reference only: this script changes nothing. Each line reads
       [SQL column]  AS [Excel header it is loaded from]

   Same two steps and the same "where to edit" guide as VariantX_ClaimLevel_Mapping.sql:
     step 1  Excel -> CSV : Schemas/LineLevel.schema.json (SHARED, avoid editing)
                            + Schemas/VariantX_LineLevel.schema.json (VariantX: Aliases / KeepRaw)
     step 2  CSV -> SQL   : Schemas/LabMappings/VariantXFieldMappings.Json, "LineLevel" block
                            <== usual place to edit; unmatched CSV columns go to [AdditionalFields]
   ===================================================================== */
USE [VariantX_LRN]
GO

SELECT
       [ClaimID]                      AS [Visit No]
      ,[T_F]                          AS [T/F]
      ,[UID]                          AS [UID]
      ,[AccessionNumber]              AS [Accession No]
      ,[Panelname]                    AS [Panel type]                        -- lab alias -> standard Panelname
      ,[PlanType]                     AS [Plan Type]
      ,[PatientID]                    AS [Patient Ac No]
      ,[PatientFirstName]             AS [Patient First Name]
      ,[PatientLastName]              AS [Patient Last Name]
      ,[PatientDOB]                   AS [DOB]
      ,[DateofService]                AS [Service From Date]
      ,[AgingDOS]                     AS [Aging DOS]
      ,[EndDOS]                       AS [Service To Date]
      ,[CreatedOn]                    AS [Created On]                        -- KeepRaw
      ,[ChargeEnteredDate]            AS [Created On]                   -- same header, lab alias -> standard ChargeEnteredDate
      ,[AgingDOE]                     AS [Aging DOE]
      ,[Facility]                     AS [Facility]
      ,[ReferringProviderFirstName]   AS [Ordering Physician First Name]     -- KeepRaw
      ,[ReferringProviderLastName]    AS [Ordering Physician Last Name]      -- KeepRaw. The file currently mislabels this column as a
                                                                             -- 2nd "Ordering Physician First Name"; the worker reads it as
                                                                             -- "Ordering Physician First Name (2)", aliased here in the lab schema
      ,[RendPhyFirstName]             AS [RenderingPhysician First Name]     -- KeepRaw
      ,[RendPhyLastName]              AS [Rendering Physician Last Name]     -- KeepRaw
      ,[ReferringProvider]            AS [Ordering Physician Last Name, First Name]   -- lab composite "Last, First"
      ,[BillingProvider]              AS [Rendering Physician Last Name, First Name]  -- lab composite "Last, First"
      ,[ServLocCode]                  AS [Service Location Code]
      ,[ServLocation]                 AS [Service Location Name]
      ,[PayerName_Raw]                AS [Primary Payer]
      ,[SubscriberId]                 AS [Primary Sub ID]
      ,[FirstBilledDate]              AS [Billed Date]
      ,[BilledWeek]                   AS [Billed Week]
      ,[CPTCode]                      AS [CPT]
      ,[CPTStatus]                    AS [CPT STATUS]
      ,[Units]                        AS [Units]
      ,[CPTXMODXUnits]                AS [CPT X MOD X UNITS]
      ,[CheckDate]                    AS [Deposit Date]
      ,[DODWeek]                      AS [Deposit Week]
      ,[DenialDate]                   AS [Denial Date]
      ,[DeniedWeek]                   AS [Denied Week]
      ,[DenialCode]                   AS [Claim Level Denial Code]           -- or "Denial Code" when that one is blank
      ,[LineLevelDenialCode]          AS [Line Level Denial Code]
      ,[ICDCode]                      AS [Claim Level ICD / Line Level ICD]  -- first non-blank of the two
      ,[ClaimLevelICDCode]            AS [Claim Level ICD]
      ,[POS]                          AS [POS]
      ,[TOS]                          AS [TOS]
      ,[Modifier]                     AS [Modifiers]
      ,[ChargeAmount]                 AS [Total Charges]
      ,[InsurancePayment]             AS [Insurance Paid]                    -- lab alias -> standard InsurancePayment
      ,[PatientPayment]               AS [Patient Paid]                      -- lab alias -> standard PatientPayment
      ,[InsuranceAdjustments]         AS [Carrier WO]
      ,[InsuranceBalance]             AS [Insurance Balance]
      ,[PatientBalance]               AS [Patient Balance]
      ,[AllowedAmount]                AS [Total Allowed]
      ,[PatientAdjustments]           AS [Patient WO]
      ,[BillingOption]                AS [Billing Option]
      ,[BillStatus]                   AS [Bill Status]
      ,[ClaimStatus]                  AS [Current Status]                    -- standard ClaimStatus alias
      ,[CurrentStatus]                AS [Current Status]               -- same header, KeepRaw
      ,[CreatedBy]                    AS [Created By]
      ,[UpdatedOn]                    AS [Updated On]
      ,[UpdatedBy]                    AS [Updated By]
      ,[PaymentPercent]               AS [Payment %]

       -- Calculated by the worker, not read from the file
      ,[ChargeAmountPerUnit]          AS [= ChargeAmount / Units]
      ,[AllowedAmountPerUnit]         AS [= AllowedAmount / Units]
      ,[InsurancePaymentPerUnit]      AS [= InsurancePayment / Units]
      ,[PatientPaymentPerUnit]        AS [= PatientPayment / Units]
      ,[PatientBalancePerUnit]        AS [= PatientBalance / Units]
      ,[TotalBalance]                 AS [= InsuranceBalance + PatientBalance]
      ,[TotalAdjustments]             AS [= InsuranceAdjustments + PatientAdjustments]
      ,[InsuranceBalance_Decimal]     AS [= InsuranceBalance as decimal]
      ,[PayerName]                    AS [= insurance master (normalized payer)]
      ,[Payer_Code]                   AS [= insurance master: payer code]
      ,[Payer_Common_Code]            AS [= insurance master: common code]
      ,[Payer_Group_Code]             AS [= insurance master: group code]
      ,[Global_Payer_ID]              AS [= insurance master: global id]
      ,[PayStatus]                    AS [= derived pay status]
      ,[LineLevelUID]                 AS [= line UID]
      ,[Source]                       AS [= source sheet stamp]
      ,[DaystoDOS]                    AS [= days since DateofService]
      ,[RollingDays]                  AS [= rolling days]
      ,[DaystoBill]                   AS [= FirstBilledDate - DateofService]
      ,[DaystoPost]                   AS [= CheckDate - FirstBilledDate]

       -- No source column in the VariantX file: ICDPointer, PaymentPostedDate, LineLevelCPT.
       -- Expected to stay in AdditionalFields: "Batch No", TotalPayments (no column in this table)
      ,[AdditionalFields]
  FROM [dbo].[LineLevelData]

GO
