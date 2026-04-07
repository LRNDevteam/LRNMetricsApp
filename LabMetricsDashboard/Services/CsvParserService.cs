using System.Globalization;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Parses the Claim Level CSV file into a list of ClaimRecord.
/// Handles quoted fields with embedded commas.
/// </summary>
public sealed class CsvParserService
{
    private static readonly string[] ClaimLevelHeaders =
    [
        "LabID", "LabName", "ClaimID", "AccessionNumber", "SourceFileID",
        "IngestedOn", "RowHash", "PayerName_Raw", "PayerName", "Payer_Code",
        "Payer_Common_Code", "Payer_Group_Code", "Global_Payer_ID", "PayerType",
        "BillingProvider", "ReferringProvider", "ClinicName", "SalesRepname",
        "PatientID", "Patient DOB", "DateofService", "ChargeEnteredDate",
        "FirstBilledDate", "Panelname", "CPT Code X Units X Modifier",
        "POS", "TOS", "ChargeAmount", "AllowedAmount", "InsurancePayment",
        "PatientPayment", "TotalPayments", "InsuranceAdjustments",
        "PatientAdjustments", "TotalAdjustments", "InsuranceBalance",
        "PatientBalance", "Total Balance", "CheckDate", "ClaimStatus",
        "DenialCode", "ICDCode", "DaystoDOS", "RollingDays",
        "DaystoBill", "DaystoPost", "ICD Pointer"
    ];

    private readonly ILogger<CsvParserService> _logger;

    public CsvParserService(ILogger<CsvParserService> logger)
    {
        _logger = logger;
    }

    public List<ClaimRecord> ParseClaimLevel(string filePath)
    {
        if (!File.Exists(filePath))
        {
            _logger.LogWarning("Claim Level CSV not found: {FilePath}", filePath);
            return [];
        }

        var records = new List<ClaimRecord>();

        try
        {
            using var reader = new StreamReader(filePath);

            // Skip header row if present
            var firstLine = reader.ReadLine();
            bool hasHeader = firstLine is not null &&
                             firstLine.Contains("LabID", StringComparison.OrdinalIgnoreCase);

            if (!hasHeader && firstLine is not null)
            {
                var record = MapRow(SplitCsvLine(firstLine));
                if (record is not null) records.Add(record);
            }

            while (!reader.EndOfStream)
            {
                var line = reader.ReadLine();
                if (string.IsNullOrWhiteSpace(line)) continue;

                var fields = SplitCsvLine(line);
                var record = MapRow(fields);
                if (record is not null) records.Add(record);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to parse Claim Level CSV: {FilePath}", filePath);
        }

        return records;
    }

    // Splits a CSV line respecting double-quoted fields that may contain commas.
    private static List<string> SplitCsvLine(string line)
    {
        var fields = new List<string>();
        var current = new System.Text.StringBuilder();
        bool inQuotes = false;

        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];

            if (c == '"')
            {
                // Handle escaped quote ("")
                if (inQuotes && i + 1 < line.Length && line[i + 1] == '"')
                {
                    current.Append('"');
                    i++;
                }
                else
                {
                    inQuotes = !inQuotes;
                }
            }
            else if (c == ',' && !inQuotes)
            {
                fields.Add(current.ToString().Trim());
                current.Clear();
            }
            else
            {
                current.Append(c);
            }
        }

