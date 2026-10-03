data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "booking" {
  name                       = "kv-booking-${substr(data.azurerm_client_config.current.subscription_id, 0, 8)}"
  location                   = azurerm_resource_group.booking.location
  resource_group_name        = azurerm_resource_group.booking.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
}

resource "azurerm_role_assignment" "aks_secrets" {
  scope                = azurerm_key_vault.booking.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.booking.key_vault_secrets_provider[0].secret_identity[0].object_id
}

resource "azurerm_role_assignment" "secret_operator" {
  scope                = azurerm_key_vault.booking.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

output "key_vault" {
  value = {
    name     = azurerm_key_vault.booking.name
    tenantId = azurerm_key_vault.booking.tenant_id
    clientId = azurerm_kubernetes_cluster.booking.key_vault_secrets_provider[0].secret_identity[0].client_id
  }
}
