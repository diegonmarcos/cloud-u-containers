#!/usr/bin/env python3
"""
Architecture Collector - Infrastructure topology from spec file
Source: /home/diego/Documents/Git/back-System/cloud/0.spec/architecture.json
"""
import json
import shutil
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
RAW_DIR = SCRIPT_DIR.parent / "2.raw" / "architecture"
DATE = datetime.now().strftime("%Y-%m-%d")

# Source of truth
ARCHITECTURE_JSON = Path("/home/diego/Documents/Git/back-System/cloud/0.spec/architecture.json")


def collect_all() -> dict:
    """Load architecture from spec file."""
    if not ARCHITECTURE_JSON.exists():
        return {
            "error": f"Source file not found: {ARCHITECTURE_JSON}",
            "timestamp": datetime.now().isoformat(),
        }

    with open(ARCHITECTURE_JSON, 'r') as f:
        data = json.load(f)

    # Add collection metadata
    data["_collected"] = {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "source": str(ARCHITECTURE_JSON),
    }

    return data


def save_raw(data: dict):
    """Save raw data to file."""
    output_dir = RAW_DIR / DATE
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"architecture_{datetime.now().strftime('%H')}00.json"

    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2, default=str)

    print(f"Saved: {output_file}")
    return output_file


if __name__ == "__main__":
    print(f"Loading architecture from: {ARCHITECTURE_JSON}")
    data = collect_all()
    save_raw(data)
