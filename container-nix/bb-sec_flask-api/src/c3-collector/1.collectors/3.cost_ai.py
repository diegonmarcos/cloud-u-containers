#!/usr/bin/env python3
"""
AI Cost Collector - Claude API token usage
Collects: Token usage from ~/.claude/projects/*.jsonl
"""
import json
from datetime import datetime, timedelta
from pathlib import Path

try:
    from config import RAW_DIR, CLAUDE_LOGS
except ImportError:
    RAW_DIR = Path(__file__).parent.parent / "2.raw"
    CLAUDE_LOGS = Path.home() / ".claude/projects"

DATE = datetime.now().strftime("%Y-%m-%d")
MONTH = datetime.now().strftime("%Y-%m")


def get_claude_usage() -> dict:
    """Calculate Claude API token usage from local logs."""
    try:
        usage = {
            "today": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0},
            "week": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0},
            "month": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0},
            "sessions": []
        }

        today = datetime.now().date()
        week_ago = today - timedelta(days=7)
        month_start = today.replace(day=1)

        if not CLAUDE_LOGS.exists():
            return {"status": "ok", "usage": usage, "note": "No Claude logs found"}

        # Find all JSONL files
        for jsonl_file in CLAUDE_LOGS.rglob("*.jsonl"):
            try:
                file_date = datetime.fromtimestamp(jsonl_file.stat().st_mtime).date()

                with open(jsonl_file, 'r') as f:
                    session_tokens = {"input": 0, "output": 0}

                    for line in f:
                        try:
                            entry = json.loads(line)
                            if "usage" in entry:
                                u = entry["usage"]
                                tokens = {
                                    "input": u.get("input_tokens", 0),
                                    "output": u.get("output_tokens", 0),
                                    "cache_read": u.get("cache_read_input_tokens", 0),
                                    "cache_write": u.get("cache_creation_input_tokens", 0),
                                }

                                session_tokens["input"] += tokens["input"]
                                session_tokens["output"] += tokens["output"]

                                # Add to period totals
                                if file_date >= month_start:
                                    for k, v in tokens.items():
                                        usage["month"][k] += v
                                if file_date >= week_ago:
                                    for k, v in tokens.items():
                                        usage["week"][k] += v
                                if file_date == today:
                                    for k, v in tokens.items():
                                        usage["today"][k] += v
                        except json.JSONDecodeError:
                            continue

                    if session_tokens["input"] > 0:
                        usage["sessions"].append({
                            "file": str(jsonl_file.name),
                            "date": str(file_date),
                            **session_tokens
                        })
            except Exception:
                continue

        # Sort sessions by date, keep last 10
        usage["sessions"] = sorted(usage["sessions"], key=lambda x: x["date"], reverse=True)[:10]

        # Calculate estimated costs (rough estimates)
        # Sonnet: $3/M input, $15/M output
        # Opus: $15/M input, $75/M output
        # Using conservative Sonnet estimate
        input_cost = usage["month"]["input"] * 0.000003
        output_cost = usage["month"]["output"] * 0.000015
        usage["estimated_cost_usd"] = round(input_cost + output_cost, 2)

        return {"status": "ok", "usage": usage}
    except Exception as e:
        return {"status": "error", "error": str(e)}


def collect_all() -> dict:
    """Collect AI cost data."""
    return {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "month": MONTH,
        "claude": get_claude_usage(),
    }


def save_raw(data: dict):
    """Save raw data to file."""
    output_dir = RAW_DIR / "costs" / MONTH
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"cost_ai_{DATE}.json"

    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2, default=str)

    print(f"Saved: {output_file}")
    return output_file


if __name__ == "__main__":
    data = collect_all()
    save_raw(data)
