namespace LabMetricsDashboard.Services;

public static class FileUploadGuard
{
    private static readonly HashSet<string> ExcelExtensions = new(StringComparer.OrdinalIgnoreCase) { ".xlsx" };
    private static readonly HashSet<string> CsvExtensions = new(StringComparer.OrdinalIgnoreCase) { ".csv" };

    public static async Task<string?> ValidateExcelAsync(IFormFile? file, long maxBytes, CancellationToken ct)
        => await ValidateAsync(file, maxBytes, ExcelExtensions, ct);

    public static async Task<string?> ValidateCsvAsync(IFormFile? file, long maxBytes, CancellationToken ct)
        => await ValidateAsync(file, maxBytes, CsvExtensions, ct);

    private static async Task<string?> ValidateAsync(IFormFile? file, long maxBytes, IReadOnlySet<string> allowedExtensions, CancellationToken ct)
    {
        if (file is null || file.Length == 0) return "Select a file to upload.";
        if (file.Length > maxBytes) return $"File is too large. Maximum allowed size is {maxBytes / 1024 / 1024:N0} MB.";

        var fileName = Path.GetFileName(file.FileName);
        if (string.IsNullOrWhiteSpace(fileName) || fileName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            return "File name is invalid.";

        var extension = Path.GetExtension(fileName);
        if (string.IsNullOrWhiteSpace(extension) || !allowedExtensions.Contains(extension))
            return $"File type '{extension}' is not allowed.";

        await using var stream = file.OpenReadStream();
        var header = new byte[Math.Min(16, (int)Math.Min(file.Length, 16))];
        _ = await stream.ReadAsync(header.AsMemory(0, header.Length), ct);
        return HeaderMatches(extension, header) ? null : "File content does not match the file extension.";
    }

    private static bool HeaderMatches(string extension, byte[] header)
    {
        if (header.Length == 0) return false;
        return extension.ToLowerInvariant() switch
        {
            ".xlsx" => StartsWith(header, 0x50, 0x4B, 0x03, 0x04) || StartsWith(header, 0x50, 0x4B, 0x05, 0x06) || StartsWith(header, 0x50, 0x4B, 0x07, 0x08),
            ".csv" => !header.Contains((byte)0),
            _ => false
        };
    }

    private static bool StartsWith(byte[] value, params byte[] prefix)
        => value.Length >= prefix.Length && prefix.Select((t, i) => value[i] == t).All(x => x);
}
