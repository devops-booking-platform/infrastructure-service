removed {
  from = azurerm_resource_group.booking
  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_key_vault.booking
  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_role_assignment.secret_operator
  lifecycle {
    destroy = false
  }
}
