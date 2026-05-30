# Drive-NMonit — Unified Network Distributed Storage

A hybrid storage system that pools all local drives into a single mount point using **mergerfs**, then aggregates storage across network nodes using **GlusterFS** — creating one unified, distributed workspace accessible from every node.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  NETWORK LAYER                       │
│         GlusterFS Distributed Volume                 │
│            Mounted: /mnt/workspace                   │
└─────────────────────────────────────────────────────┘
         ▲                    ▲                    ▲
         │                    │                    │
┌────────┴────────┐  ┌───────┴────────┐  ┌───────┴────────┐
│   NODE (Host)   │  │  NODE (Slave)  │  │  NODE (Slave)  │
├─────────────────┤  ├────────────────┤  ├────────────────┤
│ /mnt/local-pool  │  │ /mnt/local-pool│  │ /mnt/local-pool│
│   (mergerfs)     │  │   (mergerfs)   │  │   (mergerfs)   │
│    ↕  ↕  ↕       │  │    ↕  ↕        │  │    ↕           │
│  sda  sdb  sdc   │  │  sda  sdb      │  │  sda           │
└─────────────────┘  └────────────────┘  └────────────────┘
```

### Layer 1 — Local Pooling (mergerfs)

Each node pools all its local drives via **mergerfs** into `/mnt/local-pool`. This includes:
- Internal HDDs/SSDs
- External USB drives
- Any block device with a filesystem

mergerfs is a union filesystem — it presents multiple underlying filesystems as one, preserving the individual filesystems so data is never at risk if the pool software fails.

### Layer 2 — Network Distribution (GlusterFS)

Each node contributes its `/mnt/local-pool` as a **GlusterFS brick**. A **distributed volume** spans all nodes, mounted at `/mnt/workspace` on every machine. This gives every node visibility into the combined storage of the entire cluster.

## Requirements

### Per-Node Hardware
- Ubuntu 20.04+ / Debian 11+ / any systemd Linux distro
- One or more storage drives (any combination of internal/external/USB)
- Network connectivity to all other nodes (Gigabit Ethernet or better recommended)

### Network
- All nodes must be able to reach each other on TCP ports:
  - **24007** — GlusterFS daemon
  - **24008** — GlusterFS management
  - **49152–49251** — GlusterFS brick ports (one per brick)
- Static IP addresses or hostname resolution (see `templates/hosts.template`)

## Quick Start

### Step 1: Choose a Primary Node

Designate one machine as the **primary** (cluster initiator). All other nodes are **slaves**.

### Step 2: Copy the Project to All Nodes

```bash
# On each node, clone or copy this project
```

### Step 3: Install Dependencies

```bash
# Run on ALL nodes (primary + slaves)
sudo ./scripts/install-deps.sh
```

This installs:
- **mergerfs** — local drive pooling
- **glusterfs-server** — GlusterFS distributed filesystem
- Additional utilities (`jq`, `pv`, etc.)

### Step 4: Set Up Local Drive Pooling

```bash
# Run on ALL nodes
sudo ./scripts/setup-mergerfs.sh
```

This script:
1. Detects all non-system block devices with filesystems
2. Creates mount points under `/mnt/drives/`
3. Mounts each drive
4. Pools them into `/mnt/local-pool` via mergerfs

### Step 5: Initialize the GlusterFS Cluster (Primary Node Only)

```bash
# Run ONLY on the primary node
sudo ./scripts/setup-glusterfs.sh --init
```

This script will prompt you for the IP addresses/hostnames of all slave nodes.

### Step 6: Join Slave Nodes to the Cluster

```bash
# Run on EACH slave node
sudo ./scripts/setup-glusterfs.sh --join <primary-ip>
```

### Step 7: Mount the Distributed Volume

```bash
# Run on ALL nodes
sudo ./scripts/mount-all.sh
```

The unified workspace is now available at **`/mnt/workspace`** on every node!

## Management CLI (`drive-nmonit-cli`)

The project includes a comprehensive interactive CLI wrapper that orchestrates all scripts through an intuitive menu-driven interface.

### Quick Start

```bash
# Interactive menu mode (auto-detects system state on launch)
sudo ./drive-nmonit-cli

