# circuit-freeipa

A Conn3x circuit that installs a FreeIPA server and enrols hosts as its clients, so your users, groups, sudo rules and host keys live in one place and every machine asks it who someone is. One `ipa user-add` and the new person can log in everywhere, with a Kerberos ticket instead of a password typed at every box.

FreeIPA is particular about names. Every host needs a fully qualified name that resolves to its own address, not to loopback, and cloud images tend to get that wrong out of the box. The circuit sets each host's name, writes the matching lines in `/etc/hosts`, stops cloud-init putting them back at boot, and then runs the installers unattended. The admin and Directory Manager passwords reach the hosts without ever landing in the plan, the state, or a command line someone could read in `ps`.

## Usage

```hcl
module "freeipa" {
  source = "github.com/conn3xorg/circuit-freeipa?ref=v0.1.0"

  server = { ipa = "203.0.113.10" }
  clients = {
    web1 = "203.0.113.11"
    web2 = "203.0.113.12"
  }

  domain         = "ipa.example.com"
  admin_password = var.admin_password
  ds_password    = var.ds_password

  ssh_private_key_file = "~/.ssh/id_ed25519"
}

variable "admin_password" {
  type      = string
  ephemeral = true
}

variable "ds_password" {
  type      = string
  ephemeral = true
}
```

Then run `conn3x init` and `conn3x apply` with the passwords in `TF_VAR_admin_password` and `TF_VAR_ds_password`. Pass them on every plan as well: Conn3x compares a keyed hash of each password file with what's on the host. A second `conn3x plan` says `No changes.`

The hosts above get the names `ipa.ipa.example.com`, `web1.ipa.example.com` and `web2.ipa.example.com`, and the realm is `IPA.EXAMPLE.COM`. To pick a name yourself, use a host object with `hostname`. The installer takes about ten minutes on a 2 vCPU host, most of it setting up the certificate authority.

Once it's done, log in to the server and try it:

```sh
kinit admin
ipa user-add alice --first Alice --last Smith --password
```

On any client, `id alice` now answers, and `alice` can log in over SSH. The web UI is at `https://ipa.ipa.example.com/`, from a machine that can resolve that name.

