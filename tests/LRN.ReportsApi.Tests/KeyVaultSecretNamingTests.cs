using Azure.Extensions.AspNetCore.Configuration.Secrets;
using Azure.Security.KeyVault.Secrets;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Pins the vault-secret-name to configuration-key convention that both Program.cs files rely on.
///
/// Nothing in either app maps these names itself — they hand the vault to AddAzureKeyVault and let
/// its default <see cref="KeyVaultSecretManager"/> do the translation. That makes the convention an
/// undeclared contract between the names typed into kv-lrnmetrics-prod and the keys the code reads,
/// and getting it wrong is invisible until startup: the app boots with no connection strings and
/// fails on the first query with "ConnectionStrings:DefaultConnection is missing".
///
/// These run offline against the real KeyVaultSecretManager — no vault, no credential.
/// </summary>
public class KeyVaultSecretNamingTests
{
    private static string KeyFor(string secretName) =>
        new KeyVaultSecretManager().GetKey(
            SecretModelFactory.KeyVaultSecret(SecretModelFactory.SecretProperties(name: secretName), "unused"));

    [Theory]
    [InlineData("ConnectionStrings--DefaultConnection", "ConnectionStrings:DefaultConnection")]
    [InlineData("ConnectionStrings--NWLConnection", "ConnectionStrings:NWLConnection")]
    [InlineData("DenialWorkflowAuth--JwtSigningKey", "DenialWorkflowAuth:JwtSigningKey")]
    [InlineData("DenialWorkflowAuth--ImportApiKey", "DenialWorkflowAuth:ImportApiKey")]
    [InlineData("DenialWorkflowAuth--TokenMinutes", "DenialWorkflowAuth:TokenMinutes")]
    public void Double_dash_in_a_secret_name_becomes_a_configuration_section_separator(
        string secretName, string expectedKey)
        => Assert.Equal(expectedKey, KeyFor(secretName));

    [Fact]
    public void Connection_strings_from_the_vault_are_visible_to_GetConnectionString()
    {
        // The apps never read "ConnectionStrings:DefaultConnection" by that literal — they call
        // GetConnectionString("DefaultConnection"). Same key, but worth stating outright.
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            [KeyFor("ConnectionStrings--DefaultConnection")] = "Server=lrnmaster;Database=LRNMaster;",
            [KeyFor("ConnectionStrings--NWLConnection")] = "Server=lrnmaster;Database=NWL_LRN;"
        }).Build();

        Assert.Equal("Server=lrnmaster;Database=LRNMaster;", config.GetConnectionString("DefaultConnection"));
        Assert.Equal("Server=lrnmaster;Database=NWL_LRN;", config.GetConnectionString("NWLConnection"));
    }

    [Fact]
    public void An_indexed_secret_merges_into_the_array_entry_appsettings_declares()
    {
        // ExternalApiClients:Clients is split across two providers on purpose: the vault holds the
        // client id and secret hash, appsettings.json holds the display name and roles. They have to
        // land on the SAME array element or the client authenticates with no roles — or not at all.
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                // Stands in for appsettings.json.
                ["ExternalApiClients:Clients:0:DisplayName"] = "LRN ETL Data Center",
                ["ExternalApiClients:Clients:0:Roles:0"] = "ETL",
                ["ExternalApiClients:Clients:0:Enabled"] = "true"
            })
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                // Stands in for the vault, under the names the KeyVaultSecretManager produces.
                [KeyFor("ExternalApiClients--Clients--0--ClientId")] = "LRN-ETL-API-8IF4K7UT09S",
                [KeyFor("ExternalApiClients--Clients--0--SecretHash")] = "a-verifier"
            })
            .Build();

        var clients = config.GetSection("ExternalApiClients:Clients").GetChildren().ToList();
        var client = Assert.Single(clients);

        Assert.Equal("LRN-ETL-API-8IF4K7UT09S", client["ClientId"]);
        Assert.Equal("a-verifier", client["SecretHash"]);
        Assert.Equal("LRN ETL Data Center", client["DisplayName"]);
        Assert.Equal("ETL", client["Roles:0"]);
        Assert.Equal("true", client["Enabled"]);
    }

    [Fact]
    public void The_vault_provider_overrides_a_value_already_loaded_from_a_local_file()
    {
        // Program.cs adds the vault AFTER appsettings.Local.json precisely so this holds. If the
        // order were reversed, a stale connection string left on a server would quietly outrank
        // the vault's.
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:DefaultConnection"] = "stale-local-value"
            })
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                [KeyFor("ConnectionStrings--DefaultConnection")] = "vault-value"
            })
            .Build();

        Assert.Equal("vault-value", config.GetConnectionString("DefaultConnection"));
    }
}
