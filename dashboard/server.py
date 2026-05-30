#!/usr/bin/env python3
"""
drive-nmonit Dashboard Server

A lightweight, zero-dependency HTTP server that serves the health dashboard
and provides API endpoints for cluster health data.

Usage:
  sudo ./dashboard/server.py --port 8080
  sudo ./dashboard/server.py --port 8080 --nodes node1.example.com,node2.example.com
  sudo ./dashboard/server.py --port 8080 --config /etc/drive-nmonit/nodes.conf

Endpoints:
  GET  /              Serves the dashboard HTML
  GET  /api/health    Returns local node health check JSON (runs health-check.sh --json)
  GET  /api/nodes     Returns configured cluster node list with cached health data
  GET  /api/health.json  Returns aggregated cluster health data
"""
from __future__ import annotations

import http.server
import json
import os
import shlex
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = 8080
HEALTH_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "health-check.sh")
DASHBOARD_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
CACHE_TTL = 30  # seconds before re-running health check
NODES_CONFIG = "/etc/drive-nmonit/nodes.conf"

# ---------------------------------------------------------------------------
# Health data cache (per-node)
# ---------------------------------------------------------------------------

_health_cache: dict[str, dict[str, Any]] = {}       # hostname -> {data, timestamp, error}
_node_list: list[dict[str, str]] = []                # [{hostname, address, label}]

# ---------------------------------------------------------------------------
# Config loader
# ---------------------------------------------------------------------------

def load_nodes_config(config_path: str) -> list[dict[str, str]]:
    """Load node list from config file or environment.

    Config file format (one node per line):
        # comments and blank lines ignored
        hostname:address:Optional Label
        hostname:address
        hostname        # address defaults to hostname

    Also checks the DRIVE_NMONIT_NODES env var (comma-separated hostnames).
    """
    nodes: list[dict[str, str]] = []

    # 1. Try config file
    if os.path.exists(config_path):
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = [p.strip() for p in line.split(":")]
                hostname = parts[0]
                address = parts[1] if len(parts) > 1 else hostname
                label = parts[2] if len(parts) > 2 else hostname
                nodes.append({"hostname": hostname, "address": address, "label": label})

    # 2. Check env var (DRIVE_NMONIT_NODES=host1,host2,...)
    env_nodes = os.environ.get("DRIVE_NMONIT_NODES", "")
    if env_nodes:
        for hostname in env_nodes.split(","):
            hostname = hostname.strip()
            if hostname and not any(n["hostname"] == hostname for n in nodes):
                nodes.append({"hostname": hostname, "address": hostname, "label": hostname})

    # 3. Default: just the local node
    if not nodes:
        local_hostname = os.uname().nodename
        nodes.append({"hostname": local_hostname, "address": "localhost", "label": f"{local_hostname} (local)"})

    return nodes


# ---------------------------------------------------------------------------
# Health data fetcher
# ---------------------------------------------------------------------------

def run_local_health_check() -> dict[str, Any] | None:
    """Run the health-check.sh script with --json and parse the output."""
    script = os.path.abspath(HEALTH_SCRIPT)
    if not os.path.exists(script):
        return {"error": f"Health check script not found: {script}"}

    try:
        cmd = [script, "--json"]
        if os.geteuid() != 0:
            # Only use sudo if not already root
            cmd = ["sudo"] + cmd
        
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
        else:
            return {
                "error": f"Health check exited with code {result.returncode}",
                "stderr": result.stderr.strip(),
                "status": "critical",
            }
    except json.JSONDecodeError as e:
        return {"error": f"Invalid JSON from health check: {e}", "status": "critical"}
    except subprocess.TimeoutExpired:
        return {"error": "Health check timed out", "status": "critical"}
    except FileNotFoundError as e:
        if "sudo" in str(e):
            return {"error": "sudo not found — run server as root instead", "status": "critical"}
        return {"error": f"Script not found: {e}", "status": "critical"}
    except Exception as e:
        return {"error": f"Health check failed: {e}", "status": "critical"}


