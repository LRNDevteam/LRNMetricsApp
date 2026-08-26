namespace LabMetricsDashboard.Services;

using Microsoft.Extensions.Logging;

/// <summary>
/// The per-lab generic Production Summary repositories, in one place.
/// <para>
/// Both the web app (Program.cs) and LRN.ReportWorker (Program.cs) register this same
/// map, so a lab added here is picked up by the pages and by queued Excel exports
/// without the two lists drifting apart.
/// </para>
/// <para>
/// Keys are the lab names used in LabSettings / LabConfig:Labs. Augustus and NorthWest
/// are deliberately absent - they have their own dedicated repositories.
/// </para>
/// </summary>
public static class LabProductionSummaryRepositoryMap
{
    public static IReadOnlyDictionary<string, ILabProductionSummaryRepository> Create(
        ILogger<SqlLabProductionSummaryRepository> logger)
        => new Dictionary<string, ILabProductionSummaryRepository>(StringComparer.OrdinalIgnoreCase)
        {
            ["Certus"]           = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.Certus),
            ["Cove"]             = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.Cove),
            ["Elixir"]           = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.Elixir),
            ["PCRLabsofAmerica"] = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.PCRLabsofAmerica),
            ["Beech_Tree"]       = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.BeechTree),
            ["Rising_Tides"]     = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.RisingTides),
            ["Phi_Life"]         = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.PhiLife),
            ["Inhealth_DTR"]     = new SqlLabProductionSummaryRepository(logger, LabSummaryTableConfig.InHealthDTR),
        };
}
