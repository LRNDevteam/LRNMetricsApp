using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Options;

namespace LRN.MasterFileProcessorWorker.Snapshots;

/// <summary>Where snapshot files live. Paths are always '/'-separated and relative to the store root.</summary>
public interface ISnapshotStore
{
    /// <summary>For logs: the account/container or folder files go to.</summary>
    string Location { get; }

    /// <summary>Uploads, overwriting: a re-run of the same RunId replaces its files.</summary>
    Task UploadAsync(string localPath, string snapshotPath, string sha256, CancellationToken ct);

    /// <summary>Deletes every file under <paramref name="prefix"/>; returns how many.</summary>
    Task<int> DeletePrefixAsync(string prefix, CancellationToken ct);
}

/// <summary>Builds the configured <see cref="ISnapshotStore"/> on first use, so a disabled feature never touches storage.</summary>
public sealed class SnapshotStoreFactory
{
    private readonly MasterDataSnapshotOptions _options;
    private readonly IConfiguration _configuration;
    private readonly Lazy<ISnapshotStore> _store;

    public SnapshotStoreFactory(IOptions<MasterDataSnapshotOptions> options, IConfiguration configuration)
    {
        _options = options.Value;
        _configuration = configuration;
        _store = new Lazy<ISnapshotStore>(Create, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public ISnapshotStore Store => _store.Value;

    private ISnapshotStore Create()
    {
        if (string.Equals(_options.Storage, SnapshotStorageKinds.LocalFolder, StringComparison.OrdinalIgnoreCase))
        {
            var root = string.IsNullOrWhiteSpace(_options.LocalFolder) ? "Snapshots" : _options.LocalFolder;
            if (!Path.IsPathRooted(root))
                root = Path.Combine(AppContext.BaseDirectory, root);
            return new LocalFolderSnapshotStore(root);
        }

        if (string.IsNullOrWhiteSpace(_options.ContainerName))
            throw new InvalidOperationException(
                "MasterDataSnapshot:ContainerName is not set. Add the Key Vault secret MasterDataSnapshot--ContainerName " +
                "(e.g. report-snapshots).");

        if (!Uri.TryCreate(_options.BlobServiceUri?.Trim(), UriKind.Absolute, out var serviceUri) || serviceUri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException(
                "MasterDataSnapshot:BlobServiceUri is not set or not an https URI. Add the Key Vault secret " +
                $"MasterDataSnapshot--BlobServiceUri (e.g. https://<account>.blob.core.windows.net) to {_configuration["KeyVault:VaultUri"]}.");

        // The service's managed identity, the same credential that reads Key Vault. Never a key or SAS.
        var service = new BlobServiceClient(serviceUri, new DefaultAzureCredential());
        return new BlobSnapshotStore(service.GetBlobContainerClient(_options.ContainerName.Trim()));
    }
}

public sealed class BlobSnapshotStore : ISnapshotStore
{
    private readonly BlobContainerClient _container;
    private bool _containerChecked;

    public BlobSnapshotStore(BlobContainerClient container) => _container = container;

    public string Location => _container.Uri.ToString();

    public async Task UploadAsync(string localPath, string snapshotPath, string sha256, CancellationToken ct)
    {
        await EnsureContainerAsync(ct).ConfigureAwait(false);

        await _container.GetBlobClient(snapshotPath).UploadAsync(localPath, new BlobUploadOptions
        {
            HttpHeaders = new BlobHttpHeaders { ContentType = "application/vnd.apache.parquet" },
            Metadata = new Dictionary<string, string> { ["sha256"] = sha256 }
        }, ct).ConfigureAwait(false);
    }

    public async Task<int> DeletePrefixAsync(string prefix, CancellationToken ct)
    {
        int deleted = 0;

        await foreach (var item in _container.GetBlobsAsync(prefix: prefix, cancellationToken: ct).ConfigureAwait(false))
        {
            var response = await _container.DeleteBlobIfExistsAsync(item.Name, DeleteSnapshotsOption.IncludeSnapshots, cancellationToken: ct)
                .ConfigureAwait(false);
            if (response.Value) deleted++;
        }

        return deleted;
    }

    private async Task EnsureContainerAsync(CancellationToken ct)
    {
        if (_containerChecked) return;

        // Private: snapshots carry PHI. Never PublicAccessType.Blob/Container.
        await _container.CreateIfNotExistsAsync(PublicAccessType.None, cancellationToken: ct).ConfigureAwait(false);
        _containerChecked = true;
    }
}

public sealed class LocalFolderSnapshotStore : ISnapshotStore
{
    private readonly string _root;

    public LocalFolderSnapshotStore(string root) => _root = root;

    public string Location => _root;

    public Task UploadAsync(string localPath, string snapshotPath, string sha256, CancellationToken ct)
    {
        var target = Resolve(snapshotPath);
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);

        // Copy to a temp name then move, so a reader never opens a half-copied file.
        var temp = target + ".part";
        File.Copy(localPath, temp, overwrite: true);
        File.Move(temp, target, overwrite: true);
        return Task.CompletedTask;
    }

    /// <summary>Same semantics as a blob prefix: "Lab/R1_W1_" removes Lab/R1_W1_*.* (and anything below a matching folder).</summary>
    public Task<int> DeletePrefixAsync(string prefix, CancellationToken ct)
    {
        var slash = prefix.LastIndexOf('/');
        var folder = slash < 0 ? Path.GetFullPath(_root) : Resolve(prefix[..slash]);
        var namePrefix = prefix[(slash + 1)..];

        if (!Directory.Exists(folder))
            return Task.FromResult(0);

        int count = 0;

        foreach (var file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories).ToList())
        {
            var relative = Path.GetRelativePath(folder, file).Replace(Path.DirectorySeparatorChar, '/');
            if (!relative.StartsWith(namePrefix, StringComparison.Ordinal))
                continue;

            File.Delete(file);
            count++;
        }

        return Task.FromResult(count);
    }

    private string Resolve(string snapshotPath)
    {
        var full = Path.GetFullPath(Path.Combine(_root, snapshotPath.Replace('/', Path.DirectorySeparatorChar)));
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(_root)) + Path.DirectorySeparatorChar;

        // Week folder names come from SharePoint; never let one walk out of the root.
        if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Snapshot path '{snapshotPath}' resolves outside {root}.");

        return full;
    }
}
