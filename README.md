# offline-repo-stack

Ansible-deployed offline repository mirror stack using Sonatype Nexus behind Nginx with hostname-based TLS routing. Includes a TFTP server for PXE/firmware delivery.

## Architecture

```
                          ┌──────────────────────────────────────────┐
                          │             Host Machine                 │
                          │                                          │
  Clients                 │  ┌───────────┐    ┌───────────┐         │
  ───────────────────────►│  │   Nginx   │───►│   Nexus   │         │
  ubuntu.neutron.internal │  │  :443/80  │    │  :8081    │         │
  docker.neutron.internal │  │           │───►│  :8082    │         │
  pypi.neutron.internal   │  │  TLS term │    │ (docker)  │         │
  npm.neutron.internal    │  └───────────┘    └───────────┘         │
  raw.neutron.internal    │       │                 │               │
                          │  /mnt/nginx        /mnt/nexus           │
                          │  (certs VHD)       (data VHD)           │
                          │                                          │
  ───────────────────────►│  ┌───────────┐                          │
  tftp://host:69          │  │   TFTP    │                          │
                          │  │   :69/udp │                          │
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
- Externally-minted TLS certificate (wildcard `*.neutron.internal` recommended)
- Three virtual hard disks mounted at `/mnt/nexus`, `/mnt/nginx`, `/mnt/tftp`
- DNS or `/etc/hosts` entries pointing `*.neutron.internal` to the host IP

## Configuration

All settings live in [vars.yaml](vars.yaml):

| Section | Purpose |
|---------|---------|
| `images` | Container image references (pin versions here) |
| `domain_suffix` | Base domain for all service hostnames |
| `nexus` | Admin password, JVM tuning, internal ports |
| `ports` | Host-exposed ports for HTTPS, HTTP, TFTP |
| `paths` | Install prefix (`/opt/...`) and VHD mount points (`/mnt/...`) |
| `tls` | Certificate filenames and cipher config |
| `repositories` | Data-driven list -- each entry generates a Nexus repo + Nginx vhost |

## Installation

```bash
# 1. Edit vars.yaml to match your environment
vi vars.yaml

# 2. Run the installer (localhost)
ansible-playbook install.yml -i "localhost," -c local

# 3. Or target a remote host
ansible-playbook install.yml -i inventory.ini

# 4. Place TLS certificates on the nginx VHD
cp server.crt server.key /mnt/nginx/certs/

# 5. Start the stack
cd /opt/offline-repo-stack
docker compose up -d
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
├── nexus/          # VHD: Nexus persistent data (blob store, DB, etc.)
├── nginx/
│   └── certs/      # VHD: TLS certificates (server.crt, server.key)
└── tftp/           # VHD: TFTP-served files (PXE images, firmware)
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
