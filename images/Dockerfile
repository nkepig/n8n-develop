# Customer-specific n8n image with Chinese UI.
#
# Build context: project root (../)
#   docker build -t myregistry/n8n-client-a:1.0 \
#     --build-arg CLIENT_DIR=client_A \
#     -f images/Dockerfile .
#
# The base image ghcr.io/deluxebear/n8n:chs is a community-maintained Chinese
# localization of n8n. It bundles the full zh-CN UI (menu, settings, sidebar,
# node descriptions) on top of the official n8n engine.
#
# The workflows for the given CLIENT_DIR are baked into the image at /workflows.
# On first container start, images/entrypoint.sh imports them into n8n's
# database (requires the owner env vars to be set at runtime).

ARG N8N_IMAGE=ghcr.io/deluxebear/n8n:chs
FROM ${N8N_IMAGE}

# Which client's workflows to bake in. Override with --build-arg CLIENT_DIR=...
ARG CLIENT_DIR=client_A
ARG N8N_BUILTIN_WORKFLOWS_DIR=/workflows

# Bake this client's exported workflow JSONs into /workflows.
COPY workflows/${CLIENT_DIR}/ ${N8N_BUILTIN_WORKFLOWS_DIR}/

# Custom entrypoint that imports workflows on first start.
COPY images/entrypoint.sh /custom-entrypoint.sh
USER root
RUN chmod +x /custom-entrypoint.sh

# Defaults that make sense for an air-gapped / customer deployment.
# Owner credentials (EMAIL / PASSWORD_HASH) are intentionally NOT baked in;
# pass them at runtime via env so the same image can be re-used across
# environments without leaking secrets.
ENV N8N_HOST=0.0.0.0 \
    N8N_PORT=5678 \
    N8N_PROTOCOL=http \
    N8N_USER_FOLDER=/home/node/.n8n \
    N8N_BUILTIN_WORKFLOWS_DIR=${N8N_BUILTIN_WORKFLOWS_DIR} \
    GENERIC_TIMEZONE=Asia/Shanghai \
    N8N_DEFAULT_LOCALE=zh \
    # Avoid the "settings were modified" prompt for self-hosted images.
    N8N_ENFORCE_SETTINGS_ALLOWED_SOURCES="" \
    # Disable telemetry for customer deployments.
    N8N_DIAGNOSTICS_ENABLED=false \
    N8N_VERSION_NOTIFICATIONS_ENABLED=false \
    # Owner bootstrap is gated at runtime (see docker-compose.yml).
    N8N_INSTANCE_OWNER_MANAGED_BY_ENV=false

USER node
ENTRYPOINT ["/custom-entrypoint.sh"]