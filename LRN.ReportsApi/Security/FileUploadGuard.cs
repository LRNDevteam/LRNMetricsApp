namespace LRN.ReportsApi.Security;

public static class FileUploadGuard
{
    private static readonly HashSet<string> ExcelExtensions = new(StringComparer.OrdinalIgnoreCase) { ".xlsx" };
    private static readonly HashSet<string> CsvOrExcelExtensions = new(StringComparer.OrdinalIgnoreCase) { ".csv", ".xlsx" };
    private static readonly HashSet<string> DocumentExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pdf", ".png", ".jpg", ".jpeg", ".txt", ".csv", ".xlsx", ".xls", ".docx", ".doc"
    };

    public static async Task<string?> ValidateExcelAsync(IFormFile? file, long maxBytes, CancellationToken ct)
        => await ValidateAsync(file, maxBytes, ExcelExtensions, ct);

    public static async Task<string?> ValidateCsvOrExcelAsync(IFormFile? file, long maxBytes, CancellationToken ct)
        => await ValidateAsync(file, maxBytes, CsvOrExcelExtensions, ct);

    public static async Task<string?> ValidateDocumentAsync(IFormFile? file, long maxBytes, CancellationToken ct)
        => await ValidateAsync(file, maxBytes, DocumentExtensions, ct);

    private static async Task<string?> ValidateAsync(IFormFile? file, long maxBytes, IReadOnlySet<string> allowedExtensions, CancellationToken ct)
    {
        if (file is null) return "Select a file to upload.";
        // Round 4 UAT Defect E: an empty file (e.g. a Word document created via right-click >
        // New that was never opened/saved with content) previously returned "Select a file to
        // upload.", which reads as if no file was chosen. State the actual reason.
        if (file.Length == 0) return "The selected file is empty (0 KB). Open the document, add content and save it, then upload again.";
        if (file.Length > maxBytes) return $"File is too large. Maximum allowed size is {maxBytes / 1024 / 1024:N0} MB.";

        var fileName = Path.GetFileName(file.FileName);
        if (string.IsNullOrWhiteSpace(fileName) || fileName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            return "File name is invalid.";

        var extension = Path.GetExtension(fileName);
        if (string.IsNullOrWhiteSpace(extension) || !allowedExtensions.Contains(extension))
            return $"File type '{extension}' is not allowed. Allowed types: {string.Join(", ", allowedExtensions)}.";

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
            ".xlsx" or ".docx" => StartsWith(header, 0x50, 0x4B, 0x03, 0x04) || StartsWith(header, 0x50, 0x4B, 0x05, 0x06) || StartsWith(header, 0x50, 0x4B, 0x07, 0x08),
            ".xls" or ".doc" => StartsWith(header, 0xD0, 0xCF, 0x11, 0xE0),
            ".pdf" => StartsWith(header, 0x25, 0x50, 0x44, 0x46),
            ".png" => StartsWith(header, 0x89, 0x50, 0x4E, 0x47),
            ".jpg" or ".jpeg" => StartsWith(header, 0xFF, 0xD8, 0xFF),
            ".csv" or ".txt" => !header.Contains((byte)0),
            _ => false
        };
    }

    private static bool StartsWith(byte[] value, params byte[] prefix)
        => value.Length >= prefix.Length && prefix.Select((t, i) => value[i] == t).All(x => x);
}
