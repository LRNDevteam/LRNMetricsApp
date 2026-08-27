namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// Worker-level switches for the line-level / claim-level bulk copy. Per-lab and per-level
/// behaviour lives in the lab mapping JSONs; this is only the global on/off and the paths.
/// </summary>
public sealed class LineClaimImportOptions
{
    public const string SectionName = "LineClaimImport";

    /// <summary>
    /// Master switch. Defaults to FALSE so that deploying this change is inert until the SQL
    /// scripts have been run and a lab has been opted in.
    /// </summary>
    public bool Enabled { get; set; }

    /// <summary>Folder holding the per-lab mapping JSONs. Relative paths resolve from the content root.</summary>
    public string LabMappingsFolder { get; set; } = "Schemas/LabMappings";

    /// <summary>
    /// Fail the whole worker at startup when a mapping JSON is invalid. True is the safe default:
    /// a mapping error otherwise shows up as silent NULL columns days later.
    /// </summary>
    public bool FailFastOnInvalidMapping { get; set; } = true;

    /// <summary>
    /// Reports that are produced from the line-level and claim-level data rather than by a run of
    /// their own, and are therefore marked Success on the workflow dashboard once BOTH of those
    /// loaded. Configured in appsettings.json under LineClaimImport:DerivedReports.
    /// </summary>
    public List<DerivedReportOptions> DerivedReports { get; set; } = new();
}

/// <summary>
/// One derived report and the labs that produce it.
/// </summary>
public sealed class DerivedReportOptions
{
    /// <summary>
    /// Must match an active dbo.ReportTypeMaster.ReportTypeName exactly - the upsert procedure
    /// rejects anything else rather than creating a phantom row.
    /// </summary>
    public string ReportName { get; set; } = string.Empty;

    /// <summary>Set false to stop marking this report without deleting the configuration.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// Labs that produce this report. EMPTY means every lab - which is what Clinic Summary wants,
    /// and it keeps a newly onboarded lab covered without anyone remembering to add it here.
    /// Sales Rep Summary lists its labs explicitly because only some have the data.
    /// </summary>
    public List<int> LabIds { get; set; } = new();

    public bool AppliesTo(int labId) => LabIds.Count == 0 || LabIds.Contains(labId);
}
