using DenialDatabaseProcessorWorker.Models;
using System.Data;
using System.Globalization;

namespace DenialDatabaseProcessorWorker.Builders
{
    public static class DenialLineItemTableBuilder
    {
        private sealed class ColumnMap
        {
            public string ExcelColumn { get; init; } = "";
            public string SqlColumn { get; init; } = "";
            public string DataType { get; init; } = "";
        }

        private static readonly List<ColumnMap> _columns = new()
        {
            new() { ExcelColumn = "Accession No", SqlColumn = "AccessionNo", DataType = "string" },
            new() { ExcelColumn = "Visit Number", SqlColumn = "VisitNumber", DataType = "string" },
            new() { ExcelColumn = "ClaimUID", SqlColumn = "ClaimUID", DataType = "string" },
            new() { ExcelColumn = "CPTCode", SqlColumn = "CPTCode", DataType = "string" },
            new() { ExcelColumn = "Patient DOB", SqlColumn = "PatientDOB", DataType = "date" },
            new() { ExcelColumn = "Payer Code", SqlColumn = "PayerCode", DataType = "int" },
            new() { ExcelColumn = "Payer Name", SqlColumn = "PayerName", DataType = "string" },
            new() { ExcelColumn = "PayerName Normalized", SqlColumn = "PayerNameNormalized", DataType = "string" },
            new() { ExcelColumn = "Pay Status", SqlColumn = "PayStatus", DataType = "string" },
            new() { ExcelColumn = "Historical Payment", SqlColumn = "HistoricalPayment", DataType = "string" },
            new() { ExcelColumn = "Historical Paid Line-Item Count", SqlColumn = "HistoricalPaidLineItemCount", DataType = "string" },
            new() { ExcelColumn = "Historical Payment Confidence Score", SqlColumn = "HistoricalPaymentConfidenceScore", DataType = "string" },
            new() { ExcelColumn = "Total Line-Item Count", SqlColumn = "TotalLineItemCount", DataType = "int" },
            new() { ExcelColumn = "Paid Line-Item Count", SqlColumn = "PaidLineItemCount", DataType = "int" },
            new() { ExcelColumn = "% Paid Line-Item Count", SqlColumn = "PaidLineItemCountPercent", DataType = "decimal" },
            new() { ExcelColumn = "Payer Type", SqlColumn = "PayerType", DataType = "string" },
            new() { ExcelColumn = "PayerFound in Policy", SqlColumn = "PayerFoundInPolicy", DataType = "string" },
            new() { ExcelColumn = "Date of Service", SqlColumn = "DateOfService", DataType = "date" },
            new() { ExcelColumn = "First Billed Date", SqlColumn = "FirstBilledDate", DataType = "date" },
            new() { ExcelColumn = "Panel Name", SqlColumn = "PanelName", DataType = "string" },
            new() { ExcelColumn = "LIS ICD 10 Codes", SqlColumn = "LISICD10Codes", DataType = "string" },
            new() { ExcelColumn = "CCW ICD10Code", SqlColumn = "CCWICD10Code", DataType = "string" },
            new() { ExcelColumn = "Units", SqlColumn = "Units", DataType = "int" },
            new() { ExcelColumn = "Modifier", SqlColumn = "Modifier", DataType = "string" },
            new() { ExcelColumn = "DenialCode_Original", SqlColumn = "DenialCodeOriginal", DataType = "string" },
            new() { ExcelColumn = "DenialCode_Normalized", SqlColumn = "DenialCodeNormalized", DataType = "string" },
            new() { ExcelColumn = "Denial Description", SqlColumn = "DenialDescription", DataType = "string" },
            new() { ExcelColumn = "Billed Amount", SqlColumn = "BilledAmount", DataType = "decimal" },
            new() { ExcelColumn = "Allowed Amount", SqlColumn = "AllowedAmount", DataType = "decimal" },
            new() { ExcelColumn = "Insurance Payment", SqlColumn = "InsurancePayment", DataType = "decimal" },
            new() { ExcelColumn = "Insurance Adjustment", SqlColumn = "InsuranceAdjustment", DataType = "decimal" },
            new() { ExcelColumn = "Patient Paid Amount", SqlColumn = "PatientPaidAmount", DataType = "decimal" },
            new() { ExcelColumn = "Patient Adjustment", SqlColumn = "PatientAdjustment", DataType = "decimal" },
            new() { ExcelColumn = "Insurance Balance", SqlColumn = "InsuranceBalance", DataType = "decimal" },
            new() { ExcelColumn = "Patient Balance", SqlColumn = "PatientBalance", DataType = "decimal" },
            new() { ExcelColumn = "Total Balance", SqlColumn = "TotalBalance", DataType = "decimal" },
            new() { ExcelColumn = "Medicare Fee", SqlColumn = "MedicareFee", DataType = "decimal" },
            new() { ExcelColumn = "Final Claim Status", SqlColumn = "FinalClaimStatus", DataType = "string" },
            new() { ExcelColumn = "Covered ICD 10 Codes Billed", SqlColumn = "CoveredICD10CodesBilled", DataType = "string" },
            new() { ExcelColumn = "Non Covered ICD 10 Codes Billed", SqlColumn = "NonCoveredICD10CodesBilled", DataType = "string" },
            new() { ExcelColumn = "Billed ICD codes not available in Payer Policy", SqlColumn = "BilledICDCodesNotAvailableInPayerPolicy", DataType = "string" },
            new() { ExcelColumn = "Coverage Status", SqlColumn = "CoverageStatus", DataType = "string" },
            new() { ExcelColumn = "Final Coverage Status", SqlColumn = "FinalCoverageStatus", DataType = "string" },
            new() { ExcelColumn = "Covered ICD 10 codes as per Payer Policy", SqlColumn = "CoveredICD10CodesAsPerPayerPolicy", DataType = "string" },
            new() { ExcelColumn = "Non Covered ICD 10 Codes as per Payer Policy", SqlColumn = "NonCoveredICD10CodesAsPerPayerPolicy", DataType = "string" },
            new() { ExcelColumn = "Action Comment", SqlColumn = "ActionComment", DataType = "string" },
            new() { ExcelColumn = "Resolution", SqlColumn = "Resolution", DataType = "string" },
            new() { ExcelColumn = "Coding Validation", SqlColumn = "CodingValidation", DataType = "string" },
            new() { ExcelColumn = "Coding Validation Sub-Status", SqlColumn = "CodingValidationSubStatus", DataType = "string" },
            new() { ExcelColumn = "ICD Compliance Status", SqlColumn = "ICDComplianceStatus", DataType = "string" },
            new() { ExcelColumn = "ICD Compliance Substatus", SqlColumn = "ICDComplianceSubstatus", DataType = "string" },
            new() { ExcelColumn = "ICD Primary Indicator Available", SqlColumn = "ICDPrimaryIndicatorAvailable", DataType = "string" },
            new() { ExcelColumn = "Covered ICD Presence", SqlColumn = "CoveredICDPresence", DataType = "string" },
            new() { ExcelColumn = "ICD Validation Confidence", SqlColumn = "ICDValidationConfidence", DataType = "string" },
            new() { ExcelColumn = "Frequency Condition Met", SqlColumn = "FrequencyConditionMet", DataType = "string" },
            new() { ExcelColumn = "Gender Condition Met", SqlColumn = "GenderConditionMet", DataType = "string" },
            new() { ExcelColumn = "Payability", SqlColumn = "Payability", DataType = "string" },
            new() { ExcelColumn = "Forecasting Payability", SqlColumn = "ForecastingPayability", DataType = "string" },
            new() { ExcelColumn = "Policy Coverage Expectation", SqlColumn = "PolicyCoverageExpectation", DataType = "string" },
            new() { ExcelColumn = "Denial Validity", SqlColumn = "DenialValidity", DataType = "string" },
            new() { ExcelColumn = "Coverage Expectation Remarks", SqlColumn = "CoverageExpectationRemarks", DataType = "string" },
            new() { ExcelColumn = "Expected Average Allowed Amount", SqlColumn = "ExpectedAverageAllowedAmount", DataType = "decimal" },
            new() { ExcelColumn = "Expected Average Insurance Payment", SqlColumn = "ExpectedAverageInsurancePayment", DataType = "decimal" },
            new() { ExcelColumn = "Expected Allowed Amount - Same Lab", SqlColumn = "ExpectedAllowedAmountSameLab", DataType = "decimal" },
            new() { ExcelColumn = "Expected Insurance Payment - Same Lab", SqlColumn = "ExpectedInsurancePaymentSameLab", DataType = "decimal" },
            new() { ExcelColumn = "Mode Allowed Amount - Same Lab", SqlColumn = "ModeAllowedAmountSameLab", DataType = "decimal" },
            new() { ExcelColumn = "Mode Insurance Paid - Same Lab", SqlColumn = "ModeInsurancePaidSameLab", DataType = "decimal" },
            new() { ExcelColumn = "Mode Allowed Amount- Peer", SqlColumn = "ModeAllowedAmountPeer", DataType = "decimal" },
            new() { ExcelColumn = "Mode Insurance Paid - Peer", SqlColumn = "ModeInsurancePaidPeer", DataType = "decimal" },
            new() { ExcelColumn = "Median Allowed Amount- Same Lab", SqlColumn = "MedianAllowedAmountSameLab", DataType = "decimal" },
            new() { ExcelColumn = "Median Insurance Paid - Same Lab", SqlColumn = "MedianInsurancePaidSameLab", DataType = "decimal" },
            new() { ExcelColumn = "Median Allowed Amount- Peer", SqlColumn = "MedianAllowedAmountPeer", DataType = "decimal" },
            new() { ExcelColumn = "Median Insurance Paid - Peer", SqlColumn = "MedianInsurancePaidPeer", DataType = "decimal" },
            new() { ExcelColumn = "Mode Allowed Amount Difference", SqlColumn = "ModeAllowedAmountDifference", DataType = "decimal" },
            new() { ExcelColumn = "Mode Insurance Paid Difference", SqlColumn = "ModeInsurancePaidDifference", DataType = "decimal" },
            new() { ExcelColumn = "Median Allowed Amount Difference", SqlColumn = "MedianAllowedAmountDifference", DataType = "decimal" },
            new() { ExcelColumn = "Median Insurance Paid Difference", SqlColumn = "MedianInsurancePaidDifference", DataType = "decimal" },
            new() { ExcelColumn = "Denial Rate", SqlColumn = "DenialRate", DataType = "decimal" },
            new() { ExcelColumn = "Adjustment Rate", SqlColumn = "AdjustmentRate", DataType = "decimal" },
            new() { ExcelColumn = "Payment Days", SqlColumn = "PaymentDays", DataType = "int" },
            new() { ExcelColumn = "Expected Payment Date", SqlColumn = "ExpectedPaymentDate", DataType = "date" },
            new() { ExcelColumn = "Expected Payment Month", SqlColumn = "ExpectedPaymentMonth", DataType = "string" },
            new() { ExcelColumn = "BillingProvider", SqlColumn = "BillingProvider", DataType = "string" },
            new() { ExcelColumn = "ReferringProvider", SqlColumn = "ReferringProvider", DataType = "string" },
            new() { ExcelColumn = "ClinicName", SqlColumn = "ClinicName", DataType = "string" },
            new() { ExcelColumn = "SalesRepname", SqlColumn = "SalesRepname", DataType = "string" },
            new() { ExcelColumn = "PatientID", SqlColumn = "PatientID", DataType = "string" },
            new() { ExcelColumn = "Source", SqlColumn = "Source", DataType = "string" },
            new() { ExcelColumn = "Pat name", SqlColumn = "PatName", DataType = "string" },
            new() { ExcelColumn = "Subscriber Id", SqlColumn = "SubscriberId", DataType = "string" },
            new() { ExcelColumn = "Patient Name", SqlColumn = "PatientName", DataType = "string" },
            new() { ExcelColumn = "ChargeEnteredDate", SqlColumn = "ChargeEnteredDate", DataType = "date" },
            new() { ExcelColumn = "POS", SqlColumn = "POS", DataType = "string" },
            new() { ExcelColumn = "TOS", SqlColumn = "TOS", DataType = "string" },
            new() { ExcelColumn = "CheckDate", SqlColumn = "CheckDate", DataType = "date" },
            new() { ExcelColumn = "DaystoDOS", SqlColumn = "DaystoDOS", DataType = "int" },
            new() { ExcelColumn = "RollingDays", SqlColumn = "RollingDays", DataType = "string" },
            new() { ExcelColumn = "DaystoBill", SqlColumn = "DaystoBill", DataType = "int" },
            new() { ExcelColumn = "DaystoPost", SqlColumn = "DaystoPost", DataType = "int" },
            new() { ExcelColumn = "Denial Classification", SqlColumn = "DenialClassification", DataType = "string" },
            new() { ExcelColumn = "Denial Type", SqlColumn = "DenialType", DataType = "string" },
            new() { ExcelColumn = "Action Category", SqlColumn = "ActionCategory", DataType = "string" },
            new() { ExcelColumn = "Action Code", SqlColumn = "ActionCode", DataType = "string" },
            new() { ExcelColumn = "Recommended Action", SqlColumn = "RecommendedAction", DataType = "string" },
            new() { ExcelColumn = "Task Guidance", SqlColumn = "TaskGuidance", DataType = "string" },
            new() { ExcelColumn = "Denial Date", SqlColumn = "DenialDate", DataType = "date" },
            new() { ExcelColumn = "Task Status", SqlColumn = "TaskStatus", DataType = "string" },
            new() { ExcelColumn = "Assigned To", SqlColumn = "AssignedTo", DataType = "string" },
            new() { ExcelColumn = "WorkFlowStatus", SqlColumn = "WorkFlowStatus", DataType = "string" },
            new() { ExcelColumn = "ClaimFrom", SqlColumn = "ClaimFrom", DataType = "string" },
            new() { ExcelColumn = "Short Category", SqlColumn = "ShortCategory", DataType = "string" },
            new() { ExcelColumn = "Priority", SqlColumn = "Priority", DataType = "string" },
            new() { ExcelColumn = "SLA (Days)", SqlColumn = "SLADays", DataType = "string" },
            new() { ExcelColumn = "Notes / Comments", SqlColumn = "NotesComments", DataType = "string" },
            new() { ExcelColumn = "LabId", SqlColumn = "LabId", DataType = "int" },
            new() { ExcelColumn = "LabName", SqlColumn = "LabName", DataType = "string" },
            new() { ExcelColumn = "RunId", SqlColumn = "RunId", DataType = "string" },
            new() { ExcelColumn = "CreatedOn", SqlColumn = "CreatedOn", DataType = "datetime" }
        };


