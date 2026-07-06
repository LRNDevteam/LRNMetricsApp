using LRN.SharePointClient.Models;

namespace LRN.MasterFileProcessorWorker.Options;

public sealed class LabOptions
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;

    public SharePointLocation Input { get; set; } = new SharePointLocation("", "", "");
    public SharePointLocation Output { get; set; } = new SharePointLocation("", "", "");
    public SharePointLocation Logs { get; set; } = new SharePointLocation("", "", "");

    /// <summary>
    /// File name under SchemasRoot.
    /// </summary>
    public string SchemaFile { get; set; } = string.Empty;
}
