using System.Security.Cryptography;
using Azure;
using Azure.Core;
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// AR Workbench document storage (section ArWorkbenchDocuments). Production values come from Key Vault
/// (ArWorkbenchDocuments--Provider, --BlobServiceUri, ...). The API reaches storage with its managed
/// identity only: no account keys, SAS tokens or connection strings (HIPAA 164.312(d)).
/// </summary>
public sealed class ArWorkbenchDocumentStorageOptions
{
    public const string Section = "ArWorkbenchDocuments";
    public const string AzureBlobProvider = "AzureBlob";

    /// <summary>Existing local root (read by <see cref="LocalArWorkbenchDocumentStore"/>).</summary>
    public string? RootPath { get; set; }
    /// <summary>"Local" (default) or "AzureBlob": where new files go.</summary>
    public string Provider { get; set; } = "Local";
    /// <summary>https://&lt;account&gt;.blob.core.windows.net</summary>
    public string? BlobServiceUri { get; set; }
    public string ContainerName { get; set; } = "arwb-documents";
    /// <summary>User-assigned identity client ID; empty = the system-assigned identity.</summary>
    public string? ManagedIdentityClientId { get; set; }
    /// <summary>Download only after Defender for Storage reports the file clean. A malicious file is always blocked.</summary>
    public bool RequireCleanMalwareScan { get; set; } = true;
    /// <summary>Re-check the SHA-256 recorded at upload on every download.</summary>
    public bool VerifyHashOnDownload { get; set; } = true;
    /// <summary>Files above this size stream without the hash check (it needs the whole file in memory).</summary>
    public long MaxVerifiedDownloadBytes { get; set; } = 52_428_800;
}

/// <summary>
/// Azure Blob store: private account (private endpoint, CMK, versioning, soft delete), blobs written
/// once under {LabName}/{yyyy}/{MM}/{dd}/{guid}{ext} - one folder per lab, named as in LabConfig:LabsID (the
/// list that also picks the lab's database), then the UTC upload date. There is deliberately no claim
/// folder: a claim ID is an identifier, and the claim's files are found through dbo.ARWB_Document.
/// Names, metadata and tags never carry PHI - no claim ID,
/// patient name or uploaded file name; those stay in dbo.ARWB_Document. Each row stores its full
/// BlobPath, so renaming a lab later only changes where new files go.
/// </summary>
public sealed class AzureBlobArWorkbenchDocumentStore : IArWorkbenchDocumentStore
{
    /// <summary>The index tag Defender for Storage writes when on-upload malware scanning finishes.</summary>
    public const string ScanResultTag = "Malware Scanning scan result";

    private readonly BlobContainerClient _container;
    private readonly IReadOnlyDictionary<int, string> _labFolders;
    private readonly ILogger<AzureBlobArWorkbenchDocumentStore> _logger;

    public AzureBlobArWorkbenchDocumentStore(BlobServiceClient service, IOptions<ArWorkbenchDocumentStorageOptions> options,
        IConfiguration configuration, ILogger<AzureBlobArWorkbenchDocumentStore> logger)
    {
        _container = service.GetBlobContainerClient(options.Value.ContainerName);
        // Same rule as SqlArWorkbenchRepository: the first active LabConfig:LabsID entry per Id.
        _labFolders = configuration.GetSection("LabConfig:LabsID").GetChildren()
            .Select(lab => (Id: int.TryParse(lab["Id"], out var id) ? id : 0, Name: lab["Name"], Active: !bool.TryParse(lab["IsActive"], out var active) || active))
            .Where(lab => lab.Id > 0 && lab.Active && !string.IsNullOrWhiteSpace(lab.Name))
            .GroupBy(lab => lab.Id)
            .ToDictionary(g => g.Key, g => SafeFolder(g.First().Name!));
        _logger = logger;
    }

    public string ContainerName => _container.Name;

