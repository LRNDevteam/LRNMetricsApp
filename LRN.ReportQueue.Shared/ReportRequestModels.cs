using System.Security.Cryptography;
using System.Text;

namespace LRN.ReportQueue.Shared;

/// <summary>New request queued by the web app.</summary>
public sealed record NewReportRequest(
    string ReportType,
    string LabName,
    string RequestedBy,
    int?   RequestedByUserId,
    string? FilterDetailsJson)
{
    /// <summary>
    /// SHA-256 over type + lab + filters — backs the UX_UserReqReports_ActiveDuplicate
    /// unique index so the same user can't queue the identical report twice while
    /// one is still Queued/Processing.
    /// </summary>
    public string ComputeFilterHash()
    {
        var payload = $"{ReportType}|{LabName}|{FilterDetailsJson ?? string.Empty}";
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(payload)));
    }
}

/// <summary>Row claimed by the worker via usp_ClaimNextUserReqReport.</summary>
public sealed record ClaimedReport(
    long    ReportId,
    string  ReportType,
    string  LabName,
    string  RequestedBy,
    string? FilterDetailsJson,
    byte    RetryCount);

/// <summary>Row shape for the user's Reports panel / badge.</summary>
public sealed record UserReportRow(
    long         ReportId,
    string       ReportType,
    string       LabName,
    string       RequestedBy,
    DateTime     RequestedDate,
    ReportStatus Status,
    string?      FileName,
    long?        FileSizeBytes,
    int?         ReportRowCount,
    DateTime?    CompletedDate,
    DateTime?    ExpiryDate,
    string?      ErrorMessage,
    Guid         DownloadToken,
    byte?        ProgressPercent);

/// <summary>Result of a completed generation, written back by the worker.</summary>
public sealed record GeneratedReportFile(
    string FileName,
    string FilePath,
    long   FileSizeBytes,
    int    RowCount);

/// <summary>Row returned by usp_ExpireUserReqReports — file the worker must delete.</summary>
public sealed record ExpiredReportFile(long ReportId, string? FilePath);

/// <summary>Row successfully marked Deleted; FilePath is null for Failed reports (no file was written).</summary>
public sealed record DeletedReportInfo(string? FilePath);

/// <summary>Thrown when the duplicate-guard unique index rejects a queue insert.</summary>
public sealed class DuplicateReportRequestException : Exception
{
    public DuplicateReportRequestException()
        : base("An identical report request is already queued or processing.") { }
}
