#!/usr/bin/env python3
"""Compare default values between default.cfg and overlay_settings.json.

Shows three categories:
  DIFF — key exists in both files but the values disagree
  MISS — key is in the JSON but not in default.cfg (expected for custom
         overlay items like shortcuts, cpu_mode, and Rice-specific keys)
  OK   — values match (hidden by default; pass --all to show)

Items targeting [Video-Rice] or [NextUI] INI sections are hidden by default
since default.cfg only contains [Video-GLideN64] and core sections. Pass
--include-all-sections to show them.

Usage:
  python3 scripts/check-defaults.py
  python3 scripts/check-defaults.py --all                  # include OK items
  python3 scripts/check-defaults.py --include-all-sections  # include Rice/NextUI
  python3 scripts/check-defaults.py --cfg path/to/default.cfg --json path/to/overlay_settings.json
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def parse_ini(path: Path) -> Dict[str, Dict[str, str]]:
    """Parse a mupen64plus-style INI file into {section: {key: value}}."""
    sections: Dict[str, Dict[str, str]] = {}
    cur = ""
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            cur = stripped.strip("[]")
            sections.setdefault(cur, {})
        elif "=" in stripped and not stripped.startswith(("#", ";")):
            k, v = stripped.split("=", 1)
            sections.setdefault(cur, {})[k.strip()] = v.strip()
    return sections


def normalize(item: dict, ini_val: Optional[str]) -> Tuple[str, Optional[str]]:
    """Return (json_normalized, ini_normalized) for comparison."""
    json_default = item.get("default", "N/A")
    item_type = item.get("type", "")
    float_scale = item.get("float_scale", 0)

    # JSON side
    if item_type == "bool":
        json_norm = "True" if json_default else "False"
    elif float_scale and float_scale > 0:
        json_norm = f"{json_default / float_scale:.6f}"
    else:
        json_norm = str(json_default)

    # INI side
    if ini_val is None:
        return json_norm, None

    ini_clean = ini_val.strip("\"'")
    if item_type == "bool":
        ini_norm = "True" if ini_clean.lower() in ("true", "1") else "False"
    elif float_scale and float_scale > 0:
        try:
            ini_norm = f"{float(ini_clean):.6f}"
        except ValueError:
            ini_norm = ini_clean
    else:
        ini_norm = ini_clean

    return json_norm, ini_norm


def main() -> None:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--cfg",
        default=repo / "config/shared/default.cfg",
        type=Path,
        help="Path to default.cfg",
    )
    parser.add_argument(
        "--json",
        default=repo / "config/shared/overlay_settings.json",
        type=Path,
        dest="json_path",
        help="Path to overlay_settings.json",
    )
    parser.add_argument("--all", action="store_true", help="Show OK items too")
    parser.add_argument(
        "--include-all-sections",
        action="store_true",
        help="Include items targeting [Video-Rice] and [NextUI] (hidden by default)",
    )
    args = parser.parse_args()

    IGNORED_SECTIONS = {"Video-Rice", "NextUI", "NextUI-Input"}


    ini = parse_ini(args.cfg)
    with open(args.json_path, encoding="utf-8") as f:
        cfg = json.load(f)

    global_section = cfg.get("config_section", "")
    rows: List[Tuple[str, str, str, str, str, str]] = []

    for sec in cfg["sections"]:
        sec_ini = sec.get("ini_section", global_section)
        for item in sec["items"]:
            key = item["key"]
            item_ini_sec = item.get("ini_section", sec_ini)
            if not args.include_all_sections and item_ini_sec in IGNORED_SECTIONS:
                continue
            ini_val = ini.get(item_ini_sec, {}).get(key)

            json_norm, ini_norm = normalize(item, ini_val)

            if ini_val is None:
                status = "MISS"
                ini_display = "<missing>"
            elif json_norm == ini_norm:
                status = "OK"
                ini_display = ini_val
            else:
                status = "DIFF"
                ini_display = ini_val

            json_display = str(item.get("default", "N/A"))
            rows.append(
                (
                    status,
                    sec["name"],
                    key,
                    json_display,
                    ini_display,
                    f"[{item_ini_sec}]",
                )
            )

    # Print
    hdr = f"{'Status':<6} {'Section':<25} {'Key':<45} {'JSON default':<15} {'INI value':<15} {'INI section'}"
    print(hdr)
    print("-" * len(hdr))

    counts = {"OK": 0, "DIFF": 0, "MISS": 0}
    for status, sec_name, key, json_d, ini_d, ini_sec in rows:
        counts[status] += 1
        if status == "OK" and not args.all:
            continue
        print(
            f"{status:<6} {sec_name:<25} {key:<45} {json_d:<15} {ini_d:<15} {ini_sec}"
        )

    print()
    print(f"OK: {counts['OK']}  DIFF: {counts['DIFF']}  MISS: {counts['MISS']}")
    if counts["DIFF"] > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
