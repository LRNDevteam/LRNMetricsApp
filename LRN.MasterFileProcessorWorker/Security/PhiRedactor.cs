using System.Text.RegularExpressions;

namespace LRN.MasterFileProcessorWorker.Security;

/// <summary>
/// Strips row values out of text before it reaches any log, table or notification (HIPAA checklist
/// MF-07 / CC-18: "log IDs only, never row values").
/// <para>
/// The worker never logs a row on purpose. The leak is exception text: SqlClient, SqlBulkCopy and the
/// .NET parsers quote the offending cell when a value will not convert or fit -
/// <c>The given value 'SMITH, JOHN' of type String ...</c>, <c>Truncated value: '1234 Elm St'</c>,
/// <c>The duplicate key value is (A123, 01/02/1960)</c> - and that text used to flow unchanged into
/// LRN_Error_Log, ReportRunIdInfoLog, LineClaimFileLogs, the CSV logs, the event log and Teams.
/// </para>
/// <para>
/// Only the VALUE is removed. Column names, table names, row numbers and error numbers stay, because
/// those are what someone fixing the load needs and none of them identifies a patient.
/// </para>
/// </summary>
public static class PhiRedactor
{
    public const string Placeholder = "[REDACTED]";

    // '...' up to the quote that is followed by whitespace, punctuation or the end, so a value with
    // an apostrophe in it (O'BRIEN) is removed whole rather than leaving "BRIEN'" behind.
    private const string Quoted = @"'.*?'(?=[\s.,;:)\]]|$)";
    private const string DoubleQuoted = "\".*?\"(?=[\\s.,;:)\\]]|$)";

    private static readonly (Regex Pattern, string Replacement)[] Rules =
    {
        // "The given value '...' of type", "varchar value '...'", "Truncated value: '...'",
        // "Parameter value '...'", "The input string '...'", "String '...' was not recognized".
        (new Regex(@"(?i)\b(value|string)(\s*:)?\s*" + Quoted, RegexOptions.Compiled),
            "$1$2 '" + Placeholder + "'"),
        (new Regex(@"(?i)\b(value|string)(\s*:)?\s*" + DoubleQuoted, RegexOptions.Compiled),
            "$1$2 \"" + Placeholder + "\""),

        // "The duplicate key value is (A123, SMITH)." - the key columns are often patient fields.
        (new Regex(@"(?i)(duplicate key value is\s*)\(.*?\)(?=[\s.,;]|$)", RegexOptions.Compiled),
            "$1(" + Placeholder + ")"),

        // A Social Security number anywhere, however it arrived.
        (new Regex(@"\b\d{3}-\d{2}-\d{4}\b", RegexOptions.Compiled), Placeholder)
    };

    /// <summary>The text with every quoted row value replaced. Null stays null.</summary>
    public static string? Scrub(string? text)
    {
        if (string.IsNullOrEmpty(text))
            return text;

        foreach (var (pattern, replacement) in Rules)
            text = pattern.Replace(text, replacement);

        return text;
    }

    /// <summary>
    /// <see cref="Exception.ToString"/> - type, message, inner exceptions and stack - with the
    /// messages scrubbed. Stack frames name methods and source lines, never data.
    /// </summary>
    public static string ScrubException(Exception ex) => Scrub(ex.ToString())!;

    /// <summary>
    /// The same exception for a sink that renders the exception object itself (log4net, the event
    /// log): its <see cref="Exception.Message"/> and <see cref="Exception.ToString"/> are scrubbed.
    /// </summary>
    public static Exception? Wrap(Exception? ex) =>
        ex is null or RedactedException ? ex : new RedactedException(ex);

    private sealed class RedactedException : Exception
    {
        private readonly string _text;

        public RedactedException(Exception inner) : base(Scrub(inner.Message))
        {
            _text = ScrubException(inner);
            HResult = inner.HResult;
        }

        public override string ToString() => _text;
    }
}