# Direct command mode (non-interactive, useful for automation)
sudo ./drive-nmonit-cli status         # Quick cluster status overview
sudo ./drive-nmonit-cli health --json   # Health check in JSON format
sudo ./drive-nmonit-cli health --watch  # Live-updating health dashboard (5s interval)
sudo ./drive-nmonit-cli install         # Install dependencies
```

### Features

- **Interactive menu** — Color-coded TUI with status dashboard on every launch, sub-menus for complex workflows (GlusterFS cluster ops, network shares, node management)
- **State detection** — Automatically detects installed services, mount states, volume status, peer count, managed drives, and dashboard status on startup — all shown in the welcome dashboard
- **Non-interactive CLI mode** — All operations available as direct commands for scripting and automation
- **Quick status dashboard** — Services, mounts, GlusterFS volume, local drives, and web dashboard status at a glance with color-coded health indicators
- **Node management** — Add/remove nodes, probe peers, manage bricks — all from an interactive sub-menu (primary node only)
- **Log viewer** — Browse mergerfs, GlusterFS, workspace mount, health check, and dashboard logs from a single menu
- **First-run welcome** — On initial launch, displays a 5-step quick-start guide
- **Clean exit** — Trap handling restores cursor visibility on Ctrl+C

### Available Commands

| Command | Description | Requires Root |
|---------|-------------|:-------------:|
| `status` | Display cluster status overview (see sub-flags below) | No |
| &nbsp;&nbsp;`--json` | Machine-readable JSON status output | No |
| `health` | Run health check (see sub-flags below) | Yes |
| &nbsp;&nbsp;`--json` | Machine-readable JSON health output | Yes |
| &nbsp;&nbsp;`--watch` | Live-updating health dashboard (5s refresh) | Yes |
| &nbsp;&nbsp;`--nagios` | Nagios/Icinga compatible output | Yes |
| &nbsp;&nbsp;`--quiet` | Only output warnings and errors | Yes |
| &nbsp;&nbsp;`--send-alert` | Send alert notifications on issues | Yes |
| `install` | Install all dependencies | Yes |
| `setup-mergerfs` | Set up local drive pooling | Yes |
| `setup-gluster` | Set up GlusterFS cluster (see sub-flags below) | Yes |
| &nbsp;&nbsp;`--init` | Initialize cluster as primary node | Yes |
| &nbsp;&nbsp;`--join` | Join cluster as slave node | Yes |
| `mount` | Mount GlusterFS workspace volume | Yes |
| `tune` | Performance tuning (profile selection) | Yes |
| `samba` | Samba/CIFS share setup | Yes |
| `nfs` | NFS export setup | Yes |
| `dashboard` | Start/stop/restart web dashboard | Yes |
| `logs` | View component logs | No |
| `sysinfo` | System information (kernel, CPU, RAM, disks) | No |
| `init-config` | Write an interactive config file to `/etc/drive-nmonit/config` | No |
| `help` | Show usage help | No |

### JSON Status Output

Append `--json` to the `status` command to get a machine-readable JSON representation
of the cluster state suitable for scripting, monitoring, and automation:

```bash
# Full cluster status as JSON
sudo ./drive-nmonit-cli status --json

# Pipe through jq for specific field extraction
sudo ./drive-nmonit-cli status --json | jq '.overall_status'

# Check if a specific service is installed
sudo ./drive-nmonit-cli status --json | jq '.services.mergerfs'
```

**Example output (pretty-printed via `jq`):**
```json
{
  "version": "1.0.0",
  "hostname": "node1",
  "services": {
    "mergerfs": true,
    "glusterfs_daemon": true,
    "glusterfs_cli": true,
    "samba": false,
    "nfs": false,
    "jq": true
  },
  "mounts": {
    "pool": {
      "path": "/mnt/local-pool",
      "mounted": true
    },
    "workspace": {
      "path": "/mnt/workspace",
      "mounted": true,
      "usage": "10G/100G (10%)"
    }
  },
  "glusterfs": {
    "volume_name": "workspace",
    "volume_exists": true,
    "volume_running": true,
    "volume_type": "Distribute",
    "volume_status": "Started",
    "peers": 2,
    "is_primary": true,
    "role": "primary"
  },
  "drives": {
    "count": 3,
    "details": [
      {
        "label": "disk1",
        "mounted": true,
        "usage": "5G/20G (25%)"
      },
      {
        "label": "disk2",
        "mounted": true,
        "usage": "8G/20G (40%)"
      }
    ]
  },
  "dashboard": {
    "running": false,
    "url": ""
  },
  "overall_status": "healthy"
}
```

**JSON fields:**

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | CLI version |
| `hostname` | string | Node hostname |
| `services` | object | Per-service boolean status (`mergerfs`, `glusterfs_daemon`, `glusterfs_cli`, `samba`, `nfs`, `jq`) |
| `mounts.pool.mounted` | boolean | Whether `/mnt/local-pool` is mounted |
| `mounts.workspace.mounted` | boolean | Whether `/mnt/workspace` is mounted |
| `mounts.workspace.usage` | string | Disk usage (e.g. `"10G/100G (10%)"`), empty if unmounted |
| `glusterfs.volume_exists` | boolean | Whether the GlusterFS volume is created |
| `glusterfs.volume_running` | boolean | Whether the volume is started |
| `glusterfs.volume_type` | string | Volume type (`Replicate`, `Distribute`, `Disperse`, etc.) |
| `glusterfs.peers` | number | Number of connected peers |
| `glusterfs.is_primary` | boolean | Whether this node is the cluster primary |
| `glusterfs.role` | string | `"primary"` or `"slave"` |
| `drives.count` | number | Number of managed local drives |
| `drives.details[]` | array | Per-drive objects with `label`, `mounted`, and `usage` |
| `dashboard.running` | boolean | Whether the web dashboard is running |
| `dashboard.url` | string | Dashboard URL (empty if not running) |
| `overall_status` | string | `"healthy"`, `"warning"`, or `"critical"` |

All boolean fields use JSON `true`/`false` literals (not quoted strings). The output is automatically
pretty-printed through `jq` when available on the system. If `jq` is not installed, raw JSON is
printed on a single line.

### Dry-Run Mode

Add `--dry-run` before any command to preview what would be executed without making any changes:

```bash
# Preview an installation
sudo ./drive-nmonit-cli --dry-run install

