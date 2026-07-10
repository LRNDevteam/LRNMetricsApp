namespace LRN.PayerPolicyMapper.Core;

/// <summary>One scored candidate from Step 7 with its component breakdown.</summary>
public sealed class MatchCandidate
{
    public required PayerPolicyRecord Record { get; init; }
    /// <summary>Final clamped 0-100 score (base + state + program adjustments).</summary>
    public decimal Score { get; init; }
    public decimal BaseNameScore { get; init; }
    public int StateAdjustment { get; init; }
    public int ProgramAdjustment { get; init; }
    public int Rank { get; set; }
    /// <summary>True when the policy row has no parseable Global Payer ID - can never auto-map.</summary>
    public bool MissingGlobalPayerId => Record.GlobalPayerId is null;
}

/// <summary>Full result of a pipeline evaluation (before persistence).</summary>
public sealed class MatchResult
{
    public required MatchContext Context { get; init; }
    public required MatchDecision Decision { get; init; }
    /// <summary>Top candidates, best first (up to MatchingOptions.TopCandidates).</summary>
    public IReadOnlyList<MatchCandidate> Candidates { get; init; } = Array.Empty<MatchCandidate>();
    /// <summary>Confidence of the winning candidate (100 for alias hits).</summary>
    public decimal? ConfidenceScore { get; init; }
    /// <summary>Global Payer ID written on AutoMap (alias id or top candidate id).</summary>
    public int? SelectedGlobalPayerId { get; init; }
    /// <summary>True when Step 8's tie-guard forced ManualReview despite an auto-map score.</summary>
    public bool TieGuardTriggered { get; init; }
}
