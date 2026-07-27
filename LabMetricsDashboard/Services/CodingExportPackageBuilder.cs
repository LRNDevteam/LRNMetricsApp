using System.IO.Compression;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Packages Coding Summary Excel with optional CptAverage / PanelAverage CSVs
/// into a single ZIP for UI / My Reports download.
/// </summary>
public static class CodingExportPackageBuilder
{
    public static bool ShouldPackage(CodingAverageFiles averages) => averages.HasAny;

    /// <summary>
    /// Builds a ZIP containing the Coding Summary workbook plus any resolved average CSVs.
    /// </summary>
    public static byte[] BuildZip(
        byte[] excelBytes,
        string excelEntryName,
        CodingAverageFiles averages)
    {
        using var ms = new MemoryStream();
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            var excelEntry = zip.CreateEntry(excelEntryName, CompressionLevel.Optimal);
            using (var entryStream = excelEntry.Open())
                entryStream.Write(excelBytes, 0, excelBytes.Length);

            AddFileIfExists(zip, averages.CptAveragePath);
            AddFileIfExists(zip, averages.PanelAveragePath);
        }

        return ms.ToArray();
    }

    private static void AddFileIfExists(ZipArchive zip, string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            return;

        var entryName = Path.GetFileName(path);
        zip.CreateEntryFromFile(path, entryName, CompressionLevel.Optimal);
    }
}
