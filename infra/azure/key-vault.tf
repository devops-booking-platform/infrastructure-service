data "azurerm_client_config" "current" {}

data "azurerm_key_vault" "booking" {
  name                = "kv-booking-${substr(data.azurerm_client_config.current.subscription_id, 0, 8)}"
  resource_group_name = data.azurerm_resource_group.booking.name
}

resource "azurerm_role_assignment" "aks_secrets" {
  scope                = data.azurerm_key_vault.booking.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.booking.key_vault_secrets_provider[0].secret_identity[0].object_id
}

output "key_vault" {
  value = {
    name     = data.azurerm_key_vault.booking.name
    tenantId = data.azurerm_key_vault.booking.tenant_id
    clientId = azurerm_kubernetes_cluster.booking.key_vault_secrets_provider[0].secret_identity[0].client_id
  }
}
