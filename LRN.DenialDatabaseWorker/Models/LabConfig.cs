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
	public string ClaimActionMapper { get; set; } = "";

	/// <summary>
	/// Whether this lab may fall through to the classifier workbook as a last resort.
	///
	/// Every lab is tried in the same fixed order regardless of this setting: first its own
	/// dbo.DenialCodeMaster (what AR Managers edit in the web app), then LRNMaster's central
	/// dbo.DenialMapperSuperMaster. This setting only decides what happens if BOTH of those come back
	/// empty: File (default) falls through to the newest *Denial_Action_Classifier_v*.xlsx under
	/// <see cref="ClaimActionMapper"/>; Database fails the run instead of silently using a workbook
	/// that may be stale or that no per-lab edit ever reaches.
	/// </summary>
	public ClaimActionMapperSource ClaimActionMapperSource { get; set; } = ClaimActionMapperSource.File;

	public string SharePointUploadPath { get; set; } = "";

	/// <summary>
	/// Use Billed Amount as the Insurance Balance for this lab (spec WK-18).
	///
	/// This was hard-coded to LabId 18/19/20 plus a name match on Certus / Augustus / NorthWest.
	/// Those ids disagree with LRN.MasterFileProcessorWorker for four labs (REQUIREMENTS §12.4), so
	/// keying a financial rule off them was fragile: renumbering a lab silently moved the rule to a
	/// different one. The flag says what is intended instead of inferring it.
	/// </summary>
	public bool OverrideInsuranceBalanceWithBilled { get; set; }
}

public enum ClaimActionMapperSource
{
	File,
	Database
}
