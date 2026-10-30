# Facts give each host's distribution, which picks the package names, the
# default IPv4 address its name maps to, and the server's memory.
data "conn3x_host" "facts" {
  for_each = merge(var.server, var.clients)

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }

    postcondition {
      condition     = !contains(keys(var.server), each.key) || self.os_family == "redhat"
      error_message = "The server ${each.key} runs ${self.os_id}. The FreeIPA server needs Rocky Linux, AlmaLinux, RHEL, CentOS Stream or Fedora; Debian and Ubuntu ship only the client."
    }

    # ipa-server-install refuses to start with less than 1.2 GB free, and
    # the CA alone takes most of that.
    postcondition {
      condition     = !contains(keys(var.server), each.key) || self.memory_mb >= 1700
      error_message = "The server ${each.key} has ${self.memory_mb} MiB of memory. A FreeIPA server needs 2 GB or more."
    }

    # FreeIPA needs each host's name to resolve to an address on the host,
    # not to loopback.
    postcondition {
      condition     = try(each.value.ip, null) != null || self.ipv4 != ""
      error_message = "Host ${each.key} has no default IPv4 route, so there's no address to map its name to. Set ip in its host object."
    }
  }
}

locals {
  server_name = one(keys(var.server))
  hosts       = merge(var.server, var.clients)
  realm       = coalesce(var.realm, upper(var.domain))

  os       = { for name, h in local.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  hostname = { for name, h in local.hosts : name => try(h.hostname, "${name}.${var.domain}") }
  ip       = { for name, h in local.hosts : name => coalesce(try(h.ip, null), data.conn3x_host.facts[name].ipv4) }

  server_hostname = local.hostname[local.server_name]

  # Fedora names the packages freeipa-*, and the rest of the Red Hat family
  # ipa-*. Debian and Ubuntu have the client only, as freeipa-client.
  prefix = { for name, o in local.os : name => contains(["rocky", "almalinux", "rhel", "centos"], o) ? "ipa" : "freeipa" }

  hosts_steps = var.manage_hosts_file ? toset(["on"]) : toset([])
  dns         = var.setup_dns ? toset(["on"]) : toset([])

  # The installers take passwords only as arguments, which any user on the
  # host can read in ps while they run. This runs the installer's own entry
  # point in Python with the arguments read from root-only files instead.
  secrets = "/etc/conn3x-freeipa"
  launcher = {
    server = "ipaserver.install import ipa_server_install as m"
    client = "ipaclient.install import ipa_client_install as m"
  }

  server_args = concat(
    ["--unattended", "--realm", local.realm, "--domain", var.domain, "--hostname", local.server_hostname],
    var.setup_dns ? concat(["--setup-dns", "--auto-reverse"], length(var.dns_forwarders) > 0 ? flatten([for f in var.dns_forwarders : ["--forwarder", f]]) : ["--auto-forwarders"]) : [],
    var.server_options,
  )

  client_args = { for name in keys(var.clients) : name => concat(
    ["--unattended", "--domain", var.domain, "--realm", local.realm, "--server", local.server_hostname, "--hostname", local.hostname[name]],
    var.mkhomedir ? ["--mkhomedir"] : [],
    var.client_options,
  ) }

  # The installer's own record that it finished. /etc/ipa/default.conf
  # appears halfway through, so it would hide a failed install.
  installed = {
    server = "grep -qx 'complete = True' /var/lib/ipa/sysrestore/sysrestore.state"
    client = "grep -qx 'complete = True' /var/lib/ipa-client/sysrestore/sysrestore.state"
  }

  # Cloud images rewrite the name and /etc/hosts at boot, which would undo
  # what FreeIPA relies on.
  cloud_init = <<-EOT
    # Written by Conn3x. FreeIPA needs this host's name and /etc/hosts to stay as set.
    preserve_hostname: true
    manage_etc_hosts: false
  EOT
}

circuit "freeipa_server" {
  hosts = var.server

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "cloud_init" {
    for_each = local.hosts_steps
    file {
      path    = "/etc/cloud/cloud.cfg.d/99-conn3x-freeipa.cfg"
      content = local.cloud_init
    }
  }

  step "hostname" {
    for_each = local.hosts_steps
    hostname {
      name = local.hostname[each.key]
    }
  }

  step "hosts" {
    for_each = local.hosts_steps
    line {
      path   = "/etc/hosts"
      regexp = "\\s${replace(local.hostname[each.key], ".", "\\.")}(\\s|$)"
      create = true
      line   = "${local.ip[each.key]} ${local.hostname[each.key]} ${split(".", local.hostname[each.key])[0]}"
    }
  }

  # Cloud images map the name to 127.0.0.1 or 127.0.1.1, which the
  # installer rejects.
  step "hosts_loopback" {
    for_each = local.hosts_steps
    line {
      path   = "/etc/hosts"
      regexp = "^(127\\.|::1).*\\s${replace(local.hostname[each.key], ".", "\\.")}(\\s|$)"
      state  = "absent"
    }
  }

  step "server" {
    package {
      name = "${local.prefix[each.key]}-server"
    }
  }

  step "server_dns" {
    for_each = local.dns
    package {
      name = "${local.prefix[each.key]}-server-dns"
    }
  }

  step "secrets" {
    directory {
      path = local.secrets
      mode = "0700"
    }
  }

  step "admin_password" {
    file {
      path       = "${local.secrets}/admin_password"
      content_wo = var.admin_password
    }
  }

  step "ds_password" {
    file {
      path       = "${local.secrets}/ds_password"
      content_wo = var.ds_password
    }
  }

  step "install" {
    command {
      command = <<-EOT
        python3 -I - <<'PY'
        import sys
        def secret(name):
            with open("${local.secrets}/" + name) as f:
                return f.read()
        sys.argv = ["ipa-server-install"] + ${jsonencode(local.server_args)} + ["--ds-password", secret("ds_password"), "--admin-password", secret("admin_password")]
        from ${local.launcher.server}
        m.run()
        PY
      EOT
      unless  = local.installed.server
    }
  }

  step "running" {
    service {
      name    = "ipa"
      state   = "started"
      enabled = true
    }
  }
}

circuit "freeipa_clients" {
  hosts = var.clients

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "cloud_init" {
    for_each = local.hosts_steps
    file {
      path    = "/etc/cloud/cloud.cfg.d/99-conn3x-freeipa.cfg"
      content = local.cloud_init
    }
  }

  step "hostname" {
    for_each = local.hosts_steps
    hostname {
      name = local.hostname[each.key]
    }
  }

  step "hosts" {
    for_each = local.hosts_steps
    line {
      path   = "/etc/hosts"
      regexp = "\\s${replace(local.hostname[each.key], ".", "\\.")}(\\s|$)"
      create = true
      line   = "${local.ip[each.key]} ${local.hostname[each.key]} ${split(".", local.hostname[each.key])[0]}"
    }
  }

  step "hosts_server" {
    for_each = local.hosts_steps
    line {
      path   = "/etc/hosts"
      regexp = "\\s${replace(local.server_hostname, ".", "\\.")}(\\s|$)"
      line   = "${local.ip[local.server_name]} ${local.server_hostname} ${split(".", local.server_hostname)[0]}"
    }
  }

  step "hosts_loopback" {
    for_each = local.hosts_steps
    line {
      path   = "/etc/hosts"
      regexp = "^(127\\.|::1).*\\s${replace(local.hostname[each.key], ".", "\\.")}(\\s|$)"
      state  = "absent"
    }
  }

  step "client" {
    package {
      name = "${local.prefix[each.key]}-client"
    }
  }

  step "secrets" {
    directory {
      path = local.secrets
      mode = "0700"
    }
  }

  # The first line names the user to enrol as, and is empty for a one-time
  # password, which needs none.
  step "enroll_password" {
    file {
      path       = "${local.secrets}/enroll"
      content_wo = try("\n${var.client_otps[each.key]}", "${var.enroll_principal}\n${coalesce(var.enroll_password, var.admin_password)}")
    }
  }

  # Waits for the server's install, so a client and its server can come up
  # in the same apply.
  step "enroll" {
    depends_on = [conn3x_command.freeipa_server__install, conn3x_service.freeipa_server__running]
    command {
      command = <<-EOT
        python3 -I - <<'PY'
        import sys
        with open("${local.secrets}/enroll") as f:
            principal, password = f.read().split("\n", 1)
        sys.argv = ["ipa-client-install"] + ${jsonencode(local.client_args[each.key])} + ["--password", password]
        if principal:
            sys.argv += ["--principal", principal]
        from ${local.launcher.client}
        m.run()
        PY
      EOT
      unless  = local.installed.client
    }
  }

  step "sssd" {
    service {
      name    = "sssd"
      state   = "started"
      enabled = true
    }
  }
}
