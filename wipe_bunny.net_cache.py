#!/usr/bin/env python3
"""Wipe the cache for all Bunny.net CDN pull zones."""

import json
import os
import sys
import urllib.request
import urllib.error

API_BASE = "https://api.bunny.net"
CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "/root/bin/config.json")


def get_all_pullzones(api_key):
    """Fetch all pull zones, handling pagination."""
    pullzones = []
    page = 1

    while True:
        url = f"{API_BASE}/pullzone?page={page}&perPage=1000"
        req = urllib.request.Request(url, headers={"AccessKey": api_key})

        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())

        if isinstance(data, list):
            # API returns a plain list when no pagination wrapper
            return data

        pullzones.extend(data["Items"])

        if not data.get("HasMoreItems", False):
            break
        page += 1

    return pullzones


def purge_cache(api_key, pullzone_id):
    """Purge the cache for a single pull zone. Returns True on success."""
    url = f"{API_BASE}/pullzone/{pullzone_id}/purgeCache"
    req = urllib.request.Request(
        url,
        data=b"{}",
        headers={
            "AccessKey": api_key,
            "Content-Type": "application/json",
        },
        method="POST",
    )

    with urllib.request.urlopen(req) as resp:
        return resp.status == 204


def load_api_key():
    """Load API key from environment variable or .config file."""
    api_key = os.environ.get("BUNNY_API_KEY")
    if api_key:
        return api_key

    if os.path.isfile(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            config = json.load(f)
        api_key = config.get("bunny_net_api_key")
        if api_key:
            return api_key

    print(
        "Error: API key not found. Set BUNNY_API_KEY env var or"
        " add it to .config as {\"bunny_net_api_key\": \"...\"}.",
        file=sys.stderr,
    )
    sys.exit(1)


def main():
    api_key = load_api_key()

    print("Fetching pull zones...")
    try:
        pullzones = get_all_pullzones(api_key)
    except urllib.error.HTTPError as e:
        print(f"Error fetching pull zones: HTTP {e.code} {e.reason}", file=sys.stderr)
        sys.exit(1)

    if not pullzones:
        print("No pull zones found.")
        return

    print(f"Found {len(pullzones)} pull zone(s).\n")

    success = 0
    failed = 0

    for pz in pullzones:
        pz_id = pz["Id"]
        pz_name = pz.get("Name", "unnamed")
        print(f"Purging cache for '{pz_name}' (ID: {pz_id})... ", end="", flush=True)

        try:
            purge_cache(api_key, pz_id)
            print("OK")
            success += 1
        except urllib.error.HTTPError as e:
            print(f"FAILED (HTTP {e.code} {e.reason})")
            failed += 1

    print(f"\nDone. {success} succeeded, {failed} failed.")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()

