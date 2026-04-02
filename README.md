# offline-repo-stack

Ansible-deployed offline repository mirror stack using Sonatype Nexus behind Nginx with hostname-based TLS routing. Includes a TFTP server for PXE/firmware delivery. All containers run as dedicated service accounts.

## Architecture

```
                          ┌──────────────────────────────────────────┐
                          │             Host Machine                 │
                          │                                          │
  Clients                 │  ┌───────────┐    ┌───────────┐         │
  ───────────────────────►│  │   Nginx   │───►│   Nexus   │         │
  ubuntu.neutron.internal │  │  :443/80  │    │  :8081    │         │
  docker.neutron.internal │  │ svc_nginx │───►│ svc_nexus │         │
  pypi.neutron.internal   │  │  TLS term │    │  :8082    │         │
  npm.neutron.internal    │  └───────────┘    └───────────┘         │
  raw.neutron.internal    │       │                 │               │
                          │  /mnt/nginx        /mnt/nexus           │
                          │  (certs VHD)       (data VHD)           │
                          │                                          │
  ───────────────────────►│  ┌───────────┐                          │
  tftp://host:69          │  │   TFTP    │                          │
                          │  │ svc_tftp  │                          │
                          │  │  :69/udp  │                          │
                          │  └───────────┘                          │
                          │       │                                  │
                          │  /mnt/tftp                               │
                          │  (files VHD)                             │
                          └──────────────────────────────────────────┘

Config installed to: /opt/offline-repo-stack/
Data on VHDs:        /mnt/nexus, /mnt/nginx, /mnt/tftp
```

## Prerequisites

- Ansible 2.14+ on the control node
- Docker Engine 24+ and Docker Compose v2 on the target host
- Three virtual hard disks mounted at `/mnt/nexus`, `/mnt/nginx`, `/mnt/tftp`
- DNS or `/etc/hosts` entries pointing `*.neutron.internal` to the host IP
- TLS: either use `tls.self_signed: true` (default) or provide external certs

## Configuration

All settings live in [vars.yaml](vars.yaml):

| Section | Purpose |
|---------|---------|
| `images` | Container image references (pin versions here) |
| `domain_suffix` | Base domain for all service hostnames |
| `nexus` | Admin password, JVM tuning, internal ports |
| `ports` | Host-exposed ports for HTTPS, HTTP, TFTP |
| `paths` | Install prefix (`/opt/...`) and VHD mount points (`/mnt/...`) |
| `service_accounts` | Per-service system user/group with UID/GID |
| `tls` | Self-signed toggle, cert paths, cipher config |
| `repositories` | Data-driven list -- each entry generates a Nexus repo + Nginx vhost |

### TLS Certificates

Certificate paths are explicit in `vars.yaml`:

```yaml
tls:
  self_signed: true            # false for production
  cert_dir: /mnt/nginx/certs   # host directory mounted into nginx
  cert_file: server.crt
  key_file: server.key
  cert_path: /mnt/nginx/certs/server.crt   # full path to cert
  key_path: /mnt/nginx/certs/server.key    # full path to key
```

When `self_signed: true`, the installer generates a wildcard `*.neutron.internal` cert
via openssl and places it at `cert_path`/`key_path`. When `false`, you must place
externally-minted certs there before starting the stack.

### Service Accounts

Each container runs as a dedicated non-root system user:

| Service | Account | UID | GID | Owns |
|---------|---------|-----|-----|------|
| Nexus | `svc_nexus` | 2001 | 2001 | `/mnt/nexus` |
| Nginx | `svc_nginx` | 2002 | 2002 | `/mnt/nginx` |
| TFTP | `svc_tftp` | 2003 | 2003 | `/mnt/tftp` |

Nginx listens on unprivileged ports (8080/8443) inside the container; Docker maps
host ports 80/443 to those. UIDs/GIDs are configurable in `vars.yaml`.

## Installation

```bash
# 1. Edit vars.yaml to match your environment
vi vars.yaml

# 2. Run the installer (localhost)
ansible-playbook install.yml -i "localhost," -c local

# 3. Or target a remote host
ansible-playbook install.yml -i inventory.ini

# 4. If self_signed is false, place external certs
cp server.crt server.key /mnt/nginx/certs/
chown svc_nginx:svc_nginx /mnt/nginx/certs/*

# 5. Start the stack
cd /opt/offline-repo-stack
docker compose up -d
```

## Uninstall

Tears down containers, removes config from `/opt`, deletes service accounts,
and removes self-signed certs. VHD data under `/mnt/` is preserved (delete manually).

```bash
ansible-playbook install.yml -e uninstall=true -i "localhost," -c local
```

## Installed Layout

```
/opt/offline-repo-stack/
├── docker-compose.yml
├── nginx/
│   ├── nginx.conf
│   ├── ssl-params.conf
│   └── conf.d/
│       ├── default.conf
│       ├── ubuntu.conf          # ← generated from repositories list
│       ├── docker.conf
│       ├── pypi.conf
│       ├── npm.conf
│       └── raw.conf
└── nexus/
    ├── provision.py
    └── repos/
        ├── apt-ubuntu.json      # ← generated from repositories list
        ├── docker-hosted.json
        ├── pypi-hosted.json
        ├── npm-hosted.json
        └── raw-hosted.json

/mnt/
├── nexus/          # VHD: Nexus persistent data  (owned by svc_nexus)
├── nginx/
│   └── certs/      # VHD: TLS certificates        (owned by svc_nginx)
└── tftp/           # VHD: TFTP-served files        (owned by svc_tftp)
```

## Adding a New Repository

Add an entry to the `repositories` list in `vars.yaml` and re-run the playbook. Both the Nginx vhost and Nexus repo JSON are generated automatically.

```yaml
repositories:
  # ... existing entries ...
  - name: yum-centos
    hostname: yum
    format: yum
    nexus_port: 8081
    nexus_path: "/repository/yum-centos/"
    api_endpoint: "/service/rest/v1/repositories/yum/hosted"
    body:
      name: yum-centos
      online: true
      storage:
        blobStoreName: default
        strictContentTypeValidation: true
        writePolicy: ALLOW
      yum:
        repodataDepth: 0
        deployPolicy: STRICT
```

Then:
```bash
ansible-playbook install.yml -i "localhost," -c local
docker compose -f /opt/offline-repo-stack/docker-compose.yml up nexus-provision
```

## Client Configuration

### APT
```bash
deb https://ubuntu.neutron.internal jammy main
```

### Docker
```bash
docker pull docker.neutron.internal/myimage:latest
```

### pip
```bash
pip install --index-url https://pypi.neutron.internal/simple/ package-name
```

### npm
```bash
npm config set registry https://npm.neutron.internal/
```

## TFTP

Place files directly in `/mnt/tftp/` -- they are served immediately on UDP/69 with no restart required.
