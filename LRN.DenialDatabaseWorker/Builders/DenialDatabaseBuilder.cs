using DenialDatabaseProcessorWorker.Normalizers;
using DenialDatabaseProcessorWorker.Services;

namespace DenialDatabaseProcessorWorker.Builders;
public sealed class DenialDatabaseBuilder
{
    private readonly DenialCodeNormalizer _normalizer;

    public DenialDatabaseBuilder(DenialCodeNormalizer normalizer)
    {
        _normalizer = normalizer;
    }

    public (List<string> Headers, List<Dictionary<string, string>> Rows) Build(
        List<Dictionary<string, string>> payerPolicyRows,
        ClaimActionMapperIndex claimMapperIndex,
        string denialCodeHeader = "DenialCode")
    {
        if (payerPolicyRows == null || payerPolicyRows.Count == 0)
            return (new List<string>(), payerPolicyRows ?? new List<Dictionary<string, string>>());

        var baseHeaders = payerPolicyRows[0].Keys.ToList();
        var denialCodeKey = ResolveHeaderKey(baseHeaders, denialCodeHeader);

        var finalHeaders = new List<string>(baseHeaders);

        // Insert normalized code columns
        var denialIdx = finalHeaders.FindIndex(h => string.Equals(h, denialCodeKey, StringComparison.OrdinalIgnoreCase));
        if (denialIdx >= 0)
        {
            InsertIfMissing(finalHeaders, denialIdx + 1, "DenialCode_Original");
            InsertIfMissing(finalHeaders, denialIdx + 2, "DenialCode_Normalized");
        }
        else
        {
            AddIfMissing(finalHeaders, "DenialCode_Original");
            AddIfMissing(finalHeaders, "DenialCode_Normalized");
        }

        // Add mapped columns
        AddIfMissing(finalHeaders, "Denial Description");
        AddIfMissing(finalHeaders, "Denial Classification");
        AddIfMissing(finalHeaders, "Denial Type");
        AddIfMissing(finalHeaders, "Denial Validity");
        AddIfMissing(finalHeaders, "Action Category");
        AddIfMissing(finalHeaders, "Action Code");
        AddIfMissing(finalHeaders, "Status Action Code");
        AddIfMissing(finalHeaders, "Recommended Action");
        AddIfMissing(finalHeaders, "Task Guidance");
        AddIfMissing(finalHeaders, "Task Status");
        AddIfMissing(finalHeaders, "Short Category");
        AddIfMissing(finalHeaders, "Priority");
        AddIfMissing(finalHeaders, "SLA (Days)");
        AddIfMissing(finalHeaders, "Notes / Comments");

        foreach (var row in payerPolicyRows)
        {
            // Normalize denial code
            row.TryGetValue(denialCodeKey, out var rawDenialCode);
            rawDenialCode ??= "";
            var codes = _normalizer.SplitToCodes(rawDenialCode);
            var normalized = string.Join(";", codes);

            row["DenialCode_Original"] = rawDenialCode;
            row["DenialCode_Normalized"] = normalized;
            row[denialCodeKey] = normalized;

            // Extract payer fields
            var payerCoverage = row.GetValueOrDefault("Coverage Status") ?? "";
            var payerICD = row.GetValueOrDefault("ICD Compliance Status") ?? "";
            var payerCovNorm = CoverageIcdNormalizer.NormalizeCoverage(payerCoverage);
            var payerIcdNorm = CoverageIcdNormalizer.NormalizeICD(payerICD);

            var expectedPaymentDateStr = row.GetValueOrDefault("Expected Payment Date");
            var firstBilledDateStr = row.GetValueOrDefault("First Billed Date");

            DateTime? expectedPaymentDate = DateTime.TryParse(expectedPaymentDateStr, out var epd) ? epd : null;
            DateTime? firstBilledDate = DateTime.TryParse(firstBilledDateStr, out var fbd) ? fbd : null;

            string taskStatus = "Open";

            // Aggregated per-code maps
            var descMap = new Dictionary<string, string?>();
            var classMap = new Dictionary<string, string?>();
            var typeMap = new Dictionary<string, string?>();
            var validityMap = new Dictionary<string, string?>();
            var actionCodeMap = new Dictionary<string, string?>();
            var recActionMap = new Dictionary<string, string?>();
            var actionCatMap = new Dictionary<string, string?>();
            var taskMap = new Dictionary<string, string?>();
            var shortCatMap = new Dictionary<string, string?>();
            var priorityMap = new Dictionary<string, string?>();
            var slaMap = new Dictionary<string, string?>();
            var notesMap = new Dictionary<string, string?>();

            foreach (var code in codes)
            {
                var mapperRows = claimMapperIndex.FindByCode(code).ToList();
                if (mapperRows.Count == 0)
                    continue;

                var first = mapperRows.First();
                descMap[code] = first.DenialDescription;
                classMap[code] = first.DenialClassification;
                typeMap[code] = first.DenialClassification;

                // Matching logic
                var match =
                    mapperRows.FirstOrDefault(m =>
                        CoverageIcdNormalizer.IsNA(m.CoverageStatus) &&
                        CoverageIcdNormalizer.IsNA(m.IcdComplianceStatus))
                    ??
                    mapperRows.FirstOrDefault(m =>
                        CoverageIcdNormalizer.NormalizeCoverage(m.CoverageStatus) == payerCovNorm &&
                        CoverageIcdNormalizer.NormalizeICD(m.IcdComplianceStatus) == payerIcdNorm)
                    ??
                    mapperRows.FirstOrDefault(m =>
                        CoverageIcdNormalizer.IsNA(m.CoverageStatus) &&
                        CoverageIcdNormalizer.NormalizeICD(m.IcdComplianceStatus) == payerIcdNorm)
                    ??
                    mapperRows.FirstOrDefault(m =>
                        string.IsNullOrWhiteSpace(payerCoverage) &&
                        CoverageIcdNormalizer.IsNA(m.CoverageStatus) &&
                        CoverageIcdNormalizer.NormalizeICD(m.IcdComplianceStatus) == payerIcdNorm);

                if (match == null)
                    continue;

                validityMap[code] = match.DenialValidity;
                actionCodeMap[code] = match.ActionCode;
                recActionMap[code] = ExtractActionEssence(match.RecommendedAction);
                actionCatMap[code] = match.ActionCategory;
                taskMap[code] = ExtractActionEssence(match.Task);
                shortCatMap[code] = match.ShortCategory;
                priorityMap[code] = match.Priority;
                slaMap[code] = match.SlaDays;
                notesMap[code] = ExtractActionEssence(match.NotesComments);

                // Task Status logic (rebill close)
                bool isRebillTask =
                    (!string.IsNullOrWhiteSpace(match.Task) &&
                     match.Task.Contains("rebill", StringComparison.OrdinalIgnoreCase))
                    ||
                    string.Equals(match.ActionCode, "RB", StringComparison.OrdinalIgnoreCase);

                bool hasValidDates =
                    expectedPaymentDate.HasValue &&
                    firstBilledDate.HasValue &&
                    firstBilledDate.Value > expectedPaymentDate.Value;

                if (taskStatus != "Closed" && isRebillTask && hasValidDates)
                {
                    taskStatus = "Closed";
                }
            }

            // Assign aggregated values
            row["Denial Description"] = FormatGrouped(descMap);
            row["Denial Classification"] = FormatGrouped(classMap);
            row["Denial Type"] = FormatGrouped(typeMap);
            row["Denial Validity"] = FormatGrouped(validityMap);
            row["Action Code"] = FormatGrouped(actionCodeMap);
            row["Status Action Code"] = FormatGrouped(actionCodeMap);
            row["Recommended Action"] = FormatGrouped(recActionMap);
            row["Action Category"] = FormatGrouped(actionCatMap);
            row["Task Guidance"] = FormatGrouped(taskMap);
            row["Task Status"] = taskStatus;
            row["Short Category"] = FormatGrouped(shortCatMap);
            row["Priority"] = FormatGrouped(priorityMap);
            row["SLA (Days)"] = FormatGrouped(slaMap);
            row["Notes / Comments"] = FormatGrouped(notesMap);
        }

        return (finalHeaders, payerPolicyRows);
    }

