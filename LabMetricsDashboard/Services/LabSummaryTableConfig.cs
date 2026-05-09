namespace LabMetricsDashboard.Services;

/// <summary>
/// Describes the pre-aggregated output table schema used by
/// <see cref="SqlLabProductionSummaryRepository"/> for a specific lab.
/// Each lab that has its own SP-generated aggregate tables (06–11 scripts)
/// gets one of these records registered in DI.
/// </summary>
/// <param name="Prefix">
/// Table-name prefix, e.g. <c>"Cert_"</c>, <c>"Cove_"</c>, <c>"Elix_"</c>,
/// <c>"PCR_"</c>, <c>"BT_"</c>, <c>"RT_"</c>.
/// </param>
/// <param name="UnbilledAgingRowKey">
/// Column name for the row-group key in the UnbilledAging table.
/// <c>"PanelName"</c> for most labs; <c>"PayerName"</c> for Certus.
/// </param>
/// <param name="UnbilledAgingBucketCol">
/// Column name for the aging bucket in the UnbilledAging table.
/// Typically <c>"AgingBucket"</c>, <c>"AgingDOS"</c>, or <c>"Aging"</c>.
/// </param>
/// <param name="UnbilledAgingHasCharges">
/// <c>true</c> when a <c>TotalCharges</c> column exists in the UnbilledAging table.
/// <c>false</c> for Cove (table was created without it).
/// </param>
/// <param name="HasCodingTables">
/// <c>true</c> when <c>{Prefix}CodingPanelSummary</c> and
/// <c>{Prefix}CodingCPTDetail</c> exist.
/// <c>false</c> for Certus (no coding SP).
/// </param>
public record LabSummaryTableConfig(
    string Prefix,
    string UnbilledAgingRowKey,
    string UnbilledAgingBucketCol,
    bool   UnbilledAgingHasCharges,
    bool   HasCodingTables)
{
    /// <summary>
    /// <c>true</c> when ALL of the lab's Production Summary read stored procedures
    /// (<c>usp_Get{Prefix}MonthlyBilledProductionSummary</c>,
    /// <c>usp_Get{Prefix}WeeklyBilledProductionSummary</c>,
    /// <c>usp_Get{Prefix}CodingBreakdown</c>,
    /// <c>usp_Get{Prefix}PayerBreakdown</c>,
    /// <c>usp_Get{Prefix}PayerByPanel</c>,
    /// <c>usp_Get{Prefix}UnbilledAging</c>,
    /// <c>usp_Get{Prefix}CPTBreakdown</c>) accept the standard filter parameter
    /// contract and aggregate live from <c>dbo.ClaimLevelData</c> /
    /// <c>dbo.LineLevelData</c> when filters are supplied. When <c>false</c>,
    /// <see cref="SqlLabProductionSummaryRepository"/> falls back to the legacy
    /// direct-<c>SELECT</c> against the snapshot tables (no filter support) and
    /// the controller routes the filtered Monthly/Weekly path through
    /// <see cref="IProductionReportRepository"/>.
    /// </summary>
    public bool SupportsFilteredMonthlyWeeklySp { get; init; }

    // ?? Static per-lab configs ????????????????????????????????????????????

    /// <summary>Certus Labs — prefix <c>Cert_</c>. Row key = PayerName. No coding tables.</summary>
    public static readonly LabSummaryTableConfig Certus =
        new("Cert_", "PayerName",  "Aging",       UnbilledAgingHasCharges: true,  HasCodingTables: false)
        { SupportsFilteredMonthlyWeeklySp = true };

    /// <summary>COVE Labs — prefix <c>Cove_</c>. Aging table has no TotalCharges column.</summary>
    public static readonly LabSummaryTableConfig Cove =
        new("Cove_", "PanelName",  "AgingDOS",    UnbilledAgingHasCharges: false, HasCodingTables: true)
        { SupportsFilteredMonthlyWeeklySp = true };

    /// <summary>Elixir Labs — prefix <c>Elix_</c>.</summary>
    public static readonly LabSummaryTableConfig Elixir =
        new("Elix_", "PanelName",  "AgingBucket", UnbilledAgingHasCharges: true,  HasCodingTables: true)
        { SupportsFilteredMonthlyWeeklySp = true };

    /// <summary>PCR Labs of America — prefix <c>PCR_</c>. Monthly/Weekly read SPs accept filter parameters.</summary>
    public static readonly LabSummaryTableConfig PCRLabsofAmerica =
        new("PCR_",  "PanelName",  "AgingBucket", UnbilledAgingHasCharges: true,  HasCodingTables: true)
        { SupportsFilteredMonthlyWeeklySp = true };

    /// <summary>Beech Tree — prefix <c>BT_</c>.</summary>
    public static readonly LabSummaryTableConfig BeechTree =
        new("BT_",   "PanelName",  "AgingBucket", UnbilledAgingHasCharges: true,  HasCodingTables: true)
        { SupportsFilteredMonthlyWeeklySp = true };

    /// <summary>Rising Tides — prefix <c>RT_</c>.</summary>
    public static readonly LabSummaryTableConfig RisingTides =
        new("RT_",   "PanelName",  "AgingBucket", UnbilledAgingHasCharges: true,  HasCodingTables: true)
        { SupportsFilteredMonthlyWeeklySp = true };
}
