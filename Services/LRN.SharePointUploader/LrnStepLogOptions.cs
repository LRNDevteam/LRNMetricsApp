public sealed class LrnStepLogOptions
{
    public bool Enabled { get; set; } = false;

    /// <summary>
    /// Written into StepLogs.SourceSystem (e.g., "SharePointUploader").
    /// </summary>
    public string SourceSystem { get; set; } = "SharePointUploader";

    /// <summary>
    /// Default step name used for each uploaded file.
    /// </summary>
    public string StepName { get; set; } = "SharePointSync";

    /// <summary>
    /// Default step sequence.
    /// </summary>
    public int StepSeq { get; set; } = 900;
}
