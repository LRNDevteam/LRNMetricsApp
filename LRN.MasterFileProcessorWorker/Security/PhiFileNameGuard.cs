using System.Globalization;
using System.Text.RegularExpressions;

namespace LRN.MasterFileProcessorWorker.Security;

/// <summary>
/// HIPAA checklist MF-08: a file name or SharePoint path must not carry a patient identifier.
/// <para>
/// The name of the master file is copied into LRN_Run_Log, LRN_Step_Log, ReportRunIdInfoLog,
/// LineClaimFileLogs.SourceFullPath, the <c>SourceFullPath</c> / <c>FileName</c> columns of every
/// loaded row, the local folder layout and Teams messages. A name like
/// <c>Smith_123-45-6789_Claims.xlsx</c> would put an identifier into all of them, so such a file is
/// refused before it is downloaded.
/// </para>
/// <para>
/// Lab files are named by lab and week (<c>Beech Tree_Production Report.xlsx</c> under
/// <c>02.06.2026 - 02.12.2026</c>), so the test is deliberately narrow - it looks only for shapes
/// that are identifiers and never dates:
/// </para>
/// <list type="bullet">
///   <item>an SSN-shaped value (<c>123-45-6789</c>, <c>123 45 6789</c>, <c>123_45_6789</c>);</item>
///   <item>a run of 9 or more digits that is not a date or timestamp (<c>yyyyMMdd</c>,
///         <c>yyyyMMddHHmm</c>, <c>yyyyMMddHHmmss</c>, <c>MMddyyyy</c>) - the length of an SSN,
///         member ID or MRN.</item>
/// </list>
/// </summary>
public static class PhiFileNameGuard
{
    private static readonly Regex SsnShape = new(@"(?<!\d)\d{3}[-_ ]\d{2}[-_ ]\d{4}(?!\d)", RegexOptions.Compiled);
    private static readonly Regex LongDigitRun = new(@"(?<!\d)\d{9,}(?!\d)", RegexOptions.Compiled);

    private static readonly string[] DateShapes =
    {
        "yyyyMMdd", "yyyyMMddHH", "yyyyMMddHHmm", "yyyyMMddHHmmss", "yyyyMMddHHmmssfff",
        "MMddyyyy", "MMddyyyyHHmm", "MMddyyyyHHmmss"
    };

    /// <summary>
    /// Why the name looks like it carries a patient identifier, or null when it does not. The reason
    /// never repeats the matched text, so it is safe to log.
    /// </summary>
    public static string? FindIdentifier(string? nameOrPath)
    {
        if (string.IsNullOrWhiteSpace(nameOrPath))
            return null;

        if (SsnShape.IsMatch(nameOrPath))
            return "contains an SSN-shaped number";

        foreach (Match match in LongDigitRun.Matches(nameOrPath))
        {
            if (!IsDateOrTimestamp(match.Value))
                return $"contains a {match.Value.Length}-digit number that is not a date (SSN, member ID or MRN length)";
        }

        return null;
    }

    private static bool IsDateOrTimestamp(string digits) =>
        DateTime.TryParseExact(digits, DateShapes, CultureInfo.InvariantCulture, DateTimeStyles.None, out _);
}
