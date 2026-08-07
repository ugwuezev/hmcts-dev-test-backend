resource "random_password" "postgres" {
  length      = 32
  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
  min_special = 2
}

resource "azurerm_postgresql_flexible_server" "case_management" {
  name                = format(local.name, "psql")
  resource_group_name = azurerm_resource_group.case_management.name
  location            = azurerm_resource_group.case_management.location
  version             = var.postgres_version
  tags                = var.tags

  administrator_login    = var.postgres_admin_username
  administrator_password = random_password.postgres.result

  sku_name   = var.postgres_sku_name
  storage_mb = var.postgres_storage_mb

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup_enabled

  dynamic "high_availability" {
    for_each = var.postgres_high_availability_enabled ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }
}

# Flexible Server names the throttle parameter connection_throttle.enable,
# not connection_throttling as on the retired Single Server.
resource "azurerm_postgresql_flexible_server_configuration" "audit" {
  for_each = {
    "log_connections"            = "on"
    "log_checkpoints"            = "on"
    "connection_throttle.enable" = "on"
  }

  name      = each.key
  value     = each.value
  server_id = azurerm_postgresql_flexible_server.case_management.id
}

resource "azurerm_postgresql_flexible_server_database" "application" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.case_management.id
}

# 0.0.0.0/0.0.0.0 is the Azure marker for Azure services, not the internet.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.case_management.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
