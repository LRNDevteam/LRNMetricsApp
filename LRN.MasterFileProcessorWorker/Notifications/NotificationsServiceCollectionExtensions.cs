using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace LRN.MasterFileProcessorWorker.Notifications;

public static class NotificationsServiceCollectionExtensions
{
	/// <summary>
	/// Registers the Teams and email notifiers, bound to the "Notifications" section. Each channel
	/// is switched on or off by its own "Enabled" key; both are off by default.
	/// </summary>
	public static IServiceCollection AddNotifications(
		this IServiceCollection services,
		IConfiguration config)
	{
		services.Configure<TeamsWebhookOptions>(config.GetSection("Notifications:Teams"));
		services.Configure<EmailOptions>(config.GetSection("Notifications:Email"));

		services.AddHttpClient();

		services.AddSingleton<ITeamsNotifier, TeamsWebhookNotifier>();
		services.AddSingleton<IEmailNotifier, GraphEmailNotifier>();

		return services;
	}
}