# Preview health check output
sudo ./drive-nmonit-cli --dry-run health --json

# Preview what setup commands would be run
sudo ./drive-nmonit-cli --dry-run setup-mergerfs

# Interactive menu with dry-run banner displayed
sudo ./drive-nmonit-cli --dry-run
```

When `--dry-run` is active:
- All script and command calls are shown prefixed with `[DRY-RUN]` instead of executed
- A prominent banner appears at startup indicating dry-run mode
- Works with both interactive menu mode and direct CLI commands
- Supported wherever the CLI invokes underlying scripts (`install`, `setup-mergerfs`, `setup-gluster`, `mount`, `tune`, `health`, `samba`, `nfs`, `dashboard`)

Use `--no-dry-run` to explicitly disable dry-run mode, overriding a `DRY_RUN=true`
set in the config file:

```bash
# Override DRY_RUN=true from config file for one command
sudo ./drive-nmonit-cli --no-dry-run install

# Combine with --config to temporarily override a custom config
sudo ./drive-nmonit-cli --no-dry-run --config /etc/drive-nmonit/config-prod status
```

### Auto-Confirm Mode

Add `--yes`, `--confirm`, or `-y` before any command to auto-answer all confirmation prompts with their defaults:

```bash
# Install without interactive prompts
sudo ./drive-nmonit-cli --yes install

# Run health check without the "Press Enter" pause
sudo ./drive-nmonit-cli --yes health --json

# Setup mergerfs, auto-answering the "Install now?" prompt with Yes
sudo ./drive-nmonit-cli --yes setup-mergerfs

# Start the dashboard non-interactively
sudo ./drive-nmonit-cli --yes dashboard

# Combine with --dry-run for safe previews
sudo ./drive-nmonit-cli --dry-run --yes install
```

When `--yes` is active:
- All "Press Enter to continue..." pauses are silently skipped
- Yes/no confirmation prompts (e.g., "Install mergerfs now? [Y/n]:") are auto-answered with the default (capital letter)
- A banner appears at startup indicating auto-confirm mode
- Works with both interactive menu mode and direct CLI commands
- Data entry prompts (IP addresses, CIDR, numbers) still require input — in automation, use the direct CLI command form

### Persistent Configuration File

Default flags can be stored persistently in `/etc/drive-nmonit/config` so you don't
have to pass `--dry-run` or `--yes` on every invocation.

**Quick start — interactive:**
```bash
# Interactive prompts to configure settings
sudo ./drive-nmonit-cli init-config

# Or via CLI mode (prompts will still appear unless --yes is also passed)
sudo ./drive-nmonit-cli init-config
```

**Quick start — manual:**
```bash
# Copy the template and edit
sudo cp scripts/config.template /etc/drive-nmonit/config
sudo nano /etc/drive-nmonit/config
```

**Supported settings:**

| Key | Values | Equivalent CLI Flag |
|-----|--------|-------------------|
| `DRY_RUN` | `true` / `false` | `--dry-run` |
| `YES_MODE` | `true` / `false` | `--yes` / `--confirm` / `-y` |

**Precedence (highest wins):**
1. Command-line flags (`--dry-run`, `--yes`)
2. Config file (`/etc/drive-nmonit/config`)
3. Hardcoded defaults (both `false`)

**Using a custom config path:**
```bash
sudo ./drive-nmonit-cli --config /path/to/my-config
sudo ./drive-nmonit-cli --config /path/to/my-config status
```

**Validation:** Invalid values in the config file produce a warning and are
reset to their defaults at startup:

```
⚠ Config: invalid DRY_RUN='yes' in /etc/drive-nmonit/config (expected true/false) — resetting to false
```

Only exact `true` / `false` (lowercase) is accepted. Values like `yes`, `1`,
`TRUE`, or `True` will trigger a warning. Unknown keys are silently ignored.

**Example config file:**
```bash
# /etc/drive-nmonit/config
# Always preview commands in interactive mode:
DRY_RUN=true

# Auto-answer prompts for automation scripts:
YES_MODE=true
```

### Bash Completion

Enable tab completion for `drive-nmonit-cli` to get auto-completion on commands, flags, and options:

```bash
# System-wide install (all users)
sudo cp completions/drive-nmonit-cli.bash /etc/bash_completion.d/

# Or user-level install (current user only)
mkdir -p ~/.local/share/bash-completion/completions
cp completions/drive-nmonit-cli.bash ~/.local/share/bash-completion/completions/drive-nmonit-cli

