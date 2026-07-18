using Microsoft.Data.SqlClient;

namespace PredictionAnalysis.Services;

/// <summary>
/// Fills blank DenialDescription values on PV_DenialBreakdown (and optionally
/// PayerValidationReport) from LRNMaster.dbo.DenialMapperSuperMaster.
/// </summary>
public static class DenialDescriptionEnricher
{
    private const string BulkLookupSql = """
        SELECT LTRIM(RTRIM(DenialCode)) AS DenialCode,
               LTRIM(RTRIM(DenialDescription)) AS DenialDescription
        FROM (
            SELECT DenialCode, DenialDescription,
                   ROW_NUMBER() OVER (
                       PARTITION BY LTRIM(RTRIM(DenialCode))
                       ORDER BY ModifiedOn DESC) AS rn
            FROM dbo.DenialMapperSuperMaster
            WHERE IsActive = 1
              AND NULLIF(LTRIM(RTRIM(DenialCode)), '') IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NOT NULL
        ) x
        WHERE rn = 1;
        """;

    public static int EnrichLabAggregates(string labDbConnectionString, string masterDbConnectionString, string labName)
    {
        if (string.IsNullOrWhiteSpace(labDbConnectionString)
            || string.IsNullOrWhiteSpace(masterDbConnectionString))
            return 0;

        var blankCodes = new List<string>();

        using (var labConn = new SqlConnection(labDbConnectionString))
        {
            labConn.Open();
            using var cmd = new SqlCommand("""
                SELECT DISTINCT LTRIM(RTRIM(DenialCode))
                FROM dbo.PV_DenialBreakdown
                WHERE NULLIF(LTRIM(RTRIM(DenialCode)), '') IS NOT NULL
                  AND DenialCode <> N'(Blank)'
                  AND (
                        NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NULL
                     OR DenialCode LIKE N'%,%'
                     OR DenialCode LIKE N'%;%'
                     OR DenialCode LIKE N'%|%'
                  );
                """, labConn)
            {
                CommandTimeout = 120
            };

            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                var code = reader.GetString(0);
                if (!string.IsNullOrWhiteSpace(code))
                    blankCodes.Add(code);
            }
        }

        if (blankCodes.Count == 0)
            return 0;

        var masterByNorm = LoadMasterMap(masterDbConnectionString);
        var lookups = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var code in blankCodes.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (TryResolve(code, masterByNorm, out var desc))
                lookups[code] = desc;
        }

        if (lookups.Count == 0)
        {
            AppLogger.LogDbWarn(
                $"[{labName}] DenialDescription enrichment: {blankCodes.Count} blank codes, 0 matched in SuperMaster.");
            return 0;
        }

        var updated = 0;
        using (var labConn = new SqlConnection(labDbConnectionString))
        {
            labConn.Open();
            foreach (var (code, description) in lookups)
            {
                using var updAgg = new SqlCommand("""
                    UPDATE dbo.PV_DenialBreakdown
                    SET DenialDescription = @Desc
                    WHERE LTRIM(RTRIM(DenialCode)) = @Code
                      AND (
                            NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NULL
                         OR @Code LIKE '%,%'
                         OR @Code LIKE '%;%'
                         OR @Code LIKE '%|%'
                      );
                    """, labConn)
                {
                    CommandTimeout = 120
                };
                updAgg.Parameters.AddWithValue("@Desc", description);
                updAgg.Parameters.AddWithValue("@Code", code);
                updated += updAgg.ExecuteNonQuery();

                using var updRaw = new SqlCommand("""
                    UPDATE dbo.PayerValidationReport
                    SET DenialDescription = @Desc
                    WHERE LTRIM(RTRIM(DenialCode)) = @Code
                      AND LTRIM(RTRIM(ISNULL(PayStatus, N''))) = N'Denied'
                      AND (
                            NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NULL
                         OR @Code LIKE '%,%'
                         OR @Code LIKE '%;%'
                         OR @Code LIKE '%|%'
                      );
                    """, labConn)
                {
                    CommandTimeout = 300
                };
                updRaw.Parameters.AddWithValue("@Desc", description);
                updRaw.Parameters.AddWithValue("@Code", code);
                updRaw.ExecuteNonQuery();
            }
        }

        AppLogger.LogDb(
            $"[{labName}] Enriched DenialDescription on PV_DenialBreakdown from LRNMaster " +
            $"({lookups.Count} codes, {updated} aggregate row(s) updated).");

        return updated;
    }

    private static Dictionary<string, string> LoadMasterMap(string masterDbConnectionString)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        using var master = new SqlConnection(masterDbConnectionString);
        master.Open();
        using var cmd = new SqlCommand(BulkLookupSql, master) { CommandTimeout = 60 };
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var code = r.IsDBNull(0) ? null : r.GetString(0);
            var desc = r.IsDBNull(1) ? null : r.GetString(1);
            if (string.IsNullOrWhiteSpace(code) || string.IsNullOrWhiteSpace(desc))
                continue;
            var trimmedDesc = desc.Trim();
            foreach (var key in CandidateKeys(code))
            {
                if (!result.ContainsKey(key))
                    result[key] = trimmedDesc;
            }
        }
        return result;
    }

    private static bool TryResolve(
        string rawCode,
        IReadOnlyDictionary<string, string> masterByNorm,
        out string description)
    {
        description = string.Empty;
        if (string.IsNullOrWhiteSpace(rawCode))
            return false;

        // Multi-code: "CO-16,CO-109" / "CO-16;CO-109" → resolve each, join with ", "
        var parts = rawCode
            .Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(p => !string.IsNullOrWhiteSpace(p))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (parts.Length > 1)
        {
            var descs = new List<string>(parts.Length);
            var any = false;
            foreach (var part in parts)
            {
                if (TryResolveSingle(part, masterByNorm, out var partDesc)
                    && !string.IsNullOrWhiteSpace(partDesc))
                {
                    descs.Add(partDesc);
                    any = true;
                }
            }

            if (!any)
                return false;

            description = string.Join(", ", descs);
            return true;
        }

        return TryResolveSingle(rawCode, masterByNorm, out description);
    }

    private static bool TryResolveSingle(
        string rawCode,
        IReadOnlyDictionary<string, string> masterByNorm,
        out string description)
    {
        description = string.Empty;
        foreach (var candidate in CandidateKeys(rawCode))
        {
            if (masterByNorm.TryGetValue(candidate, out var desc)
                && !string.IsNullOrWhiteSpace(desc))
            {
                description = desc;
                return true;
            }
        }
        return false;
    }

    private static IEnumerable<string> CandidateKeys(string rawCode)
    {
        var trimmed = rawCode.Trim();
        yield return NormalizeCode(trimmed);

        var token = trimmed.Split([':', '|'], 2, StringSplitOptions.TrimEntries)[0];
        if (!string.IsNullOrWhiteSpace(token) && !token.Equals(trimmed, StringComparison.OrdinalIgnoreCase))
            yield return NormalizeCode(token);

        var alnum = new string(trimmed.Where(char.IsLetterOrDigit).ToArray());
        if (!string.IsNullOrWhiteSpace(alnum))
            yield return alnum.ToUpperInvariant();
    }

    private static string NormalizeCode(string code) =>
        code.Trim().ToUpperInvariant().Replace(" ", "", StringComparison.Ordinal);
}
