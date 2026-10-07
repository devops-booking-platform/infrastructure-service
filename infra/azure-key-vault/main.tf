terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }

  subscription_id                 = "bff6a774-701a-4987-b913-5288d9ef784e"
  resource_provider_registrations = "none"
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "booking" {
  name     = "booking-aks-lab"
  location = "newzealandnorth"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_key_vault" "booking" {
  name                       = "kv-booking-${substr(data.azurerm_client_config.current.subscription_id, 0, 8)}"
  location                   = azurerm_resource_group.booking.location
  resource_group_name        = azurerm_resource_group.booking.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7

  lifecycle {
    prevent_destroy = true
  }
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
  }
}
