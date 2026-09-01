using DenialDatabaseProcessorWorker.Services.ReportLogging;
using Xunit;

namespace LRN.DenialDatabaseWorker.Tests;

/// <summary>
/// Pins the canonical status vocabulary (spec DD-07 / DD-09 / DD-10).
///
/// These values are an undeclared contract with dbo.DenialStatusMaster, which LRN.ReportsApi seeds
/// in every lab database. A drift here is invisible until a status the workflow app cannot render
/// reaches the board.
/// </summary>
public class DenialStatusTests
{
	[Theory]
	[InlineData("Review", "Pending Review")]
	[InlineData("review", "Pending Review")]
	[InlineData("In Progress", "In-Progress")]
	[InlineData("InProgress", "In-Progress")]
	[InlineData("Pending-Review", "Pending Review")]
	public void Legacy_spellings_map_to_their_canonical_form(string stored, string expected)
		=> Assert.Equal(expected, DenialStatus.Canonical(stored));

	[Theory]
	[InlineData("New")]
	[InlineData("Pending Review")]
	[InlineData("In-Progress")]
	[InlineData("Verification Pending")]
	[InlineData("Duplicate")]
	[InlineData("Completed")]
	[InlineData("Closed")]
	public void A_canonical_status_is_returned_unchanged(string status)
		=> Assert.Equal(status, DenialStatus.Canonical(status));

	[Fact]
	public void An_unrecognized_status_is_cleaned_but_not_rewritten()
	{
		// The workflow app owns statuses this worker has never heard of. Silently rewriting one
		// would be worse than passing it through.
		Assert.Equal("Assigned To AR Reviewer", DenialStatus.Canonical("  Assigned To AR Reviewer  "));
	}

	[Fact]
	public void Invisible_characters_from_spreadsheet_round_trips_are_tolerated()
	{
		// DD-10: non-breaking space, zero-width space and a stray newline all arrive in practice.
		Assert.Equal("Closed", DenialStatus.Canonical("Closed​\r\n"));
		Assert.Equal("Pending Review", DenialStatus.Canonical("Pending Review"));
		Assert.True(DenialStatus.IsClosed("  Closed​ "));
	}

	[Fact]
	public void Blank_and_null_collapse_to_empty()
	{
		Assert.Equal("", DenialStatus.Canonical(null));
		Assert.Equal("", DenialStatus.Canonical("   "));
		Assert.False(DenialStatus.IsClosed(null));
	}

	[Fact]
	public void The_three_system_statuses_are_terminal_and_worker_set_only()
	{
		// DD-08: these must never be offered to a user or accepted by an API endpoint.
		foreach (var status in new[] { DenialStatus.ReSubmitted, DenialStatus.WriteOff, DenialStatus.Adjusted })
		{
			Assert.Contains(status, DenialStatus.SystemSet);
			Assert.True(DenialStatus.IsTerminal(status));
		}

		// Closed is terminal but is set by a person, so it is not in the system-set list.
		Assert.True(DenialStatus.IsTerminal(DenialStatus.Closed));
		Assert.DoesNotContain(DenialStatus.Closed, DenialStatus.SystemSet);

		Assert.False(DenialStatus.IsTerminal(DenialStatus.InProgress));
	}
}
