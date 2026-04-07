using ClosedXML.Excel;
using CaptureDataApp.Models;

namespace CaptureDataApp.Services;

/// <summary>
/// Reads a CodingValidated Excel report and extracts:
///   • All detail rows from the "CodingValidated" sheet
///   • The financial summary block from the "Financial Dashboard" sheet
/// </summary>
public static class CodingReportExcelReader
{
    private const string DetailSheet    = "CodingValidated";
    private const string DashboardSheet = "Financial Dashboard";

    // ?? Public API ????????????????????????????????????????????????????????????

    public static (List<CodingValidationRow> Rows, CodingFinancialSummary Summary)
        Read(string filePath, string labName, string weekFolder)
    {
        if (!File.Exists(filePath))
            throw new FileNotFoundException($"Report file not found: {filePath}");

        using var wb = new XLWorkbook(filePath);

        var rows    = ReadDetailRows(wb, filePath, labName, weekFolder);
        var summary = ReadFinancialSummary(wb, filePath, labName, weekFolder);

        return (rows, summary);
    }

    // ?? Detail rows (CodingValidated sheet) ???????????????????????????????????

    private static List<CodingValidationRow> ReadDetailRows(
        XLWorkbook wb, string filePath, string labName, string weekFolder)
    {
        var rows = new List<CodingValidationRow>();

        if (!wb.TryGetWorksheet(DetailSheet, out var ws))
        {
            Console.WriteLine($"  [WARN] Sheet '{DetailSheet}' not found in {Path.GetFileName(filePath)}");
            return rows;
        }

        // Build header ? column index map from row 1
        var firstRow = ws.FirstRowUsed();
        if (firstRow is null) return rows;

        var headers = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var cell in firstRow.CellsUsed())
            headers[cell.Value.ToString().Trim()] = cell.Address.ColumnNumber;

        // Derive metadata from filename:  {RunId}_{LabName}_CodingValidated_{WeekFolder}.xlsx
        // RunId is everything before the first underscore (e.g. "20260316R0215").
        var fileNameNoExt = Path.GetFileNameWithoutExtension(filePath);
        var runId         = fileNameNoExt.Split('_')[0];    // "20260316R0215"
        var fileLogId     = fileNameNoExt;                  // full name kept on the row for traceability