def fetch_remote_health(address: str, hostname: str) -> dict[str, Any] | None:
    """Fetch health data from a remote node via SSH."""
    try:
        # Use SSH to run the health check remotely; uses ControlMaster if configured
        ssh_cmd = [
            "ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
            address, f"sudo {HEALTH_SCRIPT} --json 2>/dev/null || echo '{{}}'"
        ]
        result = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout)
            return data
        else:
            return {
                "hostname": hostname,
                "status": "critical",
                "error": f"SSH connection failed: {result.stderr.strip() or 'no response'}",
            }
    except json.JSONDecodeError:
        return {"hostname": hostname, "status": "critical", "error": "Invalid JSON from remote"}
    except subprocess.TimeoutExpired:
        return {"hostname": hostname, "status": "critical", "error": "SSH timed out"}
    except FileNotFoundError:
        return {"hostname": hostname, "status": "critical", "error": "ssh not found"}
    except Exception as e:
        return {"hostname": hostname, "status": "critical", "error": str(e)}


def update_health_cache() -> None:
    """Update cached health data for all known nodes."""
    global _health_cache, _node_list

    # Run local health check
    local_hostname = os.uname().nodename
    local_data = run_local_health_check()
    if local_data:
        local_data["hostname"] = local_data.get("hostname", local_hostname)
        _health_cache[local_hostname] = {
            "data": local_data,
            "timestamp": time.time(),
            "error": None,
        }
    else:
        _health_cache[local_hostname] = {
            "data": {"hostname": local_hostname, "status": "critical", "error": "Local check failed"},
            "timestamp": time.time(),
            "error": "Local check failed",
        }

    # Fetch remote nodes in parallel (simplified: sequential for zero deps)
    for node in _node_list:
        hostname = node["hostname"]
        address = node["address"]
        # Skip localhost (already checked)
        if address in ("localhost", "127.0.0.1", "::1") or hostname == local_hostname:
            continue

        # Check if cache is still fresh
        cached = _health_cache.get(hostname)
        if cached and (time.time() - cached["timestamp"]) < CACHE_TTL:
            continue

        remote_data = fetch_remote_health(address, hostname)
        if remote_data:
            _health_cache[hostname] = {
                "data": remote_data,
                "timestamp": time.time(),
                "error": None,
            }


