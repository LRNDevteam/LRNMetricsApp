using System.Collections.Concurrent;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Progress of running Executive Summary value-popup downloads, keyed by the id the page sends with the request,
/// so the page can show a % bar while the server reads and writes the rows. In-process memory: one web server.
/// </summary>
public static class CellRowsExportProgress
{
    /// <summary>query = waiting for the database, rows = writing rows, finishing = closing the file,
    /// ready = the file is being sent, failed.</summary>
    public sealed class Entry
    {
        public string Phase { get; set; } = "query";
        public int Rows { get; set; }
        public int TotalRows { get; set; }
        public string Format { get; set; } = "Excel";
        public DateTime UpdatedUtc { get; set; } = DateTime.UtcNow;
    }

    private static readonly ConcurrentDictionary<Guid, Entry> Entries = new();
    private static readonly TimeSpan KeepFor = TimeSpan.FromMinutes(30);

    /// <summary>Starts tracking <paramref name="id"/>; null when the page sent no id.</summary>
    public static Entry? Start(string? id)
    {
        Sweep();
        if (!Guid.TryParse(id, out var key)) return null;
        var entry = new Entry();
        Entries[key] = entry;
        return entry;
    }

    public static Entry? Get(string? id) =>
        Guid.TryParse(id, out var key) && Entries.TryGetValue(key, out var entry) ? entry : null;

    public static void Update(this Entry? entry, string phase, int? rows = null)
    {
        if (entry is null) return;
        entry.Phase = phase;
        if (rows is not null) entry.Rows = rows.Value;
        entry.UpdatedUtc = DateTime.UtcNow;
    }

    private static void Sweep()
    {
        var cutoff = DateTime.UtcNow - KeepFor;
        foreach (var (key, entry) in Entries)
            if (entry.UpdatedUtc < cutoff) Entries.TryRemove(key, out _);
    }
}