    /// <summary>The lab's folder in the container: its LabConfig:LabsID name, or lab-{labId} when it has none.</summary>
    internal string LabFolder(int labId)
        => _labFolders.TryGetValue(labId, out var folder) && folder.Length > 0 ? folder : $"lab-{labId}";

    // Letters, digits, '-' and '_' only, so a name can never add a level or escape the folder.
    private static string SafeFolder(string name)
        => new string(name.Trim().Select(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' ? c : '_').ToArray()).Trim('_');

    public async Task<StoredDocument> SaveAsync(int labId, Stream content, string extension, CancellationToken ct)
    {
        // The hash needs a second pass over the bytes, so the stream must be able to rewind.
        Stream source = content;
        MemoryStream? buffer = null;
        if (!content.CanSeek)
        {
            buffer = new MemoryStream();
            await content.CopyToAsync(buffer, ct);
            buffer.Position = 0;
            source = buffer;
        }
        try
        {
            var start = source.Position;
            var sha = Convert.ToHexString(await SHA256.HashDataAsync(source, ct)).ToLowerInvariant();
            var size = source.Position - start;
            source.Position = start;

            var now = DateTime.UtcNow;
            var path = $"{LabFolder(labId)}/{now:yyyy}/{now:MM}/{now:dd}/{Guid.NewGuid():N}{LocalArWorkbenchDocumentStore.SafeExtension(extension)}";
            await _container.GetBlobClient(path).UploadAsync(source, new BlobUploadOptions
            {
                HttpHeaders = new BlobHttpHeaders { ContentType = "application/octet-stream", ContentDisposition = "attachment" },
                Metadata = new Dictionary<string, string> { ["labid"] = labId.ToString(), ["sha256"] = sha },
                // Write-once: never overwrite an existing blob.
                Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All }
            }, ct);
            return new StoredDocument(ContainerName, path, size, sha);
        }
        finally
        {
            buffer?.Dispose();
        }
    }

    public async Task<Stream?> OpenReadAsync(string container, string path, CancellationToken ct)
    {
        if (container != ContainerName) return null;
        try
        {
            var response = await _container.GetBlobClient(path).DownloadStreamingAsync(cancellationToken: ct);
            return response.Value.Content;
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    public async Task DeleteAsync(string container, string path, CancellationToken ct)
    {
        if (container != ContainerName) return;
        try
        {
            await _container.GetBlobClient(path).DeleteIfExistsAsync(DeleteSnapshotsOption.IncludeSnapshots, cancellationToken: ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "AR Workbench: could not delete unrecorded blob {Container}/{Path}", container, path);
        }
    }

    public async Task<DocumentScanResult> GetScanResultAsync(string container, string path, CancellationToken ct)
    {
        if (container != ContainerName) return DocumentScanResult.Unknown;
        try
        {
            var tags = (await _container.GetBlobClient(path).GetTagsAsync(cancellationToken: ct)).Value.Tags;
            if (!tags.TryGetValue(ScanResultTag, out var result)) return DocumentScanResult.Pending;
            return result switch
            {
                "No threats found" => DocumentScanResult.Clean,
                "Malicious" => DocumentScanResult.Malicious,
                _ => DocumentScanResult.Unknown
            };
        }
        catch (RequestFailedException ex)
        {
            _logger.LogWarning("AR Workbench: scan result for blob {Container}/{Path} could not be read (status {Status}, {Code}).",
                container, path, ex.Status, ex.ErrorCode);
            return DocumentScanResult.Unknown;
        }
    }
}

/// <summary>
/// The registered <see cref="IArWorkbenchDocumentStore"/>: new files go to Blob when it is configured,
/// else to disk; each existing row is served by the store its BlobContainer names ("local" = disk).
/// </summary>
public sealed class RoutingArWorkbenchDocumentStore : IArWorkbenchDocumentStore
{
    private readonly LocalArWorkbenchDocumentStore _local;

    public RoutingArWorkbenchDocumentStore(LocalArWorkbenchDocumentStore local, AzureBlobArWorkbenchDocumentStore? blob = null)
    {
        _local = local;
        Blob = blob;
    }

    /// <summary>The Blob store, or null when ArWorkbenchDocuments:Provider is not AzureBlob (used by the migration).</summary>
    public AzureBlobArWorkbenchDocumentStore? Blob { get; }

    public Task<StoredDocument> SaveAsync(int labId, Stream content, string extension, CancellationToken ct)
        => Blob is not null ? Blob.SaveAsync(labId, content, extension, ct) : _local.SaveAsync(labId, content, extension, ct);

    public Task<Stream?> OpenReadAsync(string container, string path, CancellationToken ct) => For(container).OpenReadAsync(container, path, ct);

    public Task DeleteAsync(string container, string path, CancellationToken ct) => For(container).DeleteAsync(container, path, ct);

    public Task<DocumentScanResult> GetScanResultAsync(string container, string path, CancellationToken ct) => For(container).GetScanResultAsync(container, path, ct);

    private IArWorkbenchDocumentStore For(string container)
        => container == LocalArWorkbenchDocumentStore.ContainerName || Blob is null ? _local : Blob;
}

public static class ArWorkbenchDocumentStorageExtensions
{
    /// <summary>
    /// Binds ArWorkbenchDocuments and registers the document stores. Provider = AzureBlob with a
    /// BlobServiceUri sends new files to Blob (managed identity); anything else keeps them on disk.
    /// </summary>
    public static IServiceCollection AddArWorkbenchDocumentStorage(this IServiceCollection services, IConfiguration configuration)
    {
        var section = configuration.GetSection(ArWorkbenchDocumentStorageOptions.Section);
        services.Configure<ArWorkbenchDocumentStorageOptions>(section);
        services.AddSingleton<LocalArWorkbenchDocumentStore>();

        var options = section.Get<ArWorkbenchDocumentStorageOptions>() ?? new ArWorkbenchDocumentStorageOptions();
        var useBlob = string.Equals(options.Provider, ArWorkbenchDocumentStorageOptions.AzureBlobProvider, StringComparison.OrdinalIgnoreCase)
                      && !string.IsNullOrWhiteSpace(options.BlobServiceUri);
        if (useBlob)
        {
            var uriText = options.BlobServiceUri!.Trim();
            if (!Uri.TryCreate(uriText, UriKind.Absolute, out var serviceUri) || serviceUri.Scheme != Uri.UriSchemeHttps)
                throw new InvalidOperationException(
                    $"ArWorkbenchDocuments:BlobServiceUri must be an absolute https URI, e.g. https://stlrnarwbphi.blob.core.windows.net - got '{uriText}'.");

            // The same credential family as Key Vault in Program.cs: the managed identity on the VM or
            // Container App, the developer's az login locally. Never an account key or SAS.
            var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
            {
                ManagedIdentityClientId = string.IsNullOrWhiteSpace(options.ManagedIdentityClientId) ? null : options.ManagedIdentityClientId.Trim()
            });
            var clientOptions = new BlobClientOptions();
            clientOptions.Retry.Mode = RetryMode.Exponential;
            clientOptions.Retry.MaxRetries = 3;

            services.AddSingleton(new BlobServiceClient(serviceUri, credential, clientOptions));
            services.AddSingleton<AzureBlobArWorkbenchDocumentStore>();
            services.AddSingleton(sp => new RoutingArWorkbenchDocumentStore(
                sp.GetRequiredService<LocalArWorkbenchDocumentStore>(), sp.GetRequiredService<AzureBlobArWorkbenchDocumentStore>()));
        }
        else
        {
            services.AddSingleton(sp => new RoutingArWorkbenchDocumentStore(sp.GetRequiredService<LocalArWorkbenchDocumentStore>()));
        }
        services.AddSingleton<IArWorkbenchDocumentStore>(sp => sp.GetRequiredService<RoutingArWorkbenchDocumentStore>());
        return services;
    }
}
