using ClaimLineCSVDataCapture.Models;
using LabMetricsDashboard.Services;
using Microsoft.Extensions.Logging.Abstractions;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Rebuilds a lab's LIS Summary aggregate tables (dbo.{Prefix}LIS_*) through the
/// dashboard's own SqlLisSummaryRepository, so the page and this refresh share one
/// implementation of the LIS Summary logic. Runs on every pass for aggregated labs;
/// the repository skips the rebuild unless a new LIMS file changed dbo.LIMSMaster.
/// </summary>
public static class LisSummaryAggregateRefresher
{
    public static void Run(AppLogger log, LabConfig lab, string? dbConnectionString)
    {
        if (!LisSummaryAggregateLabs.TryGetTablePrefix(lab.LabName, null, out var prefix))
            return;

        log.Header($"STEP 13b — LIS Summary aggregate — {lab.LabName}");
        if (string.IsNullOrWhiteSpace(dbConnectionString))
        {
            log.Warn("  [STEP 13b] DbConnectionString not configured — LIS Summary aggregate skipped.");
            return;
        }

        var force = lab.ClaimLineRefresh;
        log.Info($"  [STEP 13b] Tables {prefix}LIS_* — {(force ? "ClaimLineRefresh=true, forcing rebuild" : "rebuilding only if a new LIMS file landed")}…");
        try
        {
            var repo = new SqlLisSummaryRepository(NullLogger<SqlLisSummaryRepository>.Instance);
            var result = repo
                .RefreshSummaryAggregateAsync(dbConnectionString, lab.LabName, onlyIfLimsChanged: !force)
                .GetAwaiter()
                .GetResult();

            if (result.Refreshed)
                log.Success($"  [STEP 13b] LIS Summary aggregate rebuilt — {result.SummaryRows:N0} summary row(s), " +
                            $"{result.KeyMetricRows:N0} key-metric row(s), {result.FilterOptionRows:N0} filter option(s) " +
                            $"in {result.ElapsedMs:N0} ms. {result.Message}");
            else
                log.Info($"  [STEP 13b] Skipped — {result.Message}");
        }
        catch (Exception ex)
        {
            log.Error($"  [STEP 13b] LIS Summary aggregate refresh FAILED — {ex.Message}");
        }
    }
}
