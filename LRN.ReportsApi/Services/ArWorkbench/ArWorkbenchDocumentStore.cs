using System.Security.Cryptography;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Where AR Workbench attachments live. dbo.ARWB_Document keeps only the metadata (BlobContainer /
/// BlobPath); this store holds the bytes. Registered as <see cref="RoutingArWorkbenchDocumentStore"/>:
/// new files go to Azure Blob Storage when configured (AzureBlobArWorkbenchDocumentStore.cs), and
/// rows with container "local" are still read from disk until they are migrated.
/// </summary>
public interface IArWorkbenchDocumentStore
{
    /// <summary>Saves the stream; returns the container, the path inside it, the size and the SHA-256.</summary>
    Task<StoredDocument> SaveAsync(int labId, Stream content, string extension, CancellationToken ct);
    /// <summary>The stored bytes, or null when the container/path is not this store's or the file is gone.</summary>
    Task<Stream?> OpenReadAsync(string container, string path, CancellationToken ct);
    /// <summary>Removes a file that was stored but never recorded (refused or failed upload).</summary>
    Task DeleteAsync(string container, string path, CancellationToken ct);
    /// <summary>Malware scan state (Defender for Storage on Blob; NotApplicable on local disk).</summary>
    Task<DocumentScanResult> GetScanResultAsync(string container, string path, CancellationToken ct);
}

public enum DocumentScanResult { NotApplicable, Pending, Clean, Malicious, Unknown }

public sealed record StoredDocument(string Container, string Path, long SizeBytes, string Sha256);

/// <summary>A stored file being attached to a claim, with its own document type (category from the type) and optional notes.</summary>
public sealed record ArWorkbenchClaimUpload(string FileName, string? ContentType, StoredDocument Stored, ArWorkbenchDocumentType Type, string? Description);

/// <summary>
/// Disk store under ArWorkbenchDocuments:RootPath (default: the Denial Workflow upload root +
/// \ARWorkbench). Files are named by a GUID - never by the uploaded name - in lab\yyyy\MM folders.
/// Legacy: with ArWorkbenchDocuments:Provider = AzureBlob new files go to Blob, and the "local" rows
/// are read from here until POST documents/admin/migrate-to-blob moves them. It only takes new files
/// when Provider = Local (development, or the rollback when Blob is unreachable).
/// </summary>
public sealed class LocalArWorkbenchDocumentStore : IArWorkbenchDocumentStore
{
    public const string ContainerName = "local";
    private readonly string _root;

    public LocalArWorkbenchDocumentStore(IConfiguration configuration)
    {
        var configured = configuration["ArWorkbenchDocuments:RootPath"];
        _root = !string.IsNullOrWhiteSpace(configured)
            ? configured
            : Path.Combine(configuration["DenialWorkflowFileStorage:UploadRootPath"] ?? Path.Combine(AppContext.BaseDirectory, "Uploads"), "ARWorkbench");
    }

    public async Task<StoredDocument> SaveAsync(int labId, Stream content, string extension, CancellationToken ct)
    {
        var ext = SafeExtension(extension);
        var now = DateTime.UtcNow;
        var relative = Path.Combine(labId.ToString(), now.ToString("yyyy"), now.ToString("MM"), $"{Guid.NewGuid():N}{ext}");
        var full = FullPath(relative);
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);

        using var sha = SHA256.Create();
        await using (var file = File.Create(full))
        await using (var hashing = new CryptoStream(file, sha, CryptoStreamMode.Write))
        {
            await content.CopyToAsync(hashing, ct);
        }
        var size = new FileInfo(full).Length;
        return new StoredDocument(ContainerName, relative.Replace('\\', '/'), size, Convert.ToHexString(sha.Hash!).ToLowerInvariant());
    }

    public Task<Stream?> OpenReadAsync(string container, string path, CancellationToken ct)
    {
        if (container != ContainerName) return Task.FromResult<Stream?>(null);
        var full = FullPath(path);
        return Task.FromResult<Stream?>(File.Exists(full) ? File.OpenRead(full) : null);
    }

    public Task DeleteAsync(string container, string path, CancellationToken ct)
    {
        if (container != ContainerName) return Task.CompletedTask;
        try { var full = FullPath(path); if (File.Exists(full)) File.Delete(full); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        return Task.CompletedTask;
    }

    /// <summary>Files on disk are not scanned by Defender for Storage.</summary>
    public Task<DocumentScanResult> GetScanResultAsync(string container, string path, CancellationToken ct)
        => Task.FromResult(DocumentScanResult.NotApplicable);

    // The stored path is ours, but resolve defensively: it must stay inside the root.
    private string FullPath(string relative)
    {
        var rootFull = Path.GetFullPath(_root);
        var full = Path.GetFullPath(Path.Combine(rootFull, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (!full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Invalid document path.");
        return full;
    }

    // Shared with the Blob store so both name files the same way.
    internal static string SafeExtension(string extension)
    {
        var ext = (extension ?? string.Empty).Trim().ToLowerInvariant();
        if (!ext.StartsWith('.')) ext = "." + ext;
        return ext.Length is > 1 and <= 10 && ext[1..].All(char.IsLetterOrDigit) ? ext : ".bin";
    }
}
