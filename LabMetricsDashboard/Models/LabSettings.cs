namespace LabMetricsDashboard.Models;

/// <summary>
/// Mirrors the "LabConfig" section in appsettings.json.
/// </summary>
public sealed class LabConfigOptions
{
    public const string Section = "LabConfig";

    public string LabConfigFolder { get; init; } = string.Empty;
    public List<string> Labs { get; init; } = [];
    public List<LabIdInfo> LabsID { get; init; } = [];

    /// <summary>
    /// Labs that exist for demos and training rather than for a real client.
    /// They load and behave exactly like any other lab, with one difference: they are left
    /// out of the "admins see every lab" shortcut, so they appear only for users who were
    /// explicitly assigned them in Admin &gt; Assign User Labs - admins included.
    ///
    /// Without this a demo lab would sit in every admin's lab picker and on the Report
    /// Control Board, where a lab with deliberately stale data reads as a broken pipeline.
    /// Sourced from <c>LabConfig:DemoLabs</c>.
    /// </summary>
    public List<string> DemoLabs { get; init; } = [];

    public string? GetLabNameById(int id) =>
        LabsID.FirstOrDefault(l => l.Id == id)?.Name;

    public int? GetLabIdByName(string name) =>
        LabsID.FirstOrDefault(l => string.Equals(l.Name, name, StringComparison.OrdinalIgnoreCase))?.Id;

    public bool IsDemoLab(string? labName) =>
        !string.IsNullOrWhiteSpace(labName)
        && DemoLabs.Any(d => string.Equals(d, labName, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// The labs a user may pick from. <paramref name="assignedLabs"/> are the user's own
    /// LabName claims; an admin gets everything else for free, but never a demo lab they
    /// were not assigned.
    /// </summary>
    public List<string> VisibleLabs(IEnumerable<string> allLabs, ISet<string> assignedLabs, bool isAdmin) =>
        allLabs
            .Where(lab => assignedLabs.Contains(lab) || (isAdmin && !IsDemoLab(lab)))
            .ToList();
}

/// <summary>
/// Lab Id ? Name mapping, sourced from <c>LabConfig:LabsID</c> in appsettings.json.
/// </summary>
public sealed class LabIdInfo
{
    public int Id { get; init; }
    public string Name { get; init; } = string.Empty;
}

/// <summary>
/// Runtime-resolved CSV paths for every lab, keyed by lab name.
/// Populated in Program.cs from the per-lab JSON files in LabConfigFolder.
/// </summary>
public sealed class LabSettings
{
    // NOTE: This is updated at runtime when lab JSON files change (reloadOnChange).
    // Replace the dictionary reference atomically to avoid thread-safety issues.
    public Dictionary<string, LabCsvConfig> Labs { get; set; } = [];
}
