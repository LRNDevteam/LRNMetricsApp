using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services.ArWorkbench;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.SqlServer.TransactSql.ScriptDom;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>HIPAA Blob document storage: file signatures, DI wiring, routing by container, and script 10.</summary>
public class ArWorkbenchDocumentStorageTests
{
    private static IFormFile Upload(string name, params byte[] bytes)
        => new FormFile(new MemoryStream(bytes), 0, bytes.Length, "files", name);

    [Theory]
    [InlineData("scan.tif", new byte[] { 0x49, 0x49, 0x2A, 0x00, 1, 2 })]
    [InlineData("scan.tiff", new byte[] { 0x4D, 0x4D, 0x00, 0x2A, 1, 2 })]
    [InlineData("card.gif", new byte[] { 0x47, 0x49, 0x46, 0x38, 0x39, 0x61 })]
    [InlineData("eob.pdf", new byte[] { 0x25, 0x50, 0x44, 0x46, 0x2D })]
    public async Task ArWorkbench_accepts_scanned_images_and_documents(string name, byte[] bytes)
        => Assert.Null(await FileUploadGuard.ValidateArWorkbenchDocumentAsync(Upload(name, bytes), 1024, CancellationToken.None));

    [Fact]
    public async Task ArWorkbench_rejects_a_renamed_file()
    {
        var error = await FileUploadGuard.ValidateArWorkbenchDocumentAsync(Upload("scan.tif", 0x4D, 0x5A, 0x90, 0x00), 1024, CancellationToken.None);
        Assert.Equal("File content does not match the file extension.", error);
    }

    [Fact]
    public async Task Denial_workflow_document_rules_are_unchanged()
    {
        var error = await FileUploadGuard.ValidateDocumentAsync(Upload("scan.tif", 0x49, 0x49, 0x2A, 0x00), 1024, CancellationToken.None);
        Assert.StartsWith("File type '.tif' is not allowed", error);
    }

    private static ServiceProvider Build(Dictionary<string, string?> settings)
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();
        var services = new ServiceCollection().AddLogging().AddSingleton<IConfiguration>(config);
        services.AddArWorkbenchDocumentStorage(config);
        return services.BuildServiceProvider();
    }

    [Fact]
    public void Local_provider_needs_no_Azure()
    {
        using var sp = Build(new() { ["ArWorkbenchDocuments:Provider"] = "Local" });
        var routing = sp.GetRequiredService<RoutingArWorkbenchDocumentStore>();
        Assert.Null(routing.Blob);
        Assert.Same(routing, sp.GetRequiredService<IArWorkbenchDocumentStore>());
    }

    [Fact]
    public void AzureBlob_provider_registers_the_blob_store()
    {
        using var sp = Build(new()
        {
            ["ArWorkbenchDocuments:Provider"] = "AzureBlob",
            ["ArWorkbenchDocuments:BlobServiceUri"] = "https://stlrnarwbphi.blob.core.windows.net",
            ["ArWorkbenchDocuments:ContainerName"] = "arwb-documents"
        });
        var blob = sp.GetRequiredService<RoutingArWorkbenchDocumentStore>().Blob;
        Assert.NotNull(blob);
        Assert.Equal("arwb-documents", blob!.ContainerName);
    }

    [Fact]
    public void Each_lab_gets_its_own_folder_named_after_LabConfig()
    {
        using var sp = Build(new()
        {
            ["ArWorkbenchDocuments:Provider"] = "AzureBlob",
            ["ArWorkbenchDocuments:BlobServiceUri"] = "https://stlrnarwbphi.blob.core.windows.net",
            ["LabConfig:LabsID:0:Id"] = "13", ["LabConfig:LabsID:0:Name"] = "PCRLabsofAmerica",
            ["LabConfig:LabsID:1:Id"] = "2", ["LabConfig:LabsID:1:Name"] = "Inhealth_DTR",
            // Listed twice in appsettings.json: the first entry wins, as for the database connection.
            ["LabConfig:LabsID:2:Id"] = "25", ["LabConfig:LabsID:2:Name"] = "VariantX",
            ["LabConfig:LabsID:3:Id"] = "25", ["LabConfig:LabsID:3:Name"] = "VariantX Old",
            ["LabConfig:LabsID:4:Id"] = "30", ["LabConfig:LabsID:4:Name"] = "../Beech Tree.Labs"
        });
        var blob = sp.GetRequiredService<RoutingArWorkbenchDocumentStore>().Blob!;
        Assert.Equal("PCRLabsofAmerica", blob.LabFolder(13));
        Assert.Equal("Inhealth_DTR", blob.LabFolder(2));
        Assert.Equal("VariantX", blob.LabFolder(25));
        Assert.Equal("Beech_Tree_Labs", blob.LabFolder(30));
        Assert.Equal("lab-77", blob.LabFolder(77));
    }

    [Fact]
    public void AzureBlob_provider_refuses_a_non_https_uri()
    {
        Assert.Throws<InvalidOperationException>(() => Build(new()
        {
            ["ArWorkbenchDocuments:Provider"] = "AzureBlob",
            ["ArWorkbenchDocuments:BlobServiceUri"] = "http://stlrnarwbphi.blob.core.windows.net"
        }));
    }

    [Fact]
    public async Task Local_rows_are_served_from_disk_without_a_scan()
    {
        var root = Path.Combine(Path.GetTempPath(), "arwb-store-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var sp = Build(new() { ["ArWorkbenchDocuments:RootPath"] = root });
            var store = sp.GetRequiredService<IArWorkbenchDocumentStore>();
            var saved = await store.SaveAsync(7, new MemoryStream([1, 2, 3]), ".pdf", CancellationToken.None);

            Assert.Equal(LocalArWorkbenchDocumentStore.ContainerName, saved.Container);
            Assert.StartsWith("7/", saved.Path);
            Assert.DoesNotContain("..", saved.Path);
            Assert.Equal(DocumentScanResult.NotApplicable, await store.GetScanResultAsync(saved.Container, saved.Path, CancellationToken.None));
            await using (var read = await store.OpenReadAsync(saved.Container, saved.Path, CancellationToken.None))
                Assert.NotNull(read);
            // A blob row while Blob is not configured (the Provider = Local rollback): not found, never a disk path.
            Assert.Null(await store.OpenReadAsync("arwb-documents", saved.Path, CancellationToken.None));

            await store.DeleteAsync(saved.Container, saved.Path, CancellationToken.None);
            Assert.Null(await store.OpenReadAsync(saved.Container, saved.Path, CancellationToken.None));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void Script10_parses()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Sql", "10_ARWB_Document_Blob_HIPAA.sql");
        Assert.True(File.Exists(path), $"Script 10 was not copied to the test output: {path}");
        var parser = new TSql160Parser(initialQuotedIdentifiers: true);
        using var reader = new StringReader(File.ReadAllText(path));
        parser.Parse(reader, out var errors);
        Assert.True(errors.Count == 0, string.Join(Environment.NewLine, errors.Select(e => $"line {e.Line}: {e.Message}")));
    }
}