        private static string NormalizeIdentifier(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return string.Empty;

            value = value.Trim();

            if (value.EndsWith(".00", StringComparison.OrdinalIgnoreCase))
                value = value[..^3];

            if (decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var number))
            {
                if (number == Math.Truncate(number))
                    return ((long)number).ToString(CultureInfo.InvariantCulture);
            }

            return value;
        }

        public static DataTable Build(List<Dictionary<string, string>> excelRows, LabConfig lab, string runid)
        {
            var table = new DataTable("DenialLineItem");

            foreach (var col in _columns)
            {
                var type = col.DataType.ToLowerInvariant() switch
                {
                    "int" => typeof(int),
                    "decimal" => typeof(decimal),
                    "date" => typeof(DateTime),
                    "datetime" => typeof(DateTime),
                    _ => typeof(string)
                };

                table.Columns.Add(col.SqlColumn, type);
            }

            foreach (var row in excelRows)
            {
                var dr = table.NewRow();

                foreach (var col in _columns)
                {
                    if (col.SqlColumn == "LabId")
                        dr[col.SqlColumn] = lab.LabId;
                    else if (col.SqlColumn == "LabName")
                        dr[col.SqlColumn] = lab.LabName;
                    else if (col.SqlColumn == "RunId")
                        dr[col.SqlColumn] = runid;
                    else if (col.SqlColumn == "ClaimFrom")
                        dr[col.SqlColumn] = "Current Run";
                    else
                    {
                        row.TryGetValue(col.ExcelColumn, out var raw);
                        raw = raw?.Trim();

                        if (string.IsNullOrWhiteSpace(raw))
                        {
                            dr[col.SqlColumn] = DBNull.Value;
                            continue;
                        }


                        // Remove trailing .00 from identifier-style fields
                        if (col.SqlColumn is "VisitNumber" or "AccessionNo" or "PatientID")
                        {
                            raw = NormalizeIdentifier(raw);
                        }

                        switch (col.DataType.ToLowerInvariant())
                        {
                            case "int":
                                if (DateTime.TryParse(raw, out _))
                                {
                                    dr[col.SqlColumn] = DBNull.Value;
                                }
                                else if (int.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var i))
                                {
                                    dr[col.SqlColumn] = i;
                                }
                                else
                                {
                                    dr[col.SqlColumn] = DBNull.Value;
                                }
                                break;

                            case "decimal":
                                var cleaned = raw.Replace("%", "");
                                if (decimal.TryParse(cleaned, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
                                    dr[col.SqlColumn] = d;
                                else
                                    dr[col.SqlColumn] = DBNull.Value;
                                break;

                            case "date":
                            case "datetime":
                                // Guard month-like tokens (Apr'25, Feb'25, etc.)
                                var monthLike =
                                    raw.Contains('\'') ||
                                    (!raw.Contains('/') && raw.Length <= 7);

                                if (monthLike)
                                {
                                    dr[col.SqlColumn] = DBNull.Value;
                                    break;
                                }

                                if (DateTime.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var dt) ||
                                    DateTime.TryParse(raw, CultureInfo.CurrentCulture, DateTimeStyles.AllowWhiteSpaces, out dt))
                                {
                                    dr[col.SqlColumn] = dt;
                                }
                                else
                                {
                                    dr[col.SqlColumn] = DBNull.Value;
                                }
                                break;

                            default:
                                dr[col.SqlColumn] = raw;
                                break;
                        }
                    }
                }

                table.Rows.Add(dr);
            }

            return table;
        }
    }
}
