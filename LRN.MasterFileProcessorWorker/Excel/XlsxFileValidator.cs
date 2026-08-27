using System.IO.Compression;

public static class XlsxFileValidator
{
    // quick sanity check (avoids feeding HTML/zero-byte/partial downloads into readers)
    public static void ValidateDownloadedXlsxOrThrow(string xlsxPath)
    {
        var fi = new FileInfo(xlsxPath);
        if (!fi.Exists)
            throw new FileNotFoundException("Downloaded file not found.", xlsxPath);

        if (fi.Length < 5000)
            throw new InvalidDataException($"Downloaded file is too small to be a valid XLSX: {xlsxPath} ({fi.Length} bytes)");

        try
        {
            using var zip = ZipFile.OpenRead(xlsxPath);
            var hasContentTypes = zip.Entries.Any(e => e.FullName.Equals("[Content_Types].xml", StringComparison.OrdinalIgnoreCase));
            if (!hasContentTypes)
                throw new InvalidDataException("XLSX zip missing [Content_Types].xml");
        }
        catch (InvalidDataException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new InvalidDataException($"Invalid XLSX: {xlsxPath}", ex);
        }
    }
}