def get_aggregated_health() -> dict[str, Any]:
    """Build the aggregated cluster health response."""
    aggregate: dict[str, Any] = {
        "cluster_status": "healthy",
        "total_nodes": len(_node_list),
        "healthy_nodes": 0,
        "warning_nodes": 0,
        "critical_nodes": 0,
        "offline_nodes": 0,
        "nodes": [],
        "cluster_alerts": [],
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    for node in _node_list:
        hostname = node["hostname"]
        cached = _health_cache.get(hostname)
        if cached and cached["data"]:
            data = cached["data"]
            status = data.get("status", "critical")
            node_entry = {
                "hostname": hostname,
                "label": node.get("label", hostname),
                "status": status,
                "timestamp": cached["timestamp"],
                "age_seconds": int(time.time() - cached["timestamp"]),
                "data": data,
            }
            aggregate["nodes"].append(node_entry)

            if status == "healthy":
                aggregate["healthy_nodes"] += 1
            elif status == "warning":
                aggregate["warning_nodes"] += 1
                aggregate["cluster_alerts"].extend(data.get("alerts", []))
            else:
                aggregate["critical_nodes"] += 1
                aggregate["cluster_alerts"].extend(data.get("alerts", []))
        else:
            aggregate["critical_nodes"] += 1
            aggregate["offline_nodes"] += 1
            aggregate["nodes"].append({
                "hostname": hostname,
                "label": node.get("label", hostname),
                "status": "offline",
                "timestamp": 0,
                "age_seconds": -1,
                "data": None,
            })
            aggregate["cluster_alerts"].append({
                "level": "critical",
                "message": f"Node {hostname} is unreachable",
            })

    # Determine aggregate cluster status
    if aggregate["critical_nodes"] > 0:
        aggregate["cluster_status"] = "critical"
    elif aggregate["warning_nodes"] > 0:
        aggregate["cluster_status"] = "warning"
    else:
        aggregate["cluster_status"] = "healthy"

    return aggregate


# ---------------------------------------------------------------------------
# HTTP Request Handler
# ---------------------------------------------------------------------------

class DashboardHandler(http.server.BaseHTTPRequestHandler):
    """HTTP handler for the dashboard server."""

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        try:
            if path == "/":
                self._serve_dashboard()
            elif path == "/api/health":
                self._serve_local_health()
            elif path == "/api/nodes":
                self._serve_node_list()
            elif path == "/api/health.json":
                self._serve_aggregated_health()
            else:
                self._json_response({"error": "Not found"}, 404)
        except Exception as e:
            self._json_response({"error": str(e)}, 500)

    def _serve_dashboard(self) -> None:
        """Serve the main dashboard HTML file."""
        if os.path.exists(DASHBOARD_FILE):
            with open(DASHBOARD_FILE) as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(content.encode("utf-8"))
        else:
            self._json_response({"error": f"Dashboard not found at {DASHBOARD_FILE}"}, 500)

    def _serve_local_health(self) -> None:
        """Return the latest local health check data (always fresh)."""
        data = run_local_health_check()
        if data:
            data["_cached_at"] = time.time()
            self._json_response(data)
        else:
            self._json_response({"error": "Health check failed", "status": "critical"}, 500)

    def _serve_node_list(self) -> None:
        """Return the configured cluster node list."""
        global _node_list
        self._json_response({
            "nodes": _node_list,
            "count": len(_node_list),
        })

    def _serve_aggregated_health(self) -> None:
        """Return aggregated cluster health data (cached)."""
        update_health_cache()
        data = get_aggregated_health()
        self._json_response(data)

    def _json_response(self, data: dict, status: int = 200) -> None:
        """Send a JSON response."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode("utf-8"))

    def log_message(self, format: str, *args: Any) -> None:
        """Log to stdout with a cleaner format."""
        sys.stderr.write(f"[{self.log_date_time_string()}] {args[0]} {args[1]} {args[2]}\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    global PORT, _node_list, NODES_CONFIG

    # Parse CLI args
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--port" and i + 1 < len(args):
            PORT = int(args[i + 1])
            i += 2
        elif args[i] == "--nodes" and i + 1 < len(args):
            os.environ["DRIVE_NMONIT_NODES"] = args[i + 1]
            i += 2
        elif args[i] == "--config" and i + 1 < len(args):
            NODES_CONFIG = args[i + 1]
            i += 2
        elif args[i] == "--help" or args[i] == "-h":
            print(__doc__)
            sys.exit(0)
        else:
            print(f"Unknown argument: {args[i]}")
            sys.exit(1)

    # Check for root (needed for sudo health check)
    if os.geteuid() != 0:
        print("⚠  Warning: Not running as root. Health check may fail without password-less sudo.", file=sys.stderr)
        print("   Either run with `sudo dashboard/server.py` or configure sudoers for the health check.", file=sys.stderr)

    # Load node list
    _node_list = load_nodes_config(NODES_CONFIG)
    local_hostname = os.uname().nodename

    print(f"├─ drive-nmonit Dashboard Server")
    print(f"├─ Listening on http://0.0.0.0:{PORT}")
    print(f"├─ Dashboard served at http://0.0.0.0:{PORT}/")
    print(f"├─ API: /api/health, /api/nodes, /api/health.json")
    print(f"├─ Nodes configured: {len(_node_list)}")
    for n in _node_list:
        marker = " ← local" if n["hostname"] == local_hostname else ""
        print(f"│    {n['hostname']:20s} → {n['address']:20s}{marker}")
    print(f"└─ Ctrl+C to stop")

    # Do an initial health cache update
    print("   Running initial health check...", end=" ", file=sys.stderr)
    update_health_cache()
    print("done.", file=sys.stderr)

    # Start server
    server = http.server.HTTPServer(("0.0.0.0", PORT), DashboardHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.", file=sys.stderr)
        server.server_close()


if __name__ == "__main__":
    main()
