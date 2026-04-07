using LRN.Notifications.Models;

namespace LRN.Notifications.Abstractions
{
    public interface INotifier
    {
        Task NotifyAsync(string title, string message, CancellationToken ct);
    }

    public interface IEmailNotifier
    {
        Task SendAsync(EmailNotification email, CancellationToken ct = default);
    }

    public interface ITeamsNotifier
    {
        Task SendAsync(TeamsNotification msg, CancellationToken ct = default);
    }
}