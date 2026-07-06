using LRN.SharePointClient.Models;

namespace LRN.SharePointClient.Abstractions;

public interface ISharePointClient
{
    Task<IReadOnlyList<SharePointItemInfo>> ListChildrenAsync(SharePointLocation location, CancellationToken ct);

    Task<IReadOnlyList<SharePointItemInfo>> ListChildrenAsync(SharePointLocation location, string subFolderPath, CancellationToken ct);

    Task DownloadFileAsync(SharePointLocation location, string itemId, string localFilePath, CancellationToken ct);

    Task UploadFileAsync(SharePointLocation location, string targetFileName, string localFilePath, bool overwrite, CancellationToken ct);
}
