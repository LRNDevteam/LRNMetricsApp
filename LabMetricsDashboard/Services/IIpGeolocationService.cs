namespace LabMetricsDashboard.Services;

public interface IIpGeolocationService
{
    /// <summary>
    /// A "City, Region, Country" label for a public IP address, or null if it could not be
    /// resolved (private/loopback address, lookup failure, rate-limited). Never throws.
    /// </summary>
    Task<string?> ResolveAsync(string ipAddress, CancellationToken cancellationToken = default);
}
