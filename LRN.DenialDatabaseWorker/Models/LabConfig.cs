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
	/// Where this lab's denial-to-action mapping comes from.
	///
	/// File (default): the newest *Denial_Action_Classifier_v*.xlsx under <see cref="ClaimActionMapper"/>.
	/// Database: the lab's own dbo.DenialCodeMaster, i.e. what AR Managers edit in the web app. Falls
	/// back to File, with a warning, when that table is missing or empty.
	///
	/// Switch a lab to Database only after comparing its DenialCodeMaster against the classifier file:
	/// a code present in the file but absent from the table stops mapping on the next run.
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
