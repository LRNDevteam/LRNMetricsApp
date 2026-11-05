namespace LabMetricsDashboard.Services;

/// <summary>
/// Per-lab ClaimLevel / LineLevel column lists from Sql/Select_Script.
/// DB pages/Excel follow the lab SP SELECT list (Database/LabMetricsDashboard/ClaimLineDetails_SPs/{Lab}_Details.sql);
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
        ["VariantX"] = "VariantX",
        ["Variant_X"] = "VariantX",
        ["VariantX_LRN"] = "VariantX",
        ["AnalyzePathology"] = "AnalyzePathology",
        ["Analyze_Pathology"] = "AnalyzePathology",
        ["Analyze Pathology"] = "AnalyzePathology",
        ["WellHealth"] = "WellHealth",
        ["Well_Health"] = "WellHealth",
        ["Well Health"] = "WellHealth",
        ["CoreBio"] = "CoreBio",
        ["Core_Bio"] = "CoreBio",
        ["TexasDiagnostic"] = "TexasDiagnostic",
        ["Texas_Diagnostic"] = "TexasDiagnostic",
    };

    private static readonly string[] DefaultClaim =
    [
        "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName", "PayerType", "BillingProvider", "ReferringProvider",
        "ClinicName", "SalesRepname", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate",
        "Panelname", "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
        "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments",
        "InsuranceBalance", "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
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
        "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer"
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
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "InsuranceBalance_Decimal", "UID", "Aging", "PatientName", "SubscriberId", "EnteredWeek",
                "EnteredStatus", "BilledWeek", "BilledStatus", "PostedWeek", "ModField", "ScrubberEditReason",
                "CheqNo", "TimeToPay", "PaymentPercent", "FullyPaidCount", "FullyPaidAmount", "Adjudicated",
                "AdjudicatedAmount", "Bucket30", "Bucket30Amount", "Bucket60", "Bucket60Amount", "CPTCodeXUnitsXModifierOrginal",
                "PanelNew", "Source", "PanelCategory", "BillingStatus", "LBilledDate", "BProcessDate",
                "ClaimUID", "AgingDOE", "AgingDOS", "PanelNameLIS", "PanelNameBasedOnCPT"
            ],
        // BeechTree mandatory ClaimLevelData columns: Claim Level page / Excel, Production and Collection
        // ClaimLevel sheets, Executive Summary value popup. Keep in step with BeechTree_Details.sql and
        // 29_BeechTree_ExecutiveSummary_CellRows.sql.
        ["BeechTree"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "Payer_Code", "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "PayerType", "BillingProvider",
                "ReferringProvider", "ClinicName", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate",
                "FirstBilledDate", "Panelname", "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount",
                "AllowedAmount", "InsurancePayment", "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments",
                "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus",
                "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "InsertedDateTime", "PatientName", "PaymentPercent", "Aging",
                "BilledWeek", "PostedWeek", "FullyPaidCount", "FullyPaidAmount", "AdjudicatedAmount", "CPTCodeXUnitsXModifierOrginal",
                "BilledUnbilled", "AgingBucket", "AdjudicatedCount", "Days30Count", "Days30Amount", "Days60Count",
                "Days60Amount", "InsuranceBalance_Decimal", "Facility"
            ],
        ["Certus"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "InsuranceBalance_Decimal", "CPTCodeXUnitsXModifierOrginal", "T_F", "SubscriberId", "PatientName", "ICDCodes",
                "DiagnosisPointer", "EnteredWeek", "EnteredStatus", "BilledWeek", "BilledStatus", "ModField",
                "ServiceUnit", "CPTXUnits", "CPTCombined", "Aging", "Description", "PostedWeek",
                "ClaimAmount", "OriginalDenialCode", "LineLevelDenials", "DenialCombination", "PaymentPercent", "RejectionReasons",
                "RejectionCategory", "FullyPaidCount", "FullyPaidAmount", "Adjudicated", "AdjudicatedAmount", "Bucket30",
                "Bucket30Amount", "Bucket60", "Bucket60Amount", "ClaimType", "ClaimUID", "AgingDOE",
                "AgingDOS", "PanelNameLIS", "PanelNameBasedOnCPT"
            ],
        // Cove mandatory ClaimLevelData columns: Claim Level page / Excel, Production and Collection
        // ClaimLevel sheets, Executive Summary value popup. Keep in step with Cove_Details.sql and
        // 25_Cove_ExecutiveSummary_CellRows.sql.
        ["Cove"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "Payer_Code", "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "BillingProvider", "ReferringProvider",
                "ClinicName", "SalesRepname", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate",
                "FirstBilledDate", "Panelname", "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount",
                "AllowedAmount", "InsurancePayment", "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments",
                "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus",
                "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "CPTCodeXUnitsXModifierOrginal", "T_F",
                "UID", "Facility", "PatientName", "SubscriberId", "AgingDOS", "EndDOS",
                "AgingDOE", "BilledWeek", "Units", "DODWeek", "DenialDate", "DeniedWeek",
                "ModifierField", "TotalWO", "TotalPayment", "PaymentPercent", "BillStatus", "FullyPaidCount",
                "FullyPaidAmount", "AdjucticatedCount", "AdjucticatedAmount", "Bucket30Count", "Bucket30Amount", "Bucket60Count",
                "Bucket60Amount", "Aging", "InsuranceBalance_Decimal"
            ],
        // Elixir mandatory ClaimLevelData columns: Claim Level page / Excel, Production and Collection
        // ClaimLevel sheets, Executive Summary value popup. Keep in step with Elixir_Details.sql and
        // 23_Elixir_ExecutiveSummary_CellRows.sql.
        ["Elixir"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "Payer_Code", "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "PayerType", "BillingProvider",
                "ReferringProvider", "ClinicName", "SalesRepname", "PatientID", "PatientDOB", "DateofService",
                "ChargeEnteredDate", "FirstBilledDate", "Panelname", "CPTCodeXUnitsXModifier", "POS", "TOS",
                "ChargeAmount", "AllowedAmount", "InsurancePayment", "PatientPayment", "TotalPayments", "InsuranceAdjustments",
                "PatientAdjustments", "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance", "CheckDate",
                "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode", "DaystoDOS",
                "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "CPTCodeXUnitsXModifierOrginal",
                "T_F", "PatientFirstName", "PatientLastName", "AgingDOS", "ServiceToDate", "AgingDOE",
                "Facility", "ServiceLocationCode", "PrimarySubId", "ICDField", "DODWeek", "BilledWeek",
                "DenialReason", "BillingOption", "CurrentStatus", "BatchNo", "CreatedOn", "CreatedBy",
                "UpdatedOn", "UpdatedBy", "BillStatus", "PaymentPercent", "FullyPaidCount", "FullyPaidAmount",
                "AdjucticatedCount", "AdjucticatedAmount", "Bucket30Count", "Bucket30Amount", "Bucket60Count", "Bucket60Amount",
                "InsuranceBalance_Decimal", "Modifiers", "Units", "CptXModXUnits", "ServiceChargeAmount", "DenialDate",
                "LineLevelDenialCode"
            ],
        // InHealth DTR mandatory ClaimLevelData columns: Claim Level page / Excel, Production and
        // Collection ClaimLevel sheets, Executive Summary value popup. Keep in step with
        // InHealth_Details.sql and 29_Inhealth_ExecutiveSummary_CellRows.sql.
        ["InHealth"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "Payer_Code", "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "BillingProvider", "ReferringProvider",
                "ClinicName", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate",
                "CPTCodeXUnitsXModifier", "ChargeAmount", "AllowedAmount", "InsurancePayment", "PatientPayment", "TotalPayments",
                "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance",
                "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "CPTCodeXUnitsXModifierOrginal",
                "PaymentPercent", "AdjudicatedCount", "FullyPaidCount", "FullyPaidAmount", "AdjudicatedAmount", "PatientName",
                "BilledWeek", "PanelNameLIS", "PanelNameBasedOnCPT", "TotalWO", "BillStatus", "AgingDOS",
                "AgingDOE", "ResponsibleParty", "SubscriberID", "EndDOS", "DODWeek", "CheckNumber",
                "LineLevelICD", "Facility", "Bucket30Count", "Bucket30Amount", "Bucket60Count", "Bucket60Amount"
            ],
        // NorthWest mandatory ClaimLevelData columns: Claim Level page / Excel, Production and
        // Collection ClaimLevel sheets, Executive Summary value popup. Keep in step with
        // NorthWest_Details.sql and 50_NW_ExecutiveSummary_CellRows.sql.
        ["NorthWest"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "PatientID", "PatientDOB",
                "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname", "CPTCodeXUnitsXModifier", "ChargeAmount",
                "AllowedAmount", "InsurancePayment", "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments",
                "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus",
                "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "Aging", "PatientName",
                "LISPatientName", "SubscriberId", "PanelType", "EnteredWeek", "EnteredStatus", "LastActivityDate",
                "EmedixSubmissionDate", "ClaimType", "BilledUnbilled", "BilledStatus", "BilledWeek", "PostedWeek",
                "ModField", "CheqNo", "DuplicatePaymentPosted", "ActualPayment", "ProcTotalBal", "DeniedStatus",
                "ScrubberEditReason", "EmedixRejectionDate", "EmedixRejection", "RejectionCategory", "TimeToPay", "PaymentPercent",
                "FullyPaidCount", "FullyPaidAmount", "Adjudicated", "AdjudicatedAmount", "Bucket30", "Bucket30Amount",
                "Bucket60", "Bucket60Amount", "CPTCodeXUnitsXModifierOrginal", "NWLCollectionPostedDate", "NWLDenialPostedDate"
            ],
        ["PCRAL"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "IngestedOn",
                "CsvRowHash", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCodeXUnitsXModifier", "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
                "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
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
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
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
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
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
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
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
                "PatientBalance", "TotalBalance", "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime",
                "CPTCodeXUnitsXModifierOrginal", "PatientName", "BilledUnbilled", "ModifierField", "PaymentPercent", "Aging",
                "AgingBucket", "BilledWeek", "PostedWeek", "Facility", "FullyPaidCount", "FullyPaidAmount",
                "AdjucticatedCount", "AdjucticatedAmount", "Bucket30Count", "Bucket30Amount", "Bucket60Count", "Bucket60Amount",
                "DOE_Year", "DOE_Month", "ClaimUID", "AgingDOE", "AgingDOS", "PanelNameLIS",
                "PanelNameBasedOnCPT", "InsuranceBalance_Decimal"
            ],
        ["VariantX"] =
            [
                "LabID", "LabName", "SourceFileID", "IngestedOn", "CsvRowHash", "ClaimID",
                "AccessionNumber", "PanelName", "PlanType", "PatientID", "PatientFirstName", "PatientLastName",
                "PatientDOB", "DateofService", "AgingDOS", "EndDOS", "ChargeEnteredDate", "AgingDOE",
                "Facility", "ReferringProviderFirstName", "ReferringProviderLastName", "RendPhyFirstName", "RendPhyLastName", "BillingProvider", "ReferringProvider", "ServLocCode",
                "ServLocation", "PayerName_Raw", "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code",
                "Global_Payer_ID", "SubscriberId", "FirstBilledDate", "BilledWeek", "ClaimLevelCPT", "Modifier",
                "CheckDate", "DODWeek", "DenialDate", "DeniedWeek", "DenialCode", "LineLevelDenialCode",
                "ClaimLevelDenialCode", "LineLevelICD", "ClaimLevelICD", "POS", "TOS", "LineLevelCPT",
                "CPTCodeXUnitsXModifier", "ChargeAmount", "AllowedAmount", "InsurancePayment", "PatientPayment", "TotalPayments",
                "InsuranceBalance", "PatientBalance", "TotalBalance", "InsuranceAdjustments", "PatientAdjustments", "TotalWO",
                "BillingOption", "CurrentStatus", "BatchNo", "CreatedBy", "UpdatedOn", "UpdatedBy",
                "PaymentPercent", "BillStatus", "FullyPaidCount", "FullyPaidAmount", "AdjucticatedCount", "AdjucticatedAmount",
                "Bucket30Count", "Bucket30Amount", "Bucket60Count", "Bucket60Amount", "ClaimStatus", "DaystoDOS",
                "RollingDays", "DaystoBill", "DaystoPost", "InsertedDateTime", "DenialCodeNormalized", "DenialDescription"
            ],
        // Analyze Pathology mandatory ClaimLevelData columns: Claim Level page / Excel, Production and
        // Collection ClaimLevel sheets, Executive Summary value popup. Keep in step with
        // AnalyzePathology_Details.sql and 43_AnalyzePathology_ExecutiveSummary_CellRows.sql.
        ["AnalyzePathology"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerType",
                "ReferringProvider", "BillingProvider", "ClinicName", "PatientID", "PatientName", "PatientDOB",
                "SubscriberId", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "LastBilledDate", "BilledWeek",
                "BilledStatus", "Panelname", "CPTCodeXUnitsXModifier", "CPTCodeList", "UnitsList", "ModifierList",
                "POS", "ChargeAmount", "InsurancePayment", "PatientPayment", "TotalPayments", "InsuranceAdjustments",
                "PatientAdjustments", "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance", "TotalInsuranceBalance",
                "OtherBalance", "ChargeToDate", "ChargeTotalPayments", "ChargeTotalAdjustments", "CheckDate", "PaymentPostedDate",
                "PostedWeek", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate",
                "ICDCode", "ICDPointer", "AgingDOS", "PaymentPercent", "FullyPaidCount", "FullyPaidAmount",
                "Adjudicated", "AdjudicatedAmount", "Bucket30", "Bucket30Amount", "Bucket60", "Bucket60Amount",
                "Facility", "OrderingProviderID", "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost"
            ],
        // WellHealth mandatory ClaimLevelData columns: Claim Level page / Excel, Production and
        // Collection ClaimLevel sheets, Executive Summary value popup. Keep in step with
        // WellHealth_Details.sql and 37_WellHealth_ExecutiveSummary_CellRows.sql.
        ["WellHealth"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "PayerType", "ReferringProvider", "ClaimBillingProviderID", "ClinicName", "PatientID", "PatientName",
                "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "LastBilledDate", "BilledWeek",
                "BilledStatus", "Panelname", "ChargePanelID", "CPTCodeXUnitsXModifier", "ModifierList", "POS",
                "ChargeAmount", "InsurancePayment", "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments",
                "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance", "TotalInsuranceBalance", "OtherBalance",
                "BalanceAtCollections", "ChargeToDate", "ChargeTotalPayments", "ChargeTotalAdjustments", "CheckDate", "PostingDate",
                "PaymentPostedDate", "PostedWeek", "DepositWeek", "ClaimStatus", "DenialCode", "DenialCodeNormalized",
                "DenialDescription", "DenialDate", "ICDCode", "ICDPointer", "AgingDOS", "PaymentPercent",
                "FullyPaidCount", "FullyPaidAmount", "Adjudicated", "AdjudicatedAmount", "Bucket30", "Bucket30Amount",
                "Bucket60", "Bucket60Amount", "Facility", "DaystoDOS", "RollingDays", "DaystoBill",
                "DaystoPost"
            ],
        // CoreBio mandatory ClaimLevelData columns: Claim Level page / Excel, Production and Collection
        // ClaimLevel sheets, Executive Summary value popup. Keep in step with CoreBio_Details.sql and
        // 37_CoreBio_ExecutiveSummary_CellRows.sql.
        ["CoreBio"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "PayerType", "ReferringProvider", "ClinicName", "PatientID", "PatientName", "PatientDOB",
                "SubscriberId", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "LastBilledDate", "BilledWeek",
                "BilledStatus", "Panelname", "CPTCodeXUnitsXModifier", "CPTCodeList", "UnitsList", "ModifierList",
                "ChargeAmount", "InsurancePayment", "PatientPayment", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments",
                "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance", "TotalInsuranceBalance", "OtherBalance",
                "ChargeToDate", "ChargeTotalPayments", "ChargeTotalAdjustments", "CheckDate", "PaymentPostedDate", "PostedWeek",
                "ClaimStatus", "DenialCode", "ClaimLevelDenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate",
                "ICDCode", "ICDPointer", "AgingDOS", "PaymentPercent", "FullyPaidCount", "FullyPaidAmount",
                "Adjudicated", "AdjudicatedAmount", "Bucket30", "Bucket30Amount", "Bucket60", "Bucket60Amount",
                "Facility", "OrderingProviderID", "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost"
            ],
        // TexasDiagnostic mandatory ClaimLevelData columns: Claim Level page / Excel, Production and
        // Collection ClaimLevel sheets, Executive Summary value popup. Keep in step with
        // TexasDiagnostic_Details.sql and 37_TexasDiagnostic_ExecutiveSummary_CellRows.sql.
        ["TexasDiagnostic"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "PatientID", "PatientDOB",
                "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname", "CPTCodeXUnitsXModifier", "POS",
                "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment", "PatientPayment", "TotalPayments",
                "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance",
                "CheckDate", "ClaimStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "ICDCode",
                "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "PaymentPercent", "FullyPaidCount",
                "FullyPaidAmount", "Adjudicated", "AdjudicatedAmount", "Bucket30", "Bucket30Amount", "Bucket60",
                "Bucket60Amount", "CheckNumber", "EntryWeek", "DepositWeek", "BilledWeek"
            ],
    };

    private static readonly Dictionary<string, string[]> LineByLab = new(StringComparer.OrdinalIgnoreCase)
    {
        // Analyze Pathology mandatory LineLevelData columns: Line Level page / Excel, Production and
        // Collection LineLevel sheets (dashboard and ReportWorker downloads). Keep in step with
        // AnalyzePathology_Details.sql.
        ["AnalyzePathology"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "LineLevelUID", "PayerName_Raw",
                "PayerName", "PayerType", "ReferringProvider", "ClinicName", "PatientID", "PatientName",
                "PatientDOB", "SubscriberId", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "LastBilledDate",
                "Panelname", "CPTCode", "Units", "Modifier", "ClaimCPTs", "CptWithUnits",
                "CPTModifier", "POS", "ChargeAmount", "InsurancePayment", "PatientPayment", "TotalPayments",
                "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance", "PatientBalance", "TotalBalance",
                "TotalInsuranceBalance", "OtherBalance", "ChargeToDate", "ChargeTotalPayments", "ChargeTotalAdjustments", "CheckDate",
                "PostingDate", "PaymentPostedDate", "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription",
                "DenialDate", "ICDCode", "ICDPointer", "Facility", "OrderingProviderID", "DaystoDOS",
                "RollingDays", "DaystoBill", "DaystoPost"
            ],
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
                "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "EncounterPaymentPostedDate",
                "PanelNew", "Source", "UID", "Valid", "PanelCategory", "PatientName",
                "SubscriberId", "ClaimAmount", "Date", "EnteredStatus", "BilledStatus", "CptWithUnits",
                "Proc", "CheqNo", "AdjAmount", "InsBalance", "PatBalance", "UpdatedDenial",
                "CombinedDenial", "PaymentPercent", "Loc", "BillingStatus", "LBilledDate", "BProcessDate",
                "LineLevelUID", "InsuranceBalance_Decimal", "ICDLineLevel", "ClaimAmountRaw"
            ],
        // BeechTree mandatory LineLevelData columns: Line Level page / Excel, Production and Collection
        // LineLevel sheets (dashboard and ReportWorker downloads). Keep in step with BeechTree_Details.sql.
        ["BeechTree"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "Payer_Code", "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "PayerType", "BillingProvider",
                "ReferringProvider", "ClinicName", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate",
                "FirstBilledDate", "Panelname", "CPTCode", "Units", "Modifier", "POS",
                "TOS", "ChargeAmount", "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment",
                "InsurancePaymentPerUnit", "PatientPayment", "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments",
                "TotalAdjustments", "InsuranceBalance", "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate",
                "PostingDate", "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate",
                "ICDCode", "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "PatientName",
                "SubscriberId", "PaymentPostedDate", "ResponsibleParty", "EndDOS", "BillOccurance", "EntryUser",
                "CPTUnits", "CPTMOD", "PostedWeek", "LineLevelUID", "InsuranceBalance_Decimal", "Facility"
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
                "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "T_F",
                "UID", "SubscriberId", "PatientName", "DiagnosisPointer", "EnteredWeek", "EnteredStatus",
                "BilledWeek", "BilledStatus", "CPTXUnits", "CPTCombined", "Aging", "Description",
                "PostedWeek", "BilledAmounts", "OriginalDenialCode", "DenialCombination", "PaymentPercent", "LineLevelUID",
                "Source", "InsuranceBalance_Decimal", "ClaimAmount"
            ],
        // Cove mandatory LineLevelData columns: Line Level page / Excel, Production and Collection
        // LineLevel sheets (dashboard and ReportWorker downloads). Keep in step with Cove_Details.sql.
        ["Cove"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID", "PayerName_Raw",
                "PayerName", "Payer_Code", "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "BillingProvider",
                "ReferringProvider", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate",
                "Panelname", "CPTCode", "Units", "Modifier", "POS", "TOS",
                "ChargeAmount", "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit",
                "PatientPayment", "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments",
                "InsuranceBalance", "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate",
                "ClaimStatus", "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate",
                "ICDCode", "DaystoDOS", "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer",
                "InsertedDateTime", "PaymentPostedDate", "T_F", "UID", "Facility", "PatientName",
                "SubscriberId", "AgingDOS", "EndDOS", "AgingDOE", "BilledWeek", "LineLevelCPT",
                "DODWeek", "DeniedWeek", "LineLevelDenialCode", "PaymentPercent", "InsuranceBalance_Decimal"
            ],
        // Elixir mandatory LineLevelData columns: Line Level page / Excel, Production and Collection
        // LineLevel sheets (dashboard and ReportWorker downloads). Keep in step with Elixir_Details.sql.
        ["Elixir"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "Payer_Code", "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "BillingProvider", "ReferringProvider",
                "ClinicName", "SalesRepname", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate",
                "FirstBilledDate", "Panelname", "CPTCode", "Units", "Modifier", "POS",
                "TOS", "ChargeAmount", "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment",
                "InsurancePaymentPerUnit", "PatientPayment", "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "TotalAdjustments",
                "InsuranceBalance", "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PayStatus",
                "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS",
                "RollingDays", "DaystoBill", "DaystoPost", "T_F", "VisitXCptXMod", "UID",
                "PatientFirstName", "PatientLastName", "AgingDOS", "ServiceToDate", "AgingDOE", "OrderingPhysicianFirstName",
                "ServiceLocationCode", "PrimarySubId", "CptXModXUnits", "ServiceChargeAmount", "LineLevelDenialCode", "DenialReason",
                "BillingOption", "BillStatus", "BatchNo", "CreatedOn", "CreatedBy", "UpdatedOn",
                "UpdatedBy", "PaymentPercent", "LineLevelUID", "Source", "InsuranceBalance_Decimal"
            ],
        // InHealth DTR mandatory LineLevelData columns: Line Level page / Excel, Production and Collection
        // LineLevel sheets (dashboard and ReportWorker downloads). Keep in step with InHealth_Details.sql.
        ["InHealth"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "Payer_Code", "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "BillingProvider", "ReferringProvider",
                "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname",
                "CPTCode", "Units", "Modifier", "POS", "TOS", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PayStatus", "DenialCode",
                "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "PatientName", "ResponsibleParty", "SubscriberID", "EndDOS",
                "BillOccurance", "EntryUser", "CPTUnits", "CPTMOD", "CPTXUnitsxMod", "PaymentPercent",
                "Facility", "InsuranceBalance_Decimal"
            ],
        // NorthWest mandatory LineLevelData columns: Line Level page / Excel, Production and Collection
        // LineLevel sheets (dashboard and ReportWorker downloads). Keep in step with NorthWest_Details.sql.
        ["NorthWest"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName", "PayerType",
                "ReferringProvider", "ClinicName", "PatientID", "PatientDOB", "DateofService", "ChargeEnteredDate",
                "FirstBilledDate", "Panelname", "CPTCode", "Units", "Modifier", "ChargeAmount",
                "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment",
                "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PostingDate", "PayStatus",
                "DenialCode", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays", "DaystoBill"
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
                "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
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
                "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
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
                "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
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
                "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
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
                "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays",
                "DaystoBill", "DaystoPost", "ICDPointer", "InsertedDateTime", "PaymentPostedDate", "PatientName",
                "ResponsibleParty", "SubscriberId", "ClientAccNum", "EndDOS", "BillOccurance", "EntryUser",
                "CPTUnits", "CPTMOD", "CPTs", "PostedWeek", "Facility", "LineLevelUID",
                "Source", "InsuranceBalance_Decimal"
            ],
        ["VariantX"] =
            [
                "LabID", "LabName", "SourceFileID", "IngestedOn", "CsvRowHash", "ClaimID",
                "T_F", "LineLevelUID", "AccessionNumber", "Panelname", "PlanType", "PatientID",
                "PatientFirstName", "PatientLastName", "PatientDOB", "DateofService", "AgingDOS", "EndDOS",
                "ChargeEnteredDate", "AgingDOE", "Facility", "ReferringProviderLastName", "ReferringProviderFirstName", "RendPhyFirstName",
                "RendPhyLastName", "BillingProvider", "ReferringProvider", "ServLocCode", "ServLocation", "PayerName_Raw", "PayerName", "Payer_Code",
                "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "SubscriberId", "FirstBilledDate", "BilledWeek",
                "CPTCode", "Units", "Modifier", "CPTXMODXUnits", "LineLevelCPT", "CheckDate",
                "DODWeek", "DenialDate", "DeniedWeek", "DenialCode", "DenialCodeNormalized", "DenialDescription", "LineLevelDenialCode", "ICDCode",
                "ClaimLevelICDCode", "POS", "TOS", "ChargeAmount", "ChargeAmountPerUnit", "AllowedAmount",
                "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment", "PatientPaymentPerUnit", "InsuranceBalance",
                "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments",
                "BillingOption", "CPTStatus", "CurrentStatus", "PaymentPercent", "BillStatus", "CreatedOn",
                "CreatedBy", "UpdatedOn", "UpdatedBy", "ClaimStatus", "PayStatus", "DaystoDOS",
                "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer", "PaymentPostedDate", "UID",
                "Source", "InsuranceBalance_Decimal", "InsertedDateTime"
            ],
        // WellHealth mandatory LineLevelData columns: Line Level page / Excel, Production and Collection
        // LineLevel sheets (dashboard and ReportWorker downloads). Keep in step with WellHealth_Details.sql.
        ["WellHealth"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "Payer_Code", "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "PayerType", "ReferringProvider",
                "ClaimBillingProviderID", "ClinicName", "Facility", "PatientID", "PatientName", "PatientDOB",
                "DateofService", "ChargeToDate", "ChargeEnteredDate", "FirstBilledDate", "LastBilledDate", "Panelname",
                "ChargePanelID", "CPTCode", "Units", "Modifier", "ClaimCPTs", "CptWithUnits",
                "CPTModifier", "POS", "ChargeAmount", "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit",
                "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment", "PatientPaymentPerUnit", "TotalPayments", "ChargeTotalPayments",
                "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "ChargeTotalAdjustments", "InsuranceBalance", "PatientBalance",
                "PatientBalancePerUnit", "TotalBalance", "TotalInsuranceBalance", "OtherBalance", "BalanceAtCollections", "CheckDate",
                "PostingDate", "PaymentPostedDate", "PayStatus", "DenialCode", "DenialCodeNormalized", "DenialDescription",
                "DenialDate", "ICDCode", "ICDPointer", "DaystoDOS", "RollingDays", "DaystoBill",
                "DaystoPost", "UID"
            ],
        // CoreBio mandatory LineLevelData columns: Line Level page / Excel, Production and Collection
        // LineLevel sheets (dashboard and ReportWorker downloads). Keep in step with CoreBio_Details.sql.
        ["CoreBio"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "PayerType", "ReferringProvider", "ClinicName", "PatientID", "PatientDOB", "DateofService",
                "ChargeEnteredDate", "FirstBilledDate", "Panelname", "CPTCode", "Units", "Modifier",
                "ChargeAmount", "ChargeAmountPerUnit", "AllowedAmount", "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit",
                "PatientPayment", "PatientPaymentPerUnit", "TotalPayments", "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments",
                "InsuranceBalance", "PatientBalance", "PatientBalancePerUnit", "TotalBalance", "CheckDate", "PayStatus",
                "DenialCode", "DenialCodeNormalized", "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS",
                "RollingDays", "DaystoBill", "DaystoPost", "ICDPointer"
            ],
        // TexasDiagnostic mandatory LineLevelData columns: Line Level page / Excel, Production and
        // Collection LineLevel sheets (dashboard and ReportWorker downloads). Keep in step with
        // TexasDiagnostic_Details.sql.
        ["TexasDiagnostic"] =
            [
                "LabID", "LabName", "ClaimID", "AccessionNumber", "PayerName_Raw", "PayerName",
                "PayerType", "BillingProvider", "ReferringProvider", "ClinicName", "PatientID", "PatientDOB",
                "DateofService", "ChargeEnteredDate", "FirstBilledDate", "Panelname", "CPTCode", "Units",
                "Modifier", "POS", "TOS", "ChargeAmount", "ChargeAmountPerUnit", "AllowedAmount",
                "AllowedAmountPerUnit", "InsurancePayment", "InsurancePaymentPerUnit", "PatientPayment", "PatientPaymentPerUnit", "TotalPayments",
                "InsuranceAdjustments", "PatientAdjustments", "TotalAdjustments", "InsuranceBalance", "PatientBalance", "PatientBalancePerUnit",
                "TotalBalance", "CheckDate", "PostingDate", "PayStatus", "DenialCode", "DenialCodeNormalized",
                "DenialDescription", "DenialDate", "ICDCode", "DaystoDOS", "RollingDays", "DaystoBill",
                "DaystoPost"
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
    /// Table columns behind the Payer Type and Clinic filters. VariantX has no PayerType or
    /// ClinicName, so PlanType and Facility stand in (as in Database/LabMetricsDashboard/ClaimLineDetails_SPs/VariantX_Details.sql).
    /// </summary>
    public static (string PayerType, string Clinic) GetFilterColumns(string? labName)
        => string.Equals(NormalizeLab(labName), "VariantX", StringComparison.OrdinalIgnoreCase)
            ? ("PlanType", "Facility")
            : ("PayerType", "ClinicName");

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
        "PayerName", "PayerType", "PlanType", "ClinicName", "Facility", "Panelname", "PanelName",
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
