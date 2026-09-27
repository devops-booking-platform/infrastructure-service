terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.3.0"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id                 = "bff6a774-701a-4987-b913-5288d9ef784e"
  resource_provider_registrations = "none"
}

# Apply infra/azure first. This root reads AKS; it does not create or own it.
data "azurerm_kubernetes_cluster" "booking" {
  name                = "booking-aks"
  resource_group_name = "booking-aks-lab"
}

# Connect to the named Azure cluster, independently of the current kubectl context.
# Local account certificates match the existing short-lived lab AKS configuration.
provider "helm" {
  kubernetes = {
    host                   = data.azurerm_kubernetes_cluster.booking.kube_config[0].host
    client_certificate     = base64decode(data.azurerm_kubernetes_cluster.booking.kube_config[0].client_certificate)
    client_key             = base64decode(data.azurerm_kubernetes_cluster.booking.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.booking.kube_config[0].cluster_ca_certificate)
  }
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.15.1"
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [file("${path.module}/../ingress/nginx-values.azure.yaml")]

  wait          = true
  wait_for_jobs = true
  timeout       = 600
}
