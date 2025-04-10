# Configure the Azure provider
provider "azurerm" {
  features {}
}

# Variables for existing resources
variable "resource_group_name" {
  description = "Name of the existing resource group"
  type        = string
  default     = "your-existing-resource-group-name"  # Replace with your resource group name
}

variable "vnet_id" {
  description = "ID of the existing Virtual Network"
  type        = string
  default     = "/subscriptions/YOUR-SUBSCRIPTION-ID/resourceGroups/your-existing-resource-group-name/providers/Microsoft.Network/virtualNetworks/your-existing-vnet-name"  # Replace with your VNet ID
}

variable "integration_subnet_id" {
  description = "ID of the existing subnet for VNet integration"
  type        = string
  default     = "/subscriptions/YOUR-SUBSCRIPTION-ID/resourceGroups/your-existing-resource-group-name/providers/Microsoft.Network/virtualNetworks/your-existing-vnet-name/subnets/your-integration-subnet-name"  # Replace with your integration subnet ID
}

variable "endpoint_subnet_id" {
  description = "ID of the existing subnet for private endpoints"
  type        = string
  default     = "/subscriptions/YOUR-SUBSCRIPTION-ID/resourceGroups/your-existing-resource-group-name/providers/Microsoft.Network/virtualNetworks/your-existing-vnet-name/subnets/your-endpoint-subnet-name"  # Replace with your endpoint subnet ID
}

# Create a new App Service Plan with B1 SKU
resource "azurerm_service_plan" "function_app_plan" {
  name                = "python-function-app-plan"
  resource_group_name = var.resource_group_name
  location            = "francecentral"
  os_type             = "Linux"
  sku_name            = "B1"  # B1 SKU (Basic tier)
}

# Create a storage account for the function app
resource "azurerm_storage_account" "function_app_storage" {
  name                     = "pythonfunctionappstorage"  # Must be globally unique
  resource_group_name      = var.resource_group_name
  location                 = "francecentral"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  
  # Enable network rules for the storage account
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = []
    virtual_network_subnet_ids = [var.integration_subnet_id]
  }
}

# Create private endpoint for storage account
resource "azurerm_private_endpoint" "storage_private_endpoint" {
  name                = "storage-private-endpoint"
  location            = "francecentral"
  resource_group_name = var.resource_group_name
  subnet_id           = var.endpoint_subnet_id

  private_service_connection {
    name                           = "storage-private-connection"
    private_connection_resource_id = azurerm_storage_account.function_app_storage.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }
}

# Create Application Insights component
resource "azurerm_application_insights" "function_app_insights" {
  name                = "python-function-app-insights"
  location            = "francecentral"
  resource_group_name = var.resource_group_name
  application_type    = "web"
}

# Create the Function App
resource "azurerm_linux_function_app" "function_app" {
  name                       = "python-function-app"  # Must be globally unique
  resource_group_name        = var.resource_group_name
  location                   = "francecentral"
  service_plan_id            = azurerm_service_plan.function_app_plan.id  # Using the newly created plan
  storage_account_name       = azurerm_storage_account.function_app_storage.name
  storage_account_access_key = azurerm_storage_account.function_app_storage.primary_access_key
  
  # Connect to Application Insights
  app_settings = {
    "APPINSIGHTS_INSTRUMENTATIONKEY"             = azurerm_application_insights.function_app_insights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING"      = azurerm_application_insights.function_app_insights.connection_string
    "ApplicationInsightsAgent_EXTENSION_VERSION" = "~3"
    "WEBSITE_VNET_ROUTE_ALL"                    = "1"  # Route all outbound traffic through VNet
  }

  site_config {
    application_stack {
      python_version = "3.10"
    }

    ftps_state = "Disabled"
    vnet_route_all_enabled = true
  }

  # VNet integration
  virtual_network_subnet_id = var.integration_subnet_id
}

# Create private endpoint for function app
resource "azurerm_private_endpoint" "function_app_private_endpoint" {
  name                = "function-app-private-endpoint"
  location            = "francecentral"
  resource_group_name = var.resource_group_name
  subnet_id           = var.endpoint_subnet_id

  private_service_connection {
    name                           = "function-app-private-connection"
    private_connection_resource_id = azurerm_linux_function_app.function_app.id
    is_manual_connection           = false
    subresource_names              = ["sites"]
  }
}

# Create Private DNS Zone for function app
resource "azurerm_private_dns_zone" "function_app_dns_zone" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = var.resource_group_name
}

# Link the Private DNS Zone to the VNet
resource "azurerm_private_dns_zone_virtual_network_link" "function_app_dns_link" {
  name                  = "function-app-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.function_app_dns_zone.name
  virtual_network_id    = var.vnet_id
}

# Create DNS A record for the function app
resource "azurerm_private_dns_a_record" "function_app_dns_record" {
  name                = "python-function-app"
  zone_name           = azurerm_private_dns_zone.function_app_dns_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_private_endpoint.function_app_private_endpoint.private_service_connection[0].private_ip_address]
}

# Create Private DNS Zone for blob storage
resource "azurerm_private_dns_zone" "blob_dns_zone" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = var.resource_group_name
}

# Link the Blob Private DNS Zone to the VNet
resource "azurerm_private_dns_zone_virtual_network_link" "blob_dns_link" {
  name                  = "blob-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.blob_dns_zone.name
  virtual_network_id    = var.vnet_id
}

# Create DNS A record for blob storage
resource "azurerm_private_dns_a_record" "blob_dns_record" {
  name                = azurerm_storage_account.function_app_storage.name
  zone_name           = azurerm_private_dns_zone.blob_dns_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_private_endpoint.storage_private_endpoint.private_service_connection[0].private_ip_address]
}

# Output the function app URL (though it will only be accessible through private network)
output "function_app_url" {
  value = azurerm_linux_function_app.function_app.default_hostname
}

# Output the Application Insights instrumentation key
output "application_insights_instrumentation_key" {
  value     = azurerm_application_insights.function_app_insights.instrumentation_key
  sensitive = true
}

# Output the Application Insights app ID
output "application_insights_app_id" {
  value = azurerm_application_insights.function_app_insights.app_id
}
