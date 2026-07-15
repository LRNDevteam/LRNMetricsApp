using LRN.PayerPolicyMapper.Core.Abstractions;
using Microsoft.Extensions.Logging;

namespace LRN.PayerPolicyMapper.Core;

/// <summary>
/// Singleton Step 0 index holder with atomic rebuild. GetAsync serves the cached snapshot and
/// re-checks the rules version at most once per TTL (web app default: 5 minutes);
/// RefreshIfChangedAsync forces the version check now (worker: once per poll cycle).
/// </summary>
public sealed class CachedPayerPolicyIndexProvider : IPayerPolicyIndexProvider
{
    private readonly IReferenceDataRepository _referenceData;
    private readonly ILogger<CachedPayerPolicyIndexProvider> _logger;
    private readonly TimeSpan _versionCheckInterval;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private PayerPolicyIndex? _index;
    private string? _version;
    private DateTime _lastCheckUtc = DateTime.MinValue;

    public CachedPayerPolicyIndexProvider(IReferenceDataRepository referenceData,
        ILogger<CachedPayerPolicyIndexProvider> logger, TimeSpan? versionCheckInterval = null)
    {
        _referenceData = referenceData;
        _logger = logger;
        _versionCheckInterval = versionCheckInterval ?? TimeSpan.FromMinutes(5);
    }

    public async Task<PayerPolicyIndex> GetAsync(CancellationToken ct)
    {
        var index = _index;
        if (index != null && DateTime.UtcNow - _lastCheckUtc < _versionCheckInterval) return index;
        return (await RefreshIfChangedAsync(ct)).Index;
    }

    public async Task<(PayerPolicyIndex Index, bool Rebuilt)> RefreshIfChangedAsync(CancellationToken ct)
    {
        await _gate.WaitAsync(ct);
        try
        {
            var version = await _referenceData.GetRulesVersionAsync(ct);
            _lastCheckUtc = DateTime.UtcNow;
            if (_index != null && version == _version) return (_index, false);

            var data = await _referenceData.LoadAsync(ct);
            var index = PayerPolicyIndex.Build(data);
            var firstBuild = _index is null;
            _index = index; // atomic swap - readers always see a complete snapshot
            _version = version;

            if (firstBuild && index.RecordsMissingGlobalPayerId.Count > 0)
                _logger.LogWarning(
                    "Payer Policy index: {Count} active row(s) have no parseable GlobalPayerId and are manual-review-only candidates " +
                    "(they can be suggested but never auto-mapped): {Names}",
                    index.RecordsMissingGlobalPayerId.Count,
                    string.Join("; ", index.RecordsMissingGlobalPayerId.Take(25).Select(r => $"#{r.PPInsuranceMasterId} '{r.PayerNameRaw}'")));

            _logger.LogInformation("Payer Policy index built: {Records} active policy rows, {Aliases} aliases, {Families} family buckets (version {Version})",
                index.PolicyRecords.Count, index.Aliases.Count, index.PolicyRecordsByFamily.Count, version);
            // The first build is a baseline, not a rules change - callers must not trigger a full re-evaluation for it.
            return (index, !firstBuild);
        }
        finally
        {
            _gate.Release();
        }
    }
}
