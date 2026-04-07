using System.Globalization;
using Microsoft.Extensions.Logging;
using RcmWatcherService.Models;

namespace RcmWatcherService.Services;

/// <summary>
/// Parses a Claim Level CSV into a list of <see cref="ClaimRecord"/>.
/// Handles quoted fields with embedded commas.
/// Column order is resolved by header name — tolerant of extra or reordered columns.
/// </summary>
public sealed class CsvParserService
{
    private readonly ILogger<CsvParserService> _logger;

    // Expected header names mapped to ClaimRecord property positions
    private static readonly Dictionary<string, string> HeaderMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["LabID"]                      = nameof(ClaimRecord.LabID),
        ["LabName"]                    = nameof(ClaimRecord.LabName),
        ["ClaimID"]                    = nameof(ClaimRecord.ClaimID),
        ["PayerName"]                  = nameof(ClaimRecord.PayerName),
        ["PayerType"]                  = nameof(ClaimRecord.PayerType),
        ["ClinicName"]                 = nameof(ClaimRecord.ClinicName),
        ["Panelname"]                  = nameof(ClaimRecord.PanelName),
        ["CPT Code X Units X Modifier"]= nameof(ClaimRecord.CPTCodeUnitsModifier),
        ["DateofService"]              = nameof(ClaimRecord.DateOfService),
        ["FirstBilledDate"]            = nameof(ClaimRecord.FirstBilledDate),
        ["ClaimStatus"]                = nameof(ClaimRecord.ClaimStatus),
        ["DenialCode"]                 = nameof(ClaimRecord.DenialCode),
        ["ChargeAmount"]               = nameof(ClaimRecord.ChargeAmount),
        ["AllowedAmount"]              = nameof(ClaimRecord.AllowedAmount),
        ["InsurancePayment"]           = nameof(ClaimRecord.InsurancePayment),
        ["InsuranceAdjustments"]       = nameof(ClaimRecord.InsuranceAdjustments),
        ["PatientAdjustments"]         = nameof(ClaimRecord.PatientAdjustments),
        ["TotalPayments"]              = nameof(ClaimRecord.TotalPayments),
        ["InsuranceBalance"]           = nameof(ClaimRecord.InsuranceBalance),
        ["Total Balance"]              = nameof(ClaimRecord.TotalBalance),
        ["SalesRepname"]               = "SalesRepName",   // ignored but mapped to avoid index errors
    };

    public CsvParserService(ILogger<CsvParserService> logger) => _logger = logger;

    public List<ClaimRecord> ParseClaimLevel(string filePath)
    {
        if (!File.Exists(filePath))
        {
            _logger.LogWarning("Claim Level CSV not found: {Path}", filePath);
            return [];
        }

        var records = new List<ClaimRecord>();

        try
        {
            using var reader = new StreamReader(filePath);

            var headerLine = reader.ReadLine();
            if (headerLine is null) return records;

            var headers = SplitCsvLine(headerLine);

            // Build column-index lookup by header name
            var idx = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < headers.Count; i++)
                idx[headers[i].Trim()] = i;

            while (!reader.EndOfStream)
            {
                var line = reader.ReadLine();
                if (string.IsNullOrWhiteSpace(line)) continue;

                var fields = SplitCsvLine(line);
                var r = MapRow(fields, idx);
                if (r is not null) records.Add(r);
            }

            _logger.LogInformation("Parsed {Count} records from: {File}", records.Count, Path.GetFileName(filePath));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to parse CSV: {Path}", filePath);
        }

        return records;
    }

    private static ClaimRecord? MapRow(List<string> f, Dictionary<string, int> idx)
    {
        if (f.Count == 0) return null;

        return new ClaimRecord
        {
            LabID                = Get(f, idx, "LabID"),
            LabName              = Get(f, idx, "LabName"),
            ClaimID              = Get(f, idx, "ClaimID"),
            PayerName            = Get(f, idx, "PayerName"),
            PayerType            = Get(f, idx, "PayerType"),
            ClinicName           = Get(f, idx, "ClinicName"),
            PanelName            = Get(f, idx, "Panelname"),
            CPTCodeUnitsModifier = Get(f, idx, "CPT Code X Units X Modifier"),
            DateOfService        = Get(f, idx, "DateofService"),
            FirstBilledDate      = Get(f, idx, "FirstBilledDate"),
            ClaimStatus          = Get(f, idx, "ClaimStatus"),
            DenialCode           = Get(f, idx, "DenialCode"),
            ChargeAmount         = GetDecimal(f, idx, "ChargeAmount"),
            AllowedAmount        = GetDecimal(f, idx, "AllowedAmount"),
            InsurancePayment     = GetDecimal(f, idx, "InsurancePayment"),
            InsuranceAdjustments = GetDecimal(f, idx, "InsuranceAdjustments"),
            PatientAdjustments   = GetDecimal(f, idx, "PatientAdjustments"),
            TotalPayments        = GetDecimal(f, idx, "TotalPayments"),
            InsuranceBalance     = GetDecimal(f, idx, "InsuranceBalance"),
            TotalBalance         = GetDecimal(f, idx, "Total Balance"),
        };
    }

    private static string Get(List<string> f, Dictionary<string, int> idx, string col)
        => idx.TryGetValue(col, out var i) && i < f.Count ? f[i] : string.Empty;

    private static decimal GetDecimal(List<string> f, Dictionary<string, int> idx, string col)
    {
        var raw = Get(f, idx, col);
        return decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var v) ? v : 0m;
    }

    private static List<string> SplitCsvLine(string line)
    {
        var fields = new List<string>();
        var sb     = new System.Text.StringBuilder();
        bool inQuote = false;

        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (c == '"')
            {
                if (inQuote && i + 1 < line.Length && line[i + 1] == '"')
                { sb.Append('"'); i++; }
                else
                { inQuote = !inQuote; }
            }
            else if (c == ',' && !inQuote)
            { fields.Add(sb.ToString()); sb.Clear(); }
            else
            { sb.Append(c); }
        }
        fields.Add(sb.ToString());
        return fields;
    }
}