# Or source it directly in your current session
source completions/drive-nmonit-cli.bash
```

After installing, restart your shell or run `source /etc/bash_completion` (if using `bash-completion`).

**What's completed:**

| Context | Completions |
|---------|-------------|
| First argument | All commands: `status`, `health`, `install`, `setup-mergerfs`, `setup-gluster`, `mount`, `tune`, `samba`, `nfs`, `dashboard`, `logs`, `system-info`, `help` |
| `health` | `--json`, `--nagios`, `--quiet`, `--watch`, `--send-alert` |
| `setup-gluster` | `--init`, `--join` |
| `dashboard --port` | Common port numbers (8080, 8081, 9090, etc.) |
| `dashboard --config` | File path completion |
| `dashboard --nodes` | Hostname completion |
| Command aliases | `info`→`status`, `pool`→`setup-mergerfs`, `web`→`dashboard`, `sysinfo`→`system-info`, etc. |

### Interactive Menu Structure

```
┌─ MAIN MENU ─────────────────────────────────────────────────┐
│  1)  Install Dependencies                                   │
│  2)  Setup Local Pool (mergerfs)                            │
│  3)  GlusterFS Cluster  →  Init Cluster / Join Cluster      │
│  4)  Mount Workspace                                        │
│  5)  Performance Tuning  →  Balanced / Throughput / ...     │
│  6)  Health Check                                           │
│  7)  Network Shares    →  Samba Setup / NFS Export          │
│  8)  Web Dashboard     →  Start / Stop / Restart            │
│  9)  Node Management   →  Add / Remove / Probe             │
│ 10)  View Logs          →  mergerfs / GlusterFS / Health    │
│ 11)  System Info                                            │
│ 12)  Quick Status                                           │
│  q)  Quit                                                   │
└─────────────────────────────────────────────────────────────┘
```

The menu repeats after each action, with the status dashboard refreshed on every iteration.

### `init-config` Command

The `init-config` command in the main menu (option 13) or via CLI (`sudo ./drive-nmonit-cli init-config`)
interactively creates a persistent configuration file at `/etc/drive-nmonit/config`. It:

1. Creates the `/etc/drive-nmonit/` directory if it doesn't exist
2. Checks if a config already exists and asks to overwrite
3. Prompts you to enable **Dry-Run Mode** and **Auto-Confirm Mode** with individual Y/n prompts
4. Shows a preview of what will be written
5. Writes the config file and reloads it immediately so it takes effect
6. Validates the written values and reports any issues

In `--yes` mode, the command writes a config with both options disabled (safe default).

```bash
# Interactive prompts
sudo ./drive-nmonit-cli init-config

# Non-interactive (writes defaults: both false)
sudo ./drive-nmonit-cli --yes init-config

# Preview what would be written without writing
sudo ./drive-nmonit-cli --dry-run init-config
```

## Detailed Script Reference


### `scripts/install-deps.sh`

Installs all required packages. Detects the package manager (apt, yum, dnf, zypper).

| Package | Purpose |
|---------|---------|
| `mergerfs` | Union filesystem for local drive pooling |
| `glusterfs-server` | GlusterFS server daemon and client |
| `glusterfs-client` | GlusterFS FUSE client (for mounting) |
| `fuse3` | Filesystem in Userspace framework |
| `jq` | JSON processor (for drive detection) |

### `scripts/setup-mergerfs.sh`

Detects and pools all local drives.

**What it does:**
1. Scans `/dev/sd*`, `/dev/nvme*`, `/dev/vd*` and other block devices
2. Excludes the system disk (where `/` is mounted) and swap partitions
3. Excludes drives already managed by this script (via a marker file)
4. For each eligible drive:
   - Creates a mount point at `/mnt/drives/<drive-label-or-uuid>`
   - Mounts the drive (uses existing filesystem)
   - Records the mount in `/etc/fstab` (with `nofail` option)
5. Creates the mergerfs pool at `/mnt/local-pool`
6. Installs a **systemd service** (`mergerfs-pool.service`) to ensure the pool is mounted on boot

**Exclusion file:** `/etc/drive-nmonit/excluded-drives` — add drive UUIDs here to exclude them.

### `scripts/setup-glusterfs.sh`

Configures GlusterFS on a node.

**`--init` mode (primary node):**
1. Starts `glusterd` service
2. Probes slave nodes (you provide IPs)
3. Creates a **distributed** GlusterFS volume across all nodes
4. Starts the volume

**`--join` mode (slave nodes):**
1. Starts `glusterd` service
2. The primary node will probe this node

### `scripts/mount-all.sh`

Mounts the GlusterFS distributed volume on the local node.

1. Creates `/mnt/workspace`
2. Mounts the GlusterFS volume via FUSE
3. Adds an entry to `/etc/fstab` for persistence
4. Optionally installs a systemd mount unit

## Volume Types

The setup script creates a **distributed** volume by default. You can customise by editing the volume creation command in `setup-glusterfs.sh`:

| Volume Type | Description | Use Case |
|-------------|-------------|----------|
| **Distributed** | Files spread across bricks. No redundancy. | Maximum capacity, no fault tolerance |
| **Replicated** | Copy of data on each brick. | High availability, reduced capacity |
| **Distributed-Replicated** | Files spread across replica groups. | Balance of capacity and redundancy |
| **Dispersed** | Erasure-coded (like RAID 5/6). | Efficient redundancy |

## Network Share Export

The cluster workspace at `/mnt/workspace` can be exported to other machines on your network via **Samba/CIFS** (Windows/macOS/Linux clients) or **NFS** (Linux/Unix clients). Both export scripts follow the same conventions as the rest of the project.

### Samba/CIFS (`scripts/setup-samba.sh`)

Exposes the workspace as a network share accessible from any OS.

```bash
# Install Samba (or run the script — it installs automatically)
sudo ./scripts/install-deps.sh

# Interactive setup with authentication (default)
sudo ./scripts/setup-samba.sh