For hosts created in the same plan, pass host objects with the host key you generated and the distribution in `os`, as in [circuit-fail2ban](https://github.com/conn3xorg/circuit-fail2ban#usage). Without `os`, Conn3x can't pick the package names for a host that doesn't exist yet.

### Enrolling with one-time passwords

By default, clients enrol as `admin` with `admin_password`. That password then sits in a root-only file on every client, because Conn3x needs the file to stay put to keep the plan clean. On anything but a lab, enrol with something weaker:

- A dedicated user with only FreeIPA's `Host Enrollment` privilege, through `enroll_principal` and `enroll_password`.
- One-time passwords. Add each host on the server first with `ipa host-add web1.ipa.example.com --random`, and pass what it prints:

  ```hcl
  client_otps = var.client_otps   # an ephemeral map(string), such as { web1 = "Xy3..." }
  ```

  A one-time password is spent as soon as the host joins, so the copy left behind is useless.

### Integrated DNS

Set `setup_dns = true` to run BIND on the server with a zone for `domain` and its reverse zone. It forwards other names to `dns_forwarders`, or to the servers in the server's `/etc/resolv.conf` when that's empty. Clients still find the server through `/etc/hosts` unless you point their resolvers at it. This was not part of the tests below.

### With DNS you already run

When your DNS already has forward and reverse records for every host, set `manage_hosts_file = false`. The circuit then leaves the names, `/etc/hosts` and cloud-init alone, and the installers check DNS themselves.

## What it does

On the server:

1. Writes `/etc/cloud/cloud.cfg.d/99-conn3x-freeipa.cfg`, which tells cloud-init to keep the host's name and `/etc/hosts` as they are. Sets the host's name to its fully qualified name, removes lines in `/etc/hosts` that map that name to loopback, and maps it to the host's address. Skipped with `manage_hosts_file = false`.
2. Installs `ipa-server` on Rocky Linux, AlmaLinux, RHEL and CentOS Stream, or `freeipa-server` on Fedora, plus the `-dns` package with `setup_dns`.
3. Writes the admin and Directory Manager passwords to files in `/etc/conn3x-freeipa`, a directory only root can read.
4. Runs `ipa-server-install --unattended` with the realm, domain and name, unless the installer's own record in `/var/lib/ipa/sysrestore/sysrestore.state` says a previous install finished. It doesn't run again after that, even if you change the inputs.
5. Checks `ipa.service` is running and starts at boot.

On each client, after the server is up:

1. The same name and `/etc/hosts` steps, plus a line mapping the server's name to its address.
2. Installs `ipa-client`, or `freeipa-client` on Fedora, Debian and Ubuntu.
3. Writes the enrolment password, or the client's one-time password, to `/etc/conn3x-freeipa/enroll`.
4. Runs `ipa-client-install --unattended` against the server, with `--mkhomedir` unless you turn `mkhomedir` off, unless the client's own install record says it's enrolled.
5. Checks SSSD is running and starts at boot.

The address a name maps to is the host object's `ip`, or else the source address of the host's default IPv4 route. Before anything runs, the `conn3x_host` data source reads each host's distribution, memory and address, and the plan stops with a clear message when the server runs Debian or Ubuntu, has less than about 2 GB of memory, or a host has no address to map its name to.

### Keeping passwords off the command line

`ipa-server-install` and `ipa-client-install` take passwords only as arguments, and arguments are visible to every user on the host while the installer runs. So the circuit doesn't call them by name. It starts Python, reads the passwords from the root-only files, and calls the same entry point the `ipa-*-install` scripts call. The installers' logs leave the passwords out.

### Firewall

FreeIPA needs these open on the server, which this circuit leaves to you or to [circuit-firewall](https://github.com/conn3xorg/circuit-firewall). On firewalld, the `freeipa-4` service covers all but DNS.

| Port | Protocol | For |
| --- | --- | --- |
| 80, 443 | TCP | Web UI, API and certificate status |
| 389, 636 | TCP | LDAP and LDAPS |
| 88, 464 | TCP and UDP | Kerberos and password changes |
| 53 | TCP and UDP | DNS, with `setup_dns` |
| 123 | UDP | NTP, when clients take time from the server |

### What it doesn't do

- No replicas. `server` takes one host. A second server joins with `ipa-replica-install`, which this circuit doesn't run.
- No Debian or Ubuntu server. FreeIPA's server isn't packaged for either; their clients are covered.
- No users, groups, policies or one-time passwords. Use `ipa` on the server, or the web UI.
- It doesn't reconfigure an installed server or enrolled client. Changing `domain`, `realm` or the options afterwards does nothing to it; that takes an uninstall and a fresh install. Changing a password variable rewrites its file and nothing else, so change the password in FreeIPA too.
- The password files stay on the hosts, readable by root only. Removing the module leaves FreeIPA installed, the clients enrolled and the files where they are.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `server` | any | Required | The server, as a map of one name to an address, such as `{ ipa = "203.0.113.10" }`, or to a host object. A host object can set `address`, `host_key`, `user`, `port`, `private_key_file`, `jump_hosts`, `os`, `hostname` (its fully qualified name) and `ip` (the address its name maps to). |
| `clients` | any | `{}` | Hosts to enrol, by name, in the same form as `server`. |
| `domain` | string | Required | DNS domain of the deployment, such as `ipa.example.com`. Hosts are named `<name>.<domain>` unless they set `hostname`. |
| `realm` | string | `null` | Kerberos realm. When null, `domain` in upper case. |
| `admin_password` | string, ephemeral | Required | Password of FreeIPA's `admin` user, 8 characters or more. |
| `ds_password` | string, ephemeral | Required | Password of the LDAP Directory Manager, 8 characters or more. |
| `enroll_principal` | string | `"admin"` | User clients enrol as. |
| `enroll_password` | string, ephemeral | `null` | Password of `enroll_principal`. When null, `admin_password`. |
| `client_otps` | map(string), ephemeral | `{}` | One-time passwords by client name. A client listed here enrols with its own. |
| `setup_dns` | bool | `false` | Run FreeIPA's integrated DNS on the server. |
| `dns_forwarders` | list(string) | `[]` | Upstream DNS servers for the integrated DNS. When empty, the server's `/etc/resolv.conf`. |
| `manage_hosts_file` | bool | `true` | Set each host's name and the `/etc/hosts` lines FreeIPA needs. |
| `mkhomedir` | bool | `true` | Create a home directory when a user first logs in to a client. |
| `server_options` | list(string) | `[]` | Extra arguments to `ipa-server-install`, such as `["--setup-kra"]`. No passwords. |
| `client_options` | list(string) | `[]` | Extra arguments to `ipa-client-install`. No passwords. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |

## Outputs

| Name | Description |
| --- | --- |
| `realm` | Kerberos realm, such as `IPA.EXAMPLE.COM`. |
| `domain` | DNS domain of the deployment. |
| `server_hostname` | Fully qualified name of the server. |
| `hostnames` | Fully qualified name of every host, by name. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, with a package mirror the host can reach. The server needs Rocky Linux 10, AlmaLinux, RHEL, CentOS Stream or Fedora, and 2 GB of memory or more; 4 GB is more comfortable. Clients need to reach the server on the ports above. FreeIPA comes from each distribution's own repositories, so its version is the one your distribution ships.

## Tested on

Rocky Linux 10 and Fedora 45 as the server; Rocky Linux 10, Fedora 44 and 45, Debian 13 and Ubuntu 24.04 as clients. CI applies [examples/local](examples/local) on amd64 to four pairs of containers: a Rocky Linux 10 server with a Rocky Linux 10, Ubuntu 24.04 or Debian 13 client, and a Fedora 45 server with a Fedora 45 client. It checks that the second plan has no changes, adds a user on the server with `kinit admin` and `ipa user-add`, and checks that `id` and `getent passwd` find the user on the client through SSSD. The same pairs passed the same checks by hand in rootful Podman on arm64.

On DigitalOcean, a Rocky Linux 10 server with 2 vCPUs, 4 GB of memory and SELinux enforcing enrolled a Fedora 44 client and an Ubuntu 24.04 client, all three named by the circuit and reaching each other on public addresses. The server's install took about eleven minutes. `kinit admin` and `ipa user-add` worked on the server, `id` and `getent passwd` found the user on both clients, and the second plan had no changes. After a reboot of all three, FreeIPA came back on its own, the names and `/etc/hosts` lines held, and the plan stayed clean. The Ubuntu client was then unenrolled and joined again with a one-time password from `ipa host-add --password`, and the plan stayed clean after that too. Neither password showed up in the installers' logs.

Integrated DNS (`setup_dns`), RHEL, AlmaLinux and CentOS Stream haven't been tried.

## License

MPL-2.0. See [LICENSE](LICENSE). FreeIPA itself is GPL-3.0.
