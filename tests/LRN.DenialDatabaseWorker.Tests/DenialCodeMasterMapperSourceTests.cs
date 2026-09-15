using DenialDatabaseProcessorWorker.Models;
using DenialDatabaseProcessorWorker.Services;
using Xunit;

namespace LRN.DenialDatabaseWorker.Tests;

/// <summary>
/// Rows read from dbo.DenialCodeMaster must map exactly like rows read from the classifier workbook.
///
/// ClaimActionMapperIndex finds columns by fuzzy header match (equal, starts-with or contains), so a
/// header that happens to contain another column's name would silently pick up the wrong value.
/// Every column gets a distinct value here so any such cross-wiring fails.
/// </summary>
public class DenialCodeMasterMapperSourceTests
{
	private static Dictionary<string, string> Row(string code, string icd, string suffix = "")
	{
		var row = DenialCodeMasterRepository.Columns
			.ToDictionary(c => c.Header, c => c.Column + suffix, StringComparer.OrdinalIgnoreCase);
		row["Denial Code"] = code;
		row["ICD Compliance Status"] = icd;
		return row;
	}

	[Fact]
	public void Every_column_maps_to_its_own_field()
	{
		var index = new ClaimActionMapperIndex([Row("CO-50", "Compliant")]);

		var mapped = Assert.Single(index.FindByCodeAndICD("co-50", "compliant"));

		Assert.Equal("CO-50", mapped.DenialCode);
		Assert.Equal("DenialDescription", mapped.DenialDescription);
		Assert.Equal("DenialClassification", mapped.DenialClassification);
		Assert.Equal("CoverageStatus", mapped.CoverageStatus);
		Assert.Equal("COMPLIANT", mapped.IcdComplianceStatus);
		Assert.Equal("DenialValidity", mapped.DenialValidity);
		Assert.Equal("ActionCode", mapped.ActionCode);
		Assert.Equal("RecommendedAction", mapped.RecommendedAction);
		Assert.Equal("ActionCategory", mapped.ActionCategory);
		Assert.Equal("Task", mapped.Task);
		Assert.Equal("ShortCategory", mapped.ShortCategory);
		Assert.Equal("Priority", mapped.Priority);
		Assert.Equal("SLADays", mapped.SlaDays);
		Assert.Equal("NotesComments", mapped.NotesComments);
	}

	[Fact]
	public void NA_icd_row_is_the_fallback_for_an_unlisted_icd_status()
	{
		// The API stores a blank ICD Compliance Status as "N/A", which the index treats as the wildcard.
		var index = new ClaimActionMapperIndex([Row("CO-16", "N/A", "-any"), Row("CO-16", "Non-Compliant", "-nc")]);

		Assert.Equal("ActionCode-nc", Assert.Single(index.FindByCodeAndICD("CO-16", "Non-Compliant")).ActionCode);
		Assert.Equal("ActionCode-any", Assert.Single(index.FindByCodeAndICD("CO-16", "Compliant")).ActionCode);
	}

	[Fact]
	public void Labs_default_to_the_classifier_workbook()
		=> Assert.Equal(ClaimActionMapperSource.File, new LabConfig().ClaimActionMapperSource);
}
