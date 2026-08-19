using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using LRN.AzBlobSync.Models;

namespace LRN.AzBlobSync.Services;

public sealed class KeyVaultSecretReader
{
    private readonly BlobSyncOptions _options;
    private readonly ILogger<KeyVaultSecretReader> _logger;
    private readonly Dictionary<string, string> _cache = new(StringComparer.OrdinalIgnoreCase);

    public KeyVaultSecretReader(BlobSyncOptions options, ILogger<KeyVaultSecretReader> logger)
    {
        _options = options;
        _logger = logger;
    }

    public Task<string> GetSecretAsync(CancellationToken ct)
        => GetSecretAsync(_options.SecretName, ct);

    public async Task<string> GetSecretAsync(string secretName, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(secretName))
            throw new InvalidOperationException("Secret name is empty.");

        if (_cache.TryGetValue(secretName, out var cached))
            return cached;

        if (string.IsNullOrWhiteSpace(_options.KeyVaultUri))
        {
            throw new InvalidOperationException(
                "BlobSync:KeyVaultUri must be set in appsettings.json.");
        }

        var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ExcludeInteractiveBrowserCredential = true,
        });

        var client = new SecretClient(new Uri(_options.KeyVaultUri.TrimEnd('/')), credential);
        _logger.LogInformation(
            "[BlobSync] Reading secret '{Secret}' from {Vault}",
            secretName, _options.KeyVaultUri);

        var secret = await client.GetSecretAsync(secretName, cancellationToken: ct);
        var value = secret.Value.Value?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(value))
            throw new InvalidOperationException($"Key Vault secret '{secretName}' is empty.");

        _cache[secretName] = value;
        _logger.LogInformation("[BlobSync] Loaded Key Vault secret '{Secret}'.", secretName);
        return value;
    }
}
