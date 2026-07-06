namespace LRN.SharePointClient.Graph;

public sealed class GraphAuthOptions
{
    public string TenantId { get; set; } = string.Empty;
    public string ClientId { get; set; } = string.Empty;
    public string ClientSecret { get; set; } = string.Empty;

    public string Scope { get; set; } = "https://graph.microsoft.com/.default";
}
