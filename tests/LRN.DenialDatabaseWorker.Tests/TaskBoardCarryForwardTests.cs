using DenialDatabaseProcessorWorker.Builders;
using DenialDatabaseProcessorWorker.Services;
using Xunit;
using static DenialDatabaseProcessorWorker.Services.DenialTaskBoardRepository;

namespace LRN.DenialDatabaseWorker.Tests;

/// <summary>
/// The status carry-forward table from spec §4.9, and the TaskID sequencing that replaced the
/// per-run counter (DD-04).
///
/// This is the rule that protects human work: an in-flight status must never be overwritten by a
/// re-import (WK-17). Getting it wrong silently returns assigned, part-worked denials to New on the
/// next nightly pass, which no test downstream would catch.
/// </summary>
public class TaskBoardCarryForwardTests
{
	private const string Visit = "500090";
	private const string Accession = "ACC1";
	private const string Dos = "2026-02-05";
	private const string Cpt = "81514";
	private const string DenialCode = "CO29";

	private static string ClaimUid => $"{Visit}_{Accession}_20260205";
	private static string TrackId => $"{ClaimUid}|{Cpt}|{DenialCode}";

	private static List<Dictionary<string, string>> OneLine() => new()
	{
		new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
		{
			["DenialCode_Normalized"] = DenialCode,
			["Visit Number"] = Visit,
			["Accession No"] = Accession,
			["Date of Service"] = Dos,
			["CPTCode"] = Cpt,
			["PatientID"] = "P1",
			["Denial Description"] = "Timely filing",
			["Recommended Action"] = "Gather proof of timely filing",
			["Insurance Balance"] = "125.50",
			["SLA (Days)"] = "7"
		}
	};

	private static Dictionary<string, ExistingTaskInfo> Existing(
		string status, string assignedTo, string taskId = "TSK-00042", string workflowStatus = "") =>
		new(StringComparer.OrdinalIgnoreCase)
		{
			[TrackId] = new ExistingTaskInfo
			{
				TaskId = taskId,
				Status = status,
				AssignedTo = assignedTo,
				WorkFlowStatus = workflowStatus,
				DateOpened = new DateTime(2026, 1, 2),
				DateCompleted = null
			}
		};

	private static Dictionary<string, string> BuildOne(Dictionary<string, ExistingTaskInfo> existing)
	{
		var builder = new TaskBoardBuilder(18, "Certus", "R20260205CER0001", existing);
		var rows = builder.Build(OneLine());
		return Assert.Single(rows);
	}

	[Fact]
	public void A_denial_with_no_existing_task_starts_New()
	{
		var row = BuildOne(new Dictionary<string, ExistingTaskInfo>());

		Assert.Equal("New", row["Status"]);
		Assert.Equal(TrackId, row["UniqueTrackId"]);
		Assert.Equal(ClaimUid, row["ClaimUID"]);
	}

	[Theory]
	[InlineData("In-Progress", "In-Progress")]
	[InlineData("Completed", "Completed")]
	[InlineData("Verification Pending", "Verification Pending")]
	// Anything else a reviewer left it in returns to their queue for review.
	[InlineData("Assigned", "Pending Review")]
	[InlineData("Pending Review", "Pending Review")]
	// Legacy spelling is canonicalized on the way through (DD-09).
	[InlineData("Review", "Pending Review")]
	public void An_assigned_task_keeps_the_state_its_reviewer_put_it_in(string stored, string expected)
	{
		var row = BuildOne(Existing(stored, "jameel"));

		Assert.Equal(expected, row["Status"]);
		Assert.Equal("jameel", row["Assigned To"]);
	}

	[Theory]
	[InlineData("Pending Review")]
	[InlineData("In-Progress")]
	[InlineData("Assigned")]
	public void An_unassigned_task_is_redefined_by_the_incoming_run(string stored)
	{
		// No human work to protect, so §4.9 hands it back to the pipeline.
		var row = BuildOne(Existing(stored, ""));
		Assert.Equal("New", row["Status"]);
	}

	[Fact]
	public void A_closed_task_is_never_resurrected()
	{
		// Deviation 12.8: §4.9 says unassigned goes to New regardless, but that is only safe once
		// §7 archives closed denials first. Carry-forward reads a snapshot taken BEFORE
		// reconciliation, so Closed short-circuits in both assigned and unassigned cases.
		Assert.Equal("Closed", BuildOne(Existing("Closed", ""))["Status"]);
		Assert.Equal("Closed", BuildOne(Existing("Closed", "jameel"))["Status"]);
	}

	[Fact]
	public void An_existing_task_keeps_its_TaskID_and_DateOpened()
	{
		var row = BuildOne(Existing("In-Progress", "jameel", taskId: "TSK-00042"));

		Assert.Equal("TSK-00042", row["Task ID"]);
		Assert.Equal("2026-01-02", row["Date Opened"]);
	}

	[Fact]
	public void New_tasks_are_left_blank_until_the_reserved_block_is_stamped()
	{
		// The count is only knowable after the board is built, so Build leaves the id blank and the
		// worker reserves exactly this many from the lab's persistent sequence.
		var builder = new TaskBoardBuilder(18, "Certus", "R1", new Dictionary<string, ExistingTaskInfo>());
		var rows = builder.Build(OneLine());

		Assert.Equal(1, builder.NewTaskCount);
		Assert.Equal("", rows[0]["Task ID"]);

		builder.AssignNewTaskIds(500);
		Assert.Equal("TSK-00500", rows[0]["Task ID"]);
	}

	[Fact]
	public void A_carried_task_consumes_no_new_id()
	{
		var builder = new TaskBoardBuilder(18, "Certus", "R1", Existing("In-Progress", "jameel"));
		builder.Build(OneLine());

		Assert.Equal(0, builder.NewTaskCount);
	}

	[Fact]
	public void TaskIds_widen_past_five_digits_rather_than_wrapping()
	{
		Assert.Equal("TSK-00001", TaskIdSequenceRepository.Format(1));
		Assert.Equal("TSK-99999", TaskIdSequenceRepository.Format(99999));
		Assert.Equal("TSK-100000", TaskIdSequenceRepository.Format(100000));
	}

	[Fact]
	public void A_line_with_no_normalized_denial_code_produces_no_task()
	{
		var lines = OneLine();
		lines[0]["DenialCode_Normalized"] = "";

		var builder = new TaskBoardBuilder(18, "Certus", "R1", new Dictionary<string, ExistingTaskInfo>());
		Assert.Empty(builder.Build(lines));
	}

	[Fact]
	public void Multiple_denial_codes_on_one_line_produce_one_task_each()
	{
		var lines = OneLine();
		lines[0]["DenialCode_Normalized"] = "CO29;CO97";

		var builder = new TaskBoardBuilder(18, "Certus", "R1", new Dictionary<string, ExistingTaskInfo>());
		var rows = builder.Build(lines);

		Assert.Equal(2, rows.Count);
		Assert.Equal(new[] { "CO29", "CO97" }, rows.Select(r => r["Denial Code"]).ToArray());
		Assert.Equal(2, builder.NewTaskCount);
	}
}
