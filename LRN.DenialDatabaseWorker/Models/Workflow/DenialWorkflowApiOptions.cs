namespace DenialDatabaseProcessorWorker.Models.Workflow;

public sealed class DenialWorkflowApiOptions
{
    public const string SectionName = "DenialWorkflowApi";
    public bool Enabled { get; set; } = true;
    public string BaseUrl { get; set; } = "http://localhost:5058";
}
