using LRN.Notifications.Abstractions;
using LRN.Notifications.Implementations;
using LRN.Notifications.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace LRN.Notifications
{
    public static class ServiceCollectionExtensions
    {
        public static IServiceCollection AddMyCompanyNotifications(
            this IServiceCollection services,
            IConfiguration config)
        {
            services.Configure<SmtpOptions>(config.GetSection("Notifications:Smtp"));

            var teamsSection = config.GetSection("Notifications:Teams");
            if (!teamsSection.Exists())
            {
                teamsSection = config.GetSection("TeamsSettings");
            }

            services.Configure<TeamsWebhookOptions>(teamsSection);

            services.AddHttpClient();

            services.AddSingleton<IEmailNotifier, SmtpEmailNotifier>();
            services.AddSingleton<ITeamsNotifier, TeamsWebhookNotifier>();

            return services;
        }
    }
}
