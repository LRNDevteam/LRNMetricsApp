using System.Globalization;
using CodingMasterGenerator.Models;
using CsvHelper;
using CsvHelper.Configuration;

namespace CodingMasterGenerator.Services;

/// <summary>
/// Reads Line Level CSV, groups by ClaimID, builds processed claims,
/// deduplicates, and produces the final Coding Master output rows.
/// </summary>
public static class CodingMasterEngine
{
    /// <summary>Runs the full pipeline and returns sorted output rows.</summary>
    public static List<CodingMasterOutputRow> Generate(string lineLevelCsvPath, AppLogger log)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(lineLevelCsvPath);
        ArgumentNullException.ThrowIfNull(log);

        if (!File.Exists(lineLevelCsvPath))
            throw new FileNotFoundException($"Line Level CSV not found: {lineLevelCsvPath}");

        // Step 1: Read line-level rows
        log.Info("Reading Line Level CSV...");
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var lineRows = ReadLineLevelCsv(lineLevelCsvPath);
        sw.Stop();
        log.Info($"Read {lineRows.Count:N0} line-level rows in {sw.Elapsed.TotalSeconds:F1}s.");

        // Step 2: Group by ClaimID and build processed claims
        log.Info("Grouping by ClaimID and building processed claims...");
        sw.Restart();
        var processedClaims = BuildProcessedClaims(lineRows);
        sw.Stop();
        log.Info($"Built {processedClaims.Count:N0} processed claims in {sw.Elapsed.TotalSeconds:F1}s.");

        // Log panel distribution
        var panelCounts = processedClaims
            .GroupBy(c => c.CodingMasterPanelName, StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(g => g.Count())
            .Take(15);
        log.Info("Top panels by claim count:");
        foreach (var pg in panelCounts)
            log.Info($"  {pg.Key,-30} {pg.Count():N0} claims");

        // Step 3: Deduplicate by (CodingMasterPanelName, Payer_Common_Code)
        log.Info("Deduplicating by (CodingMasterPanelName, Payer_Common_Code)...");
        sw.Restart();
        var outputRows = DeduplicateAndBuildOutput(processedClaims);
        sw.Stop();
        log.Info($"Generated {outputRows.Count:N0} output rows in {sw.Elapsed.TotalSeconds:F1}s.");

        return outputRows;
    }

    private static List<LineLevelRow> ReadLineLevelCsv(string path)
    {
        var rows = new List<LineLevelRow>();

        using var reader = new StreamReader(path);
        using var csv = new CsvReader(reader, new CsvConfiguration(CultureInfo.InvariantCulture)
        {
            HasHeaderRecord = true,
            MissingFieldFound = null,
            HeaderValidated = null,
            TrimOptions = TrimOptions.Trim,
            BadDataFound = null,
        });

        csv.Read();
        csv.ReadHeader();

        while (csv.Read())
        {
            var claimId = csv.GetField("ClaimID")?.Trim() ?? "";
            if (string.IsNullOrWhiteSpace(claimId)) continue;

            var unitsStr = csv.GetField("Units")?.Trim() ?? "1";
            int.TryParse(unitsStr.Replace(".00", ""), out int units);
            if (units < 1) units = 1;

            var chargeStr = csv.GetField("ChargeAmount")?.Trim() ?? "0";
            decimal.TryParse(chargeStr, NumberStyles.Any, CultureInfo.InvariantCulture, out decimal charge);

            rows.Add(new LineLevelRow
            {
                ClaimID = StripDecimalSuffix(claimId),
                CPTCode = StripDecimalSuffix(csv.GetField("CPTCode")?.Trim() ?? ""),
                Units = units,
                ChargeAmount = charge,
                PayerName = csv.GetField("PayerName")?.Trim() ?? "",
                Payer_Common_Code = csv.GetField("Payer_Common_Code")?.Trim() ?? "",
                Panelname = csv.GetField("Panelname")?.Trim() ?? "",
            });
        }

        return rows;
    }

