using LabMetricsDashboard.Models;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services;

/// <summary>The outcome of an availability check for one report on one lab.</summary>
/// <param name="IsAvailable">False means the cell renders as a padlock rather than a run status.</param>
/// <param name="LockReason">Why it is locked, for the cell tooltip. Null when available.</param>
public sealed record ReportAvailabilityResult(bool IsAvailable, string? LockReason);

/// <summary>
/// Decides whether a report is offered to a lab at all, before any run status is considered.
/// </summary>
public interface IReportAvailabilityService
{
    /// <param name="featureEnabled">
    /// The lab's own feature flag for this report, already resolved by the caller (including its
    /// "unmapped lab" guard). Only consulted when configuration has no rule for the report.
    /// </param>
    ReportAvailabilityResult Evaluate(
        ReportCatalogEntry entry,
        string? labKey,
        string? labDisplayName,
        bool featureEnabled);
}

/// <summary>
/// Reads the "ReportAvailability" section on every call through <see cref="IOptionsMonitor{T}"/>,
/// so an edit to appsettings.json shows up on the next page load without an app restart.
///
/// Precedence, deliberately: a rule in configuration REPLACES the built-in decision for that
/// report rather than narrowing it. An admin who adds a lab to a report's list expects to see the
/// report appear; if the lab's feature flag still had a veto, the setting would look broken. The
/// flag continues to govern whether the cell can be CLICKED THROUGH to the page — see
/// ReportBoardController.BuildCell — so a lab that is listed here but has the page switched off
/// shows its true run status with a tooltip saying the feature is not enabled.
/// </summary>
public sealed class ReportAvailabilityService : IReportAvailabilityService
{
    private readonly IOptionsMonitor<ReportAvailabilitySettings> _settings;

    public ReportAvailabilityService(IOptionsMonitor<ReportAvailabilitySettings> settings)
        => _settings = settings;

    public ReportAvailabilityResult Evaluate(
        ReportCatalogEntry entry,
        string? labKey,
        string? labDisplayName,
        bool featureEnabled)
    {
        var rule = FindRule(entry);

        if (rule is not null)
        {
            if (!rule.Enabled)
                return Locked(rule, "This report is switched off for all labs in settings.");

            if (MatchesAny(rule.ExcludeLabs, labKey, labDisplayName))
                return Locked(rule, "This lab is excluded from this report in settings.");

            if (rule.Labs.Count > 0 && !MatchesAny(rule.Labs, labKey, labDisplayName))
                return Locked(rule, $"Only {Join(rule.Labs)} produce this report.");

            return new ReportAvailabilityResult(true, null);
        }

        // No rule in configuration: the behaviour the board has always had.
        if (!ReportCatalog.IsAvailableForLab(entry, labKey, labDisplayName))
            return new ReportAvailabilityResult(false, "This report is not produced for this lab.");

        if (!featureEnabled)
            return new ReportAvailabilityResult(false, "This report is not enabled for this lab.");

        return new ReportAvailabilityResult(true, null);
    }

    /// <summary>A rule's own Note wins over the generated sentence, so an admin can explain the lock.</summary>
    private static ReportAvailabilityResult Locked(ReportAvailabilityRule rule, string fallback)
        => new(false, string.IsNullOrWhiteSpace(rule.Note) ? fallback : rule.Note.Trim());

    /// <summary>
    /// Finds the rule for a report. The settings key may be the tracker column, the display name
    /// or the short column header, in any casing or spacing.
    /// </summary>
    private ReportAvailabilityRule? FindRule(ReportCatalogEntry entry)
    {
        var reports = _settings.CurrentValue?.Reports;
        if (reports is null || reports.Count == 0) return null;

        var names = new[] { entry.TrackerColumn, entry.DisplayName, entry.ShortName }
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(Key)
            .ToHashSet(StringComparer.Ordinal);

        foreach (var (name, rule) in reports)
        {
            if (rule is not null && names.Contains(Key(name))) return rule;
        }

        return null;
    }

    private static bool MatchesAny(List<string>? labs, string? labKey, string? labDisplayName)
    {
        if (labs is null || labs.Count == 0) return false;

        var candidates = new[] { labKey, labDisplayName }
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(ReportCatalog.LabToken)
            .ToList();
        if (candidates.Count == 0) return false;

        return labs.Any(lab =>
        {
            var token = ReportCatalog.LabToken(lab);
            return token.Length > 0 && candidates.Any(c => c == token);
        });
    }

    /// <summary>Letters and digits only, upper-cased — "Coding Validation" == "codingvalidation".</summary>
    private static string Key(string? value)
        => new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    /// <summary>"Cove, Certus and PCR Labs of America" — reads as a sentence in the tooltip.</summary>
    private static string Join(List<string> labs)
    {
        var names = labs.Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim()).ToList();
        return names.Count switch
        {
            0 => "some labs",
            1 => names[0],
            _ => $"{string.Join(", ", names.Take(names.Count - 1))} and {names[^1]}"
        };
    }
}
