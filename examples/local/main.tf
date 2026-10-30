variable "port" {
  type    = number
  default = 2222
}

# up.sh writes the containers' addresses to ips.auto.tfvars.
variable "server_ip" {
  type    = string
  default = null
}

variable "client_ip" {
  type    = string
  default = null
}

variable "admin_password" {
  type      = string
  ephemeral = true
  default   = "example-admin-change-me"
}

variable "ds_password" {
  type      = string
  ephemeral = true
  default   = "example-dm-change-me"
}

module "freeipa" {
  source = "../.."

  # up.sh puts the server on port, and the client on the one after it.
  server  = { ipa = { address = "127.0.0.1", port = var.port, ip = var.server_ip } }
  clients = { client1 = { address = "127.0.0.1", port = var.port + 1, ip = var.client_ip } }

  domain         = "example.test"
  admin_password = var.admin_password
  ds_password    = var.ds_password

  # A container can't set the clock, so neither side runs chrony.
  server_options = ["--no-ntp"]
  client_options = ["--no-ntp"]

  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"
}

output "realm" {
  value = module.freeipa.realm
}
