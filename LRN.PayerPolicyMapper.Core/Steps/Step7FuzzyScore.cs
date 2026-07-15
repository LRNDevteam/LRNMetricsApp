using Raffinert.FuzzySharp;

namespace LRN.PayerPolicyMapper.Core.Steps;

/// <summary>
/// Step 7 - fuzzy scoring. Per candidate the CanonicalName is scored against BOTH the candidate's
/// canonicalized PayerNameRaw and PayerNameNormalized and the better base score wins (vs normalized
/// "BCBS TX" alone, "Blue Cross Blue Shield of Texas" scores ~52 - a false near-miss; vs the full
/// name it scores 100). Weights are fixed by the validated spec:
///   Base = 0.40 x TokenSetRatio + 0.25 x WeightedRatio + 0.20 x PartialRatio + 0.15 x TokenSortRatio
/// State adjust: both present and equal +8, both present and different -20, else 0.
/// Program adjust: match +5, mismatch -10, else 0. Clamp 0-100.
/// </summary>
public static class Step7FuzzyScore
{
    public static List<MatchCandidate> Run(MatchContext context, IReadOnlyList<PayerPolicyRecord> candidates, int topCandidates)
    {
        var scored = new List<MatchCandidate>(candidates.Count);
        foreach (var record in candidates)
        {
            var baseScore = BaseScore(context.CanonicalName, record.CanonicalRawName);
            if (record.CanonicalNormalizedName is { Length: > 0 })
                baseScore = Math.Max(baseScore, BaseScore(context.CanonicalName, record.CanonicalNormalizedName));

            var stateAdjust = 0;
            if (context.ResolvedStateCode != null && record.StateCode != null)
                stateAdjust = string.Equals(context.ResolvedStateCode, record.StateCode, StringComparison.OrdinalIgnoreCase) ? 8 : -20;

            var programAdjust = 0;
            if (!string.IsNullOrWhiteSpace(context.ResolvedProgramType) && !string.IsNullOrWhiteSpace(record.ProgramType))
                programAdjust = string.Equals(context.ResolvedProgramType.Trim(), record.ProgramType.Trim(), StringComparison.OrdinalIgnoreCase) ? 5 : -10;

            var final = Math.Clamp(baseScore + stateAdjust + programAdjust, 0m, 100m);
            scored.Add(new MatchCandidate
            {
                Record = record,
                Score = decimal.Round(final, 2),
                BaseNameScore = decimal.Round(baseScore, 2),
                StateAdjustment = stateAdjust,
                ProgramAdjustment = programAdjust
            });
        }

        var top = scored
            .OrderByDescending(c => c.Score)
            .ThenByDescending(c => c.BaseNameScore)
            .ThenBy(c => c.Record.PPInsuranceMasterId)
            .Take(topCandidates)
            .ToList();
        for (var i = 0; i < top.Count; i++) top[i].Rank = i + 1;
        return top;
    }

    /// <summary>Base name score used both by the pipeline and the typeahead search (which has no state/program context).</summary>
    public static decimal BaseScore(string query, string candidate)
    {
        if (query.Length == 0 || candidate.Length == 0) return 0m;
        var tokenSet = Fuzz.TokenSetRatio(query, candidate);
        var weighted = Fuzz.WeightedRatio(query, candidate);
        var partial = Fuzz.PartialRatio(query, candidate);
        var tokenSort = Fuzz.TokenSortRatio(query, candidate);
        return 0.40m * tokenSet + 0.25m * weighted + 0.20m * partial + 0.15m * tokenSort;
    }
}
