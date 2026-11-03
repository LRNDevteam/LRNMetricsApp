using Azure.Identity;
using Azure.Storage.Blobs;

namespace LabMetricsDashboard.Services.ReportSnapshots;

/// <summary>
/// Read-only access to the weekly snapshot files (LRNMaster.dbo.ReportSnapshotFile.BlobPath), for the
/// snapshot viewer. The master file processor and LRN.SnapshotGenerator write them; this never writes.
/// </summary>
public interface IReportSnapshotFileStore
{
    /// <summary>The whole file in memory (snapshot files are a few MB); throws when it is missing.</summary>
    Task<byte[]> ReadAsync(string snapshotPath, CancellationToken ct);
}

/// <summary>
/// Same settings as the two services, section <c>MasterDataSnapshot</c>: <c>Storage</c> "Blob" (default) or
/// "LocalFolder" with <c>LocalFolder</c>; for Blob the Key Vault secrets <c>MasterDataSnapshot--BlobServiceUri</c>
/// and <c>MasterDataSnapshot--ContainerName</c>. Authenticates as the site's managed identity, which needs
/// Storage Blob Data Reader on the container - never a key or SAS.
/// </summary>
public sealed class ReportSnapshotFileStore : IReportSnapshotFileStore
{
    /// <summary>Larger files are refused rather than loaded into the web server's memory.</summary>
    public const long MaxFileBytes = 200L * 1024 * 1024;

    private readonly IConfiguration _configuration;
    private readonly Lazy<BlobContainerClient?> _container;

    public ReportSnapshotFileStore(IConfiguration configuration)
    {
        _configuration = configuration;
        _container = new Lazy<BlobContainerClient?>(CreateContainer, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    private IConfigurationSection Section => _configuration.GetSection("MasterDataSnapshot");

    private bool IsLocalFolder =>
        string.Equals(Section["Storage"], "LocalFolder", StringComparison.OrdinalIgnoreCase);

    public async Task<byte[]> ReadAsync(string snapshotPath, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(snapshotPath))
            throw new ArgumentException("No snapshot path.", nameof(snapshotPath));

        if (IsLocalFolder)
        {
            var file = ResolveLocal(snapshotPath);
            if (new FileInfo(file).Length > MaxFileBytes)
                throw new InvalidOperationException($"{snapshotPath} is larger than {MaxFileBytes / 1024 / 1024} MB.");
            return await File.ReadAllBytesAsync(file, ct);
        }

        var blob = _container.Value!.GetBlobClient(snapshotPath);
        var properties = await blob.GetPropertiesAsync(cancellationToken: ct);
        if (properties.Value.ContentLength > MaxFileBytes)
            throw new InvalidOperationException($"{snapshotPath} is larger than {MaxFileBytes / 1024 / 1024} MB.");
        var content = await blob.DownloadContentAsync(ct);
        return content.Value.Content.ToArray();
    }

    private BlobContainerClient? CreateContainer()
    {
        if (IsLocalFolder) return null;

        var container = Section["ContainerName"]?.Trim();
        if (string.IsNullOrWhiteSpace(container))
            throw new InvalidOperationException(
                "MasterDataSnapshot:ContainerName is not set. Add the Key Vault secret MasterDataSnapshot--ContainerName " +
                "(the snapshot container the master file processor writes to).");
        if (!Uri.TryCreate(Section["BlobServiceUri"]?.Trim(), UriKind.Absolute, out var serviceUri) || serviceUri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException(
                "MasterDataSnapshot:BlobServiceUri is not set or not an https URI. Add the Key Vault secret " +
                "MasterDataSnapshot--BlobServiceUri (e.g. https://<account>.blob.core.windows.net).");

        return new BlobServiceClient(serviceUri, new DefaultAzureCredential()).GetBlobContainerClient(container);
    }

    private string ResolveLocal(string snapshotPath)
    {
        var root = Section["LocalFolder"];
        if (string.IsNullOrWhiteSpace(root)) root = "Snapshots";
        if (!Path.IsPathRooted(root)) root = Path.Combine(AppContext.BaseDirectory, root);

        var full = Path.GetFullPath(Path.Combine(root, snapshotPath.Replace('/', Path.DirectorySeparatorChar)));
        var rootFull = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
        // The path comes from the index; never let it walk out of the snapshot folder.
        if (!full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Snapshot path '{snapshotPath}' resolves outside {rootFull}.");
        return full;
    }
}
