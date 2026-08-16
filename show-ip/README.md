# 🌐 show-ip

One clear picture of a Docker host's IPv4 layout: host NICs, Docker networks, and every container's IPs and ports — **including IPVLAN/MACVLAN containers, whose ports `docker ps` never shows**.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║       IPv4 ADDRESS LIST   ·   HOST NICs · DOCKER NETWORKS · CONTAINERS       ║
╟──────────────────────────────────────────────────────────────────────────────╢
║ HOST    ubuntu-srv-21                  OS      Ubuntu 24.04.3 LTS x86_64     ║
║ KERNEL  6.8.0-137-generic              UPTIME  12 days, 4 hours              ║
║ DOCKER  27.3.1                         LOAD    0.15 0.10 0.09  (8 cpu)       ║
║ TIME    2026-08-16 12:34:53 PDT        MEMORY  12.4G used / 31.3G            ║
╚══════════════════════════════════════════════════════════════════════════════╝

▌ HOST NICs
┌──────┬─────────┬─────────────────┬───────────────────┬───────┬────────────┬────────┬─────────────────────────────────────────────┐
│ NIC  │ STATE   │ IPv4 / CIDR     │ MAC ADDRESS       │ MTU   │ DRIVER     │ SPEED  │ ROLE                                        │
├──────┼─────────┼─────────────────┼───────────────────┼───────┼────────────┼────────┼─────────────────────────────────────────────┤
│ eth0 │ up      │ 10.70.21.254/16 │ 2a:02:02:70:20:21 │ 1500  │ virtio_net │ -      │ -                                           │
│ eth1 │ up      │ 10.71.21.254/16 │ 1a:02:02:71:20:21 │ 1500  │ iavf       │ 25Gb/s │ parent of docker-ipv-services-21(ipvlan/l2) │
└──────┴─────────┴─────────────────┴───────────────────┴───────┴────────────┴────────┴─────────────────────────────────────────────┘

▌ DOCKER NETWORKS
┌────────────────────────┬────────┬────────┬─────────────────────┬────────────────┬───────────────┬───────┬────────────┐
│ DOCKER NETWORK         │ DRIVER │ MODE   │ HOST IFACE / PARENT │ SUBNET         │ GATEWAY       │ SCOPE │ CONTAINERS │
├────────────────────────┼────────┼────────┼─────────────────────┼────────────────┼───────────────┼───────┼────────────┤
│ docker-br-mgmt-21      │ bridge │ bridge │ br-8a307bdc2dda     │ 172.20.10.0/24 │ 172.20.10.254 │ local │     1      │
│ docker-ipv-services-21 │ ipvlan │ l2     │ eth1 (parent)       │ 10.71.0.0/16   │ 10.71.0.254   │ local │     3      │
└────────────────────────┴────────┴────────┴─────────────────────┴────────────────┴───────────────┴───────┴────────────┘

▌ DOCKER CONTAINERS — STACKS, NETWORKS, IPs & PORTS
┌──────────────┬─────────────────┬─────────┬────────────────────────┬───────────────┬────────────────┬───────────────┬─────────────────────────┐
│ STACK        │ CONTAINER       │ STATE   │ DOCKER NETWORK         │ DRV/MODE      │ IP ADDRESS     │ GATEWAY       │ PORTS                   │
├──────────────┼─────────────────┼─────────┼────────────────────────┼───────────────┼────────────────┼───────────────┼─────────────────────────┤
│ npm-stack    │ npm-app         │ running │ docker-ipv-services-21 │ ipvlan/l2     │ 10.71.21.20/16 │ 10.71.0.254   │ ⇢ 10.71.21.20:80/tcp    │
│              │                 │         │                        │               │                │               │ ⇢ 10.71.21.20:443/tcp   │
│              │ npm-db          │ running │ npm-stack_default      │ bridge/bridge │ 172.22.0.2/16  │ 172.22.0.1    │ ⇢ 172.22.0.2:3306/tcp   │
├──────────────┼─────────────────┼─────────┼────────────────────────┼───────────────┼────────────────┼───────────────┼─────────────────────────┤
│ (standalone) │ dockge-21       │ running │ docker-br-mgmt-21      │ bridge/bridge │ 172.20.10.1/24 │ 172.20.10.254 │ *:5001 → 5001/tcp       │
│              │ plex-21         │ running │ docker-ipv-services-21 │ ipvlan/l2     │ 10.71.21.10/16 │ 10.71.0.254   │ ⇢ 10.71.21.10:32400/tcp │
└──────────────┴─────────────────┴─────────┴────────────────────────┴───────────────┴────────────────┴───────────────┴─────────────────────────┘
   legend:  → published host:port to container port    ⇢ socket listening inside the container netns

   4 host NICs  ·  6 docker networks  ·  1 stack  ·  4/4 containers running
