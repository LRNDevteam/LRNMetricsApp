using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Handoff §9.2: internal follow-up comments and QA notes are never shown to client users (Client,
/// Clinic and Provider Viewers - RoleCode "viewer"). A client sees the claim's own data and, on the
/// Escalation Requests screen, only the client-facing CIP comment and their response.
/// <para>
/// Applied by the API to every claim read a viewer can make, so opening a claim by its URL
/// (#/claims/{key}) or calling the claim API directly exposes nothing more than the screen shows
/// (test report DEF-15).
/// </para>
/// </summary>
public static class ArWorkbenchClientVisibility
{
    /// <summary>Claim row columns that describe internal work rather than the claim itself.</summary>
    private static readonly string[] InternalClaimColumns =
    [
        "QaStatus", "QaIsEscalation", "QaIsWriteOff", "QaSubmittedBy", "QaSubmittedOn",
        "PendingAgentRequests", "AssignedAgentUser", "AssignedAgentName", "AssignmentBatchId",
        "WorkedStatus", "FixResolution", "AdHocFollowUpAssigned"
    ];

    /// <summary>
    /// Claims export columns a client never gets: every note on the claim, the follow-up note fields,
    /// its QA review, the status verification and who the claim is assigned to. The claim's own data
    /// (codes, amounts, dates, statuses from the master file) stays.
    /// </summary>
    public static readonly IReadOnlySet<string> InternalExportColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "Assigned Agent", "Fix / Resolution", "Notes", "Assigned By", "Assigned On",
        "Follow-Up Notes Logged", "FU Claim Type", "FU Follow Up Type", "FU Claim Status", "FU Denial Root Cause",
        "FU Fix / Resolution", "FU Comment", "FU Next Follow-Up Date", "FU CIP Category", "FU CIP Required Info",
        "FU CIP Comment", "FU Logged By", "FU Logged By Role", "FU Logged On",
        "QA Status", "QA Reviewed By", "QA Reviewer Role", "QA Reviewed On", "QA Error Type", "QA / Manager Comment",
        "Status Verification", "Source Status Change", "Verification Manager", "Verification Decision",
        "Verified By", "Verified On", "Verification Comment"
    };

    public static bool IsClientUser(ArWorkbenchUserContext user) => !user.SiteAdmin && user.RoleCode == "viewer";

    /// <summary>The claim list (GET claims): the same internal fields the claim page hides.</summary>
    public static void Apply(IEnumerable<ArWorkbenchClaimRow> rows, ArWorkbenchUserContext user)
    {
        if (!IsClientUser(user)) return;
        foreach (var row in rows)
        {
            row.AssignedAgentUser = null;
            row.AssignedAgentName = null;
            row.FixResolution = null;
            row.QaStatus = null;
            row.PendingAgentRequests = 0;
        }
    }

    /// <summary>Removes everything internal from <paramref name="detail"/> when the caller is a client user.</summary>
    public static void Apply(ArWorkbenchClaimDetail detail, ArWorkbenchUserContext user)
    {
        if (!IsClientUser(user)) return;

        detail.FollowUps = new();        // agent follow-up notes (internal comment)
        detail.Activity = new();         // timeline: agent / QA / manager notes
        detail.QaReview = null;          // QA scoring, error type and notes
        detail.CipCases = new();         // full CIP history incl. internal comments; clients use Escalation Requests
        detail.AgentRequests = new();    // escalation / reassignment requests

        foreach (var column in InternalClaimColumns)
            detail.Claim.Remove(column);
    }
}