        var lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
        for (int r = 2; r <= lastRow; r++)
        {
            var row = ws.Row(r);
            if (row.IsEmpty()) continue;

            rows.Add(new CodingValidationRow
            {
                FileLogId        = runId,        // short prefix: "20260316R0215"
                WeekFolder       = weekFolder,
                SourceFilePath   = filePath,
                RunNumber        = fileLogId,    // full filename (without extension) kept for traceability
                VisitNumber      = Get(row, headers, "VisitNumber"),
                AccessionNo      = Get(row, headers, "AccessionNo"),
                PayerName_Raw    = Get(row, headers, "PayerName_Raw"),
                Carrier          = Get(row, headers, "Carrier"),
                Payer_Code       = Get(row, headers, "Payer_Code"),
                PayerCommonCode  = Get(row, headers, "PayerCommonCode"),
                Payer_Group_Code = Get(row, headers, "Payer_Group_Code"),
                Global_Payer_ID  = Get(row, headers, "Global_Payer_ID"),
                PayerType        = Get(row, headers, "PayerType"),
                BillingProvider  = Get(row, headers, "BillingProvider"),
                ReferringProvider = Get(row, headers, "ReferringProvider"),
                ClinicName       = Get(row, headers, "ClinicName"),
                SalesRepname     = Get(row, headers, "SalesRepname"),
                PatientID        = Get(row, headers, "PatientID"),
                PatientDOB       = Get(row, headers, "PatientDOB"),
                DateofService    = Get(row, headers, "DateofService"),
                ChargeEnteredDate = Get(row, headers, "ChargeEnteredDate"),
                FirstBillDate    = Get(row, headers, "FirstBillDate"),
                PanelName        = Get(row, headers, "PanelName"),
                POS              = Get(row, headers, "POS"),
                TOS              = Get(row, headers, "TOS"),
                TotalCharge      = Get(row, headers, "TotalCharge"),
                AllowedAmount    = Get(row, headers, "AllowedAmount"),
                InsurancePayment = Get(row, headers, "InsurancePayment"),
                PatientPayment   = Get(row, headers, "PatientPayment"),
                TotalPayments    = Get(row, headers, "TotalPayments"),
                InsuranceAdjustments = Get(row, headers, "InsuranceAdjustments"),
                PatientAdjustments   = Get(row, headers, "PatientAdjustments"),
                TotalAdjustments     = Get(row, headers, "TotalAdjustments"),
                InsuranceBalance     = Get(row, headers, "InsuranceBalance"),
                PatientBalance       = Get(row, headers, "PatientBalance"),
                TotalBalance         = Get(row, headers, "TotalBalance"),
                CheckDate            = Get(row, headers, "CheckDate"),
                ClaimStatus          = Get(row, headers, "ClaimStatus"),
                DenialCode           = Get(row, headers, "DenialCode"),
                ICDCode              = Get(row, headers, "ICDCode"),
                DaystoDOS            = Get(row, headers, "DaystoDOS"),
                RollingDays          = Get(row, headers, "RollingDays"),
                DaystoBill           = Get(row, headers, "DaystoBill"),
                DaystoPost           = Get(row, headers, "DaystoPost"),
                ICDPointer           = Get(row, headers, "ICDPointer"),
                ActualCPTCode        = Get(row, headers, "ActualCPTCode"),
                ExpectedCPTCode      = Get(row, headers, "ExpectedCPTCode"),
                MissingCPTCodes      = Get(row, headers, "MissingCPTCodes"),
                AdditionalCPTCodes   = Get(row, headers, "AdditionalCPTCodes"),
                MissingCPT_Charges   = Get(row, headers, "Missing CPT (Charge)"),
                MissingCPT_ChargeSource    = Get(row, headers, "MissingCPT_ChargeSource"),
                AdditionalCPT_Charges      = Get(row, headers, "Additional CPT (Charges)"),
                AdditionalCPT_ChargeSource = Get(row, headers, "AdditionalCPT_ChargeSource"),
                ExpectedCharges      = Get(row, headers, "Expected Charges"),
                ValidationStatus     = Get(row, headers, "Validation Status"),
                Remarks              = Get(row, headers, "Remarks"),
                MissingCPT_AvgAllowedAmount               = Get(row, headers, "MissingCPT_AvgAllowedAmount"),
                MissingCPT_AvgPaidAmount                  = Get(row, headers, "MissingCPT_AvgPaidAmount"),
                MissingCPT_AvgPatientResponsibilityAmount  = Get(row, headers, "MissingCPT_AvgPatientResponsibilityAmount"),
                AdditionalCPT_AvgAllowedAmount             = Get(row, headers, "AdditionalCPT_AvgAllowedAmount"),
                AdditionalCPT_AvgPaidAmount                = Get(row, headers, "AdditionalCPT_AvgPaidAmount"),
                AdditionalCPT_AvgPatientResponsibilityAmount = Get(row, headers, "AdditionalCPT_AvgPatientResponsibilityAmount"),
                LabID    = Get(row, headers, "LabID"),
                LabName  = string.IsNullOrWhiteSpace(Get(row, headers, "LabName")) ? labName : Get(row, headers, "LabName"),
            });
        }

