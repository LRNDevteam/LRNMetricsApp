namespace LRN.MasterFileProcessorWorker.Options;

public sealed class MasterFileProcessorOptions
{
    public int PollingIntervalSeconds { get; set; } = 300;
    public string WorkRoot { get; set; } = "work";
    public string SchemasRoot { get; set; } = "schemas";
    public string SourceSystem { get; set; } = "LRN.MasterFileProcessor";
}
