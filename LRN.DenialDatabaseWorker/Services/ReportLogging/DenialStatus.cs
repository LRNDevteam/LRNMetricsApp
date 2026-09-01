namespace DenialDatabaseProcessorWorker.Services.ReportLogging;

/// <summary>
/// The task-progression vocabulary for dbo.DenialTaskBoard.Status (spec DD-07).
///
/// These mirror dbo.DenialStatusMaster, which LRN.ReportsApi seeds in every lab database
/// (Sql/Denial_Lab_Database_Setup_Merged.sql). The seven human statuses are the API's; the three
/// system statuses at the bottom are set ONLY by this worker and must never be offered to a user
/// or accepted by an API endpoint (DD-08).
///
/// This is deliberately NOT the same axis as DenialTaskBoard.WorkFlowStatus, which the workflow
/// app uses for escalation state ("Internal Escalation", "Response Escalation", "Closed Claim",
/// "Assigned To AR Reviewer", …). Do not fold the two together — see REQUIREMENTS §12 note on the
/// two status axes.
/// </summary>
public static class DenialStatus
{
	// ── Human statuses, shared with LRN.ReportsApi ───────────────────────────────────────────
	public const string New = "New";
	public const string PendingReview = "Pending Review";
	public const string InProgress = "In-Progress";
	public const string VerificationPending = "Verification Pending";
	public const string Duplicate = "Duplicate";
	public const string Completed = "Completed";
	public const string Closed = "Closed";

	// ── System statuses, set only by this worker (DD-08) ─────────────────────────────────────
	public const string ReSubmitted = "Re-Submitted";
	public const string WriteOff = "Write Off";
	public const string Adjusted = "Adjusted";

	/// <summary>Statuses that terminally remove a denial from the board.</summary>
	public static readonly IReadOnlySet<string> Terminal =
		new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Closed, ReSubmitted, WriteOff, Adjusted };

	/// <summary>Statuses this worker may set. Anything else on the board came from a human.</summary>
	public static readonly IReadOnlySet<string> SystemSet =
		new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ReSubmitted, WriteOff, Adjusted };

	/// <summary>
	/// Legacy stored values mapped to their canonical form (DD-09). "Open" is deliberately absent:
	/// it is a display rollup of New + Pending Review + In-Progress, never a stored value.
	/// </summary>
	private static readonly Dictionary<string, string> LegacyAliases = new(StringComparer.OrdinalIgnoreCase)
	{
		["Review"] = PendingReview,
		["In Progress"] = InProgress,
		["InProgress"] = InProgress,
		["Pending-Review"] = PendingReview
	};

	/// <summary>
	/// Canonicalizes a stored status. Tolerates the non-breaking spaces, zero-width spaces and
	/// stray newlines that arrive from spreadsheet round-trips (DD-10), then maps legacy spellings.
	/// An unrecognized value is returned cleaned but otherwise untouched — this worker must not
	/// silently rewrite a status the workflow app introduced.
	/// </summary>
	public static string Canonical(string? value)
	{
		var cleaned = Clean(value);

		if (cleaned.Length == 0)
			return "";

		return LegacyAliases.TryGetValue(cleaned, out var canonical) ? canonical : cleaned;
	}

	/// <summary>Strips invisible characters and collapses whitespace, without changing the word.</summary>
	public static string Clean(string? value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return "";

		return value
			.Replace(" ", " ")
			.Replace("​", "")
			.Replace("\r", " ")
			.Replace("\n", " ")
			.Trim();
	}

	public static bool IsClosed(string? value)
		=> string.Equals(Canonical(value), Closed, StringComparison.OrdinalIgnoreCase);

	public static bool IsTerminal(string? value)
		=> Terminal.Contains(Canonical(value));
}