# Public guest-access share (no password required)
sudo ./scripts/setup-samba.sh --public

# Remove the share configuration
sudo ./scripts/setup-samba.sh --remove

# Dry-run to preview changes
sudo ./scripts/setup-samba.sh --public --dry-run

# Share a custom directory instead of /mnt/workspace
sudo ./scripts/setup-samba.sh --path /mnt/data
```

**Features:**
- **Two access modes:** `--auth` (Samba user required) or `--public` (guest access)
- **Automatic Samba installation** if not already present
- **Performance tuning** — adds global settings (`SMB2_10` min protocol, `sendfile`, `aio`, socket tuning)
- **Samba user creation** — interactive prompt to create a Samba user with `smbpasswd`
- **Firewall configuration** — opens ports 139, 445, 137, 138 via UFW or firewalld
- **Backup** — existing `smb.conf` is backed up before modification
- **Removal** — cleanly removes only the workspace share section, leaving other shares intact

**Client access (from any OS):**

```bash
# Linux mount
sudo mount -t cifs -o username=<samba-user> //<server-ip>/workspace /mnt/smb-workspace

# macOS Finder
# Go → Connect to Server → smb://<server-ip>/workspace

# Windows
# \\<server-ip>\workspace
```

**Add additional Samba users:**
```bash
sudo smbpasswd -a <username>
```

### NFS (`scripts/setup-nfs.sh`)

Exports the workspace as an NFSv4 share for Linux/Unix clients.

```bash
# Install NFS server (or run the script — it installs automatically)
sudo ./scripts/install-deps.sh

# Interactive setup with auto-detected subnet (default)
sudo ./scripts/setup-nfs.sh

# Read-write for a specific subnet
sudo ./scripts/setup-nfs.sh --rw --clients 10.0.0.0/24

# Read-only for a single client
sudo ./scripts/setup-nfs.sh --ro --clients 10.0.0.1

# No filesystem caching (sync, no_subtree_check) for data integrity
sudo ./scripts/setup-nfs.sh --clients 10.0.0.0/24 --no-fs-cache

# Allow NFS clients from ports above 1024
sudo ./scripts/setup-nfs.sh --insecure

# Remove the export
sudo ./scripts/setup-nfs.sh --remove

# Dry-run to preview changes
sudo ./scripts/setup-nfs.sh --dry-run
```

**Features:**
- **Two access modes:** `--rw` (read-write, default) or `--ro` (read-only)
- **Flexible client specifications:** CIDR notation (`10.0.0.0/24`), single IP, or `@all` for any client
- **Auto-detect subnet** — detects the primary network interface subnet and prompts to use it
- **NFSv4.2** — configures modern NFS version with performance options
- **Server tuning** — creates `/etc/nfs.conf.d/drive-nmonit.conf` with optimized thread counts, connection limits, and write-delay
- **`crossmnt`** — allows traversal to sub-mounts (important for mergerfs + GlusterFS layered architecture)
- **Security** — `root_squash` by default (root clients mapped to `nobody`)
- **Firewall configuration** — opens ports 111 and 2049 via UFW or firewalld
- **Removal** — comments out export lines matching the workspace path, leaving other exports intact

**Client access (Linux/Unix):**

```bash
# Mount from a client machine
sudo mount -t nfs4 -o vers=4.2,noatime <server-ip>:/mnt/workspace /mnt/nfs-workspace

# Or add to /etc/fstab
<server-ip>:/mnt/workspace /mnt/nfs-workspace nfs4 vers=4.2,noatime,_netdev 0 0
```

### Choosing Between Samba and NFS

| Feature | Samba/CIFS | NFS |
|---------|------------|-----|
| **Client OS** | Windows, macOS, Linux | Linux, Unix (macOS via `nfs://`) |
| **Performance** | Good, slight overhead | Excellent, kernel-native |
| **Authentication** | User/password via SMB | IP/hostname-based (kerberos optional) |
| **Setup complexity** | Moderate (users, passwords) | Simple (just exports) |
| **Use case** | Cross-platform office/storage | Linux-only high-performance |
| **Security model** | User-level | Network-level (IP/CIDR) |
| **Ports** | 139, 445, 137, 138 | 111, 2049 |

> **Tip:** For mixed OS environments, run both — they can export the same path simultaneously.

## Performance Tuning

### Quick Start

During `setup-glusterfs.sh --init`, you'll be prompted to select a tuning profile. The profiles are:

| Profile | Best For | RAM Usage | Threads | Caching |
|---------|----------|-----------|---------|---------|
| **balanced** | Mixed workloads (default) | ~25% of RAM | 4× CPU cores | Moderate |
| **throughput** | Large files, media, backups | ~33% of RAM | 2× CPU cores | Aggressive read/write |
| **metadata** | Many small files, directories | ~50% of RAM | 8× CPU cores | Heavy metadata caching |
| **capacity** | Low-RAM nodes, archival | Minimal | Minimal | Disabled |

You can also run tuning independently at any time:

```bash
# Apply a profile to an existing volume
sudo ./scripts/tune-glusterfs.sh workspace balanced
sudo ./scripts/tune-glusterfs.sh workspace throughput
sudo ./scripts/tune-glusterfs.sh workspace metadata
sudo ./scripts/tune-glusterfs.sh workspace capacity

# Interactive custom tuning
sudo ./scripts/tune-glusterfs.sh workspace custom
```

