using LRN.ReportsApi.Services;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>With a Key Vault configured, lab connections come from its secrets only.</summary>
public class LabConnectionResolverTests
{
    private const string Prod = "Server=s;Initial Catalog=InHealthDTRLRN;";
    private const string Test = "Server=s;Initial Catalog=InHealthTEST;";

    private static IConfigurationRoot Config(Dictionary<string, string?> settings, Dictionary<string, string?>? vault)
    {
        var builder = new ConfigurationBuilder().AddInMemoryCollection(settings);
        if (vault is not null) builder.Add(new FakeAzureKeyVaultSource(vault));
        return builder.Build();
    }

    [Fact]
    public void Vault_secret_is_used_over_appsettings()
    {
        var config = Config(new() { ["ConnectionStrings:InHealthConn"] = Prod },
                            new() { ["ConnectionStrings:InHealthConn"] = Test });
        Assert.Equal(Test, LabConnectionResolver.Resolve(config, 2, "Inhealth_DTR", null, out var source));
        Assert.Contains("Key Vault", source);
    }

    [Fact]
    public void With_a_vault_appsettings_alone_is_never_used()
    {
        var config = Config(new() { ["ConnectionStrings:InHealthConn"] = Prod, ["ConnectionStrings:Lab_2"] = Prod },
                            new() { ["ConnectionStrings:DefaultConnection"] = "x" });
        Assert.Equal(string.Empty, LabConnectionResolver.Resolve(config, 2, "Inhealth_DTR", null, out var source));
        Assert.Contains("no matching Key Vault secret", source);
    }

    [Fact]
    public void Without_a_vault_appsettings_is_used()
    {
        var config = Config(new() { ["ConnectionStrings:InHealthConn"] = Prod }, null);
        Assert.Equal(Prod, LabConnectionResolver.Resolve(config, 2, "Inhealth_DTR", null, out _));
    }

    private sealed class FakeAzureKeyVaultSource(Dictionary<string, string?> data) : IConfigurationSource
    {
        public IConfigurationProvider Build(IConfigurationBuilder builder) => new FakeAzureKeyVaultProvider(data);
    }

    // The resolver recognises the vault provider by its type name, as with AzureKeyVaultConfigurationProvider.
    private sealed class FakeAzureKeyVaultProvider : ConfigurationProvider
    {
        public FakeAzureKeyVaultProvider(Dictionary<string, string?> data)
            => Data = new Dictionary<string, string?>(data, StringComparer.OrdinalIgnoreCase);
    }
}
