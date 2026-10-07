namespace LabMetricsDashboard.Services;

/// <summary>
/// Keeps the Denial Insight "$ Impact (%)" column on one scale: <b>57 means 57%</b>.
///
/// <para>Excel hands back 0.57 for a cell displaying "57%", because a percent-formatted cell stores
/// the fraction. Where the workbook's formatting says so, the import scales it back. This handles
/// the cases the formatting does not announce - a cell pasted as a plain 0.57, and every row
/// already in the database from an import that ran before the scaling was fixed.</para>
/// </summary>
public static class DenialInsightPercent
{
    /// <summary>
    /// Scales a fraction up to a percentage, and leaves a value that is already a percentage alone.
    /// </summary>
    /// <remarks>
    /// <para>The test is "greater than zero and no more than 1". In this report that is
    /// unambiguous: the column is a denial's share of a payer's balance, and the client's own sheet
    /// runs from about 12% to 100%. A row that genuinely accounted for 1% or less of the balance
    /// would not be on a top-denials list at all, so a stored 0.57 is a fraction, not a very small
    /// percentage.</para>
    /// <para>Deliberately idempotent: 57 stays 57. That is what lets it run on read as well as on
    /// import, so rows written before the import was fixed display correctly without anyone having
    /// to re-upload the workbook, and re-importing them later does not scale them twice.</para>
    /// </remarks>
    public static decimal Normalize(decimal value) =>
        value > 0m && value <= 1m ? value * 100m : value;

    /// <summary>
    /// The "$ Impact (%)" text to show: the workbook's own text, unless it is a number outside 0-100%.
    /// </summary>
    /// <remarks>
    /// The column is the payer's insurance balance as a share of the code's total balance, so it can
    /// never exceed 100%. A larger figure means the workbook cell computed something else - a client
    /// sheet whose "Previously Discussed" formula divided Ins. Balance by # of Denials showed 41380.76%
    /// - and is replaced by Ins. Balance / Total Balance. Text that is not a number ("-", "N/A") and
    /// in-range values stay exactly as the workbook displayed them.
    /// </remarks>
    public static string DisplayText(string? text, decimal insuranceBalance, decimal totalBalance)
    {
        var shown = (text ?? string.Empty).Trim();
        var raw = shown.Replace("%", string.Empty).Replace(",", string.Empty).Trim();
        if (!decimal.TryParse(raw, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out var value)) return shown;
        if (value is >= 0m and <= 100m) return shown;
        if (totalBalance <= 0m || insuranceBalance < 0m || insuranceBalance > totalBalance) return shown;
        return (decimal.Round(insuranceBalance / totalBalance * 100m, 2)).ToString("0.##", System.Globalization.CultureInfo.InvariantCulture) + "%";
    }
}