    private static string ExtractActionEssence(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return "";

        var parts = text.Split('.', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Trim())
            .Where(p => !string.IsNullOrWhiteSpace(p))
            .ToList();

        if (parts.Count == 0)
            return "";

        var essence = parts.Last().Trim().TrimEnd('.');
        return essence;
    }

    private static string FormatGrouped(Dictionary<string, string?> codeToValue)
    {
        if (codeToValue.Count == 0)
            return "";

        var groups = codeToValue
            .GroupBy(kv => string.IsNullOrWhiteSpace(kv.Value) ? "" : kv.Value!.Trim())
            .ToList();

        var results = new List<string>();

        foreach (var g in groups)
        {
            if (string.IsNullOrWhiteSpace(g.Key))
                continue;

            var codes = string.Join(", ", g.Select(x => x.Key));
            results.Add($"{codes}: {g.Key}");
        }

        return string.Join(", ", results);
    }

    private static void AddIfMissing(List<string> headers, string header)
    {
        if (!headers.Contains(header, StringComparer.OrdinalIgnoreCase))
            headers.Add(header);
    }

    private static void InsertIfMissing(List<string> headers, int index, string header)
    {
        if (headers.Contains(header, StringComparer.OrdinalIgnoreCase))
            return;

        index = Math.Clamp(index, 0, headers.Count);
        headers.Insert(index, header);
    }

    private static string ResolveHeaderKey(List<string> headers, string desired)
    {
        var exact = headers.FirstOrDefault(h => string.Equals(h, desired, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(exact))
            return exact;

        var desiredNorm = CoverageIcdNormalizer.NormalizeGeneral(desired);
        var norm = headers.FirstOrDefault(h => CoverageIcdNormalizer.NormalizeGeneral(h) == desiredNorm);
        if (!string.IsNullOrWhiteSpace(norm))
            return norm;

        return desired;
    }
}