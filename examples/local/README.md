# Local example

Applies circuit-freeipa to two throwaway Rocky Linux 10 containers with systemd: a FreeIPA server, `ipa.example.test`, and a client enrolled with it, `client1.example.test`. You need Conn3x and Podman, and about 3 GB of memory free for the server.

FreeIPA runs a directory server, a Kerberos KDC and a certificate authority under systemd, so the containers run privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The server's install takes ten minutes or so. The second plan says `No changes.` To try it, add a user on the server and look it up on the client:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  'echo example-admin-change-me | kinit admin && ipa user-add testuser --first Test --last User'
ssh -p 2223 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 id testuser
```

The example's passwords are defaults in `main.tf`, which is fine for a container you'll delete. Anywhere else, pass them at run time with `TF_VAR_admin_password` and `TF_VAR_ds_password`.

`up.sh` puts the server on `127.0.0.1:2222` and the client on `127.0.0.1:2223`, and writes the containers' own addresses to `ips.auto.tfvars`. Set `PORT` to use another pair of ports, and pass the first to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro for both, such as one of the images in Conn3x's `test/images`, which CI uses, or `CLIENT_CONTAINERFILE` for the client alone. The server needs a Rocky Linux or Fedora image.

`./down.sh` removes the containers, their volumes, the key and the state.
