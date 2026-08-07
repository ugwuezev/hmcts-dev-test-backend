# Shared across services and environments, so it is read rather than owned.
# One registry keeps a sha- tag the same artefact from dev through to prd.
data "azurerm_container_registry" "shared" {
  name                = var.registry_name
  resource_group_name = var.registry_resource_group_name
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = data.azurerm_container_registry.shared.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.api.principal_id
}
