variable "server" {
  type        = any
  description = "The FreeIPA server, as a map of one name to an address, or to a host object with an address and optional host_key, user, port, private_key_file, jump_hosts, os, hostname or ip."

  validation {
    condition     = length(var.server) == 1
    error_message = "server takes exactly one host. Replicas aren't covered by this circuit."
  }

  validation {
    condition     = alltrue([for h in var.server : contains(["rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "rocky"))])
    error_message = "The server's os must be one of rocky, almalinux, rhel, centos or fedora. Debian and Ubuntu ship no FreeIPA server."
  }
}

variable "clients" {
  type        = any
  default     = {}
  description = "Hosts to enrol as FreeIPA clients, by name, in the same form as server. A name can't be both the server and a client."

  validation {
    condition     = length(setintersection(keys(var.server), keys(var.clients))) == 0
    error_message = "A name can't be both the server and a client. The server enrols itself."
  }

  validation {
    condition     = alltrue([for h in var.clients : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "rocky"))])
    error_message = "A client's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }

  validation {
    condition = alltrue([for name, h in merge(var.server, var.clients) : (
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", try(h.hostname, "${name}.${var.domain}")))
      && length(try(h.hostname, "${name}.${var.domain}")) <= 64
      && try(h.hostname, "${name}.${var.domain}") != var.domain
    )])
    error_message = "Every host needs a fully qualified name in lower case, up to 64 characters, that isn't the domain itself, such as ipa.example.com. It's the host's name with the domain after it unless a host object sets hostname."
  }

  validation {
    condition     = alltrue([for h in merge(var.server, var.clients) : try(h.ip, null) == null || can(cidrhost("${try(h.ip, "")}/32", 0))])
    error_message = "A host object's ip must be an IPv4 address."
  }
}

variable "domain" {
  type        = string
  description = "DNS domain of the FreeIPA deployment, such as ipa.example.com. Hosts are named <name>.<domain> unless a host object sets hostname."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain))
    error_message = "domain must be a DNS name in lower case with at least two labels, such as ipa.example.com. FreeIPA doesn't support single-label domains."
  }
}

variable "realm" {
  type        = string
  default     = null
  description = "Kerberos realm. When null, the domain in upper case."

  validation {
    condition     = var.realm == null || can(regex("^[A-Z0-9]([A-Z0-9.-]*[A-Z0-9])?$", coalesce(var.realm, "-")))
    error_message = "realm must be in upper case, such as IPA.EXAMPLE.COM."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password of FreeIPA's admin user, set when the server is installed. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  validation {
    condition     = length(var.admin_password) >= 8
    error_message = "admin_password must be at least 8 characters, as FreeIPA requires."
  }
}

variable "ds_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password of the LDAP Directory Manager, set when the server is installed. Pass it at run time with -var or TF_VAR_ds_password; it never reaches state or the plan."

  validation {
    condition     = length(var.ds_password) >= 8
    error_message = "ds_password must be at least 8 characters, as FreeIPA requires."
  }
}

variable "enroll_principal" {
  type        = string
  default     = "admin"
  nullable    = false
  description = "User clients enrol as, with enroll_password. Clients listed in client_otps use their one-time password instead."
}

variable "enroll_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password of enroll_principal. When null, admin_password. Pass it at run time; it never reaches state or the plan."
}

variable "client_otps" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  description = "One-time enrolment passwords, by client name, from ipa host-add --random or --password. A client listed here joins with its own instead of enroll_principal."
}

variable "setup_dns" {
  type        = bool
  default     = false
  description = "Run FreeIPA's integrated DNS server, BIND, on the server, with a zone for domain."
}

variable "dns_forwarders" {
  type        = list(string)
  default     = []
  description = "Upstream DNS servers the integrated DNS forwards to, with setup_dns. When empty, the ones in the server's /etc/resolv.conf."

  validation {
    condition     = alltrue([for ip in var.dns_forwarders : can(cidrhost("${ip}/${strcontains(ip, ":") ? 128 : 32}", 0))])
    error_message = "Each of dns_forwarders must be an IP address."
  }
}

variable "manage_hosts_file" {
  type        = bool
  default     = true
  description = "Set each host's name to its fully qualified name and map the names of the host and the server to their addresses in /etc/hosts. FreeIPA needs both to resolve. Turn it off when your DNS already does that."
}

variable "mkhomedir" {
  type        = bool
  default     = true
  description = "Create a home directory when a FreeIPA user first logs in to a client."
}

variable "server_options" {
  type        = list(string)
  default     = []
  description = "Extra arguments to ipa-server-install, such as [\"--no-ntp\"] or [\"--setup-kra\"]. Don't put passwords here: they would land in state."

  validation {
    condition     = alltrue([for o in var.server_options : !can(regex("^-(p|a|-ds-password|-admin-password|-dirsrv-pin|-http-pin|-pkinit-pin)", o))])
    error_message = "Passwords and PINs can't go in server_options. Use admin_password and ds_password."
  }
}

variable "client_options" {
  type        = list(string)
  default     = []
  description = "Extra arguments to ipa-client-install, such as [\"--no-ntp\"]. Don't put passwords here: they would land in state."

  validation {
    condition     = alltrue([for o in var.client_options : !can(regex("^-(w|-password)", o))])
    error_message = "Passwords can't go in client_options. Use enroll_password or client_otps."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}