    private static List<ProcessedClaim> BuildProcessedClaims(List<LineLevelRow> lineRows)
    {
        var claims = new List<ProcessedClaim>();

        var groups = lineRows.GroupBy(r => r.ClaimID, StringComparer.OrdinalIgnoreCase);

        foreach (var group in groups)
        {
            var lines = group.ToList();

            // Aggregate CPTs: sum units per CPT code
            var cptUnits = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var line in lines)
            {
                if (string.IsNullOrWhiteSpace(line.CPTCode)) continue;
                if (cptUnits.ContainsKey(line.CPTCode))
                    cptUnits[line.CPTCode] += line.Units;
                else
                    cptUnits[line.CPTCode] = line.Units;
            }

            // Build procedure string: sorted by units descending, then CPT code
            var procedureParts = cptUnits
                .OrderByDescending(kv => kv.Value)
                .ThenBy(kv => kv.Key)
                .Select(kv => $"{kv.Key}*{kv.Value}");
            var procedure = string.Join(",", procedureParts);

            // Sum charge
            decimal totalCharge = lines.Sum(l => l.ChargeAmount);

            // Pick payer info (most common in the group)
            var payerName = lines
                .Where(l => !string.IsNullOrWhiteSpace(l.PayerName))
                .GroupBy(l => l.PayerName, StringComparer.OrdinalIgnoreCase)
                .OrderByDescending(g => g.Count())
                .Select(g => g.Key)
                .FirstOrDefault() ?? "";

            var payerCommonCode = lines
                .Where(l => !string.IsNullOrWhiteSpace(l.Payer_Common_Code))
                .GroupBy(l => l.Payer_Common_Code, StringComparer.OrdinalIgnoreCase)
                .OrderByDescending(g => g.Count())
                .Select(g => g.Key)
                .FirstOrDefault() ?? "";

            // Panel name: use from data if populated, else detect
            var rawPanel = lines
                .Where(l => !string.IsNullOrWhiteSpace(l.Panelname))
                .GroupBy(l => l.Panelname, StringComparer.OrdinalIgnoreCase)
                .OrderByDescending(g => g.Count())
                .Select(g => g.Key)
                .FirstOrDefault() ?? "";

            var cptSet = new HashSet<string>(cptUnits.Keys, StringComparer.OrdinalIgnoreCase);

            string detectedPanel = !string.IsNullOrWhiteSpace(rawPanel)
                ? rawPanel
                : PanelDefinitions.DetectPanel(cptSet);

            // Apply ABR suffix
            bool hasAbr = PanelDefinitions.ShouldAppendAbr(cptSet, detectedPanel);
            string codingMasterPanel = hasAbr ? $"{detectedPanel} + ABR" : detectedPanel;

            // Production panel name
            string productionPanel = PanelDefinitions.GetProductionPanelName(codingMasterPanel);

            claims.Add(new ProcessedClaim
            {
                ClaimID = group.Key,
                PayerName = payerName,
                Payer_Common_Code = payerCommonCode,
                RawPanelName = rawPanel,
                DetectedPanel = detectedPanel,
                CodingMasterPanelName = codingMasterPanel,
                ProductionPanelName = productionPanel,
                Procedure = procedure,
                TotalBilledCharge = totalCharge,
                CptCodes = cptSet,
            });
        }

        return claims;
    }

    private static List<CodingMasterOutputRow> DeduplicateAndBuildOutput(List<ProcessedClaim> claims)
    {
        // Group by (CodingMasterPanelName, Payer_Common_Code)
        var deduped = claims
            .GroupBy(c => (c.CodingMasterPanelName, c.Payer_Common_Code),
                new PanelPayerComparer())
            .Select(g =>
            {
                // Most frequent procedure string
                var bestProcedure = g
                    .GroupBy(c => c.Procedure, StringComparer.OrdinalIgnoreCase)
                    .OrderByDescending(pg => pg.Count())
                    .Select(pg => pg.Key)
                    .First();

                // Most frequent payer name
                var bestPayer = g
                    .Where(c => !string.IsNullOrWhiteSpace(c.PayerName))
                    .GroupBy(c => c.PayerName, StringComparer.OrdinalIgnoreCase)
                    .OrderByDescending(pg => pg.Count())
                    .Select(pg => pg.Key)
                    .FirstOrDefault() ?? "";

                // Sum total billed
                decimal totalBilled = g.Sum(c => c.TotalBilledCharge);

                // Production panel from first (all same in group)
                var first = g.First();

                return new CodingMasterOutputRow
                {
                    ProductionPanelName = first.ProductionPanelName,
                    CodingMasterPanelName = first.CodingMasterPanelName,
                    Payer = bestPayer,
                    Payer_Common_Code = first.Payer_Common_Code,
                    Procedure = bestProcedure,
                    TotalBilledCharge = totalBilled,
                    ConditionIfAny = "",
                };
            })
            .OrderBy(r => r.ProductionPanelName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(r => r.Payer_Common_Code, StringComparer.OrdinalIgnoreCase)
            .ToList();

        // Assign sequential S.No
        for (int i = 0; i < deduped.Count; i++)
            deduped[i].SNo = i + 1;

        return deduped;
    }

    private sealed class PanelPayerComparer : IEqualityComparer<(string CodingMasterPanelName, string Payer_Common_Code)>
    {
        public bool Equals((string CodingMasterPanelName, string Payer_Common_Code) x,
                           (string CodingMasterPanelName, string Payer_Common_Code) y)
            => string.Equals(x.CodingMasterPanelName, y.CodingMasterPanelName, StringComparison.OrdinalIgnoreCase)
            && string.Equals(x.Payer_Common_Code, y.Payer_Common_Code, StringComparison.OrdinalIgnoreCase);

        public int GetHashCode((string CodingMasterPanelName, string Payer_Common_Code) obj)
            => HashCode.Combine(
                obj.CodingMasterPanelName?.ToUpperInvariant(),
                obj.Payer_Common_Code?.ToUpperInvariant());
    }

    /// <summary>Strips trailing ".00" or ".0" decimal suffixes from numeric string fields (e.g., "87798.00" ? "87798").</summary>
    private static string StripDecimalSuffix(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return value;
        // Handle ".00", ".0", and any trailing ".000..." patterns
        var idx = value.IndexOf('.');
        if (idx > 0 && value[idx..].TrimEnd('0') is "." or "")
            return value[..idx];
        return value;
    }
}
