using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>Escalation &amp; Reassignment Request rules, free of SQL so they can be unit-tested.</summary>
public static class ArWorkbenchAgentRequestRules
{
    public const string Escalation = "Escalation to Supervisor";
    public const string Reassignment = "Reassignment Request";
    public const int MaxNoteLength = 2000;
    public const int MaxBulk = 500;

    public static readonly IReadOnlyList<string> Types = [Escalation, Reassignment];

    /// <summary>escalation / reassignment (or the full type name) -> the stored RequestType; null when unknown.</summary>
    public static string? ParseType(string? value) => (value ?? string.Empty).Trim().ToLowerInvariant() switch
    {
        "escalation" or "escalate" or "escalation to supervisor" => Escalation,
        "reassignment" or "reassign" or "reassignment request" => Reassignment,
        _ => null
    };

    /// <summary>The Master Values list a request type's reason must come from.</summary>
    public static string ReasonList(string requestType) => requestType == Escalation ? "ESCALATION_REASON" : "REASSIGNMENT_REASON";

    /// <summary>Activity entry written when the request is raised, and when it is answered.</summary>
    public static string RaisedActivity(string requestType) => requestType == Escalation ? "Escalated to Supervisor" : "Reassignment Requested";
    public static string ResolvedActivity(string requestType) => requestType == Escalation ? "Escalation Resolved" : "Reassignment Request Resolved";

    /// <summary>
    /// Shape checks for a new request: a known type, a reason (checked against the active list by the
    /// repository) and a note of 1-2000 characters. Returns the stored type, trimmed reason and note.
    /// </summary>
    public static (string? Type, string? Reason, string? Note, string? Error) ValidateCreate(ArWorkbenchAgentRequestCreate? request)
    {
        var type = ParseType(request?.RequestType);
        if (type is null) return (null, null, null, "Choose Escalate to Supervisor or Request Reassignment.");
        var reason = request!.ReasonCategory?.Trim();
        if (string.IsNullOrEmpty(reason)) return (null, null, null, "Choose a reason.");
        var note = request.Note?.Trim();
        if (string.IsNullOrEmpty(note)) return (null, null, null, type == Escalation ? "Describe what you need the supervisor's help with." : "Explain why the claim should be reassigned.");
        if (note.Length > MaxNoteLength) return (null, null, null, $"The note must be {MaxNoteLength:N0} characters or fewer.");
        return (type, reason, note, null);
    }

    /// <summary>A resolve needs at least one request (at most 500, duplicates removed) and a response note.</summary>
    public static (IReadOnlyList<long>? Ids, string? Note, string? Error) ValidateResolve(ArWorkbenchAgentRequestResolve? request)
    {
        var ids = (request?.RequestIds ?? []).Where(id => id > 0).Distinct().ToList();
        if (ids.Count == 0) return (null, null, "Select at least one request.");
        if (ids.Count > MaxBulk) return (null, null, $"Resolve at most {MaxBulk} requests at a time.");
        var note = request!.Note?.Trim();
        if (string.IsNullOrEmpty(note)) return (null, null, "Add a response note: it is what the agent sees.");
        if (note.Length > MaxNoteLength) return (null, null, $"The note must be {MaxNoteLength:N0} characters or fewer.");
        return (ids, note, null);
    }
}
