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

    /// <summary>
    /// Denial Summary (Denial Claim Report) week per lab: lab name -> "Mon to Sun" / "Tue to Mon" /
    /// "Wed to Tue" / "Thu to Wed" / "Fri to Thu". Sourced from <c>LabConfig:DenialSummaryWeekRange</c>.
    /// Labs not listed keep the report's default Wednesday-to-Tuesday week.
    /// </summary>
    public Dictionary<string, string> DenialSummaryWeekRange { get; init; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The configured first day of the Denial Summary week for a lab, or null when not configured.</summary>
    public DayOfWeek? GetDenialSummaryWeekStart(string? labName)
    {
        if (string.IsNullOrWhiteSpace(labName) || DenialSummaryWeekRange is null) return null;
        static string Key(string v) => new(v.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        var wanted = Key(labName);
        foreach (var (lab, range) in DenialSummaryWeekRange)
        {
            if (Key(lab) != wanted || string.IsNullOrWhiteSpace(range)) continue;
            // Only a recognised range counts; a typo keeps the default rather than silently becoming Monday.
            return range.Trim().ToLowerInvariant() switch
            {
                "mon to sun" => DayOfWeek.Monday,
                "tue to mon" => DayOfWeek.Tuesday,
                "wed to tue" => DayOfWeek.Wednesday,
                "thu to wed" => DayOfWeek.Thursday,
                "fri to thu" => DayOfWeek.Friday,
                "sat to fri" => DayOfWeek.Saturday,
                "sun to sat" => DayOfWeek.Sunday,
                _ => null
            };
        }
        return null;
    }

    /// <summary>
    /// Denial Summary date column per lab: lab name -> a ClaimLevelData column ("CheckDate") whose
    /// date places each denied claim in a Monthly / Weekly column. Sourced from
    /// <c>LabConfig:DenialSummaryDateColumn</c>. Labs not listed keep the Denial Date.
    /// </summary>
    public Dictionary<string, string> DenialSummaryDateColumn { get; init; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The configured Denial Summary date column for a lab, or null when not configured.</summary>
    public string? GetDenialSummaryDateColumn(string? labName)
    {
        if (string.IsNullOrWhiteSpace(labName) || DenialSummaryDateColumn is null) return null;
        static string Key(string v) => new(v.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        var wanted = Key(labName);
        foreach (var (lab, column) in DenialSummaryDateColumn)
        {
            if (Key(lab) == wanted && !string.IsNullOrWhiteSpace(column)) return column.Trim();
        }
        return null;
    }

    /// <summary>
    /// Denial Summary balance column per lab: lab name -> the ClaimLevelData column the Monthly /
    /// Weekly summaries, tiles, Claim Level tab and download are measured on ("TotalInsuranceBalance").
    /// Sourced from <c>LabConfig:DenialSummaryBalanceColumn</c>. Labs not listed keep InsuranceBalance.
    /// </summary>
    public Dictionary<string, string> DenialSummaryBalanceColumn { get; init; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The configured Denial Summary balance column for a lab, or null when not configured.</summary>
    public string? GetDenialSummaryBalanceColumn(string? labName)
    {
        if (string.IsNullOrWhiteSpace(labName) || DenialSummaryBalanceColumn is null) return null;
        static string Key(string v) => new(v.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        var wanted = Key(labName);
        foreach (var (lab, column) in DenialSummaryBalanceColumn)
        {
            if (Key(lab) == wanted && !string.IsNullOrWhiteSpace(column)) return column.Trim();
        }
        return null;
    }

    /// <summary>
    /// How a lab key is shown on screen: lab key -> display name. Sourced from
    /// <c>LabConfig:LabDisplayNames</c>. Lab keys double as file names (Configs\&lt;key&gt;.json,
    /// output folders), so they carry no spaces; this puts the space back for display only.
    /// Labs not listed show their key as before.
    /// </summary>
    public Dictionary<string, string> LabDisplayNames { get; init; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The configured display name for a lab key or tracker lab name, else the name itself.</summary>
    public string DisplayNameFor(string? labName)
    {
        if (string.IsNullOrWhiteSpace(labName) || LabDisplayNames is null) return labName ?? string.Empty;
        static string Key(string v) => new(v.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        var wanted = Key(labName);
        foreach (var (lab, display) in LabDisplayNames)
        {
            if (Key(lab) == wanted && !string.IsNullOrWhiteSpace(display)) return display.Trim();
        }
        return labName;
    }

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
