using LRN.MasterFileProcessorWorker.Schema;

namespace LRN.MasterFileProcessorWorker.Processing;

public static class ColumnValidator
{
    public static List<string> FindMissingMandatoryColumns(HashSet<string> inputColumns, IEnumerable<string> mandatory)
    {
        var missing = new List<string>();
        foreach (var col in mandatory)
        {
            if (string.IsNullOrWhiteSpace(col)) continue;
            if (!inputColumns.Contains(col))
                missing.Add(col);
        }
        return missing;
    }

    public static List<string> FindMissingRequiredMappings(HashSet<string> inputColumns, IEnumerable<ColumnMappingDefinition> mappings)
    {
        var missing = new List<string>();
        foreach (var m in mappings.Where(x => x.Required))
        {
            if (m.SourceAliases == null || m.SourceAliases.Count == 0)
                continue;

            var ok = m.SourceAliases.Any(a => inputColumns.Contains(a));
            if (!ok)
                missing.Add(m.Target);
        }
        return missing;
    }
}