### `scripts/tune-glusterfs.sh`

Comprehensive performance tuning script with workload-specific profiles.

**What it configures:**
- **Metadata caching** — `md-cache`, `nl-cache`, `cache-invalidation`, `inode-lru-limit`
- **I/O threading** — `io-thread-count`, `client.event-threads`, `server.event-threads`
- **Read/write behavior** — `read-ahead-page-count`, `write-behind-window-size`, `flush-behind`
- **Directory operations** — `readdir-ahead`, `parallel-readdir`
- **Network tuning** — `ping-timeout`, `frame-timeout`, `remote-dio-write-behind`
- **Storage settings** — `fips-mode-rchecksum`, `lookup-optimize`, `read-hash-mode`

**Adaptive tuning:** The script detects your system's CPU cores and RAM, then adjusts cache sizes and thread counts accordingly.

### `scripts/sysctl-glusterfs.conf`

Kernel-level network and memory tuning template. Installed system-wide when you opt in during tuning:

```bash
# Install manually if desired:
sudo cp scripts/sysctl-glusterfs.conf /etc/sysctl.d/90-glusterfs.conf
sudo sysctl --system
```

**Key settings:**
- **TCP buffer auto-tuning** up to 16 MB (1GbE) / 32 MB (10GbE)
- **TCP window scaling** for high-throughput links
- **`vm.swappiness = 10`** — prefer file caching over swapping
- **`vm.vfs_cache_pressure = 50`** — retain dentry/inode cache longer
- **Connection tracking** increased for many brick connections

### Mount Options (Client-side)

The `mount-all.sh` script now uses performance-optimized FUSE mount options:

```
defaults,_netdev,noatime,direct-io-mode=disable,log-level=WARNING,fetch-attempts=10,use-readdirp=yes,backupvolfile-server=localhost
```

| Option | Purpose |
|--------|---------|
| `noatime` | Skip access-time updates (reduces metadata I/O) |
| `direct-io-mode=disable` | Enable kernel page cache for better read performance |
| `log-level=WARNING` | Reduce log verbosity in the FUSE mount |
| `fetch-attempts=10` | Retry failed volfile fetches (improves resilience) |
| `use-readdirp=yes` | Fetch directory entries + attributes in one operation |
| `backupvolfile-server=localhost` | Fallback to local volfile server if primary is down |

### Performance Methodology

1. **Establish a baseline** — Use `fio` or `dd` before tuning
2. **Apply one profile at a time** — Each profile contains coherent groups of settings
3. **Profile the volume** after tuning:
   ```bash
   gluster volume profile workspace start
   # ... run your workload ...
   gluster volume profile workspace info    # Shows operation latencies
   gluster volume profile workspace stop
   ```
4. **Check top operations:**
   ```bash
   gluster volume top workspace read open    # Most frequently opened files
   gluster volume top workspace read-perf    # Read performance per brick
   ```

### Network Best Practices

- Use a **dedicated storage network** (separate NIC/subnet) for GlusterFS traffic
- Enable **jumbo frames** (MTU 9000) on all nodes for the storage network
- Minimum **1 Gbps** between nodes; **10 Gbps** recommended for production
- Low latency is critical for metadata operations — keep nodes in the same rack/DC

### Hardware Considerations

- **Don't mix drive types** in a distributed volume — performance is limited by the slowest brick
- **XFS is the recommended brick filesystem** (better extended attribute support than ext4)
- **RAM is your friend** — GlusterFS metadata caching is extremely effective; more RAM = better performance
- **Fast storage (NVMe) on the primary metadata node** can improve volume-wide metadata operations

## Health Monitoring

The project includes a comprehensive health check script that monitors all components of your distributed storage cluster.

### Quick Start

```bash
# Via the CLI wrapper (recommended)
sudo ./drive-nmonit-cli health               # Basic health check (human-readable)
sudo ./drive-nmonit-cli health --watch        # Live-updating dashboard (5s interval)
sudo ./drive-nmonit-cli health --json         # Machine-parseable JSON output

# Or directly via the script (same flags):
sudo ./scripts/health-check.sh                # Basic health check
sudo ./scripts/health-check.sh --watch        # Continuous watch mode
sudo ./scripts/health-check.sh --json         # JSON output
sudo ./scripts/health-check.sh --nagios       # Nagios/Icinga compatible output
sudo ./scripts/health-check.sh --quiet        # Only warnings and errors
sudo ./scripts/health-check.sh --send-alert   # With alert notifications
```

**Exit codes:** `0` = all healthy, `1` = warnings, `2` = critical.

### `scripts/health-check.sh`

Monitors the following (in order):

| Check | What It Monitors | Failure Impact |
|-------|-----------------|----------------|
| **System Services** | `glusterd`, `mergerfs-pool`, workspace mount | Data inaccessibility |
| **GlusterFS Volume** | Status, type, bricks, split-brain, heal, rebalance, quorum | Data corruption or loss |
| **Peer Connectivity** | All GlusterFS peer states | Cluster fragmentation |
| **Disk Space** | Pool usage %, inode usage %, per-drive capacity | Out of space |
| **MergerFS Pool Health** | Mount status, filesystem type, source drive count | Pool failure |
| **Network Latency** | RTT to each peer (50ms+ threshold) | Performance degradation |
| **System Resources** | Memory usage (80% warn / 90% crit), CPU load, glusterfsd processes | Node instability |

