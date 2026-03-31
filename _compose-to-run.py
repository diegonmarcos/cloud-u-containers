#!/usr/bin/env python3
"""Convert docker-compose.yml (via JSON) to idempotent docker-run.sh script.

Usage: docker compose -f docker-compose.yml config --format json | python3 _compose-to-run.py > docker-run.sh

Generates one `docker rm -f + docker run` per service, in dependency order.
No docker compose Go binary needed on the target VM.
"""
import json
import sys
from collections import defaultdict


def topo_sort(services: dict) -> list[str]:
    """Sort services by depends_on (dependencies first)."""
    graph = defaultdict(set)
    for name, svc in services.items():
        for dep in svc.get("depends_on", {}):
            graph[name].add(dep)
    visited, order = set(), []
    def visit(n):
        if n in visited:
            return
        visited.add(n)
        for dep in graph.get(n, []):
            visit(dep)
        order.append(n)
    for name in services:
        visit(name)
    return order


def svc_to_run(name: str, svc: dict, project: str, volumes: dict) -> list[str]:
    """Convert one compose service to docker run arguments."""
    args = ["docker run -d"]
    args.append(f"--name {name}")

    # Labels for container-init.sh to find containers by project
    args.append(f'--label "com.docker.compose.project={project}"')
    args.append(f'--label "com.docker.compose.service={name}"')

    # Network
    net = svc.get("network_mode", "")
    if net:
        args.append(f"--network {net}")
    else:
        for net_name in svc.get("networks", {}):
            args.append(f"--network {net_name}")

    # Ports
    for port in svc.get("ports", []):
        if isinstance(port, dict):
            target = port.get("target", "")
            published = port.get("published", "")
            proto = port.get("protocol", "tcp")
            if published:
                args.append(f"-p {published}:{target}/{proto}")
            else:
                args.append(f"-p {target}/{proto}")
        else:
            args.append(f"-p {port}")

    # Volumes
    for vol in svc.get("volumes", []):
        if isinstance(vol, dict):
            src = vol.get("source", "")
            tgt = vol.get("target", "")
            ro = ",ro" if vol.get("read_only") else ""
            bind_type = vol.get("type", "volume")
            if bind_type == "bind":
                args.append(f"-v {src}:{tgt}{ro}")
            else:
                args.append(f"-v {src}:{tgt}{ro}")
        else:
            args.append(f"-v {vol}")

    # Environment
    env = svc.get("environment", {})
    if isinstance(env, dict):
        for k, v in env.items():
            if v is None:
                args.append(f"-e {k}")
            else:
                val = str(v).replace('"', '\\"')
                args.append(f'-e "{k}={val}"')
    elif isinstance(env, list):
        for e in env:
            args.append(f'-e "{e}"')

    # Env file
    for ef in svc.get("env_file", []):
        if isinstance(ef, dict):
            args.append(f"--env-file {ef.get('path', '')}")
        else:
            args.append(f"--env-file {ef}")

    # Resource limits
    deploy = svc.get("deploy", {}).get("resources", {})
    limits = deploy.get("limits", {})
    if limits.get("memory"):
        args.append(f"--memory {limits['memory']}")
    if limits.get("cpus"):
        args.append(f"--cpus {limits['cpus']}")
    reservations = deploy.get("reservations", {})
    if reservations.get("memory"):
        args.append(f"--memory-reservation {reservations['memory']}")

    # Restart policy
    restart = svc.get("restart", "no")
    if restart and restart != "no":
        args.append(f"--restart {restart}")

    # Healthcheck
    hc = svc.get("healthcheck", {})
    if hc.get("test"):
        test = hc["test"]
        if isinstance(test, list):
            if test[0] == "CMD-SHELL":
                args.append(f'--health-cmd "{test[1]}"')
            elif test[0] == "CMD":
                args.append(f'--health-cmd "{" ".join(test[1:])}"')
        else:
            args.append(f'--health-cmd "{test}"')
        if hc.get("interval"):
            args.append(f"--health-interval {hc['interval']}")
        if hc.get("timeout"):
            args.append(f"--health-timeout {hc['timeout']}")
        if hc.get("retries"):
            args.append(f"--health-retries {hc['retries']}")

    # Capabilities
    for cap in svc.get("cap_add", []):
        args.append(f"--cap-add {cap}")
    for cap in svc.get("cap_drop", []):
        args.append(f"--cap-drop {cap}")

    # Security options
    for opt in svc.get("security_opt", []):
        args.append(f"--security-opt {opt}")

    # Hostname
    if svc.get("hostname"):
        args.append(f"--hostname {svc['hostname']}")

    # Working dir
    if svc.get("working_dir"):
        args.append(f"-w {svc['working_dir']}")

    # User
    if svc.get("user"):
        args.append(f"--user {svc['user']}")

    # Logging
    logging = svc.get("logging", {})
    if logging.get("driver"):
        args.append(f"--log-driver {logging['driver']}")
        for k, v in logging.get("options", {}).items():
            args.append(f'--log-opt {k}="{v}"')

    # Entrypoint
    ep = svc.get("entrypoint")
    if ep:
        if isinstance(ep, list):
            args.append(f'--entrypoint "{ep[0]}"')
        else:
            args.append(f'--entrypoint "{ep}"')

    # Image
    image = svc.get("image", "")
    if not image:
        # Service has build section but no image — skip (needs pre-build)
        return []
    args.append(image)

    # Command
    cmd = svc.get("command")
    if cmd:
        if isinstance(cmd, list):
            args.append(" ".join(f'"{c}"' if " " in str(c) else str(c) for c in cmd))
        else:
            args.append(str(cmd))

    return args


