using System.Text;
using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using LRN.AzBlobSync.Models;

namespace LRN.AzBlobSync.Services;

public sealed class AzureBlobUploader
{
    public const string LatestBlobName = "latest-folder.json";

    private readonly BlobSyncOptions _options;
    private readonly KeyVaultSecretReader _secrets;
    private readonly ILogger<AzureBlobUploader> _logger;
    private BlobContainerClient? _container;

    public AzureBlobUploader(
        BlobSyncOptions options,
        KeyVaultSecretReader secrets,
        ILogger<AzureBlobUploader> logger)
    {
        _options = options;
        _secrets = secrets;
        _logger = logger;
    }

    public async Task EnsureDestinationAsync(CancellationToken ct)
    {
        var container = await GetContainerAsync(ct);

        var prefix = NormalizePrefix(_options.BlobPrefix);
        var marker = container.GetBlobClient($"{prefix}/.keep");
        if (!await marker.ExistsAsync(ct))
        {
            await using var empty = new MemoryStream(Encoding.UTF8.GetBytes("beech-tree three-pillar inputs"));
            await marker.UploadAsync(empty, overwrite: true, cancellationToken: ct);
            _logger.LogInformation("[BlobSync] Created blob folder '{Prefix}' in container '{Container}'.", prefix, _options.ContainerName);
        }
        else
        {
            _logger.LogInformation("[BlobSync] Blob folder '{Prefix}' already exists.", prefix);
        }
    }

    public async Task<int> UploadWeekFolderAsync(
        DirectoryInfo weekFolder,
        IReadOnlyList<FileInfo> jsonFiles,
        CancellationToken ct)
    {
        var container = await GetContainerAsync(ct);
        var prefix = NormalizePrefix(_options.BlobPrefix);
        var weekName = weekFolder.Name;
        var uploaded = 0;

        foreach (var file in jsonFiles)
        {
            ct.ThrowIfCancellationRequested();
            var relative = Path.GetRelativePath(weekFolder.FullName, file.FullName).Replace('\\', '/');
            var blobPath = $"{prefix}/{weekName}/{relative}";
            var blob = container.GetBlobClient(blobPath);

            await using var stream = file.Open(FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            await blob.UploadAsync(stream, new BlobUploadOptions
            {
                HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" },
            }, ct);

            uploaded++;
            _logger.LogInformation("[BlobSync] Uploaded {Blob}", blob.Uri.AbsolutePath);
        }

        return uploaded;
    }

    public async Task UploadLatestStateAsync(string json, CancellationToken ct)
    {
        var container = await GetContainerAsync(ct);
        var prefix = NormalizePrefix(_options.BlobPrefix);
        var blob = container.GetBlobClient($"{prefix}/{LatestBlobName}");
        var bytes = Encoding.UTF8.GetBytes(json);
        await using var stream = new MemoryStream(bytes);
        await blob.UploadAsync(stream, new BlobUploadOptions
        {
            HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" },
        }, ct);

        _logger.LogInformation("[BlobSync] Updated blob latest-folder JSON: {Blob}", blob.Uri.AbsolutePath);
    }

    public async Task<string?> TryDownloadTextAsync(string blobPath, CancellationToken ct)
    {
        var container = await GetContainerAsync(ct);
        var blob = container.GetBlobClient(NormalizeBlobPath(blobPath));
        try
        {
            var result = await blob.DownloadContentAsync(ct);
            return result.Value.Content.ToString();
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    public async Task UploadTextAsync(string blobPath, string text, CancellationToken ct)
    {
        var container = await GetContainerAsync(ct);
        var blob = container.GetBlobClient(NormalizeBlobPath(blobPath));
        var bytes = Encoding.UTF8.GetBytes(text);
        await using var stream = new MemoryStream(bytes);
        await blob.UploadAsync(stream, new BlobUploadOptions
        {
            HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" },
        }, ct);

        _logger.LogInformation("[BlobSync] Uploaded {Blob}", blob.Uri.AbsolutePath);
    }

    private static string NormalizeBlobPath(string blobPath)
        => blobPath.Replace('\\', '/').Trim('/');

    private async Task<BlobContainerClient> GetContainerAsync(CancellationToken ct)
    {
        if (_container is not null)
            return _container;

        if (!string.IsNullOrWhiteSpace(_options.KeyVaultUri) && !string.IsNullOrWhiteSpace(_options.SecretName))
        {
            var sas = await _secrets.GetSecretAsync(ct);
            _container = CreateClientFromSas(sas);
            _logger.LogInformation(
                "[BlobSync] Using Key Vault SAS for container '{Container}'.",
                _options.ContainerName);
            return _container;
        }

        if (string.IsNullOrWhiteSpace(_options.ConnectionString)
            || _options.ConnectionString.Contains("PUT-YOUR-KEY-HERE", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "Set BlobSync:KeyVaultUri and BlobSync:SecretName (preferred), or BlobSync:ConnectionString.");
        }

        var service = new BlobServiceClient(_options.ConnectionString);
        _container = service.GetBlobContainerClient(_options.ContainerName);
        return _container;
    }

    private BlobContainerClient CreateClientFromSas(string secretValue)
    {
        var value = secretValue.Trim().Trim('"');

        if (value.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            return new BlobContainerClient(new Uri(value));

        if (value.StartsWith("DefaultEndpointsProtocol=", StringComparison.OrdinalIgnoreCase))
            return new BlobServiceClient(value).GetBlobContainerClient(_options.ContainerName);

        var token = value.TrimStart('?');
        var uri = new Uri(
            $"https://lrnbackupstorage01.blob.core.windows.net/{_options.ContainerName}?{token}");
        return new BlobContainerClient(uri);
    }

    private static string NormalizePrefix(string prefix)
        => prefix.Trim().Trim('/');
}
