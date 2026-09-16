namespace LabMetricsDashboard.Services;

/// <summary>
/// The denial description cascade, in the order the requirements define it.
///
/// <list type="number">
///   <item>The lab's own Denial-Action master (<c>dbo.DenialCodeMaster</c>) matched on the RAW code.</item>
///   <item>The Denial-Action Super Master (<c>LRNMaster.dbo.DenialMapperSuperMaster</c>), RAW code.</item>
///   <item>The lab's Denial-Action master matched on the NORMALIZED code.</item>
///   <item>The Super Master, normalized code.</item>
/// </list>
///
/// <para>The lab's own table outranks the Super Master at both steps because a lab that has
/// customised a description means it; the raw code outranks the normalized one because it is the
/// more specific match, and falling back to the normalized code is what lets a claim carrying CO10
/// pick up a description the master stores only under PR10.</para>
///
/// <para>This mirrors <c>LRN.MasterFileProcessorWorker.BulkLoad.DenialDescriptionLookup</c>, which
/// applies the same cascade when it writes DenialDescription during the claim-level import. The
/// duplication is deliberate: the worker takes no project reference on the web apps, and both sides
/// have to agree on the rule or a summary row and its claims would show different descriptions.</para>
/// </summary>
public sealed class DenialDescriptionLookup
{
    private readonly Dictionary<string, string> _labByRaw = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _labByNormalized = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _superByRaw = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _superByNormalized = new(StringComparer.OrdinalIgnoreCase);

    public int LabCodeCount => _labByRaw.Count;
    public int SuperCodeCount => _superByRaw.Count;
    public bool IsEmpty => _labByRaw.Count == 0 && _superByRaw.Count == 0;

    /// <summary>Adds one row of the lab's own Denial-Action master.</summary>
    public void AddLab(string? denialCode, string? description) =>
        Add(_labByRaw, _labByNormalized, denialCode, description);

    /// <summary>Adds one row of the Denial-Action Super Master.</summary>
    public void AddSuper(string? denialCode, string? description) =>
        Add(_superByRaw, _superByNormalized, denialCode, description);

    private static void Add(
        Dictionary<string, string> byRaw,
        Dictionary<string, string> byNormalized,
        string? denialCode,
        string? description)
    {
        var code = (denialCode ?? string.Empty).Trim();
        if (code.Length == 0 || string.IsNullOrWhiteSpace(description)) return;

        var text = description.Trim();
        byRaw.TryAdd(code, text);

        // CO10, PR10 and PI10 all collapse onto "10" here. They carry the same description, so the
        // first one read wins and which one that was does not matter.
        var normalized = DenialCodeKey.Normalize(code);
        if (normalized.Length > 0) byNormalized.TryAdd(normalized, text);
    }

    /// <summary>The description for one code, or null when no master has one.</summary>
    public string? Resolve(string? denialCode)
    {
        var raw = (denialCode ?? string.Empty).Trim();
        if (raw.Length == 0) return null;

        if (_labByRaw.TryGetValue(raw, out var labRaw)) return labRaw;
        if (_superByRaw.TryGetValue(raw, out var superRaw)) return superRaw;

        var normalized = DenialCodeKey.Normalize(raw);
        if (normalized.Length == 0) return null;

        if (_labByNormalized.TryGetValue(normalized, out var labNormalized)) return labNormalized;
        if (_superByNormalized.TryGetValue(normalized, out var superNormalized)) return superNormalized;

        return null;
    }
}
