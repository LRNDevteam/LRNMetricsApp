namespace DenialDatabaseProcessorWorker.Services;

public sealed class PolicyActionMapperIndex
{
    public sealed record PolicyRule(
        string DenialType,
        string CoverageStatus,
        string IcdComplianceStatus,
        string DenialValidity,
        string ActionCode,
        string RecommendedAction,
        string Task);

    private readonly Dictionary<string, List<PolicyRule>> _byDenialType;

    public PolicyActionMapperIndex(List<Dictionary<string, string>> rows)
    {
        _byDenialType = Build(rows);
    }

    public IReadOnlyList<PolicyRule> GetRules(string denialType)
    {
        denialType = (denialType ?? "").Trim();
        if (string.IsNullOrWhiteSpace(denialType))
            return Array.Empty<PolicyRule>();

        return _byDenialType.TryGetValue(denialType, out var rules)
            ? rules
            : Array.Empty<PolicyRule>();
    }

    /// <summary>
    /// Matches NON-NA policy rules for a single denial type, using payer Coverage Status + ICD Compliance Status.
    /// Rule matching:
    /// - Rule Coverage Status:
    ///   - empty => wildcard (matches any)
    ///   - "Blank" => matches when payer is null/empty (or literal "Blank")
    ///   - "NA" / "N/A" => excluded from this match function (handled separately)
    ///   - otherwise => case-insensitive equals
    /// - Rule ICD Compliance Status: same behavior (empty wildcard, "Blank" = payer empty, else equals)
    /// </summary>
    public IReadOnlyList<PolicyRule> FindMatches(string denialType, string payerCoverageStatus, string payerIcdComplianceStatus)
    {
        denialType = (denialType ?? "").Trim();
        if (string.IsNullOrWhiteSpace(denialType))
            return Array.Empty<PolicyRule>();

        var cov = NormalizePayerStatus(payerCoverageStatus);
        var icd = NormalizePayerStatus(payerIcdComplianceStatus);

        if (!_byDenialType.TryGetValue(denialType, out var rules))
            return Array.Empty<PolicyRule>();

        return rules
            .Where(r => !IsNaRule(r.CoverageStatus))
            .Where(r => MatchesRuleValue(r.CoverageStatus, cov) && MatchesRuleValue(r.IcdComplianceStatus, icd))
            .ToList();
    }

    public static bool IsNaRule(string? ruleCoverageStatus)
    {
        var v = (ruleCoverageStatus ?? "").Trim();
        return string.Equals(v, "NA", StringComparison.OrdinalIgnoreCase)
            || string.Equals(v, "N/A", StringComparison.OrdinalIgnoreCase);
    }

    private static bool MatchesRuleValue(string ruleValueRaw, string? payerValueNormalized)
    {
        var ruleValue = (ruleValueRaw ?? "").Trim();

        // wildcard
        if (string.IsNullOrWhiteSpace(ruleValue))
            return true;

        // explicit blank match
        if (string.Equals(ruleValue, "Blank", StringComparison.OrdinalIgnoreCase))
            return string.IsNullOrWhiteSpace(payerValueNormalized);

        // normal equals
        return string.Equals(ruleValue, payerValueNormalized ?? "", StringComparison.OrdinalIgnoreCase);
    }

    private static string? NormalizePayerStatus(string? payerValue)
    {
        var v = (payerValue ?? "").Trim();

        // treat literal "Blank" as empty
        if (string.Equals(v, "Blank", StringComparison.OrdinalIgnoreCase))
            return "";

        return v;
    }

    private static Dictionary<string, List<PolicyRule>> Build(List<Dictionary<string, string>> rows)
    {
        string Get(Dictionary<string, string> r, params string[] candidates)
        {
            foreach (var c in candidates)
            {
                var key = r.Keys.FirstOrDefault(k => NormalizeHeader(k) == NormalizeHeader(c));
                if (key != null && r.TryGetValue(key, out var v))
                    return v?.Trim() ?? "";
            }
            return "";
        }

        var dict = new Dictionary<string, List<PolicyRule>>(StringComparer.OrdinalIgnoreCase);

        foreach (var r in rows)
        {
            // Denial Type may be comma-separated in policy mapper; index each denial type
            var denialTypeRaw = Get(r, "Denial Type");
            var denialTypes = (denialTypeRaw ?? "")
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Where(t => !string.IsNullOrWhiteSpace(t))
                .ToList();

            if (denialTypes.Count == 0)
                continue;

            var coverage = Get(r, "Coverage Status");
            var icd = Get(r, "ICD Compliance Status");

            var ruleBase = new PolicyRule(
                DenialType: "",
                CoverageStatus: coverage,
                IcdComplianceStatus: icd,
                DenialValidity: Get(r, "Denial Validity"),
                ActionCode: Get(r, "Action Code"),
                RecommendedAction: Get(r, "Recommended Action"),
                Task: Get(r, "Task")
            );

            foreach (var dt in denialTypes)
            {
                var rule = ruleBase with { DenialType = dt };

                if (!dict.TryGetValue(dt, out var list))
                {
                    list = new List<PolicyRule>();
                    dict[dt] = list;
                }

                list.Add(rule);
            }
        }

        return dict;
    }

    private static string NormalizeHeader(string s)
    {
        if (string.IsNullOrWhiteSpace(s)) return "";
        return new string(s.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
    }
}
