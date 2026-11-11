using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LRN.MasterFileProcessorWorker.ProcessLogging;

/// <summary>A master file uploaded from the AR Workbench (LRNMaster dbo.MasterFileUpload), without its content.</summary>
public sealed record MasterFileUpload(
    long UploadId,
    int LabId,
    string FileName,
    long FileSizeBytes,
    string FileSha256,
    DateTime PeriodStart,
    DateTime PeriodEnd,
    DateTime UploadedOn,
    bool ContentAvailable);

/// <summary>
/// Reads <c>LRNMaster.dbo.MasterFileUpload</c>: the standard-template workbook a user uploaded on the
/// AR Workbench Data Processing screen, for a lab whose master file does not come from SharePoint.
///
/// <para>
/// The upload replaces only the "find and download the file" steps of a run. The workbook is
/// written to the same local path a SharePoint download would use, and everything after that -
/// validation, standardization, denial enrichment, bulk load, AR Workbench sync, archive - is the
/// same code on the same path.
/// </para>
/// <para>
/// The content is PHI, so <see cref="PurgeContentAsync"/> clears it once the run has finished with
/// it, whatever the outcome. The row stays as the record of the upload.
/// </para>
/// </summary>
public sealed class MasterFileUploadStore
{
    private readonly string _connectionString;
    private readonly ILogger<MasterFileUploadStore> _logger;

    public MasterFileUploadStore(IConfiguration configuration, ILogger<MasterFileUploadStore> logger)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing DefaultConnection connection string (LRNMaster).");

        _logger = logger;
    }

    /// <summary>
    /// The upload's details, or null when there is no such upload for this lab. The lab is part of
    /// the lookup so a request can never pull another lab's workbook into this lab's database.
    /// </summary>
    public async Task<MasterFileUpload?> GetAsync(long uploadId, int labId, CancellationToken ct)
    {
        const string sql = @"
SELECT UploadId, LabId, FileName, FileSizeBytes, FileSha256, PeriodStart, PeriodEnd, UploadedOn,
       CAST(CASE WHEN FileContent IS NULL THEN 0 ELSE 1 END AS bit)
FROM   dbo.MasterFileUpload
WHERE  UploadId = @Id AND LabId = @LabId;";

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = uploadId;
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;

        await using var rd = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        if (!await rd.ReadAsync(ct).ConfigureAwait(false))
            return null;

        return new MasterFileUpload(
            UploadId: rd.GetInt64(0),
            LabId: rd.GetInt32(1),
            FileName: rd.GetString(2),
            FileSizeBytes: rd.GetInt64(3),
            FileSha256: rd.GetString(4),
            PeriodStart: rd.GetDateTime(5),
            PeriodEnd: rd.GetDateTime(6),
            UploadedOn: rd.GetDateTime(7),
            ContentAvailable: rd.GetBoolean(8));
    }

    /// <summary>Streams the workbook to <paramref name="destinationPath"/>. Throws when the content is gone.</summary>
    public async Task SaveContentToFileAsync(long uploadId, int labId, string destinationPath, CancellationToken ct)
    {
        const string sql = @"
SELECT FileContent
FROM   dbo.MasterFileUpload
WHERE  UploadId = @Id AND LabId = @LabId AND FileContent IS NOT NULL;";

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = uploadId;
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;

        // SequentialAccess streams the varbinary instead of buffering a large workbook in memory.
        await using var rd = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct).ConfigureAwait(false);
        if (!await rd.ReadAsync(ct).ConfigureAwait(false))
            throw new InvalidOperationException(
                $"Uploaded master file #{uploadId} has no content any more (it was already processed or removed). Upload the file again.");

        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);

        await using (var source = rd.GetStream(0))
        await using (var target = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            await source.CopyToAsync(target, ct).ConfigureAwait(false);
        }
    }

    /// <summary>Clears the workbook content (PHI). Never throws: the run's outcome is already decided.</summary>
    public async Task PurgeContentAsync(long uploadId, CancellationToken ct)
    {
        const string sql = @"
UPDATE dbo.MasterFileUpload
SET    FileContent = NULL,
       ContentPurgedOn = SYSUTCDATETIME()
WHERE  UploadId = @Id AND FileContent IS NOT NULL;";

        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct).ConfigureAwait(false);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
            cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = uploadId;
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Left for the next attempt to find: the row still says the content is there, which
            // is visible, rather than silently claiming it was cleared.
            _logger.LogWarning(ex, "Uploaded master file {UploadId}: could not clear the stored workbook.", uploadId);
        }
    }
}
