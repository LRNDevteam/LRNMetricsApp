namespace LabMetricsDashboard.Models;

public sealed class DenialFilterAutocompleteOptions
{
    public IReadOnlyList<string> PayerNames { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> PayerTypes { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> PanelNames { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> ReferringProviders { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> ClinicNames { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> SalesRepnames { get; init; } = Array.Empty<string>();
}