        fields.Add(current.ToString().Trim());
        return fields;
    }

    private static ClaimRecord? MapRow(List<string> f)
    {
        if (f.Count < 40) return null;

        return new ClaimRecord
        {
            LabID                  = Get(f, 0),
            LabName                = Get(f, 1),
            ClaimID                = Get(f, 2),
            AccessionNumber        = Get(f, 3),
            SourceFileID           = Get(f, 4),
            IngestedOn             = Get(f, 5),
            RowHash                = Get(f, 6),
            PayerName_Raw          = Get(f, 7),
            PayerName              = Get(f, 8),
            Payer_Code             = Get(f, 9),
            Payer_Common_Code      = Get(f, 10),
            Payer_Group_Code       = Get(f, 11),
            Global_Payer_ID        = Get(f, 12),
            PayerType              = Get(f, 13),
            BillingProvider        = Get(f, 14),
            ReferringProvider      = Get(f, 15),
            ClinicName             = Get(f, 16),
            SalesRepName           = Get(f, 17),
            PatientID              = Get(f, 18),
            PatientDOB             = Get(f, 19),
            DateOfService          = Get(f, 20),
            ChargeEnteredDate      = Get(f, 21),
            FirstBilledDate        = Get(f, 22),
            PanelName              = Get(f, 23),
            CPTCodeUnitsModifier   = Get(f, 24),
            POS                    = Get(f, 25),
            TOS                    = Get(f, 26),
            ChargeAmount           = ParseDecimal(Get(f, 27)),
            AllowedAmount          = ParseDecimal(Get(f, 28)),
            InsurancePayment       = ParseDecimal(Get(f, 29)),
            PatientPayment         = ParseDecimal(Get(f, 30)),
            TotalPayments          = ParseDecimal(Get(f, 31)),
            InsuranceAdjustments   = ParseDecimal(Get(f, 32)),
            PatientAdjustments     = ParseDecimal(Get(f, 33)),
            TotalAdjustments       = ParseDecimal(Get(f, 34)),
            InsuranceBalance       = ParseDecimal(Get(f, 35)),
            PatientBalance         = ParseDecimal(Get(f, 36)),
            TotalBalance           = ParseDecimal(Get(f, 37)),
            CheckDate              = Get(f, 38),
            ClaimStatus            = Get(f, 39),
            DenialCode             = Get(f, 40),
            ICDCode                = Get(f, 41),
            DaysToDOS              = Get(f, 42),
            RollingDays            = Get(f, 43),
            DaysToBill             = Get(f, 44),
            DaysToPost             = Get(f, 45),
            ICDPointer             = Get(f, 46)
        };
    }

    public List<LineRecord> ParseLineLevel(string filePath)
    {
        if (!File.Exists(filePath))
        {
            _logger.LogWarning("Line Level CSV not found: {FilePath}", filePath);
            return [];
        }

        var records = new List<LineRecord>();

        try
        {
            using var reader = new StreamReader(filePath);

            var firstLine = reader.ReadLine();
            bool hasHeader = firstLine is not null &&
                             firstLine.Contains("LabID", StringComparison.OrdinalIgnoreCase);

            if (!hasHeader && firstLine is not null)
            {
                var record = MapLineRow(SplitCsvLine(firstLine));
                if (record is not null) records.Add(record);
            }

            while (!reader.EndOfStream)
            {
                var line = reader.ReadLine();
                if (string.IsNullOrWhiteSpace(line)) continue;

                var record = MapLineRow(SplitCsvLine(line));
                if (record is not null) records.Add(record);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to parse Line Level CSV: {FilePath}", filePath);
        }

        return records;
    }

    // Line Level column layout (0-based):
    // 0  LabID               17 SalesRepname         34 PatientPaymentPerUnit
    // 1  LabName             18 PatientID            35 TotalPayments
    // 2  ClaimID             19 Patient DOB          36 InsuranceAdjustments
    // 3  AccessionNumber     20 DateofService        37 PatientAdjustments
    // 4  SourceFileID        21 ChargeEnteredDate    38 TotalAdjustments
    // 5  IngestedOn          22 FirstBilledDate      39 InsuranceBalance
    // 6  RowHash             23 Panelname            40 PatientBalance
    // 7  PayerName_Raw       24 CPTCode              41 PatientBalancePerUnit
    // 8  PayerName           25 Units                42 Total Balance
    // 9  Payer_Code          26 Modifier             43 CheckDate
    // 10 Payer_Common_Code   27 POS                  44 ClaimStatus
    // 11 Payer_Group_Code    28 TOS                  45 Pay Status
    // 12 Global_Payer_ID     29 ChargeAmount         46 DenialCode
    // 13 PayerType           30 ChargeAmountPerUnit  47 ICDCode
    // 14 BillingProvider     31 AllowedAmount        48 DaystoDOS
    // 15 ReferringProvider   32 AllowedAmountPerUnit 49 RollingDays
    // 16 ClinicName          33 InsurancePayment     50 DaystoBill
    //                           InsurancePaymentPerUnit 51 DaystoPost
    //                           PatientPayment          52 ICD Pointer
    private static LineRecord? MapLineRow(List<string> f)
    {
        if (f.Count < 45) return null;

        return new LineRecord
        {
            LabID                   = Get(f, 0),
            LabName                 = Get(f, 1),
            ClaimID                 = Get(f, 2),
            AccessionNumber         = Get(f, 3),
            SourceFileID            = Get(f, 4),
            IngestedOn              = Get(f, 5),
            RowHash                 = Get(f, 6),
            PayerName_Raw           = Get(f, 7),
            PayerName               = Get(f, 8),
            Payer_Code              = Get(f, 9),
            Payer_Common_Code       = Get(f, 10),
            Payer_Group_Code        = Get(f, 11),
            Global_Payer_ID         = Get(f, 12),
            PayerType               = Get(f, 13),
            BillingProvider         = Get(f, 14),
            ReferringProvider       = Get(f, 15),
            ClinicName              = Get(f, 16),
            SalesRepName            = Get(f, 17),
            PatientID               = Get(f, 18),
            PatientDOB              = Get(f, 19),
            DateOfService           = Get(f, 20),
            ChargeEnteredDate       = Get(f, 21),
            FirstBilledDate         = Get(f, 22),
            PanelName               = Get(f, 23),
            CPTCode                 = NormalizeCptCode(Get(f, 24)),
            Units                   = ParseDecimal(Get(f, 25)),
            Modifier                = Get(f, 26),
            POS                     = Get(f, 27),
            TOS                     = Get(f, 28),
            ChargeAmount            = ParseDecimal(Get(f, 29)),
            ChargeAmountPerUnit     = ParseDecimal(Get(f, 30)),
            AllowedAmount           = ParseDecimal(Get(f, 31)),
            AllowedAmountPerUnit    = ParseDecimal(Get(f, 32)),
            InsurancePayment        = ParseDecimal(Get(f, 33)),
            InsurancePaymentPerUnit = ParseDecimal(Get(f, 34)),
            PatientPayment          = ParseDecimal(Get(f, 35)),
            PatientPaymentPerUnit   = ParseDecimal(Get(f, 36)),
            TotalPayments           = ParseDecimal(Get(f, 37)),
            InsuranceAdjustments    = ParseDecimal(Get(f, 38)),
            PatientAdjustments      = ParseDecimal(Get(f, 39)),
            TotalAdjustments        = ParseDecimal(Get(f, 40)),
            InsuranceBalance        = ParseDecimal(Get(f, 41)),
            PatientBalance          = ParseDecimal(Get(f, 42)),
            PatientBalancePerUnit   = ParseDecimal(Get(f, 43)),
            TotalBalance            = ParseDecimal(Get(f, 44)),
            CheckDate               = Get(f, 45),
            ClaimStatus             = Get(f, 46),
            PayStatus               = Get(f, 47),
            DenialCode              = Get(f, 48),
            ICDCode                 = Get(f, 49),
            DaysToDOS               = Get(f, 50),
            RollingDays             = Get(f, 51),
            DaysToBill              = Get(f, 52),
            DaysToPost              = Get(f, 53),
            ICDPointer              = Get(f, 54)
        };
    }

    private static string NormalizeCptCode(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return value;
        // Some labs export CPT codes as decimals e.g. "84443.00" ? "84443"
        if (decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
            return ((long)d).ToString(CultureInfo.InvariantCulture);
        return value.Trim();
    }

    private static string Get(List<string> fields, int index) =>
        index < fields.Count ? fields[index] : string.Empty;

    private static decimal ParseDecimal(string value) =>
        decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var result)
            ? result : 0m;
}
