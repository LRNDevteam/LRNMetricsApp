namespace LRN.PayerPolicyMapper;

/// <summary>Worker knobs (appsettings.json section "PayerMapper"). Matching thresholds live in "PayerMatching".</summary>
public sealed class PayerMapperOptions
{
    public int PollIntervalSeconds { get; set; } = 30;
    public int BatchSize { get; set; } = 50;
    /// <summary>UTC hour (0-23) of the nightly safety-net rescan of ALL unmapped rows.</summary>
    public int NightlyHourUtc { get; set; } = 2;
}
