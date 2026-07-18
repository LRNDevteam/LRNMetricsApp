using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Looks up DenialDescription from LRNMaster.dbo.DenialMapperSuperMaster and
/// writes missing values onto PV_DenialBreakdown (lab DB) + in-memory rows.
/// </summary>
public sealed class DenialDescriptionMasterLookup
{
    private readonly IConfiguration _configuration;
    private readonly ILogger<DenialDescriptionMasterLookup> _logger;

    public DenialDescriptionMasterLookup(
        IConfiguration configuration,
        ILogger<DenialDescriptionMasterLookup> logger)
    {
        _configuration = configuration;
        _logger        = logger;
    }

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

    /// <summary>
    /// Enriches denial breakdown rows whose DenialDescription is blank.
    /// Resolves master connection from lab config or ConnectionStrings:DefaultConnection.
    /// </summary>
    public async Task<List<DenialBreakdownSpRow>> EnrichAsync(
        string? labDbConnectionString,
        string? masterDbConnectionString,
        List<DenialBreakdownSpRow> rows,
        CancellationToken ct = default)
    {
        if (rows.Count == 0)
            return rows;

        var masterConn = ResolveMasterConnection(masterDbConnectionString);
        if (string.IsNullOrWhiteSpace(masterConn))
        {
            _logger.LogWarning(
                "DenialDescription enrichment skipped — MasterDbConnectionString and DefaultConnection are empty.");
            return rows;
        }

        var blankCount = rows.Count(r => string.IsNullOrWhiteSpace(r.DenialDescription)
                                         && !string.IsNullOrWhiteSpace(r.DenialCode)
                                         && !r.DenialCode.Equals("(Blank)", StringComparison.OrdinalIgnoreCase));

        // Also resolve multi-code rows so joined master descriptions overwrite a single/wrong source desc.
        var multiCodeCount = rows.Count(r =>
            !string.IsNullOrWhiteSpace(r.DenialCode)
            && DenialCodeHelper.SplitCodes(r.DenialCode).Length > 1);

        if (blankCount == 0 && multiCodeCount == 0)
        {
            _logger.LogDebug("DenialDescription enrichment: no blank/multi-code descriptions to fill.");
            return rows;
        }

        Dictionary<string, string> masterByNorm;
        try
        {
            masterByNorm = await LoadMasterMapAsync(masterConn, ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "Failed to load DenialMapperSuperMaster from LRNMaster (conn starts with '{Prefix}').",
                masterConn.Length > 40 ? masterConn[..40] : masterConn);
            return rows;
        }

        if (masterByNorm.Count == 0)
        {
            _logger.LogWarning("DenialMapperSuperMaster returned 0 active description rows.");
            return rows;
        }

        var matched = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var code in rows
                     .Where(r =>
                         !string.IsNullOrWhiteSpace(r.DenialCode)
                         && !r.DenialCode.Equals("(Blank)", StringComparison.OrdinalIgnoreCase)
                         && (string.IsNullOrWhiteSpace(r.DenialDescription)
                             || DenialCodeHelper.SplitCodes(r.DenialCode).Length > 1))
                     .Select(r => r.DenialCode)
                     .Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (TryResolve(code, masterByNorm, out var desc))
                matched[code] = desc;
        }

        _logger.LogInformation(
            "DenialDescription enrichment: {Blank} blank + {Multi} multi-code row-codes, {Matched} matched from SuperMaster ({MasterCount} master codes).",
            blankCount, multiCodeCount, matched.Count, masterByNorm.Count);

        if (matched.Count == 0)
            return rows;

