terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.32.0"
    }
  }
  required_version = "=0.13.5"
}

provider "azurerm" {
  features {}
}

locals {
  hosts       = toset(["bastion", "private"])
  access_list = {
    my_ip = "${chomp(data.http.my_ip.body)}/32"
  }
}

resource "tls_private_key" "ssh_keys" {
  for_each    = local.hosts
  algorithm   = "RSA"
}

resource "local_file" "pem_files" {
    for_each        = local.hosts
    content         = tls_private_key.ssh_keys[each.value].private_key_pem
    filename        = "${path.module}/${each.value}.pem"
    file_permission = "0600" 
}

data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

data "azurerm_subscription" "current" {
}

resource "random_string" "random" {
  length  = 12
  upper   = false
  number  = false
  special = false
}

resource "random_password" "admin" {
  for_each    = local.hosts
  length      = 14
  special     = true
}

module "subscription" {
  source = "github.com/Azure-Terraform/terraform-azurerm-subscription-data.git?ref=v1.0.0"
  subscription_id = data.azurerm_subscription.current.subscription_id
}

module "rules" {
  source = "git@github.com:openrba/python-azure-naming.git"
}

module "metadata" {
  source = "github.com/Azure-Terraform/terraform-azurerm-metadata.git?ref=v1.1.0"

  naming_rules = module.rules.yaml

  market              = "us"
  project             = "https://gitlab.ins.risk.regn.net/example/"
  location            = "eastus2"
  sre_team            = "iog-core-services"
  environment         = "sandbox"
  product_name        = random_string.random.result
  business_unit       = "iog"
  product_group       = "core"
  subscription_id     = module.subscription.output.subscription_id
  subscription_type   = "nonprod"
  resource_group_type = "app"
}

module "resource_group" {
  source = "github.com/Azure-Terraform/terraform-azurerm-resource-group.git?ref=v1.0.0"

  location = module.metadata.location
  names    = module.metadata.names
  tags     = module.metadata.tags
}

module "virtual_network" {
  source = "../../"

  naming_rules = module.rules.yaml

  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  names               = module.metadata.names
  tags                = module.metadata.tags

  address_space = ["10.1.0.0/22"]

  subnets = {
    "iaas-public"   = { cidrs                    = ["10.1.0.0/24"]
                        allow_vnet_inbound       = true
                        allow_vnet_outbound      = true
                      }
    "iaas-private"   = { cidrs                   = ["10.1.1.0/24"]
                        allow_vnet_inbound       = true
                        allow_vnet_outbound      = true
                      }
    "iaas-outbound"   = { cidrs = ["10.1.2.0/24"]
                        allow_vnet_inbound       = true
                        allow_vnet_outbound      = true
                        route_table_association  = "default"
                      }
  }

  route_tables = {
    default = {
      disable_bgp_route_propagation = true
      routes = {
        internet = {
          address_prefix         = "0.0.0.0/0"
          next_hop_type          = "Internet"
        }
        internal-1 = { 
          address_prefix         = "10.0.0.0/8"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = "1.1.1.1"
        }
        internal-2 = {
          address_prefix         = "172.16.0.0/12"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = "1.1.1.1"
        }
        internal-3 = {
          address_prefix         = "192.168.0.0/16"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = "1.1.1.1"
        }
        local-vnet = {
          address_prefix         = "8.8.8.0/24"
          next_hop_type          = "vnetlocal"
        }
      }
    }
  }

}

resource "azurerm_public_ip" "bastion" {
  name                = "${module.metadata.names.product_name}-bastion-public"
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location

  allocation_method   = "Static"
  sku                 = "Basic"

  tags                = module.metadata.tags
}

resource "azurerm_network_interface" "bastion" {
  name                = "${module.metadata.names.product_name}-bastion"
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location

  ip_configuration {
    name                          = "bastion"
    subnet_id                     = module.virtual_network.subnet["iaas-public"].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion.id
  }

  tags                = module.metadata.tags
}

resource "azurerm_network_security_rule" "bastion_in" {
  name                        = "bastion-in"
  priority                    = 101
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = values(local.access_list)
  destination_address_prefix  = azurerm_network_interface.bastion.private_ip_address
  resource_group_name         = module.resource_group.name
  network_security_group_name = module.virtual_network.subnet_nsg_names["iaas-public"]
}

resource "azurerm_network_interface" "private" {
  name                = "${module.metadata.names.product_name}-private"
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location

  ip_configuration {
    name                          = "private"
    subnet_id                     = module.virtual_network.subnet["iaas-private"].id
    private_ip_address_allocation = "Dynamic"
  }

  tags                = module.metadata.tags
}

resource "azurerm_linux_virtual_machine" "bastion" {
  name                = "${module.metadata.names.product_name}-bastion"
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  size                = "Standard_B2s"
  admin_username      = "adminuser"

  network_interface_ids = [
    azurerm_network_interface.bastion.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.ssh_keys["bastion"].public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }
}

resource "azurerm_linux_virtual_machine" "private" {
  name                = "${module.metadata.names.product_name}-private"
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  size                = "Standard_B2s"
  admin_username      = "adminuser"

  network_interface_ids = [
    azurerm_network_interface.private.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.ssh_keys["private"].public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }
}

output "bastion_ssh" {
  value = "ssh -i bastion.pem adminuser@${azurerm_public_ip.bastion.ip_address}"
}

output "private_ssh" {
  value = "ssh -i private.pem -o ProxyCommand=\"ssh -W %h:%p -i bastion.pem adminuser@${azurerm_public_ip.bastion.ip_address}\" adminuser@${azurerm_network_interface.private.private_ip_address}"
}