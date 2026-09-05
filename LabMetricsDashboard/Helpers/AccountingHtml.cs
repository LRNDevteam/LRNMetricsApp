using Microsoft.AspNetCore.Html;

namespace LabMetricsDashboard.Helpers;

/// <summary>
/// Page money in Accounting layout (not Currency): $ left, amount right,
/// negatives in parentheses, zero as a dash.
/// </summary>
public static class AccountingHtml
{
    public static IHtmlContent Acct(decimal value, int decimals = 0) => Render(value, decimals);

    public static IHtmlContent Acct(decimal? value, int decimals = 0) =>
        value.HasValue ? Render(value.Value, decimals) : HtmlString.Empty;

    public static IHtmlContent Acct2(decimal value) => Render(value, 2);

    public static IHtmlContent Acct2(decimal? value) => Acct(value, 2);

    /// <summary>Plain-text Accounting for badges, titles, and view-model strings.</summary>
    public static string Text(decimal value, int decimals = 0)
    {
        var fmt = NumberFormat(decimals);
        if (value == 0m) return "$ -";
        if (value < 0m) return "$ (" + Math.Abs(value).ToString(fmt) + ")";
        return "$ " + value.ToString(fmt);
    }

    public static string Text(decimal? value, int decimals = 0) =>
        value.HasValue ? Text(value.Value, decimals) : string.Empty;

    private static IHtmlContent Render(decimal value, int decimals)
    {
        var fmt = NumberFormat(decimals);
        var num = value == 0m ? "-"
            : value < 0m ? "(" + Math.Abs(value).ToString(fmt) + ")"
            : value.ToString(fmt);
        return new HtmlString(
            $"<span class=\"acct\"><span class=\"acct-sym\">$</span><span class=\"acct-val\">{num}</span></span>");
    }

    private static string NumberFormat(int decimals) =>
        decimals <= 0 ? "#,##0" : "#,##0." + new string('0', decimals);
}
