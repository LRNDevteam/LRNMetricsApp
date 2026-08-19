namespace LRN.AzBlobSync.Models;

public sealed class LatestFolderState
{
    public string RecentFolderName { get; set; } = string.Empty;
    public DateTimeOffset? UploadedUtc { get; set; }
    public string BlobPrefix { get; set; } = string.Empty;
    public int FileCount { get; set; }
    public Dictionary<string, FolderUploadRecord> ProcessedFolders { get; set; } =
        new(StringComparer.OrdinalIgnoreCase);
}

public sealed class FolderUploadRecord
{
    public DateTimeOffset UploadedUtc { get; set; }
    public string Fingerprint { get; set; } = string.Empty;
    public int FileCount { get; set; }
}
