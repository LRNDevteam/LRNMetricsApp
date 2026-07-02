using DenialDatabaseProcessorWorker.Models;

namespace DenialDatabaseProcessorWorker.Services.SharePoint;

public interface ISharePointUploader
{
    Task UploadIfEnabledAsync(LabConfig lab, string localFilePath, DateTime localDateTime, CancellationToken ct);
}