```

## 💡 Why

`docker ps` only knows about **published** ports. Containers on an **IPVLAN or MACVLAN** network are never `-p` published — they hold a real address on your LAN — so their ports show up blank. `show-ip` enters each container's network namespace and reports the sockets actually listening, mapped to the IP they answer on.

## ✨ What it shows

- **Host NICs** — IPv4/CIDR, MAC, MTU, link state, driver, speed, and which Docker ipvlan/macvlan networks use the NIC as their parent.
- **Docker networks** — driver, mode (`ipvlan l2`/`l3`, `macvlan`, `bridge`, `overlay`), host interface or parent NIC, subnet(s), gateway, live container count.
- **Containers grouped by stack** — Compose project or Swarm namespace, one table row per stack, expanding to fit its containers.
- **One block per bind IP** — a container on two networks gets a block per network, each listing only the ports reachable on that IP.
- **Real ports** — published NAT mappings *and* in-namespace listening sockets, deduplicated.

## 📦 Installation

### 📜 Get the script

```bash
curl -fsSL https://raw.githubusercontent.com/jagmeets1ngh/linux/main/show-ip/show-ip -o ~/show-ip
```

<details>
<summary>No curl? Paste it manually</summary>

```bash
nano ~/show-ip
```

Paste the script, then save and exit.
</details>

### ⚙️ Install

```bash
chmod +x ~/show-ip
sudo ~/show-ip --install
```

Installs to:

```text
/usr/local/bin/show-ip
```

## 🚀 Usage

```bash
sudo show-ip
```

> [!IMPORTANT]
> Run with `sudo` for full container namespace and IPVLAN port information. Without root, the ports column shows `(need root)`.

### Options

| Option | Description |
|---|---|
| `-a, --all` | include stopped containers |
| `-v, --veth` | also list veth*/virtual leaf interfaces |
| `-P, --no-ports` | skip the in-namespace port scan (faster) |
| `-M, --no-mac` | drop the container MAC column |
| `-L, --loopback` | also show 127.0.0.1-bound sockets (hidden by default) |
| `-H, --host-only` | host NIC table only |
| `-N, --net-only` | Docker network table only |
| `-C, --containers` | container table only |
| `-w, --watch [SEC]` | refresh every SEC seconds (default 5) |
| `-n, --no-color` | disable colour (also honours `NO_COLOR`) |
| `-A, --ascii` | ASCII borders instead of box-drawing glyphs |
| `--skip-deps` | don't auto-install iproute2; run degraded instead of aborting |
| `--install` | copy the script to `/usr/local/bin/show-ip` |
| `-h, --help` | show help |
| `-V, --version` | show version |

## 📋 Requirements

| | |
|---|---|
| Bash | 4.3 or newer |
| `iproute2` (`ip`, `ss`) | **required** — auto-installed via apt/dnf/yum/zypper/pacman/apk |
| `util-linux` (`nsenter`) | optional — without it, container listening ports can't be read |
| Docker | optional — the host NIC table works without it |

> [!NOTE]
> On first run, if `iproute2` is missing, `show-ip` installs it, verifies the binaries actually landed, and **aborts** rather than printing an incomplete picture. Use `--skip-deps` to run degraded instead.

## 🔍 Verify

```bash
command -v show-ip
show-ip --version
show-ip --help
```

Expected:

```text
/usr/local/bin/show-ip
show-ip 3.1
```

## 🔄 Update

```bash
curl -fsSL https://raw.githubusercontent.com/jagmeets1ngh/linux/main/show-ip/show-ip -o ~/show-ip
sudo ~/show-ip --install
```

## 🗑️ Uninstall

```bash
sudo rm /usr/local/bin/show-ip
```

## 🏠 User-local Install

If you don't want a system-wide installation:

```bash
mkdir -p ~/.local/bin
cp ~/show-ip ~/.local/bin/
chmod +x ~/.local/bin/show-ip
```

Add it to your `PATH` if needed:

```bash
grep -q '.local/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

> [!NOTE]
> A user-local install still needs `sudo show-ip` for container ports, and `sudo` doesn't search `~/.local/bin` by default — use `sudo ~/.local/bin/show-ip`.

## 📖 Reading the output

- `→` is a published host→container mapping; `⇢` is a socket listening inside the container's namespace.
- A socket bound to `0.0.0.0` appears under **every** network the container is attached to, because it genuinely answers on all of them. A socket bound to one specific IP appears only under that network.
- Loopback-bound sockets are hidden by default (unreachable from outside the container); the count of suppressed entries is reported, and `-L` shows them.

## 📄 License

MIT
