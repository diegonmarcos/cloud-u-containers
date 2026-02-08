#!/usr/bin/env python3
"""
Converter: JSON → JS files for browser
Wraps JSON data in JavaScript variable assignments for HTML script loading
"""
import json
import shutil
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
JSON_DIR = SCRIPT_DIR.parent / "4.jsons"
JS_DIR = SCRIPT_DIR.parent / "4.jsonsjs"
FRONT_DIR = SCRIPT_DIR.parent / "5.front_c3"
# Also copy to web_front src_vanilla (where cloud_control.html lives)
WEB_FRONT_DIR = Path("/home/diego/Documents/Git/back-System/cloud/a_solutions/web_front/cloud_portal_web/cloud/src_vanilla")

# Mapping: json filename → (js filename, variable name)
JS_MAPPING = {
    "dashboard.json": ("monitor.js", "MONITOR"),
    "availability.json": ("availability.js", "AVAILABILITY"),
    "security.json": ("security.js", "SECURITY"),
    "performance.json": ("performance.js", "PERFORMANCE"),
    "docker.json": ("docker.js", "DOCKER"),
    "web.json": ("web.js", "WEB"),
    "costs.json": ("costs.js", "COSTS"),
}


def convert_all():
    """Convert all JSON files to JS variable files."""
    JS_DIR.mkdir(parents=True, exist_ok=True)

    for json_file, (js_file, var_name) in JS_MAPPING.items():
        json_path = JSON_DIR / json_file
        if not json_path.exists():
            print(f"Skipping {json_file} (not found)")
            continue

        print(f"Converting {json_file} → {js_file}...")

        with open(json_path, 'r') as f:
            data = json.load(f)

        # Wrap in JS variable assignment
        js_content = f"const {var_name} = {json.dumps(data, indent=2)};\n"

        js_path = JS_DIR / js_file
        with open(js_path, 'w') as f:
            f.write(js_content)

        print(f"  Saved: {js_path}")

    # Copy to 5.front_c3/
    copy_to_front()


def copy_to_front():
    """Copy JS files to frontend directories."""
    for target_dir in [FRONT_DIR, WEB_FRONT_DIR]:
        if not target_dir.exists():
            target_dir.mkdir(parents=True, exist_ok=True)

        print(f"\nCopying to {target_dir}...")
        for js_file in JS_DIR.glob("*.js"):
            dest = target_dir / js_file.name
            shutil.copy2(js_file, dest)
            print(f"  Copied: {dest}")


if __name__ == "__main__":
    convert_all()
