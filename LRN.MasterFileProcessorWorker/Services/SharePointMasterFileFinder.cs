using LRN.SharePointClient.Abstractions;
using LRN.SharePointClient.Models;

namespace LRN.MasterFileProcessorWorker.Services;

public sealed class SharePointMasterFileFinder
{
    private static readonly HashSet<string> _allowedExt = new(StringComparer.OrdinalIgnoreCase)
    {
        ".csv", ".xlsx", ".xlsm", ".xltx", ".xltm"
    };

    private readonly ISharePointClient _sp;

    public SharePointMasterFileFinder(ISharePointClient sp)
    {
        _sp = sp;
    }

    public async Task<MasterFileDiscoveryResult?> FindLatestAsync(SharePointLocation inputLocation, CancellationToken ct)
    {
        var children = await _sp.ListChildrenAsync(inputLocation, ct);

        var folders = children.Where(x => x.IsFolder).OrderByDescending(x => x.LastModifiedUtc).ToList();
        var filesAtRoot = children.Where(x => !x.IsFolder && IsAllowed(x.Name)).OrderByDescending(x => x.LastModifiedUtc).ToList();

        // Prefer latest sub-folder if present; otherwise look at root.
        if (folders.Count > 0)
        {
            var latestFolder = folders[0];
            var folderChildren = await _sp.ListChildrenAsync(inputLocation, latestFolder.Name, ct);
            var latestFile = folderChildren
                .Where(x => !x.IsFolder && IsAllowed(x.Name))
                .OrderByDescending(x => x.LastModifiedUtc)
                .FirstOrDefault();

            if (latestFile == null)
                return null;

            return new MasterFileDiscoveryResult(EffectiveFolderPath: Combine(inputLocation.FolderPath, latestFolder.Name), File: latestFile);
        }

        if (filesAtRoot.Count == 0)
            return null;

        return new MasterFileDiscoveryResult(EffectiveFolderPath: inputLocation.FolderPath, File: filesAtRoot[0]);
    }

    private static bool IsAllowed(string name) => _allowedExt.Contains(Path.GetExtension(name));

    private static string Combine(string a, string b)
    {
        a = (a ?? string.Empty).Trim().Trim('/');
        b = (b ?? string.Empty).Trim().Trim('/');
        if (string.IsNullOrWhiteSpace(a)) return b;
        if (string.IsNullOrWhiteSpace(b)) return a;
        return $"{a}/{b}";
    }
}
