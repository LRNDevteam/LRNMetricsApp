namespace LRN.PayerPolicyMapper.Core;

/// <summary>
/// Decision thresholds (Step 8). The Step 7 scoring weights are fixed by the validated
/// spec (0.40 TokenSet + 0.25 Weighted + 0.20 Partial + 0.15 TokenSort) and are not configurable.
/// </summary>
public sealed class MatchingOptions
{
    public decimal AutoMapThreshold { get; set; } = 95m;
    public decimal ReviewThreshold { get; set; } = 70m;
    public decimal TieMarginPoints { get; set; } = 0.5m;
    public int TopCandidates { get; set; } = 5;
}
