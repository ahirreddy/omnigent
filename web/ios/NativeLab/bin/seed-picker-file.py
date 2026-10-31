#!/usr/bin/env python3
"""Put one harmless text fixture in an iOS simulator's On My iPhone storage."""

import argparse
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("device", help="Booted simulator UDID")
args = parser.parse_args()
groups = subprocess.check_output(
    ["xcrun", "simctl", "get_app_container", args.device, "com.apple.DocumentsApp", "groups"],
    text=True,
)
storage = next(
    Path(line.split("\t", 1)[1]) / "File Provider Storage"
    for line in groups.splitlines()
    if line.startswith("group.com.apple.FileProvider.LocalStorage\t")
)
storage.mkdir(exist_ok=True)
fixture = storage / "Omni native attachment.txt"
fixture.write_text("OMNI_FILE_PICKER_OK\n", encoding="utf-8")
print(fixture)
