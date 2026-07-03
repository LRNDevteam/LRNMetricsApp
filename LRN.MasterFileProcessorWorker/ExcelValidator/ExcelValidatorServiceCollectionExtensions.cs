using Microsoft.Extensions.DependencyInjection;

namespace LRN.ExcelValidator.Services;

public static class ExcelValidatorServiceCollectionExtensions
{
    public static IServiceCollection AddExcelValidator(this IServiceCollection services)
    {
        services.AddSingleton<IColumnSchemaLoader, JsonColumnSchemaLoader>();
        services.AddSingleton<IExcelHeaderReader, ExcelDataReaderHeaderReader>();
        services.AddSingleton<IExcelSchemaValidator, ExcelSchemaValidator>();
        return services;
    }
}