### Thresholds

Customize thresholds via environment variables or by editing the script:

| Variable | Default | Description |
|----------|---------|-------------|
| `WARN_DISK_PCT` | 80 | Warning when disk usage exceeds this % |
| `CRIT_DISK_PCT` | 90 | Critical when disk usage exceeds this % |
| `WARN_INODE_PCT` | 80 | Warning when inode usage exceeds this % |
| `CRIT_INODE_PCT` | 90 | Critical when inode usage exceeds this % |
| `WARN_BRICK_LAG` | 30 | Warning if brick changelog lags by this many entries |
| `CRIT_BRICK_OFFLINE` | 1 | Critical if this many bricks are offline |

Example:
```bash
# Alert earlier — 75% warning, 85% critical
sudo env WARN_DISK_PCT=75 CRIT_DISK_PCT=85 ./scripts/health-check.sh
```

### Alert Notifications

The `--send-alert` flag enables alert deduplication and notification:

1. **Deduplication** — Same-status alerts are batched (one notification every ~30 minutes at 5-minute intervals)
2. **Recovery detection** — A recovery notification is sent when the system returns to healthy
3. **Custom alert script** — Create `/etc/drive-nmonit/alert.sh` to integrate with email, Slack, PagerDuty, etc.:

```bash
#!/usr/bin/env bash
# /etc/drive-nmonit/alert.sh
# Available environment variables: ALERT_STATUS, ALERT_MESSAGE, ALERT_HOSTNAME, ALERT_TIME

case "$ALERT_STATUS" in
    critical)
        curl -s -X POST https://hooks.slack.com/services/YOUR/WEBHOOK/URL \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"🚨 [${ALERT_HOSTNAME}] ${ALERT_MESSAGE}\"}"
        ;;
    warning)
        logger -t drive-nmonit-alert "WARN: ${ALERT_MESSAGE}"
        ;;
    RECOVERY)
        curl -s -X POST https://hooks.slack.com/services/YOUR/WEBHOOK/URL \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"✅ [${ALERT_HOSTNAME}] All systems recovered\"}"
        ;;
esac
```

4. **Fallback** — If no alert script exists, alerts are logged via `logger` to syslog

### Periodic Scheduling (Systemd Timer)

Enable the included systemd timer for automatic periodic health checks:

```bash
# Copy the systemd files (adjust paths if needed)
sudo cp systemd/drive-nmonit-health.service /etc/systemd/system/
sudo cp systemd/drive-nmonit-health.timer /etc/systemd/system/

# Create a symlink for the health check binary
sudo ln -sf "$(pwd)/scripts/health-check.sh" /usr/local/sbin/drive-nmonit-health-check

# Reload and enable the timer
sudo systemctl daemon-reload
sudo systemctl enable --now drive-nmonit-health.timer

# View check results
journalctl -u drive-nmonit-health.service --since "1 hour ago"
```

The timer runs every **5 minutes** with a randomized delay (30s) to avoid all nodes checking simultaneously. JSON output is saved to `/var/log/drive-nmonit/health-latest.json` for external monitoring tools.

### Integration with External Monitoring

**Nagios / Icinga:**
```bash
# NRPE command definition
command[check_drive_nmonit]=/usr/local/sbin/drive-nmonit-health-check --nagios
```

**Grafana / Prometheus:** Use the `--json` output and ship with `prometheus-node-exporter`'s textfile collector:
```bash
# Cron: write prometheus metrics
* * * * * /usr/local/sbin/drive-nmonit-health-check --json | prometheus-stats-exporter
```

### Logging

- Health check results are logged to `journald` via the systemd service
- JSON snapshots are written to `/var/log/drive-nmonit/health-latest.json`
- Alert notifications fall back to syslog via `logger`
- State tracking is persisted in `/etc/drive-nmonit/health-state/` for alert deduplication

## Web Dashboard

The project includes a lightweight, zero-dependency web dashboard that displays real-time cluster health data with per-node status indicators.

### Quick Start

```bash
# Start the dashboard server (requires root for health check access)
sudo ./dashboard/server.py

# Specify a different port
sudo ./dashboard/server.py --port 9090

# Specify cluster nodes (comma-separated hostnames)
sudo ./dashboard/server.py --nodes node1.example.com,node2.example.com,node3.example.com

# Use a config file
sudo ./dashboard/server.py --config /etc/drive-nmonit/nodes.conf
```

Then open **http://localhost:8080** in your browser.

### Features

- **Cluster overview** — Total nodes, healthy/warning/critical/offline counts at a glance
- **Per-node cards** — Each node shows volume status, brick count, memory usage, CPU load, and disk usage with animated progress bars
- **Status indicators** — Pulsing green/yellow/red dots for quick visual assessment
- **Alert display** — Color-coded alerts per node with expand/collapse for long lists
- **Auto-refresh** — 30-second polling with smooth countdown ring animation
- **Real-time refresh** — Manual refresh button with loading state
- **Responsive design** — Adapts from desktop grid to mobile single-column
- **Dark theme** — Modern dark UI with glassmorphism, gradients, and micro-interactions

