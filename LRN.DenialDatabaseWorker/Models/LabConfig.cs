namespace DenialDatabaseProcessorWorker.Models;

public sealed class LabConfig
{
	public string LabName { get; set; } = "";
	public int LabId { get; set; }
	public string LabConnectionString { get; set; } = "";
	public string PayerPolicyFile { get; set; } = "";
	public string ClaimActionMapper { get; set; } = "";
	public string SharePointUploadPath { get; set; } = "";
}
