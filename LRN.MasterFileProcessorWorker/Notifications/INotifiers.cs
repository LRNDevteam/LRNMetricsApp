namespace LRN.MasterFileProcessorWorker.Notifications;

public interface IEmailNotifier
{
	Task SendAsync(EmailNotification email, CancellationToken ct = default);
}

public interface ITeamsNotifier
{
	Task SendAsync(TeamsNotification msg, CancellationToken ct = default);
}
