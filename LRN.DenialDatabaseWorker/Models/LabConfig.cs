namespace DenialDatabaseProcessorWorker.Models;

public sealed class LabConfig
{
	public string LabName { get; set; } = "";
	public int LabId { get; set; }

	/// <summary>
	/// Name of the Key Vault secret holding this lab's connection string: "CoveConnection" is read
	/// from the vault secret "ConnectionStrings--CoveConnection". This is what appsettings.json
	/// carries - the connection string itself never appears in a committed file.
	/// </summary>
	public string LabDbConnectionKey { get; set; } = "";

	/// <summary>
	/// Resolved at startup from <see cref="LabDbConnectionKey"/>; see Program.cs. A literal value in
	/// configuration still wins, but use that only for a throwaway local override.
	/// </summary>
	public string LabConnectionString { get; set; } = "";
	public string PayerPolicyFile { get; set; } = "";
	public string ClaimActionMapper { get; set; } = "";
	public string SharePointUploadPath { get; set; } = "";
}
