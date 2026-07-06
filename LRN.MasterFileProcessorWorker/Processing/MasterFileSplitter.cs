using LRN.MasterFileProcessorWorker.IO;
using LRN.MasterFileProcessorWorker.Schema;

namespace LRN.MasterFileProcessorWorker.Processing;

public sealed class MasterFileSplitter
{
    public async Task<(TabularData Line, TabularData Claim)> SplitAsync(string inputPath, SchemaDefinition schema, CancellationToken ct)
    {
        var ext = Path.GetExtension(inputPath).ToLowerInvariant();

        TabularData line;
        TabularData claim;

        if (ext == ".csv")
        {
            line = await CsvUtils.ReadAsync(inputPath, ct);
            claim = DeriveClaimFromLine(line, schema);
        }
        else if (ext == ".xlsx" || ext == ".xlsm" || ext == ".xltx" || ext == ".xltm")
        {
            line = ExcelReader.ReadSheet(inputPath, schema.Input.LineLevelSheetName, schema.Input.HeaderRow);

            if (!string.IsNullOrWhiteSpace(schema.Input.ClaimLevelSheetName) && ExcelReader.HasSheet(inputPath, schema.Input.ClaimLevelSheetName))
            {
                claim = ExcelReader.ReadSheet(inputPath, schema.Input.ClaimLevelSheetName, schema.Input.HeaderRow);
            }
            else
            {
                claim = DeriveClaimFromLine(line, schema);
            }
        }
        else
        {
            throw new InvalidOperationException($"Unsupported input extension: {ext}");
        }

        return (line, claim);
    }

    private static TabularData DeriveClaimFromLine(TabularData line, SchemaDefinition schema)
    {
        var claim = new TabularData();
        foreach (var c in line.Columns) claim.Columns.Add(c);

        var key = schema.ClaimKey;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var row in line.Rows)
        {
            if (!row.TryGetValue(key, out var keyVal) || string.IsNullOrWhiteSpace(keyVal))
                continue;

            if (seen.Add(keyVal))
                claim.Rows.Add(new Dictionary<string, string?>(row, StringComparer.OrdinalIgnoreCase));
        }

        return claim;
    }
}