        return rows;
    }

    // ?? Financial Dashboard sheet (key-value blocks) ??????????????????????????

    private static CodingFinancialSummary ReadFinancialSummary(
        XLWorkbook wb, string filePath, string labName, string weekFolder)
    {
        var summary = new CodingFinancialSummary
        {
            LabName        = labName,
            WeekFolder     = weekFolder,
            SourceFilePath = filePath,
        };

        if (!wb.TryGetWorksheet(DashboardSheet, out var ws))
        {
            Console.WriteLine($"  [WARN] Sheet '{DashboardSheet}' not found in {Path.GetFileName(filePath)}");
            return summary;
        }

        // Read all non-empty rows into a flat list of (row, col, value) for pattern matching
        var cellMap = new Dictionary<(int r, int c), string>();
        foreach (var cell in ws.CellsUsed())
        {
            var v = cell.Value.ToString().Trim();
            if (!string.IsNullOrWhiteSpace(v))
                cellMap[(cell.Address.RowNumber, cell.Address.ColumnNumber)] = v;
        }

        // Helper: get value at (r,c)
        string Val(int r, int c) => cellMap.TryGetValue((r, c), out var v) ? v : string.Empty;

        // Scan rows to find section anchors by label text
        foreach (var kv in cellMap)
        {
            var (r, c) = kv.Key;
            var label  = kv.Value;

            if (label.StartsWith("Report Date", StringComparison.OrdinalIgnoreCase))
            {
                summary.ReportDate = label.Replace("Report Date:", "").Trim();
                continue;
            }

            // Row 5: header  ? row 6: values  (Totals block)
            if (label == "Total No. of Claims" && Val(r + 1, c) is { Length: > 0 } tc)
            {
                if (summary.TotalClaims is null && int.TryParse(tc, out var n))
                {
                    summary.TotalClaims          = n;
                    summary.TotalBilledCharges   = ParseDec(Val(r + 1, c + 1));
                    summary.ExpectedBilledCharges = ParseDec(Val(r + 1, c + 2));
                }
                continue;
            }

            // Revenue Impact header row
            if (label == "Revenue Impact")
            {
                summary.RevenueImpact_Claims        = ParseInt(Val(r + 2, c));
                summary.RevenueImpact_ActualBilled   = ParseDec(Val(r + 2, c + 1));
                summary.RevenueImpact_PotentialLoss  = ParseDec(Val(r + 2, c + 2));
                summary.RevenueImpact_ExpectedRecoup = ParseDec(Val(r + 2, c + 3));
                continue;
            }

            // Revenue Loss header row
            if (label == "Revenue Loss")
            {
                summary.RevenueLoss_Claims        = ParseInt(Val(r + 2, c));
                summary.RevenueLoss_ActualBilled   = ParseDec(Val(r + 2, c + 1));
                summary.RevenueLoss_PotentialLoss  = ParseDec(Val(r + 2, c + 2));
                continue;
            }

            // Revenue at Risk header row
            if (label == "Revenue at Risk")
            {
                summary.RevenueAtRisk_Claims          = ParseInt(Val(r + 2, c));
                summary.RevenueAtRisk_ActualBilled     = ParseDec(Val(r + 2, c + 1));
                summary.RevenueAtRisk_PotentialRecoup  = ParseDec(Val(r + 2, c + 2));
                continue;
            }

            // Compliance Rate header row
            if (label == "Compliance Rate" && summary.Compliance_TotalClaims is null)
            {
                summary.Compliance_TotalClaims      = ParseInt(Val(r + 2, c));
                summary.Compliance_ClaimsWithIssues = ParseInt(Val(r + 2, c + 1));
                summary.ComplianceRate              = Val(r + 2, c + 2);
                continue;
            }

            // Detail breakdown rows
            if (label == "Claims with Issues")
            {
                summary.ClaimsWithMissingCPTs              = ParseInt(Val(r + 1, c + 1));
                summary.ClaimsWithAdditionalCPTs           = ParseInt(Val(r + 2, c + 1));
                summary.ClaimsWithBothMissingAndAdditional = ParseInt(Val(r + 3, c + 1));
                summary.TotalErrorClaims                   = ParseInt(Val(r + 4, c + 1));
                continue;
            }

            if (label == "Compliance Rate" && summary.ComplianceRatePct == string.Empty)
            {
                summary.ComplianceRatePct = Val(r, c + 1);
                continue;
            }
        }

        return summary;
    }

    // ?? Helpers ???????????????????????????????????????????????????????????????

    private static string Get(IXLRow row, Dictionary<string, int> headers, string col)
    {
        if (!headers.TryGetValue(col, out var colIdx)) return string.Empty;
        var cell = row.Cell(colIdx);
        return cell.IsEmpty() ? string.Empty : cell.Value.ToString().Trim();
    }

    private static int? ParseInt(string s)
        => int.TryParse(s.Replace(",", ""), out var v) ? v : null;

    private static decimal? ParseDec(string s)
    {
        s = s.Replace(",", "").Replace("%", "").Trim();
        return decimal.TryParse(s, System.Globalization.NumberStyles.Any,
            System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : null;
    }
}
