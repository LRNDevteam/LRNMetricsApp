using System.Globalization;
using System.Text;

/// <summary>
/// Daily master processor log required by client:
///   Master_File_Processor_Log_18Feb2026.csv
/// Stored locally and optionally uploaded to SharePoint.
///
/// The exact column schema was not provided by the client in this ticket,
/// so we use a practical CSV with the key fields needed for auditing.
/// </summary>
public static class MasterProcessorLogCsv
{
    private const string Header =
        "date,time,lab_id,lab_name,source_file_name,source_file_location,status,message,claim_output,line_output";

    public static string GetDailyFileName(DateTime localNow)
        => $"Master_File_Processor_Log_{localNow.ToString("ddMMMyyyy", CultureInfo.InvariantCulture)}.csv";

    /// <summary>
    /// Appends one row to today's master processor CSV.
    /// Creates the file + header if missing.
    /// Returns the full local file path.
    /// </summary>
    public static string Append(
        string folder,
        DateTime localNow,
        int labId,
        string labName,
        string sourceFileName,
        string sourceFileLocation,
        string status,
        string message,
        string claimOutput,
        string lineOutput)
    {
        Directory.CreateDirectory(folder);

        var csvPath = Path.Combine(folder, GetDailyFileName(localNow));

        if (!File.Exists(csvPath))
        {
            File.WriteAllText(csvPath, Header + Environment.NewLine, Encoding.UTF8);
        }

        var row = string.Join(",",
            Escape(localNow.ToString("MM/dd/yyyy", CultureInfo.InvariantCulture)),
            Escape(localNow.ToString("HH:mm", CultureInfo.InvariantCulture)),
            labId.ToString(CultureInfo.InvariantCulture),
            Escape(labName),
            Escape(sourceFileName),
            Escape(sourceFileLocation),
            Escape(status),
            Escape(message),
            Escape(claimOutput),
            Escape(lineOutput));

        File.AppendAllText(csvPath, row + Environment.NewLine, Encoding.UTF8);
        return csvPath;
    }

    private static string Escape(string? value)
    {
        value ??= "";
        if (value.Contains('"')) value = value.Replace("\"", "\"\"");
        if (value.Contains(',') || value.Contains('\n') || value.Contains('\r') || value.Contains('"'))
            return "\"" + value + "\"";
        return value;
    }
}
