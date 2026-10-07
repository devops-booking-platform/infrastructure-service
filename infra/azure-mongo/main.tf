terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
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

data "azurerm_resource_group" "booking" {
  name = "booking-aks-lab"
}

data "azurerm_key_vault" "booking" {
  name                = "kv-booking-bff6a774"
  resource_group_name = data.azurerm_resource_group.booking.name
}

resource "random_password" "mongo" {
  length           = 32
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!_-"
}

resource "azurerm_key_vault_secret" "mongo_password" {
  name         = "mongo-azure-admin-password"
  value        = random_password.mongo.result
  key_vault_id = data.azurerm_key_vault.booking.id
}

variable "allowed_ipv4" {
  description = "Complete map of operator and AKS outbound IPv4 addresses, shared with the SQL firewall setup."
  type        = map(string)
  validation {
    condition = length(var.allowed_ipv4) > 0 && alltrue([
      for ip in values(var.allowed_ipv4) : can(cidrnetmask("${ip}/32")) && ip != "0.0.0.0"
    ])
    error_message = "Supply individual IPv4 addresses, including the AKS outbound IP; no ranges or 0.0.0.0."
  }
}

resource "azurerm_mongo_cluster" "booking" {
  name                   = "mongo-booking-bff6a774"
  resource_group_name    = data.azurerm_resource_group.booking.name
  location               = "francecentral"
  administrator_username = "bookingmongo"
  administrator_password = azurerm_key_vault_secret.mongo_password.value
  compute_tier           = "Free"
  high_availability_mode = "Disabled"
  shard_count            = 1
  storage_size_in_gb     = 32
  version                = "7.0"
  public_network_access  = "Enabled"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_mongo_cluster_firewall_rule" "allowed" {
  for_each         = var.allowed_ipv4
  name             = each.key
  mongo_cluster_id = azurerm_mongo_cluster.booking.id
  start_ip_address = each.value
  end_ip_address   = each.value
}

resource "azurerm_key_vault_secret" "search_connection" {
  name         = "mongo-conn-search-azure"
  value        = azurerm_mongo_cluster.booking.connection_strings[0].value
  key_vault_id = data.azurerm_key_vault.booking.id
}

output "mongo" {
  value = {
    name              = azurerm_mongo_cluster.booking.name
    location          = azurerm_mongo_cluster.booking.location
    tier              = azurerm_mongo_cluster.booking.compute_tier
    connection_secret = azurerm_key_vault_secret.search_connection.name
  }
}
