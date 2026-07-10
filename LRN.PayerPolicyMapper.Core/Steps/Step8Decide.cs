namespace LRN.PayerPolicyMapper.Core.Steps;

/// <summary>
/// Step 8 - decision: >= AutoMapThreshold auto-maps, [ReviewThreshold, AutoMapThreshold) goes to a
/// person, below that (or no candidates) is NoMatch. Two mandatory guards:
///  - Tie-guard: top-2 within TieMarginPoints AND StateSignalSource == None forces ManualReview
///    even at 100 (real case: bare "Ambetter" tied at 100 across 5 state variants).
///  - A candidate with no parseable GlobalPayerId can never AutoMap - capped at ManualReview.
/// </summary>
public static class Step8Decide
{
    public static (MatchDecision Decision, bool TieGuard) Run(MatchContext context, IReadOnlyList<MatchCandidate> candidates, MatchingOptions options)
    {
        if (candidates.Count == 0) return (MatchDecision.NoMatch, false);

        var top = candidates[0];
        if (top.Score < options.ReviewThreshold) return (MatchDecision.NoMatch, false);
        if (top.Score < options.AutoMapThreshold) return (MatchDecision.ManualReview, false);

        if (top.MissingGlobalPayerId) return (MatchDecision.ManualReview, false);

        var tie = candidates.Count > 1
            && candidates[0].Score - candidates[1].Score <= options.TieMarginPoints
            && context.StateSignalSource == StateSignalSource.None;
        return tie ? (MatchDecision.ManualReview, true) : (MatchDecision.AutoMap, false);
    }
}
