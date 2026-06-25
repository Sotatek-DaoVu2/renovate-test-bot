resource "azurerm_log_analytics_workspace" "lbr-gpt-logs" {
  name                = local.log_analytics_workspace_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_container_app_environment" "lbr-gpt-aca-env" {
  name                       = local.aca_environment_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.lbr-gpt-logs.id
  public_network_access      = "Enabled"
  infrastructure_subnet_id   = azurerm_subnet.lbr-gpt-aca-subnet.id
  # Separate RG for Azure-managed ACA infrastructure (LB, etc.). Must not match libeara-gpt-{env}.
  infrastructure_resource_group_name = var.INFRA_RG
  workload_profile {
    maximum_count         = 0
    minimum_count         = 0
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = local.common_tags

  depends_on = [azurerm_resource_provider_registration.microsoft_app]
}

resource "azurerm_container_app" "lbr-gpt-aca" {
  name                         = "lbr-gpt-aca-${var.ENVIRONMENT_SHORT}"
  container_app_environment_id = azurerm_container_app_environment.lbr-gpt-aca-env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.common_tags

  ingress {
    allow_insecure_connections = false
    client_certificate_mode    = "ignore"
    external_enabled           = true
    transport                  = "auto"
    target_port                = 8080

    dynamic "ip_security_restriction" {
      for_each = var.enable_ip_whitelist ? var.IP_WHITELIST : []
      content {
        action           = "Allow"
        ip_address_range = ip_security_restriction.value
        name             = "allow-${ip_security_restriction.key}"
      }
    }

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    max_replicas = 1
    min_replicas = 1

    volume {
      name          = "open-webui-data"
      storage_name  = azurerm_container_app_environment_storage.open_webui_data.name
      storage_type  = "AzureFile"
      mount_options = "nobrl"
    }

    volume {
      name          = "lbr-gpt-build"
      storage_name  = azurerm_container_app_environment_storage.lbrgptbuild.name
      storage_type  = "AzureFile"
      mount_options = "nobrl"
    }
    volume {
      name          = "lbr-gpt-pipelines"
      storage_name  = azurerm_container_app_environment_storage.pipelines.name
      storage_type  = "AzureFile"
      mount_options = "nobrl"
    }

    volume {
      name          = local.litellm_env_storage_name
      storage_name  = azurerm_container_app_environment_storage.litellm_config.name
      storage_type  = "AzureFile"
      mount_options = "nobrl"
    }

    container {
      name   = "lbr-gpt-aca-container"
      image  = "ghcr.io/open-webui/open-webui:v0.9.6"
      cpu    = 0.5
      memory = "1Gi"

      args = [
        "-c",
        "sed -i '/if WEBUI_NAME != \"Open WebUI\":/{N; /WEBUI_NAME += \" (Open WebUI)\"/d;}' /app/backend/open_webui/env.py && cd /app/backend && exec bash start.sh",
      ]

      command = [
        "/bin/sh"
      ]

      volume_mounts {
        name = "open-webui-data"
        path = "/app/backend/data"
      }

      volume_mounts {
        name = "lbr-gpt-build"
        path = "/app/build/static"
      }

      liveness_probe {
        initial_delay    = 0
        interval_seconds = 10
        port             = 8080
        timeout          = 5
        transport        = "TCP"
      }

      readiness_probe {
        failure_count_threshold = 48
        initial_delay           = 0
        interval_seconds        = 5
        port                    = 8080
        success_count_threshold = 1
        timeout                 = 5
        transport               = "TCP"
      }

      startup_probe {
        failure_count_threshold = 240
        initial_delay           = 1
        interval_seconds        = 1
        port                    = 8080
        transport               = "TCP"
      }

      env {
        name  = "WEBUI_AUTH"
        value = "true"
      }

      env {
        name        = "WEBUI_SECRET_KEY"
        secret_name = "webui-secret-key"
      }

      env {
        name  = "JWT_EXPIRES_IN"
        value = var.JWT_EXPIRES_IN
      }

      env {
        name  = "WEBUI_URL"
        value = var.WEBUI_URL
      }

      env {
        name  = "ENABLE_SIGNUP"
        value = "true"
      }

      env {
        name  = "ENABLE_OAUTH_SIGNUP"
        value = "true"
      }

      env {
        name  = "ENABLE_LOGIN_FORM"
        value = "false"
      }

      env {
        name  = "OAUTH_MERGE_ACCOUNTS_BY_EMAIL"
        value = "true"
      }

      env {
        name  = "OAUTH_UPDATE_PICTURE_ON_LOGIN"
        value = "true"
      }

      env {
        name  = "MICROSOFT_CLIENT_ID"
        value = var.MICROSOFT_CLIENT_ID
      }

      env {
        name  = "MICROSOFT_CLIENT_TENANT_ID"
        value = var.MICROSOFT_CLIENT_TENANT_ID
      }

      env {
        name        = "MICROSOFT_CLIENT_SECRET"
        secret_name = "microsoft-client-secret"
      }

      env {
        name        = "DATABASE_URL"
        secret_name = "psql-connection-string"
      }

      env {
        name  = "WEBUI_NAME"
        value = var.WEBUI_NAME
      }

      env {
        name  = "BYPASS_ADMIN_ACCESS_CONTROL"
        value = "false"
      }

      env {
        name  = "OPENAI_API_BASE_URLS"
        value = "http://localhost:4000/v1;http://localhost:9099"
      }

      env {
        name        = "OPENAI_API_KEYS"
        secret_name = "openai-api-keys"
      }

      env {
        name  = "RAG_EMBEDDING_ENGINE"
        value = "openai"
      }

      env {
        name  = "RAG_EMBEDDING_MODEL"
        value = "text-embedding-3-small"
      }

      env {
        name  = "RAG_OPENAI_API_BASE_URL"
        value = "http://localhost:4000/v1"
      }

      env {
        name        = "RAG_OPENAI_API_KEY"
        secret_name = "litellm-master-key"
      }

      env {
        name  = "ENABLE_RAG_WEB_SEARCH"
        value = "false"
      }

    }

    container {
      name   = "lbr-gpt-aca-container-litellm"
      image  = "ghcr.io/berriai/litellm:main-latest"
      cpu    = 1.0
      memory = "2Gi"

      args = ["--config", "/etc/litellm/config.yaml", "--port", "4000"]

      volume_mounts {
        name = local.litellm_env_storage_name
        path = "/etc/litellm"
      }

      liveness_probe {
        initial_delay           = 30
        interval_seconds        = 30
        port                    = 4000
        timeout                 = 10
        transport               = "HTTP"
        path                    = "/health/liveliness"
        failure_count_threshold = 3
      }

      readiness_probe {
        failure_count_threshold = 12
        initial_delay           = 30
        interval_seconds        = 10
        port                    = 4000
        success_count_threshold = 1
        timeout                 = 10
        transport               = "HTTP"
        path                    = "/health/liveliness"
      }

      # Prisma migrate on first boot can take many minutes; ACA startup probe max is 240 failures.
      # Worst case wait: initial_delay (60s) + 240 * interval_seconds (10s) ≈ 41 minutes.
      startup_probe {
        failure_count_threshold = 240
        initial_delay           = 60
        interval_seconds        = 10
        port                    = 4000
        transport               = "HTTP"
        path                    = "/health/liveliness"
        timeout                 = 15
      }

      env {
        name        = "AZURE_AI_API_KEY"
        secret_name = "azure-ai-api-key"
      }

      env {
        name  = "AZURE_OPENAI_ENDPOINT"
        value = var.AZURE_OPENAI_ENDPOINT
      }

      env {
        name  = "AZURE_CLAUDE_ENDPOINT"
        value = var.AZURE_CLAUDE_ENDPOINT
      }

      env {
        name        = "LITELLM_MASTER_KEY"
        secret_name = "litellm-master-key"
      }

      env {
        name        = "DATABASE_URL"
        secret_name = "litellm-database-url"
      }

      env {
        name  = "STORE_MODEL_IN_DB"
        value = "True"
      }
    }

    container {
      # PIPELINES IMAGE
      name   = "lbr-gpt-aca-container-pipelines"
      image  = "ghcr.io/open-webui/pipelines:main"
      cpu    = 0.25
      memory = "0.5Gi"

      volume_mounts {
        name = "lbr-gpt-pipelines"
        path = "/app/pipelines"
      }

      liveness_probe {
        initial_delay    = 0
        interval_seconds = 10
        port             = 9099
        timeout          = 5
        transport        = "TCP"
      }

      readiness_probe {
        failure_count_threshold = 48
        initial_delay           = 0
        interval_seconds        = 5
        port                    = 9099
        success_count_threshold = 1
        timeout                 = 5
        transport               = "TCP"
      }

      startup_probe {
        failure_count_threshold = 240
        initial_delay           = 1
        interval_seconds        = 1
        port                    = 9099
        transport               = "TCP"
      }

      env {
        name  = "AUDIT_DB_HOST"
        value = azurerm_postgresql_flexible_server.lbr-gpt-psql-flexible-server.fqdn
      }

      env {
        name  = "AUDIT_DB_PORT"
        value = "5432"
      }

      env {
        name  = "AUDIT_DB_USER"
        value = "openwebui"
      }

      env {
        name        = "AUDIT_DB_PASSWORD"
        secret_name = "psql-admin-password"
      }

      env {
        name  = "AUDIT_DB_NAME"
        value = "openwebui"
      }

      env {
        name  = "AUDIT_DB_POOL_MIN"
        value = "1"
      }

      env {
        name  = "AUDIT_DB_POOL_MAX"
        value = "5"
      }

      env {
        name        = "PIPELINES_API_KEY"
        secret_name = "pipelines-api-key"
      }
    }
  }

  secret {
    name  = "microsoft-client-secret"
    value = var.MICROSOFT_CLIENT_SECRET
  }


  secret {
    name  = "psql-connection-string"
    value = local.openwebui_database_url
  }

  secret {
    name  = "psql-admin-password"
    value = var.PSQL_ADMIN_PASSWORD
  }

  secret {
    name  = "pipelines-api-key"
    value = var.PIPELINES_API_KEY
  }

  secret {
    name  = "azure-ai-api-key"
    value = var.AZURE_AI_API_KEY
  }

  secret {
    name  = "litellm-master-key"
    value = var.LITELLM_MASTER_KEY
  }

  secret {
    name  = "webui-secret-key"
    value = var.WEBUI_SECRET_KEY
  }

  secret {
    name  = "litellm-database-url"
    value = local.litellm_database_url
  }

  secret {
    name  = "openai-api-keys"
    value = "${var.LITELLM_MASTER_KEY};${var.PIPELINES_API_KEY}"
  }

  depends_on = [
    azurerm_container_app_environment_storage.litellm_config,
    azurerm_container_app_environment_storage.open_webui_data,
    azurerm_container_app_environment_storage.lbrgptbuild,
    azurerm_container_app_environment_storage.pipelines,
    azurerm_storage_share_file.litellm_config_yaml,
    azurerm_postgresql_flexible_server_database.litellm,
    azurerm_postgresql_flexible_server_database.openwebui,
  ]
}

# Custom domain + Azure-managed certificate for Open WebUI ingress.
# Before apply succeeds, create DNS records (outside Terraform if libeara.com DNS is external):
#   CNAME  <custom domain>              -> <container app default FQDN>
#   TXT    asuid.<custom domain>        -> <custom_domain_verification_id output>
resource "azurerm_container_app_custom_domain" "lbr-gpt-aca" {
  count            = local.aca_custom_domain != "" ? 1 : 0
  name             = local.aca_custom_domain
  container_app_id = azurerm_container_app.lbr-gpt-aca.id

  lifecycle {
    ignore_changes = [certificate_binding_type, container_app_environment_certificate_id]
  }

  depends_on = [
    azurerm_dns_txt_record.aca_custom_domain,
    azurerm_dns_cname_record.aca_custom_domain,
  ]
}

resource "azurerm_container_app_environment_managed_certificate" "lbr-gpt-aca" {
  count                        = local.aca_custom_domain != "" ? 1 : 0
  name                         = local.aca_managed_certificate_name
  container_app_environment_id = azurerm_container_app_environment.lbr-gpt-aca-env.id
  subject_name                 = local.aca_custom_domain
  domain_control_validation    = "CNAME"
  tags                         = local.common_tags

  depends_on = [azurerm_container_app_custom_domain.lbr-gpt-aca]
}

output "aca_custom_domain" {
  description = "Custom domain bound to the Open WebUI container app."
  value       = local.aca_custom_domain != "" ? local.aca_custom_domain : null
}

output "aca_custom_domain_cname_target" {
  description = "CNAME target for the custom domain (container app default hostname)."
  value       = local.aca_custom_domain != "" ? azurerm_container_app.lbr-gpt-aca.ingress[0].fqdn : null
}

output "aca_custom_domain_verification_txt_name" {
  description = "TXT record host for domain verification (asuid.<custom domain>)."
  value       = local.aca_custom_domain != "" ? "asuid.${local.aca_custom_domain}" : null
}

output "aca_custom_domain_verification_txt_value" {
  description = "TXT record value for domain verification."
  value       = local.aca_custom_domain != "" ? azurerm_container_app.lbr-gpt-aca.custom_domain_verification_id : null
  sensitive   = true
}

resource "azurerm_container_app" "lbr-gpt-aca-pgadmin" {
  # PGADMIN CONTAINER APP - OPTIONAL, can be used for DB management if needed. Edit/remove as necessary.
  name                         = "lbr-gpt-aca-pgadmin"
  container_app_environment_id = azurerm_container_app_environment.lbr-gpt-aca-env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.common_tags

  ingress {
    allow_insecure_connections = false
    client_certificate_mode    = "ignore"
    external_enabled           = true
    transport                  = "auto"
    target_port                = 5050

    ip_security_restriction {
      # Edit this section to restrict/enable access to the app.
      action           = "Allow"
      ip_address_range = "4.194.217.194/32"
      name             = "Libeara VPN"
    }
    ip_security_restriction {
      # Edit this section to restrict/enable access to the app.
      action           = "Allow"
      ip_address_range = "121.7.228.34"
      name             = "Libeara Office"
    }
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    max_replicas = 1
    min_replicas = 1
    container {
      name   = "lbr-gpt-aca-container-pgadmin"
      image  = "dpage/pgadmin4:latest"
      cpu    = 0.25
      memory = "0.5Gi"
      env {
        name  = "PGADMIN_DEFAULT_EMAIL"
        value = "admin@libeara.com"
      }
      env {
        name        = "PGADMIN_DEFAULT_PASSWORD"
        secret_name = "pgadmin-password"
      }
      env {
        name  = "PGADMIN_LISTEN_PORT"
        value = "5050"
      }
    }
  }

  secret {
    name  = "pgadmin-password"
    value = var.PGADMIN_PASSWORD
  }
}
