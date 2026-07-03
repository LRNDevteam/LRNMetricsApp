namespace LRN.SharePointClient.Graph;

public interface IGraphTokenProvider
{
    Task<string> GetAccessTokenAsync(CancellationToken ct);
}
