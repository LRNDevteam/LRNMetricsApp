using System.Security.Cryptography;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Where AR Workbench attachments live. dbo.ARWB_Document keeps only the metadata (BlobContainer /
/// BlobPath); this store holds the bytes. The handoff targets Azure Blob Storage; until that is
/// provisioned the local-disk store below is used (container "local"), and a blob implementation
/// can replace it behind this interface without touching the callers or the table.
/// </summary>
public interface IArWorkbenchDocumentStore
{
    /// <summary>Saves the stream; returns the container, the path inside it, the size and the SHA-256.</summary>
    Task<StoredDocument> SaveAsync(int labId, Stream content, string extension, CancellationToken ct);
    Stream? OpenRead(string container, string path);
    void Delete(string container, string path);
}

public sealed record StoredDocument(string Container, string Path, long SizeBytes, string Sha256);

/// <summary>
/// Disk store under ArWorkbenchDocuments:RootPath (default: the Denial Workflow upload root +
/// \ARWorkbench). Files are named by a GUID - never by the uploaded name - in lab\yyyy\MM folders.
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

    public Stream? OpenRead(string container, string path)
    {
        if (container != ContainerName) return null;
        var full = FullPath(path);
        return File.Exists(full) ? File.OpenRead(full) : null;
    }

    public void Delete(string container, string path)
    {
        if (container != ContainerName) return;
        try { var full = FullPath(path); if (File.Exists(full)) File.Delete(full); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    // The stored path is ours, but resolve defensively: it must stay inside the root.
    private string FullPath(string relative)
    {
        var rootFull = Path.GetFullPath(_root);
        var full = Path.GetFullPath(Path.Combine(rootFull, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (!full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Invalid document path.");
        return full;
    }

    private static string SafeExtension(string extension)
    {
        var ext = (extension ?? string.Empty).Trim().ToLowerInvariant();
        if (!ext.StartsWith('.')) ext = "." + ext;
        return ext.Length is > 1 and <= 10 && ext[1..].All(char.IsLetterOrDigit) ? ext : ".bin";
    }
}
