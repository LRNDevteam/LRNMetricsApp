using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ClaimLineCSVDataCapture.Models;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Loads all lab configs from the LabConfigFolder.
/// Each file is named {LabName}.json and contains a flat <see cref="LabConfig"/> object at the root.
/// <para>
/// Write-backs (<see cref="TryResetClaimLineRefresh"/> and <see cref="TryWriteLastProcessedRunId"/>)
/// are performed as targeted <b>text</b> edits rather than re-serialising the parsed JSON.
/// The lab config files carry extensive <c>//</c> deploy-instruction comments, which a
/// JsonNode round-trip would silently strip (and which JsonNode.Parse would reject outright).
/// The text edit rewrites only the single value in question and leaves every comment,
/// key order and indentation byte-for-byte intact.
/// </para>
/// </summary>
public static class LabConfigLoader
{
    private static readonly JsonSerializerOptions _opts = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling         = JsonCommentHandling.Skip,
        AllowTrailingCommas         = true,
    };

    public static List<LabConfig> LoadAll(string labConfigFolder, IEnumerable<string> labNames, AppLogger log)
    {
        var results = new List<LabConfig>();

        foreach (var labName in labNames)
        {
            var filePath = Path.Combine(labConfigFolder, $"{labName}.json");
            if (!File.Exists(filePath))
            {
                log.Warn($"  [WARN] Lab config not found, skipping '{labName}': {filePath}");
                continue;
            }

            try
            {
                var json = File.ReadAllText(filePath);
                var config = JsonSerializer.Deserialize<LabConfig>(json, _opts)
                             ?? new LabConfig();

                config.LabName = labName;
                results.Add(config);

                var storedRunId = string.IsNullOrWhiteSpace(config.LastProcessedRunId)
                                  ? "(none)"
                                  : config.LastProcessedRunId;

                log.Info($"  [OK] Loaded config for '{labName}' - ClaimLineInsert={config.ClaimLineInsert}, " +
                         $"ClaimLineRefresh={config.ClaimLineRefresh}, DBEnabled={config.DBEnabled}, " +
                         $"LastProcessedRunId={storedRunId}");
            }
            catch (Exception ex)
            {
                log.Error($"  Failed to load '{labName}': {ex.Message}");
            }
        }

        return results;
    }

    /// <summary>
    /// Resets the <c>ClaimLineRefresh</c> flag to <c>false</c> in the lab's JSON config file
    /// after a successful refresh run, so the next scheduled execution resumes normal
    /// (change-detection) behaviour.
    /// </summary>
    /// <returns><c>true</c> when the file was updated; <c>false</c> on any error.</returns>
    public static bool TryResetClaimLineRefresh(string labConfigFolder, string labName, AppLogger log)
    {
        var filePath = Path.Combine(labConfigFolder, $"{labName}.json");
        try
        {
            if (!File.Exists(filePath))
            {
                log.Warn($"  [Refresh] Lab config not found - cannot reset ClaimLineRefresh: {filePath}");
                return false;
            }

            var json = File.ReadAllText(filePath);

            if (!TryReplaceScalarValue(json, "ClaimLineRefresh", "false", out var updated))
            {
                log.Warn($"  [Refresh] ClaimLineRefresh key not found in {filePath} - nothing to reset.");
                return false;
            }

            WriteAllTextPreservingBom(filePath, updated);
            log.Info($"  [Refresh] ClaimLineRefresh reset to false in {filePath}.");
            return true;
        }
        catch (Exception ex)
        {
            log.Error($"  [Refresh] Failed to reset ClaimLineRefresh in {filePath}: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Persists the RunId that was just processed into the lab's JSON config file,
    /// alongside the <c>ClaimLineRefresh</c> key. The next execution compares this
    /// value against the latest successfully completed RunId returned by
    /// <c>sp_GetRecentSuccessRunByLab</c> (LRNMaster) to decide whether there is new
    /// data to process.
    /// <para>
    /// When the <c>LastProcessedRunId</c> key is absent it is inserted immediately
    /// after <c>ClaimLineRefresh</c>, so existing lab config files need no manual edit.
    /// </para>
    /// </summary>
    /// <returns><c>true</c> when the file was updated; <c>false</c> on any error.</returns>
    public static bool TryWriteLastProcessedRunId(
        string labConfigFolder, string labName, string? runId, AppLogger log)
    {
        var filePath = Path.Combine(labConfigFolder, $"{labName}.json");
        try
        {
            if (!File.Exists(filePath))
            {
                log.Warn($"  [RunId Store] Lab config not found - cannot persist LastProcessedRunId: {filePath}");
                return false;
            }

            var json     = File.ReadAllText(filePath);
            var newValue = JsonSerializer.Serialize(runId ?? string.Empty); // quoted + escaped

            if (TryReplaceScalarValue(json, "LastProcessedRunId", newValue, out var updated))
            {
                WriteAllTextPreservingBom(filePath, updated);
                log.Info($"  [RunId Store] LastProcessedRunId updated to '{runId ?? "(empty)"}' in {filePath}.");
                return true;
            }

            // Key not present yet - insert it directly after the ClaimLineRefresh entry.
            if (TryInsertAfterKey(json, "ClaimLineRefresh", "LastProcessedRunId", newValue, out updated))
            {
                WriteAllTextPreservingBom(filePath, updated);
                log.Info($"  [RunId Store] LastProcessedRunId key added with value '{runId ?? "(empty)"}' in {filePath}.");
                return true;
            }

            log.Warn($"  [RunId Store] Could not locate ClaimLineRefresh in {filePath} - " +
                     $"LastProcessedRunId not persisted. Add the key manually to enable change detection.");
            return false;
        }
        catch (Exception ex)
        {
            log.Error($"  [RunId Store] Failed to persist LastProcessedRunId in {filePath}: {ex.Message}");
            return false;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Text-edit helpers - keep comments and formatting intact.
    // ─────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// Replaces the scalar value of a <c>"key": value</c> pair with
    /// <paramref name="newValueLiteral"/> (which must already be a valid JSON literal,
    /// e.g. <c>false</c> or <c>"20260522R0118"</c>). Matching is case-insensitive and
    /// ignores anything inside <c>//</c> or <c>/* */</c> comments, so a key mentioned
    /// in the deploy notes is never mistaken for the real setting.
    /// </summary>
    private static bool TryReplaceScalarValue(string json, string key, string newValueLiteral, out string updated)
    {
        var mask = MaskComments(json);

        // "Key"  :  <string | number | bool | null>
        var pattern = $"(\"{Regex.Escape(key)}\"\\s*:\\s*)(\"(?:[^\"\\\\]|\\\\.)*\"|true|false|null|-?\\d+(?:\\.\\d+)?)";
        var match   = new Regex(pattern, RegexOptions.IgnoreCase).Match(mask);

        if (!match.Success)
        {
            updated = json;
            return false;
        }

        // Indices from the mask map 1:1 onto the original (MaskComments preserves length).
        var valueStart = match.Groups[2].Index;
        var valueLen   = match.Groups[2].Length;

        updated = json.Remove(valueStart, valueLen).Insert(valueStart, newValueLiteral);
        return true;
    }

    /// <summary>
    /// Inserts <c>"newKey": newValueLiteral</c> on its own line immediately after the
    /// line declaring <paramref name="anchorKey"/>, matching that line's indentation.
    /// <para>
    /// Comma placement mirrors the anchor: if the anchor line already ends with a comma
    /// then more properties follow, so the NEW line receives the comma. If the anchor
    /// has no comma it was the object's last property, so the anchor gains a comma and
    /// the new line becomes the last property. A trailing <c>//</c> comment on the
    /// anchor line is respected — the comma goes before it, never inside it.
    /// </para>
    /// </summary>
    private static bool TryInsertAfterKey(
        string json, string anchorKey, string newKey, string newValueLiteral, out string updated)
    {
        var mask = MaskComments(json);

        // NOTE: no '$' anchor. In Multiline mode '$' matches only before '\n', so on a
        // CRLF file the match would fail at the '\r'. '[^\r\n]*' is greedy and already
        // stops at the line end, and leaving the '\r\n' outside the match means the
        // original line terminator is preserved untouched.
        var rx    = new Regex($"^([ \\t]*)\"{Regex.Escape(anchorKey)}\"\\s*:[^\\r\\n]*",
                              RegexOptions.IgnoreCase | RegexOptions.Multiline);
        var match = rx.Match(mask);

        if (!match.Success)
        {
            updated = json;
            return false;
        }

        var indent      = match.Groups[1].Value;
        var lineStart   = match.Index;
        var lineLen     = match.Length;
        var anchorLine  = json.Substring(lineStart, lineLen);   // original text, comments intact
        var maskedLine  = mask.Substring(lineStart, lineLen);   // comments blanked out

        // Split the anchor line into "code" and "trailing comment" using the mask:
        // everything from the first blanked-out region to end of line is the comment.
        var codeLen = maskedLine.TrimEnd().Length;
        var code    = anchorLine.Substring(0, codeLen);
        var comment = anchorLine.Substring(codeLen);

        string newAnchorLine, newPropertyLine;
        if (code.TrimEnd().EndsWith(','))
        {
            // More properties follow the anchor -> the new line needs the comma.
            newAnchorLine   = anchorLine;
            newPropertyLine = $"{indent}\"{newKey}\": {newValueLiteral},";
        }
        else
        {
            // Anchor was the last property -> give it a comma, new line becomes last.
            newAnchorLine   = code.TrimEnd() + "," + comment;
            newPropertyLine = $"{indent}\"{newKey}\": {newValueLiteral}";
        }

        var newline = json.Contains("\r\n") ? "\r\n" : "\n";

        updated = json.Remove(lineStart, lineLen)
                      .Insert(lineStart, newAnchorLine + newline + newPropertyLine);
        return true;
    }

    /// <summary>
    /// Returns a same-length copy of <paramref name="json"/> in which every
    /// <c>//</c> line comment and <c>/* */</c> block comment is replaced by spaces
    /// (newlines preserved). String literals are left untouched, and <c>//</c>
    /// occurring inside a string (e.g. a URL in a connection string) is not treated
    /// as a comment. Because the length is preserved, regex indices found on the mask
    /// apply directly to the original text.
    /// </summary>
    private static string MaskComments(string json)
    {
        var buf      = json.ToCharArray();
        var inString = false;
        var i        = 0;

        while (i < json.Length)
        {
            var c = json[i];

            if (inString)
            {
                if (c == '\\')        { i += 2; continue; }
                if (c == '"')         { inString = false; }
                i++;
                continue;
            }

            if (c == '"') { inString = true; i++; continue; }

            if (c == '/' && i + 1 < json.Length && json[i + 1] == '/')
            {
                while (i < json.Length && json[i] != '\n' && json[i] != '\r')
                    buf[i++] = ' ';
                continue;
            }

            if (c == '/' && i + 1 < json.Length && json[i + 1] == '*')
            {
                var end = json.IndexOf("*/", i + 2, StringComparison.Ordinal);
                end = end < 0 ? json.Length : end + 2;
                while (i < end)
                {
                    if (json[i] != '\n' && json[i] != '\r') buf[i] = ' ';
                    i++;
                }
                continue;
            }

            i++;
        }

        return new string(buf);
    }

    /// <summary>
    /// Writes the file back using UTF-8. A BOM is preserved when the original had one,
    /// since several lab config files are saved with one.
    /// </summary>
    private static void WriteAllTextPreservingBom(string filePath, string content)
    {
        bool hadBom;
        using (var fs = File.OpenRead(filePath))
        {
            Span<byte> head = stackalloc byte[3];
            var read = fs.Read(head);
            hadBom = read == 3 && head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF;
        }

        File.WriteAllText(filePath, content, new UTF8Encoding(encoderShouldEmitUTF8Identifier: hadBom));
    }
}
