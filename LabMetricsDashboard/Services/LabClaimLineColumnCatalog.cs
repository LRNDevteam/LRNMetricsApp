namespace LabMetricsDashboard.Services;

/// <summary>
/// Per-lab ClaimLevel / LineLevel column lists from Sql/Select_Script.
/// DB pages/Excel follow the lab SP SELECT list (Sql/ClaimLineDetails_SPs/{Lab}_Details.sql);
/// this catalog is the CSV fallback and money-heading helper.
/// </summary>
public static class LabClaimLineColumnCatalog
{
    private static readonly Dictionary<string, string> LabAliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["NorthWest"] = "NorthWest",
        ["NWL"] = "NorthWest",
        ["Cove"] = "Cove",
        ["Certus"] = "Certus",
        ["Augustus"] = "Augustus",
        ["Augustus_Labs"] = "Augustus",
        ["BeechTree"] = "BeechTree",
        ["Beech_Tree"] = "BeechTree",
        ["Elixir"] = "Elixir",
        ["PCRAL"] = "PCRAL",
        ["PCR_Dx_AL"] = "PCRAL",
        ["PCRCO"] = "PCRCO",
        ["PCR_Dx_CO"] = "PCRCO",
        ["PCRDx"] = "PCRCO",
        ["PCRLOA"] = "PCRLOA",
        ["PCRLabsofAmerica"] = "PCRLOA",
        ["InHealth"] = "InHealth",
        ["Inhealth_DTR"] = "InHealth",
        ["InHealthDTRLRN"] = "InHealth",
        ["PhiLife"] = "PhiLife",
        ["Phi_Life"] = "PhiLife",
        ["Philife"] = "PhiLife",
        ["RisingTides"] = "RisingTides",
        ["Rising_Tides"] = "RisingTides",
        ["Rishing_Tides"] = "RisingTides",
    };

    private static readonly string[] DefaultClaim =
    [
        "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName", "PayerType", "BillingProvider", "ReferringProvider",
        "ClinicName", "SalesRepname", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate",
        "Panelname", "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
        "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments",
        "InsuranceBalance", "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
        "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime"
    ];

    private static readonly string[] DefaultLine =
    [
        "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName", "PayerType", "BillingProvider", "ReferringProvider",
        "ClinicName", "SalesRepname", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate",
        "Panelname", "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount", "ChargeAmountPerUnit", "AllowedAmount",
        "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment", "PatientPaymentPerUnit",
        "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
        "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus", "PayStatus",
        "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer"
    ];

    private static readonly Dictionary<string, string[]> ClaimByLab = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Augustus"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "InsuranceBalance_Decimal", "UID", "Aging", "PatientName", "SubscriberId", "EnteredWeek",
                "EnteredStatus", "BilledWeek", "BilledStatus", "PostedWeek", "ModField", "ScrubberEditReason",
                "CheqNo", "TimeToPay", "PaymentPercent", "FullyPaidCount", "FullyPaidAmount", "Adjudicated",
                "AdjudicatedAmount", "Bucket30", "Bucket30Amount", "Bucket60", "Bucket60Amount", "CPTCodeXUnitsXModifierOrginal",
                "PanelNew", "Source", "PanelCategory", "BillingStatus", "LBilledDate", "BProcessDate",
                "ClaimUID", "AgingDOE", "AgingDOS", "PanelNameLIS", "PanelNameBasedOnCPT"
            ],
        ["BeechTree"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "PatientName", "PaymentPercent", "Aging", "BilledWeek", "PostedWeek", "FullyPaidCount",
                "FullyPaidAmount", "AdjudicatedAmount", "CPTCodeXUnitsXModifierOrginal", "BilledUnbilled", "AgingBucket", "AdjudicatedCount",
                "Days30Count", "Days30Amount", "Days60Count", "Days60Amount", "DOE_Year", "DOE_Month",
                "ClaimUID", "AgingDOE", "AgingDOS", "PanelNameLIS", "PanelNameBasedOnCPT", "InsuranceBalance_Decimal",
                "Facility", "Modifier"
            ],
        ["Certus"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "InsuranceBalance_Decimal", "CPTCodeXUnitsXModifierOrginal", "T_F", "SubscriberId", "PatientName", "ICDCodes",
                "DiagnosisPointer", "EnteredWeek", "EnteredStatus", "BilledWeek", "BilledStatus", "ModField",
                "ServiceUnit", "CPTXUnits", "CPTCombined", "Aging", "Description", "PostedWeek",
                "ClaimAmount", "OriginalDenialCode", "LineLevelDenials", "DenialCombination", "PaymentPercent", "RejectionReasons",
                "RejectionCategory", "FullyPaidCount", "FullyPaidAmount", "Adjudicated", "AdjudicatedAmount", "Bucket30",
                "Bucket30Amount", "Bucket60", "Bucket60Amount", "ClaimType", "ClaimUID", "AgingDOE",
                "AgingDOS", "PanelNameLIS", "PanelNameBasedOnCPT"
            ],
        ["Cove"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "CPTCodeXUnitsXModifierOrginal", "T_F", "UID", "Facility", "PatientName", "SubscriberId",
                "AgingDOS", "EndDOS", "AgingDOE", "BilledWeek", "ProcedureField", "Units",
                "LineLevelCPT", "DODWeek", "DenialDate", "DeniedWeek", "LineLevelDenialCode", "LineLevelICD",
                "ModifierField", "TotalWO", "TotalPayment", "PaymentPercent", "BillStatus", "FullyPaidCount",
                "FullyPaidAmount", "AdjucticatedCount", "AdjucticatedAmount", "Bucket30Count", "Bucket30Amount", "Bucket60Count",
                "Bucket60Amount", "Aging", "LISPatientName", "PanelType", "EnteredWeek", "EnteredStatus",
                "LastActivityDate", "EmedixSubmissionDate", "ClaimType", "BilledStatus", "PostedWeek", "ModField",
                "CheqNo", "DuplicatePaymentPosted", "ActualPayment", "ProcTotalBal", "DeniedStatus", "ScrubberEditReason",
                "EmedixRejectionDate", "EmedixRejection", "RejectionCategory", "TimeToPay", "Adjudicated", "AdjudicatedAmount",
                "Bucket30", "Bucket60", "ClaimUID", "PanelNameLIS", "PanelNameBasedOnCPT", "InsuranceBalance_Decimal"
            ],
        ["Elixir"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "CPTCodeXUnitsXModifierOrginal", "T_F", "PatientFirstName", "PatientLastName", "PatientAddress", "Coverage",
                "AgingDOS", "ServiceToDate", "AgingDOE", "Facility", "ServiceLocationCode", "ServiceLocationName",
                "PrimarySubId", "ICDField", "DODWeek", "BilledWeek", "DenialReason", "BillingOption",
                "CurrentStatus", "BatchNo", "CreatedOn", "CreatedBy", "UpdatedOn", "UpdatedBy",
                "BillStatus", "PaymentPercent", "FullyPaidCount", "FullyPaidAmount", "AdjucticatedCount", "AdjucticatedAmount",
                "Bucket30Count", "Bucket30Amount", "Bucket60Count", "Bucket60Amount", "ClaimUID", "PanelNameLIS",
                "PanelNameBasedOnCPT", "InsuranceBalance_Decimal", "Modifiers", "Units", "CptXModXUnits", "ServiceChargeAmount",
                "DenialDate", "LineLevelDenialCode"
            ],
        ["InHealth"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "DOE_Year", "DOE_Month", "AgingBucket", "BilledUnbilled", "Modifier", "CPTCode",
                "Units", "CPTCodeXUnitsXModifierOrginal", "PaymentPercent", "AdjudicatedCount", "Days30Count", "Days30Amount",
                "Days60Count", "Days60Amount", "FullyPaidCount", "FullyPaidAmount", "AdjudicatedAmount", "PatientName",
                "BilledWeek", "PostedWeek", "PanelNameLIS", "PanelNameBasedOnCPT", "TotalWO", "BillStatus",
                "AgingDOS", "AgingDOE", "ResponsibleParty", "SubscriberID", "ClientAccNum", "EndDOS",
                "DODWeek", "CheckNumber", "LineLevelICD", "Facility", "ClaimUID", "InsuranceBalance_Decimal",
                "DenialDate", "Bucket30Count", "Bucket30Amount", "Bucket60Count", "Bucket60Amount"
            ],
        ["NorthWest"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "InsuranceBalance_Decimal", "UID", "Aging", "PatientName", "LISPatientName", "SubscriberId",
                "PanelType", "EnteredWeek", "EnteredStatus", "LastActivityDate", "EmedixSubmissionDate", "ClaimType",
                "BilledStatus", "BilledWeek", "PostedWeek", "ModField", "CheqNo", "DuplicatePaymentPosted",
                "ActualPayment", "ProcTotalBal", "DeniedStatus", "ScrubberEditReason", "EmedixRejectionDate", "EmedixRejection",
                "RejectionCategory", "TimeToPay", "PaymentPercent", "FullyPaidCount", "FullyPaidAmount", "Adjudicated",
                "AdjudicatedAmount", "Bucket30", "Bucket30Amount", "Bucket60", "Bucket60Amount", "ClaimUID",
                "AgingDOE", "AgingDOS", "PanelNameLIS", "PanelNameBasedOnCPT", "CPTCodeXUnitsXModifierOrginal"
            ],
        ["PCRAL"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "InsuranceBalance_Decimal", "EncCptTc", "UID", "Facility", "PatientName", "ResponsibleParty",
                "SubscriberID", "EndDOS", "BilledWeek", "BillOccurance", "EntryUser", "ProcedureName",
                "Units", "LineLevelCPT", "DODWeek", "CheckNumber", "DenialDate", "LineLevelDenialCode",
                "ICD", "LineLevelICD", "Modifier", "TotalWO", "TotalPayment", "PaymentPercent",
                "BillStatus", "FullyPaidCount", "FullyPaidAmount", "AdjudicatedCount", "AdjudicatedAmount", "Bucket30Count",
                "Bucket30Amount", "Bucket60Count", "Bucket60Amount"
            ],
        ["PCRCO"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "InsuranceBalance_Decimal", "EncCptTc", "UID", "Facility", "PatientName", "ResponsibleParty",
                "SubscriberID", "EndDOS", "BilledWeek", "BillOccurance", "EntryUser", "ProcedureName",
                "Units", "LineLevelCPT", "DODWeek", "CheckNumber", "DenialDate", "DeniedWeek",
                "LineLevelDenialCode", "LineLevelICD", "Modifier", "TotalWO", "TotalPayment", "PaymentPercent",
                "BillStatus", "FullyPaidCount", "FullyPaidAmount", "AdjudicatedCount", "AdjudicatedAmount", "Bucket30Count",
                "Bucket30Amount", "Bucket60Count", "Bucket60Amount"
            ],
        ["PCRLOA"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "CPTCodeXUnitsXModifierOrginal", "PatientName", "BilledUnbilled", "ModifierField", "PaymentPercent", "Aging",
                "AgingBucket", "BilledWeek", "PostedWeek", "FullyPaidCount", "FullyPaidAmount", "AdjucticatedCount",
                "AdjucticatedAmount", "Bucket30Count", "Bucket30Amount", "Bucket60Count", "Bucket60Amount", "DOE_Year",
                "DOE_Month", "ClaimUID", "AgingDOE", "AgingDOS", "PanelNameLIS", "PanelNameBasedOnCPT",
                "InsuranceBalance_Decimal", "Facility"
            ],
        ["PhiLife"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "CPTCodeXUnitsXModifierOrginal", "BilledUnbilled", "Modifier", "AgingBucket", "AdjudicatedCount", "Days30Count",
                "Days30Amount", "Days60Count", "Days60Amount", "DOE_Year", "DOE_Month", "PatientName",
                "PaymentPercent", "Aging", "BilledWeek", "PostedWeek", "FullyPaidCount", "FullyPaidAmount",
                "AdjudicatedAmount", "CPTCode", "Units", "Adjudicated", "ClaimUID", "AgingDOE",
                "AgingDOS", "PanelNameLIS", "PanelNameBasedOnCPT", "InsuranceBalance_Decimal", "Facility"
            ],
        ["RisingTides"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "CPTCodeXUnitsXModifierOrginal", "PatientName", "BilledUnbilled", "ModifierField", "PaymentPercent", "Aging",
                "AgingBucket", "BilledWeek", "PostedWeek", "Facility", "FullyPaidCount", "FullyPaidAmount",
                "AdjucticatedCount", "AdjucticatedAmount", "Bucket30Count", "Bucket30Amount", "Bucket60Count", "Bucket60Amount",
                "DOE_Year", "DOE_Month", "ClaimUID", "AgingDOE", "AgingDOS", "PanelNameLIS",
                "PanelNameBasedOnCPT", "InsuranceBalance_Decimal"
            ],
    };

    private static readonly Dictionary<string, string[]> LineByLab = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Augustus"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "EncounterPaymentPostedDate",
                "PanelNew", "Source", "UID", "Valid", "PanelCategory", "PatientName",
                "SubscriberId", "ClaimAmount", "Date", "EnteredStatus", "BilledStatus", "CptWithUnits",
                "Proc", "CheqNo", "AdjAmount", "InsBalance", "PatBalance", "UpdatedDenial",
                "CombinedDenial", "PaymentPercent", "Loc", "BillingStatus", "LBilledDate", "BProcessDate",
                "LineLevelUID", "InsuranceBalance_Decimal", "ICDLineLevel", "ClaimAmountRaw"
            ],
        ["BeechTree"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PatientName", "SubscriberId",
                "PaymentPostedDate", "ResponsibleParty", "EndDOS", "BillOccurance", "EntryUser", "CPTUnits",
                "CPTMOD", "PostedWeek", "LineLevelUID", "Source", "InsuranceBalance_Decimal", "Facility"
            ],
        ["Certus"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "T_F",
                "UID", "SubscriberId", "PatientName", "DiagnosisPointer", "EnteredWeek", "EnteredStatus",
                "BilledWeek", "BilledStatus", "CPTXUnits", "CPTCombined", "Aging", "Description",
                "PostedWeek", "BilledAmounts", "OriginalDenialCode", "DenialCombination", "PaymentPercent", "LineLevelUID",
                "Source", "InsuranceBalance_Decimal", "ClaimAmount"
            ],
        ["Cove"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "T_F",
                "UID", "Facility", "PatientName", "SubscriberId", "AgingDOS", "EndDOS",
                "AgingDOE", "BilledWeek", "LineLevelCPT", "DODWeek", "DeniedWeek", "LineLevelDenialCode",
                "PaymentPercent", "LineLevelUID", "Source", "InsuranceBalance_Decimal"
            ],
        ["Elixir"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "T_F",
                "VisitXCptXMod", "UID", "PatientFirstName", "PatientLastName", "AgingDOS", "ServiceToDate",
                "AgingDOE", "OrderingPhysicianFirstName", "ServiceLocationCode", "PrimarySubId", "CptXModXUnits", "ServiceChargeAmount",
                "LineLevelDenialCode", "DenialReason", "BillingOption", "BillStatus", "BatchNo", "CreatedOn",
                "CreatedBy", "UpdatedOn", "UpdatedBy", "PaymentPercent", "LineLevelUID", "Source",
                "InsuranceBalance_Decimal"
            ],
        ["InHealth"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PatientName", "PaymentPostedDate",
                "ResponsibleParty", "SubscriberID", "EndDOS", "BillOccurance", "EntryUser", "CPTUnits",
                "CPTMOD", "CPTs", "PostedWeek", "CPTXUnitsxMod", "PaymentPercent", "Facility",
                "ClientAccNum", "LineLevelUID", "Source", "InsuranceBalance_Decimal"
            ],
        ["NorthWest"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "UID", "T_F",
                "PatientName", "CombinedLineLevelICD", "SubscriberId", "ClaimAmount", "CptWithUnits", "Proc",
                "EnteredStatus", "BilledStatus", "ProcTotalBal", "UpdatedDenialCode", "CombinedLineLevelDenialCode", "Loc",
                "ProcInsLastRefiledDeniedReason", "ProcInsResponsibleCarrierOriginalFilingDate", "ProcInsStatus", "ProcInsLastRefiledDeniedDate", "LineLevelUID", "Source",
                "InsuranceBalance_Decimal"
            ],
        ["PCRAL"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "InsuranceBalance_Decimal", "EncCptTc",
                "UID", "Facility", "PatientName", "ResponsibleParty", "SubscriberID", "AgingDOS",
                "EndDOS", "AgingDOE", "BilledWeek", "BillOccurance", "EntryUser", "LineLevelCPT",
                "DODWeek", "CheckNumber", "LineLevelDenialCode", "PaymentPercent"
            ],
        ["PCRCO"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "InsuranceBalance_Decimal", "EncCptTc",
                "UID", "Facility", "PatientName", "ResponsibleParty", "SubscriberID", "AgingDOS",
                "EndDOS", "AgingDOE", "BilledWeek", "BillOccurance", "EntryUser", "LineLevelCPT",
                "DODWeek", "CheckNumber", "DeniedWeek", "LineLevelDenialCode", "PaymentPercent"
            ],
        ["PCRLOA"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "PatientName",
                "ResponsibleParty", "SubscriberId", "ClientAccNum", "EndDOS", "BillOccurance", "EntryUser",
                "CPTUnits", "CPTMOD", "CPTs", "PostedWeek", "LineLevelUID", "Source",
                "InsuranceBalance_Decimal", "Facility"
            ],
        ["PhiLife"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "PatientName",
                "ResponsibleParty", "SubscriberId", "EndDOS", "BillOccurance", "EntryUser", "CPTUnits",
                "CPTMOD", "CPTs", "PostedWeek", "AgingBucket", "LineLevelUID", "Source",
                "InsuranceBalance_Decimal", "Facility", "ClientAccNum"
            ],
        ["RisingTides"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "ClaimStatus",
                "PayStatus", "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "PatientName",
                "ResponsibleParty", "SubscriberId", "ClientAccNum", "EndDOS", "BillOccurance", "EntryUser",
                "CPTUnits", "CPTMOD", "CPTs", "PostedWeek", "Facility", "LineLevelUID",
                "Source", "InsuranceBalance_Decimal"
            ],
    };

    public static string NormalizeLab(string? labName)
    {
        if (string.IsNullOrWhiteSpace(labName)) return string.Empty;
        return LabAliases.TryGetValue(labName.Trim(), out var key) ? key : labName.Trim();
    }

    public static IReadOnlyList<string> GetClaimColumns(string? labName)
        => ClaimByLab.TryGetValue(NormalizeLab(labName), out var cols) ? cols : DefaultClaim;

    public static IReadOnlyList<string> GetLineColumns(string? labName)
        => LineByLab.TryGetValue(NormalizeLab(labName), out var cols) ? cols : DefaultLine;

    /// <summary>
    /// SELECT list for Excel / page exports: Select_Script columns with the same
    /// ClaimID trimming and money CAST used on the Claim/Line pages.
    /// </summary>
    public static string GetExportSelectList(string? labName, bool isLineLevel)
        => ToSqlSelectList(isLineLevel ? GetLineColumns(labName) : GetClaimColumns(labName), isLineLevel);

    public static string ToAliasedSqlSelectList(IReadOnlyList<string> columns, string alias)
        => string.Join(", ", columns.Select(c => alias + "." + Bracket(c)));

    public static string ToSqlSelectList(IReadOnlyList<string> columns)
        => string.Join(", ", columns.Select(Bracket));

    /// <summary>
    /// SELECT list with ClaimID/PatientID/.00 trimming, money CAST, and name TRIM
    /// matching the Claim/Line pages and their Excel downloads.
    /// </summary>
    public static string ToSqlSelectList(IReadOnlyList<string> columns, bool isLineLevel)
        => string.Join(",\r\n            ", columns.Select(c => FormatSelectColumn(c, isLineLevel)));

    public static bool IsMoneyColumn(string column)
    {
        if (string.IsNullOrEmpty(column)) return false;
        if (column.Contains("Percent", StringComparison.OrdinalIgnoreCase)
            || column.Contains("Count", StringComparison.OrdinalIgnoreCase)
            || column.Contains("Days", StringComparison.OrdinalIgnoreCase)
            || column.Contains("Entered", StringComparison.OrdinalIgnoreCase)
            || column.Contains("Posted", StringComparison.OrdinalIgnoreCase)
            || column.Contains("Date", StringComparison.OrdinalIgnoreCase)
            || column.Equals("Units", StringComparison.OrdinalIgnoreCase)
            || column.Equals("ServiceUnit", StringComparison.OrdinalIgnoreCase))
            return false;

        return column.Contains("Amount", StringComparison.OrdinalIgnoreCase)
            || column.Contains("Balance", StringComparison.OrdinalIgnoreCase)
            || column.Contains("Payment", StringComparison.OrdinalIgnoreCase)
            || column.Contains("Charge", StringComparison.OrdinalIgnoreCase)
            || column.EndsWith("WO", StringComparison.OrdinalIgnoreCase)
            || column.Equals("ProcTotalBal", StringComparison.OrdinalIgnoreCase)
            || column.Equals("ClaimAmount", StringComparison.OrdinalIgnoreCase)
            || column.Equals("ActualPayment", StringComparison.OrdinalIgnoreCase);
    }

    private static readonly HashSet<string> TrimColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "PayerName", "PayerType", "ClinicName", "Panelname", "PanelName",
        "ClaimStatus", "PayStatus", "SalesRepname", "SalesRepName", "CPTCode",
    };

    private static string Bracket(string column)
        => "[" + column.Replace("]", "]]") + "]";

    private static string FormatSelectColumn(string column, bool isLineLevel)
    {
        var b = Bracket(column);

        if (column.Equals("ClaimID", StringComparison.OrdinalIgnoreCase)
            || column.Equals("PatientID", StringComparison.OrdinalIgnoreCase)
            || (isLineLevel && column.Equals("CPTCode", StringComparison.OrdinalIgnoreCase))
            || (isLineLevel && column.Equals("Modifier", StringComparison.OrdinalIgnoreCase)))
        {
            return $"CASE WHEN {b} LIKE '%.00' THEN LEFT({b}, LEN({b})-3) ELSE ISNULL(LTRIM(RTRIM({b})),'') END AS {b}";
        }

        if (isLineLevel && column.Equals("Units", StringComparison.OrdinalIgnoreCase))
            return $"ISNULL(FLOOR(TRY_CAST({b} AS DECIMAL(18,2))), 0) AS {b}";

        if (IsMoneyColumn(column))
            return $"ISNULL(TRY_CAST({b} AS DECIMAL(18,2)), 0) AS {b}";

        if (TrimColumns.Contains(column))
            return $"ISNULL(LTRIM(RTRIM({b})),'') AS {b}";

        return $"{b}";
    }
}
