using System.Text.Json.Serialization;

namespace RcmWatcherService.Models;

/// <summary>Per-lab configuration loaded from each lab's dedicated JSON file.</summary>
public sealed class LabCsvConfig
{
    public string  ProductionMasterCsvPath         { get; init; } = string.Empty;
    public string  PayerPolicyValidationReportPath { get; init; } = string.Empty;
    public bool    DBEnabled                       { get; init; }
    public string? DbConnectionString             { get; init; }
    public string? DbLabName                      { get; init; }
    public string? InsightPath                    { get; init; }

    /// <summary>
    /// Accepts both "RCMJsonPath" and "RCMJsonpath" (the key used in lab JSON files).
    /// </summary>
    [JsonPropertyName("RCMJsonpath")]
    public string? RCMJsonPath                    { get; init; }
}