### API Endpoints

The server exposes the following REST endpoints:

| Endpoint | Description |
|----------|-------------|
| `GET /` | Serves the dashboard HTML |
| `GET /api/health` | Runs the health check and returns local node JSON |
| `GET /api/nodes` | Returns the configured cluster node list |
| `GET /api/health.json` | Returns aggregated cluster health (all nodes, cached 30s) |

### Multi-Node Configuration

**Option 1: Nodes list file** — `/etc/drive-nmonit/nodes.conf`
```
# /etc/drive-nmonit/nodes.conf
# Format: hostname:address:Optional Label
node1:10.0.0.1:Primary
node2:10.0.0.2:Storage-1
node3:10.0.0.3:Storage-2
```

**Option 2: Environment variable**
```bash
sudo env DRIVE_NMONIT_NODES=node1,node2,node3 ./dashboard/server.py
```

**Option 3: CLI argument**
```bash
sudo ./dashboard/server.py --nodes node1,node2,node3
```

If no configuration is provided, the dashboard shows only the local node.

### Remote Node Polling

The server fetches health data from remote nodes via SSH (`BatchMode=yes`). For this to work:

1. **SSH key-based authentication** must be configured from the dashboard host to each node
2. The SSH user must have **password-less sudo** for the health check script
3. Nodes must be reachable on port 22

Configure SSH key access:
```bash
# On the dashboard host, as root:
ssh-keygen -t ed25519 -f /root/.ssh/id_drive_nmonit -N ""
ssh-copy-id -i /root/.ssh/id_drive_nmonit user@node1
ssh-copy-id -i /root/.ssh/id_drive_nmonit user@node2

# Configure /root/.ssh/config for BatchMode:
Host 10.0.0.*
    IdentityFile /root/.ssh/id_drive_nmonit
    User root
    BatchMode yes
    ConnectTimeout 10
```

### Dashboard Screenshot

The dashboard features:

- Glassmorphism node cards with color-coded top borders
- Pulsing status dots (green/yellow/red/gray)
- Animated disk usage progress bars
- Memory and CPU load per node
- Expandable alert lists
- Countdown ring showing seconds until next auto-refresh
- Responsive grid layout

### Systemd Integration

For a persistent dashboard server:

```bash
# Create a systemd service file
sudo cat > /etc/systemd/system/drive-nmonit-dashboard.service << 'SERVICE'
[Unit]
Description=drive-nmonit Cluster Dashboard
After=network-online.target glusterd.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/drive-nmonit-dashboard
Restart=on-failure
RestartSec=10
User=root
Nice=10

[Install]
WantedBy=multi-user.target
SERVICE

# Create symlink
sudo ln -sf "$(pwd)/dashboard/server.py" /usr/local/sbin/drive-nmonit-dashboard

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable --now drive-nmonit-dashboard
```

**Note:** The dashboard server listens on `0.0.0.0` by default. For production, restrict access via firewall or reverse proxy with authentication.

## Adding a New Drive

1. Plug in the drive
2. If it already has a filesystem, it will be detected and mounted automatically on next boot
3. Run `sudo ./scripts/setup-mergerfs.sh` again to add it to the pool immediately
4. For a completely new (unformatted) drive:
   ```bash
   sudo mkfs.ext4 /dev/<drive>   # or xfs, btrfs, etc.
   sudo ./scripts/setup-mergerfs.sh
   ```

## Adding a New Node

1. Copy the project to the new node
2. Run `scripts/install-deps.sh`
3. Run `scripts/setup-mergerfs.sh`
4. On the **primary** node, run:
   ```bash
   sudo gluster peer probe <new-node-ip>
   sudo gluster volume add-brick workspace <new-node-ip>:/mnt/local-pool
   ```
5. On the **new node**, run `scripts/mount-all.sh`

## Removing a Node

```bash
# On the primary node
sudo gluster volume remove-brick workspace <node-ip>:/mnt/local-pool start

# Check migration status
sudo gluster volume remove-brick workspace <node-ip>:/mnt/local-pool status

# Commit the removal
sudo gluster volume remove-brick workspace <node-ip>:/mnt/local-pool commit
```

## Systemd Services

| Service | Purpose |
|---------|---------|
| `mergerfs-pool.service` | Pools local drives via mergerfs at boot |
| `glusterd.service` | GlusterFS daemon (installed by package) |
| `mnt-workspace.mount` | Mounts the GlusterFS volume at boot |

## Troubleshooting

### Check mergerfs pool
```bash
mount | grep mergerfs
```

### Check GlusterFS status
```bash
sudo gluster pool list
sudo gluster volume info
sudo gluster volume status
```

### Check GlusterFS mounts
```bash
mount | grep glusterfs
df -h | grep workspace
```

### View logs
```bash
journalctl -u mergerfs-pool.service
journalctl -u glusterd.service
journalctl -u mnt-workspace.mount
```

## Network Requirements

For best performance:
- Use **dedicated storage network** if possible (separate NIC/subnet)
- Minimum **1 Gbps** between nodes
- **10 Gbps** recommended for production use
- Low latency is critical for metadata operations

## License

MIT
