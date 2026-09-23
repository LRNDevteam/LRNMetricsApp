# LRN.ReportsApi - the reporting / Denial Workflow API (net8.0).
#
# BUILD FROM THE REPOSITORY ROOT, not from this folder:
#
#   docker build -f LRN.ReportsApi/Dockerfile -t lrn-reportsapi .
#
# The project references ..\LRN.PayerPolicyMapper.Core, which a context rooted at this
# directory cannot see.
#
# This targets net8.0 while LabMetricsDashboard targets net9.0 - that split is
# deliberate in the solution, so the two images sit on different base tags.

# ── Build ────────────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
ARG BUILD_CONFIGURATION=Release
WORKDIR /src

# Project files first so the restore layer survives ordinary source edits.
COPY ["LRN.ReportsApi/LRN.ReportsApi.csproj", "LRN.ReportsApi/"]
COPY ["LRN.PayerPolicyMapper.Core/LRN.PayerPolicyMapper.Core.csproj", "LRN.PayerPolicyMapper.Core/"]
RUN dotnet restore "LRN.ReportsApi/LRN.ReportsApi.csproj"

COPY . .
RUN dotnet publish "LRN.ReportsApi/LRN.ReportsApi.csproj" \
    -c "$BUILD_CONFIGURATION" \
    -o /app/publish \
    --no-restore \
    /p:UseAppHost=false

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final

# Same reason as the dashboard image: ClosedXML measures text against real font
# files when a sheet auto-fits its columns, and the API's Excel services
# (DenialMapperExcelService, CptLookupService, MasterValuesService) do exactly that.
RUN apt-get update \
    && apt-get install -y --no-install-recommends fontconfig fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -f

WORKDIR /app
COPY --from=build /app/publish .

RUN mkdir -p /var/lrn/logs && chown -R $APP_UID:$APP_UID /var/lrn

ENV ASPNETCORE_ENVIRONMENT=Production \
    ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_gcServer=1

EXPOSE 8080

# CORS caveat: the "MetricsWeb" origins are HARD-CODED in Program.cs (lines 170-186),
# not read from configuration. Production allows only https://www.lrnanalytics.com and
# https://lrnanalytics.com; the localhost origins are added only when the environment is
# Development. So a container serving the SPA from any other origin is blocked, and
# there is no environment variable that changes it - it needs a code change. The
# compose file works around this locally by running this service as Development and
# publishing the SPA on 5173, which is in the allowed list.
USER $APP_UID

ENTRYPOINT ["dotnet", "LRN.ReportsApi.dll"]
