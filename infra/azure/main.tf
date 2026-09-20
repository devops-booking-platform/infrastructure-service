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
  features {}

  subscription_id                 = "bff6a774-701a-4987-b913-5288d9ef784e"
  resource_provider_registrations = "none"
}

resource "azurerm_resource_group" "booking" {
  name     = "booking-aks-lab"
  location = "newzealandnorth"
}

resource "azurerm_kubernetes_cluster" "booking" {
  name                = "booking-aks"
  location            = azurerm_resource_group.booking.location
  resource_group_name = azurerm_resource_group.booking.name
  node_resource_group = "${azurerm_resource_group.booking.name}-nodes"
  dns_prefix          = "booking-aks-lab"
  sku_tier            = "Free"

  # Short-lived lab: upgrades with an extra node need 12 vCPUs; current quota is 10.
  node_os_upgrade_channel = "None"

  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name                 = "system"
    node_count           = 2
    vm_size              = "Standard_F4ams_v6"
    auto_scaling_enabled = false
    os_sku               = "Ubuntu2404"
    os_disk_type         = "Managed"
    os_disk_size_gb      = 64
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }
}
