using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Carries the Denial Workflow state for one line item onto the export.
/// <see cref="Notes"/> is the reviewer's comment (dbo.DenialTaskBoard.ReviewerComments,
/// surfaced as <see cref="DenialRecord.Feedback"/>) — what the workflow page shows in its
/// Comments box.
/// </summary>
public sealed record DenialWorkflowAnnotation(
    string TaskId,
    string AssignedTo,
    string Status,
    string Notes)
{
    public static readonly DenialWorkflowAnnotation Empty = new(string.Empty, string.Empty, string.Empty, string.Empty);
}

/// <summary>
/// Matches dbo.DenialLineItem rows to their dbo.DenialTaskBoard task so the Line Item
/// sheet can show the workflow's Assigned To / Status / notes next to each denial.
///
/// The two tables have no shared surrogate key: the task board stores the claim as
/// ClaimID (the "short" claim id) while the line item stores VisitNumber, and the
/// loader writes one with a "CLM-" prefix and the other without — hence the
/// normalization here, which mirrors the API's own ClaimIDNormalized = VisitNumberNormalized
/// matching. Denial codes are matched against BOTH the original and normalized line-item
/// code because the task board keeps whichever form the source file carried.
///
/// Lookup order (first hit wins):
///   1. claim + CPT + denial code — the exact task;
///   2. claim + CPT             — same line, code re-mapped between runs;
/// A claim-only fallback is deliberately NOT used: one claim spans many CPTs that can be
/// assigned to different reviewers, so it would attach the wrong reviewer's notes.
/// </summary>
public sealed class DenialWorkflowLineItemAnnotator
{
    private readonly Dictionary<string, DenialWorkflowAnnotation> _byClaimCptCode;
    private readonly Dictionary<string, DenialWorkflowAnnotation> _byClaimCpt;

    /// <summary>True when at least one task board row was available to match against.</summary>
    public bool HasWorkflowData { get; }

    public DenialWorkflowLineItemAnnotator(IEnumerable<DenialRecord> taskBoardRows)
    {
        _byClaimCptCode = new Dictionary<string, DenialWorkflowAnnotation>(StringComparer.OrdinalIgnoreCase);
        _byClaimCpt = new Dictionary<string, DenialWorkflowAnnotation>(StringComparer.OrdinalIgnoreCase);

        var count = 0;
        // Newest first so the most recent task wins a duplicate key.
        foreach (var row in taskBoardRows.OrderByDescending(x => x.CreatedOn ?? x.DateOpened))
        {
            count++;
            var claim = NormalizeClaim(row.ClaimId);
            if (claim.Length == 0) continue;

            var annotation = new DenialWorkflowAnnotation(
                row.TaskId ?? string.Empty,
                row.AssignedTo ?? string.Empty,
                row.Status ?? string.Empty,
                row.Feedback ?? string.Empty);

            var cpt = Key(row.CptCode);
            var code = Key(row.DenialCode);

            _byClaimCptCode.TryAdd($"{claim}|{cpt}|{code}", annotation);
            _byClaimCpt.TryAdd($"{claim}|{cpt}", annotation);
        }

        HasWorkflowData = count > 0;
    }

    public DenialWorkflowAnnotation Resolve(DenialLineItemRecord item)
    {
        var claim = NormalizeClaim(item.VisitNumber);
        if (claim.Length == 0) return DenialWorkflowAnnotation.Empty;

        var cpt = Key(item.CptCode);

        if (_byClaimCptCode.TryGetValue($"{claim}|{cpt}|{Key(item.DenialCodeNormalized)}", out var byNormalized))
            return byNormalized;
        if (_byClaimCptCode.TryGetValue($"{claim}|{cpt}|{Key(item.DenialCodeOriginal)}", out var byOriginal))
            return byOriginal;
        if (_byClaimCpt.TryGetValue($"{claim}|{cpt}", out var byLine))
            return byLine;

        return DenialWorkflowAnnotation.Empty;
    }

    /// <summary>Drops the loader's "CLM-" prefix so ClaimID and VisitNumber compare equal.</summary>
    private static string NormalizeClaim(string? value)
    {
        var key = Key(value);
        return key.StartsWith("CLM-", StringComparison.OrdinalIgnoreCase) ? key[4..] : key;
    }

    private static string Key(string? value) => (value ?? string.Empty).Trim();
}
