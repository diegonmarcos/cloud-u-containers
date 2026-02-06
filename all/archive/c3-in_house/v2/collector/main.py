#!/usr/bin/env python3
"""
Cloud Control Center - Main Runner
Orchestrates collectors and converters

Usage:
    python main.py           # Run all (collect + convert)
    python main.py collect   # Run collectors only
    python main.py convert   # Run converters only
    python main.py <name>    # Run single collector (e.g., "availability")
"""
import sys
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
COLLECTORS_DIR = SCRIPT_DIR / "1.collectors"
CONVERTERS_DIR = SCRIPT_DIR / "3.converters"

# Collector hierarchy
COLLECTORS = {
    # 0. Orchestrate
    "architecture": "0.architecture.py",
    "docker": "0.docker.py",
    # 1. Monitor
    "availability": "1.availability.py",
    "performance": "1.performance.py",
    # 2. Security
    "security": "2.security.py",
    "backups": "2.backups.py",
    "web": "2.web.py",
    # 3. Cost
    "cost_infra": "3.cost_infra.py",
    "cost_ai": "3.cost_ai.py",
}

# Ordered list for full runs
COLLECTOR_ORDER = [
    "0.architecture.py",
    "0.docker.py",
    "1.availability.py",
    "1.performance.py",
    "2.security.py",
    "2.backups.py",
    "2.web.py",
    "3.cost_infra.py",
    "3.cost_ai.py",
]


def run_collector(name: str) -> bool:
    """Run a single collector by name or filename."""
    # Check if it's a full filename
    if name in COLLECTOR_ORDER:
        filename = name
    # Check if it's a short name
    elif name in COLLECTORS:
        filename = COLLECTORS[name]
    else:
        print(f"Unknown collector: {name}")
        print(f"Available: {', '.join(COLLECTORS.keys())}")
        return False

    path = COLLECTORS_DIR / filename
    if not path.exists():
        print(f"Collector not found: {path}")
        return False

    print(f"\n>>> {filename}")
    result = subprocess.run([sys.executable, str(path)])
    return result.returncode == 0


def run_collectors():
    """Run all collectors in order."""
    print("=" * 60)
    print("RUNNING COLLECTORS")
    print("=" * 60)

    for filename in COLLECTOR_ORDER:
        path = COLLECTORS_DIR / filename
        if path.exists():
            print(f"\n>>> {filename}")
            subprocess.run([sys.executable, str(path)])
        else:
            print(f"\n>>> {filename} (skipped - not found)")


def run_converters():
    """Run all converters (JSON, Markdown, CSV)."""
    print("\n" + "=" * 60)
    print("RUNNING CONVERTERS")
    print("=" * 60)

    converters = [
        ("to_json.py", "JSON"),
        ("to_markdown.py", "Markdown"),
        ("to_csv.py", "CSV"),
        ("to_js.py", "JS (browser)"),
    ]

    for filename, name in converters:
        converter = CONVERTERS_DIR / filename
        if converter.exists():
            print(f"\n>>> {name} ({filename})")
            subprocess.run([sys.executable, str(converter)])
        else:
            print(f"\n>>> {name} ({filename}) - skipped, not found")


def print_help():
    """Print usage help."""
    print(__doc__)
    print("\nAvailable collectors:")
    for name, filename in COLLECTORS.items():
        exists = "✓" if (COLLECTORS_DIR / filename).exists() else "✗"
        print(f"  {exists} {name:15} → {filename}")


def main():
    """Main entry point."""
    if len(sys.argv) > 1:
        cmd = sys.argv[1]

        if cmd in ("help", "-h", "--help"):
            print_help()
        elif cmd == "collect":
            run_collectors()
        elif cmd == "convert":
            run_converters()
        elif cmd == "all":
            run_collectors()
            run_converters()
        elif cmd in COLLECTORS or cmd in COLLECTOR_ORDER:
            run_collector(cmd)
        else:
            print(f"Unknown command: {cmd}")
            print_help()
            return 1
    else:
        # Default: run everything
        run_collectors()
        run_converters()

    print("\n" + "=" * 60)
    print("DONE")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
