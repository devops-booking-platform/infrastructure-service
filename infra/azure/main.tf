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

data "azurerm_resource_group" "booking" {
  name = "booking-aks-lab"
}

variable "aks_location" {
  description = "AKS region. Use azure-sql.tfvars for the Italy North SQL deployment."
  type        = string
  default     = "newzealandnorth"
}

variable "node_vm_size" {
  description = "Node VM size. Price and quota must be checked in the selected region."
  type        = string
  default     = "Standard_F4ams_v6"
}

resource "azurerm_kubernetes_cluster" "booking" {
  name                = "booking-aks"
  location            = var.aks_location
  resource_group_name = data.azurerm_resource_group.booking.name
  node_resource_group = "${data.azurerm_resource_group.booking.name}-nodes"
  dns_prefix          = "booking-aks-lab"
  sku_tier            = "Free"

  node_os_upgrade_channel = "None"

  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name                 = "system"
    node_count           = 2
    vm_size              = var.node_vm_size
    auto_scaling_enabled = false
    os_sku               = "Ubuntu2404"
    os_disk_type         = "Managed"
    os_disk_size_gb      = 64
  }

  identity {
    type = "SystemAssigned"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }
}
