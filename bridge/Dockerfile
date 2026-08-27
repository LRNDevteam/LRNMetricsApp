# Reimbursement bridge — Data API Builder over LRNMaster, fronted by API Management.
#
# The image is nothing but the public DAB runtime plus our config: DAB reads
# dab-config.json at startup and serves /api, /graphql and /mcp from it. Keeping the
# image this thin is deliberate — an entity change is a config edit and a rebuild,
# never a code change.
#
# The connection string is NOT baked in. dab-config.json references
# @env('DATABASE_CONNECTION_STRING'), which the Container App supplies from its
# `sql-conn` secret. Never replace that reference with a literal.
FROM mcr.microsoft.com/azure-databases/data-api-builder:latest

COPY dab-config.json /App/dab-config.json
