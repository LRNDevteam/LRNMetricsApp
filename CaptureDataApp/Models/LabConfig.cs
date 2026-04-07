using System.Text.Json.Serialization;

namespace CaptureDataApp.Models;

public sealed class LabConfig
{
 public string LabName { get; set; } = string.Empty;
 [JsonPropertyName("Paths")]
 public LabPaths Paths { get; set; } = new();
 [JsonPropertyName("Output")]
 public LabOutput Output { get; set; } = new();
 public bool DBEnabled { get; set; }
 public string? DbConnectionString { get; set; }

 /// <summary>The lab-specific folder that contains the latest CodingValidated reports.</summary>
 [JsonIgnore]
 public string CodingReportsPath => Output.Reports;
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
