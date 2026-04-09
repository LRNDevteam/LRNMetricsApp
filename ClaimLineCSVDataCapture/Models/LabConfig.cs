using System.Text.Json.Serialization;

namespace ClaimLineCSVDataCapture.Models;

public sealed class LabConfig
{
    public string LabName { get; set; } = string.Empty;

    [JsonPropertyName("Paths")]
    public LabPaths Paths { get; set; } = new();

    [JsonPropertyName("Output")]
    public LabOutput Output { get; set; } = new();

    public bool DBEnabled { get; set; }
    public string? DbConnectionString { get; set; }

    /// <summary>
    /// When <c>true</c>, the claim-line CSV capture process reads the file
    /// and inserts data into SQL via <see cref="DbConnectionString"/>.
    /// </summary>
    public bool ClaimLineInsert { get; set; }

    /// <summary>
    /// Combined path: <c>ServerMastersBasePath</c> \ <c>ServerMasterFolderName</c>.
    /// This is where Claim Level and Line Level CSV files are located.
    /// </summary>
    [JsonIgnore]
    public string ServerMastersPath =>
        string.IsNullOrWhiteSpace(Paths.ServerMastersBasePath) || string.IsNullOrWhiteSpace(Paths.ServerMasterFolderName)
            ? string.Empty
            : Path.Combine(Paths.ServerMastersBasePath, Paths.ServerMasterFolderName);
}

public sealed class LabPaths
{
    public string ServerMastersBasePath { get; set; } = string.Empty;
    public string ServerMasterFolderName { get; set; } = string.Empty;
    public string LabProcessingBasePath { get; set; } = string.Empty;
    public string RecentlyProcessedLineLevelStandardizedFile { get; set; } = string.Empty;
    public string RecentlyProcessedClaimLevelStandardizedFile { get; set; } = string.Empty;
    public string LineLevelStandardizedCsv { get; set; } = string.Empty;
    public string ClaimLevelStandardizedCsv { get; set; } = string.Empty;
    public string PayerMaster { get; set; } = string.Empty;
    public string CodingMaster { get; set; } = string.Empty;
    public string CptFeeSchedule { get; set; } = string.Empty;
}

public sealed class LabOutput
{
    public string PayerCptAverageBase { get; set; } = string.Empty;
    public string CodingValidationBase { get; set; } = string.Empty;
    public string Reports { get; set; } = string.Empty;
    public string Avgs { get; set; } = string.Empty;
    public string Archive { get; set; } = string.Empty;
    public string ConslidatedAvgs { get; set; } = string.Empty;
}
