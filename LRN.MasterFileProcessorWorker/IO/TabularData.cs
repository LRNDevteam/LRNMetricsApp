namespace LRN.MasterFileProcessorWorker.IO;

public sealed class TabularData
{
    public HashSet<string> Columns { get; } = new(StringComparer.OrdinalIgnoreCase);
    public List<Dictionary<string, string?>> Rows { get; } = new();
}
