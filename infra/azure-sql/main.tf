terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = "bff6a774-701a-4987-b913-5288d9ef784e"
  resource_provider_registrations = "none"
}

provider "azapi" {
  subscription_id            = "bff6a774-701a-4987-b913-5288d9ef784e"
  skip_provider_registration = true
}

data "azurerm_resource_group" "booking" {
  name = "booking-aks-lab"
}

data "azurerm_client_config" "current" {}

variable "administrator_password" {
  description = "SQL administrator password loaded from Key Vault sql-admin-password through TF_VAR_administrator_password. Never commit the value. Application services use separate contained users."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "allowed_ipv4" {
  description = "Named individual public IPv4 addresses: operator and, later, every AKS outbound IP. No AllowAllAzureServices rule."
  type        = map(string)
  default     = {}
  validation {
    condition = alltrue([
      for ip in values(var.allowed_ipv4) : can(cidrnetmask("${ip}/32")) && ip != "0.0.0.0"
    ])
    error_message = "Use individual IPv4 addresses, not ranges or 0.0.0.0."
  }
}

locals {
  databases = {
    user          = "UserServiceDb"
    accommodation = "AccommodationServiceDb"
    reservation   = "ReservationServiceDb"
    rating        = "RatingServiceDb"
    notification  = "NotificationServiceDb"
  }
}

resource "azurerm_mssql_server" "booking" {
  name                                    = "sql-booking-it-bff6a774"
  resource_group_name                     = data.azurerm_resource_group.booking.name
  location                                = "italynorth"
  version                                 = "12.0"
  minimum_tls_version                     = "1.2"
  public_network_access_enabled           = true
  administrator_login                     = "booking_sql_admin"
  administrator_login_password_wo         = var.administrator_password
  administrator_login_password_wo_version = 1

  azuread_administrator {
    login_username              = "Booking administrator"
    object_id                   = data.azurerm_client_config.current.object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = false
  }
}

resource "azurerm_mssql_firewall_rule" "allowed" {
  for_each         = var.allowed_ipv4
  name             = each.key
  server_id        = azurerm_mssql_server.booking.id
  start_ip_address = each.value
  end_ip_address   = each.value
}

resource "azapi_resource" "database" {
  for_each  = local.databases
  type      = "Microsoft.Sql/servers/databases@2023-08-01"
  name      = each.value
  parent_id = azurerm_mssql_server.booking.id
  location  = azurerm_mssql_server.booking.location

  body = {
    sku = {
      name     = "GP_S_Gen5"
      tier     = "GeneralPurpose"
      family   = "Gen5"
      capacity = 2
    }
    properties = {
      useFreeLimit                     = true
      freeLimitExhaustionBehavior      = "AutoPause"
      autoPauseDelay                   = 60
      minCapacity                      = 0.5
      maxSizeBytes                     = 34359738368
      requestedBackupStorageRedundancy = "Local"
    }
  }
}

output "sql" {
  value = {
    server    = azurerm_mssql_server.booking.fully_qualified_domain_name
    databases = local.databases
  }
}