        if (!string.IsNullOrWhiteSpace(labDbConnectionString))
        {
            try
            {
                await PersistToAggregateAsync(labDbConnectionString, matched, ct);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex,
                    "Failed to persist DenialDescription onto PV_DenialBreakdown.");
            }
        }

        return rows.Select(r =>
        {
            if (!matched.TryGetValue(r.DenialCode, out var desc))
                return r;
            // Always apply joined multi-code master text; single-code only when blank.
            var isMulti = DenialCodeHelper.SplitCodes(r.DenialCode).Length > 1;
            if (!isMulti && !string.IsNullOrWhiteSpace(r.DenialDescription))
                return r;
            return r with { DenialDescription = desc };
        }).ToList();
    }

    /// <summary>
    /// Fills blank descriptions on already-assembled denial code rows (after multi-code split).
    /// </summary>
    public async Task<DenialBreakdown> EnrichBreakdownAsync(
        DenialBreakdown breakdown,
        string? masterDbConnectionString,
        CancellationToken ct = default)
    {
        if (breakdown.PayerRows.Count == 0)
            return breakdown;

        var needsLookup = breakdown.PayerRows
            .SelectMany(p => p.TopDenialCodes)
            .Any(c =>
                !string.IsNullOrWhiteSpace(c.DenialCode)
                && !c.DenialCode.Equals("(Blank)", StringComparison.OrdinalIgnoreCase)
                && !c.DenialCode.Equals("(No Code)", StringComparison.OrdinalIgnoreCase)
                && (string.IsNullOrWhiteSpace(c.DenialDescription)
                    || DenialCodeHelper.SplitCodes(c.DenialCode).Length > 1));

        if (!needsLookup)
            return breakdown;

        var masterConn = ResolveMasterConnection(masterDbConnectionString);
        if (string.IsNullOrWhiteSpace(masterConn))
            return breakdown;

        Dictionary<string, string> masterByNorm;
        try
        {
            masterByNorm = await LoadMasterMapAsync(masterConn, ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "EnrichBreakdownAsync: failed to load DenialMapperSuperMaster.");
            return breakdown;
        }

        if (masterByNorm.Count == 0)
            return breakdown;

        var updatedPayers = new List<DenialPayerRow>(breakdown.PayerRows.Count);
        var filled = 0;
        foreach (var payer in breakdown.PayerRows)
        {
            var codes = payer.TopDenialCodes.Select(c =>
            {
                var isMulti = DenialCodeHelper.SplitCodes(c.DenialCode).Length > 1;
                if (!isMulti && !string.IsNullOrWhiteSpace(c.DenialDescription))
                    return c;

                if (TryResolve(c.DenialCode, masterByNorm, out var resolved)
                    && !string.IsNullOrWhiteSpace(resolved))
                {
                    filled++;
                    return c with { DenialDescription = resolved };
                }

                return c;
            }).ToList();

            updatedPayers.Add(payer with { TopDenialCodes = codes });
        }

        _logger.LogInformation("EnrichBreakdownAsync: filled {Filled} denial-code description(s).", filled);

        return new DenialBreakdown
        {
            Months = breakdown.Months,
            PayerRows = updatedPayers,
            TotalClaims = breakdown.TotalClaims,
            TotalPredictedAllowed = breakdown.TotalPredictedAllowed,
            TotalPredictedInsurance = breakdown.TotalPredictedInsurance,
            TotalActualAllowed = breakdown.TotalActualAllowed,
            TotalActualInsurance = breakdown.TotalActualInsurance,
            TotalVarianceAllowed = breakdown.TotalVarianceAllowed,
            TotalVariancePaid = breakdown.TotalVariancePaid,
            TotalByMonth = breakdown.TotalByMonth
        };
    }

    private string? ResolveMasterConnection(string? labMaster) =>
        !string.IsNullOrWhiteSpace(labMaster)
            ? labMaster
            : _configuration.GetConnectionString("DefaultConnection");

    private static async Task<Dictionary<string, string>> LoadMasterMapAsync(
        string masterDbConnectionString,
        CancellationToken ct)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        await using var master = new SqlConnection(masterDbConnectionString);
        await master.OpenAsync(ct);

        await using var cmd = new SqlCommand(BulkLookupSql, master) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
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
        var parts = DenialCodeHelper.SplitCodes(rawCode);
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

            description = DenialCodeHelper.JoinDescriptions(descs);
            return !string.IsNullOrWhiteSpace(description);
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

        // "CO16: something" / "CO16 | text" → take leading token (do not split on hyphen — CO-16)
        var token = trimmed.Split([':', '|'], 2, StringSplitOptions.TrimEntries)[0];
        if (!string.IsNullOrWhiteSpace(token) && !token.Equals(trimmed, StringComparison.OrdinalIgnoreCase))
            yield return NormalizeCode(token);

        // Strip non-alphanumeric (CO-16 / CO 16 → CO16)
        var alnum = new string(trimmed.Where(char.IsLetterOrDigit).ToArray());
        if (!string.IsNullOrWhiteSpace(alnum))
            yield return alnum.ToUpperInvariant();
    }

    private static string NormalizeCode(string code) =>
        code.Trim().ToUpperInvariant().Replace(" ", "", StringComparison.Ordinal);

    private static async Task PersistToAggregateAsync(
        string labDbConnectionString,
        IReadOnlyDictionary<string, string> lookups,
        CancellationToken ct)
    {
        await using var lab = new SqlConnection(labDbConnectionString);
        await lab.OpenAsync(ct);

        foreach (var (code, description) in lookups)
        {
            await using var cmd = new SqlCommand("""
                UPDATE dbo.PV_DenialBreakdown
                SET DenialDescription = @Desc
                WHERE LTRIM(RTRIM(DenialCode)) = @Code
                  AND (
                        NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NULL
                     OR @Code LIKE '%,%'
                     OR @Code LIKE '%;%'
                     OR @Code LIKE '%|%'
                  );
                """, lab)
            {
                CommandTimeout = 120
            };
            cmd.Parameters.AddWithValue("@Desc", description);
            cmd.Parameters.AddWithValue("@Code", code);
            await cmd.ExecuteNonQueryAsync(ct);
        }
    }
}