def main():
    data = json.load(sys.stdin)
    services = data.get("services", {})
    volumes = data.get("volumes", {})
    # Project name: compose uses directory name, override with COMPOSE_PROJECT_NAME or x-project
    project = data.get("x-project", data.get("name", "unknown"))

    order = topo_sort(services)

    print("#!/bin/sh")
    print("# Auto-generated from docker-compose.yml — DO NOT EDIT")
    print("# Run this instead of 'docker compose up' on E2 Micro VMs (1GB RAM)")
    print(f"# Project: {project}")
    print(f"# Services: {', '.join(order)}")
    print("set -e")
    print()

    # Create named volumes
    for vol_name, vol_conf in volumes.items():
        if vol_conf and vol_conf.get("external"):
            continue
        print(f"docker volume create {vol_name} 2>/dev/null || true")
    if volumes:
        print()

    # Create networks (skip host mode)
    networks = data.get("networks", {})
    for net_name, net_conf in networks.items():
        if net_conf and net_conf.get("external"):
            continue
        driver = ""
        if net_conf and net_conf.get("driver"):
            driver = f" --driver {net_conf['driver']}"
        print(f"docker network create{driver} {net_name} 2>/dev/null || true")
    if networks:
        print()

    # Pull all images first (sequential, lightweight)
    images = set()
    for name in order:
        img = services[name].get("image", "")
        if img:
            images.add(img)
    if images:
        print("# Pull latest images (ensures GHCR remote always wins)")
        for img in sorted(images):
            print(f'echo "  pull: {img}"')
            print(f"docker pull {img} 2>/dev/null || true")
        print()

    for name in order:
        svc = services[name]
        args = svc_to_run(name, svc, project, volumes)
        if not args:
            print(f"# SKIP {name}: no image (needs pre-build + push to GHCR)")
            continue

        print(f"# --- {name} ---")
        print(f"docker rm -f {name} 2>/dev/null || true")
        # Join args with backslash continuation for readability
        cmd = " \\\n  ".join(args)
        print(cmd)
        print(f'echo "  started: {name}"')
        print()


if __name__ == "__main__":
    main()
