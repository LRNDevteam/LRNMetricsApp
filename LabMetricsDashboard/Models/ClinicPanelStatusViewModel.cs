namespace LabMetricsDashboard.Models;

/// <summary>
/// View model for the Clinic Panel Status pivot table.
/// Rows are ClinicName (with drill-down to PanelName), columns are ClaimStatus values.
/// Cell values are COUNT(DISTINCT ClaimID).
/// </summary>
public sealed class ClinicPanelStatusViewModel
{
    public string SelectedLab { get; init; } = string.Empty;

    /// <summary>Ordered list of distinct ClaimStatus values (column headers).</summary>
    public List<string> Statuses { get; init; } = [];

    /// <summary>Clinic-level rows with nested panel rows, sorted by GrandTotal descending.</summary>
    public List<ClinicPanelStatusClinicRow> Clinics { get; init; } = [];

    /// <summary>Grand total row across all clinics.</summary>
    public Dictionary<string, int> GrandTotals { get; init; } = new();

    public int GrandTotalAll { get; init; }

    public string? ErrorMessage { get; init; }
}

/// <summary>One clinic row in the pivot table.</summary>
public sealed class ClinicPanelStatusClinicRow
{
    public string ClinicName { get; init; } = string.Empty;

    /// <summary>Count per status at the clinic level. Key = ClaimStatus, Value = count of unique ClaimIDs.</summary>
    public Dictionary<string, int> StatusCounts { get; init; } = new();

    public int GrandTotal { get; init; }

    /// <summary>Panel-level drill-down rows under this clinic.</summary>
    public List<ClinicPanelStatusPanelRow> Panels { get; init; } = [];
}

/// <summary>One panel row nested under a clinic in the pivot table.</summary>
public sealed class ClinicPanelStatusPanelRow
{
    public string PanelName { get; init; } = string.Empty;

    /// <summary>Count per status at the panel level. Key = ClaimStatus, Value = count of unique ClaimIDs.</summary>
    public Dictionary<string, int> StatusCounts { get; init; } = new();

    public int GrandTotal { get; init; }
}
