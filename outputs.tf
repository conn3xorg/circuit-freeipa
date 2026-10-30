output "realm" {
  description = "Kerberos realm of the deployment."
  value       = local.realm
}

output "domain" {
  description = "DNS domain of the deployment."
  value       = var.domain
}

output "server_hostname" {
  description = "Fully qualified name of the server, which clients enrol with and users reach the web UI at."
  value       = local.server_hostname
}

output "hostnames" {
  description = "Fully qualified name of every host, server and clients, by name."
  value       = local.hostname
}
