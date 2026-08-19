using System.Text.Json;
using LRN.AzBlobSync.Models;

namespace LRN.AzBlobSync.Services;

public sealed class LatestFolderStateStore
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly BlobSyncOptions _options;
    private readonly ILogger<LatestFolderStateStore> _logger;
    private readonly object _gate = new();

    public LatestFolderStateStore(BlobSyncOptions options, ILogger<LatestFolderStateStore> logger)
    {
        _options = options;
        _logger = logger;
    }

    public LatestFolderState Load()
    {
        lock (_gate)
        {
            var path = _options.StateJsonPath;
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
                return new LatestFolderState();

            try
            {
                var json = File.ReadAllText(path);
                return JsonSerializer.Deserialize<LatestFolderState>(json, JsonOpts) ?? new LatestFolderState();
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "[BlobSync] Could not read state JSON {Path} — starting empty.", path);
                return new LatestFolderState();
            }
        }
    }

    public void Save(LatestFolderState state)
    {
        lock (_gate)
        {
            var path = _options.StateJsonPath;
            if (string.IsNullOrWhiteSpace(path))
                throw new InvalidOperationException("BlobSync:StateJsonPath is not configured.");

            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(dir))
                Directory.CreateDirectory(dir);

            var tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(state, JsonOpts));
            File.Copy(tmp, path, overwrite: true);
            File.Delete(tmp);

            _logger.LogInformation(
                "[BlobSync] Updated recent folder JSON: {Folder} → {Path}",
                state.RecentFolderName, path);
        }
    }
}
