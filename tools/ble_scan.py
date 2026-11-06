#!/usr/bin/env python3
"""Read-only BLE scanner / GATT inventory for E900EarPhoneCam.

Uses Bleak on macOS; never calls write_gatt_char, pairs, or triggers OTA.
Peripheral opaque identifiers are intentionally not printed.
"""
from __future__ import annotations

import argparse
import asyncio
import sys
from collections.abc import Mapping

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    print("Missing dependency: python -m pip install bleak", file=sys.stderr)
    raise SystemExit(2)


def display_name(device, advertisement) -> str:
    return advertisement.local_name or device.name or "(unnamed BLE device)"


async def scan(seconds: float):
    print(f"Scanning BLE for {seconds:g}s (read-only, no writes)...")
    # Return advertisement objects to record the locally advertised service UUIDs.
    discovered = await BleakScanner.discover(timeout=seconds, return_adv=True)
    entries = list(discovered.values())
    entries.sort(key=lambda item: (display_name(*item).lower(), -item[1].rssi))
    if not entries:
        print("No BLE advertisements detected. Check Bluetooth permission, power and GlassX connection.")
        return entries

    for index, (device, advertisement) in enumerate(entries, start=1):
        print(f"\n[{index}] {display_name(device, advertisement)}")
        print(f"    RSSI: {advertisement.rssi} dBm")
        advertised = sorted(advertisement.service_uuids or [])
        print(f"    Advertised services: {', '.join(advertised) if advertised else '(none in advertisement)'}")
        # Show manufacturer company IDs only; not payload, address or personal identifiers.
        mfg = sorted((advertisement.manufacturer_data or {}).keys())
        if mfg:
            print(f"    Manufacturer company IDs: {', '.join(hex(company) for company in mfg)}")
    return entries


async def inspect(device, timeout: float) -> int:
    print("\nConnecting to selected BLE device for GATT inventory (NO writes)...")
    async with BleakClient(device, timeout=timeout) as client:
        print(f"Connected: {client.is_connected}")
        services = client.services
        n_services = 0
        n_characteristics = 0
        for service in services:
            n_services += 1
            print(f"\nSERVICE  {service.uuid}  {service.description}")
            for characteristic in service.characteristics:
                n_characteristics += 1
                props = ", ".join(characteristic.properties)
                print(f"  CHAR   {characteristic.uuid}  [{props}]")
        print(f"\nInventory complete: {n_services} services / {n_characteristics} characteristics.")
        print("No GATT writes, reads of characteristic values, pairing, or OTA were performed.")
    return 0


async def main(args) -> int:
    entries = await scan(args.scan_seconds)
    if args.connect is None:
        print("\nTo inspect a device, run again with --connect <index>.")
        print("The list is recreated on every run; verify the name shown before proceeding.")
        return 0

    index = args.connect - 1
    if index < 0 or index >= len(entries):
        print(f"Invalid index {args.connect}: valid range is 1..{len(entries)}", file=sys.stderr)
        return 2

    selected, advertisement = entries[index]
    print(f"\nSelected [{args.connect}] {display_name(selected, advertisement)}")
    # An explicit confirmation reduces accidental connections to unrelated BLE peripherals.
    print("Confirm this is your E900. This action only enumerates GATT (no writes).")
    if not args.yes:
        answer = input("Connect? [y/N] ").strip().lower()
        if answer not in {"y", "yes"}:
            print("Cancelled.")
            return 0
    return await inspect(selected, args.timeout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scan-seconds", type=float, default=15.0)
    parser.add_argument("--connect", type=int, metavar="INDEX",
                        help="Connect to this scan-list index for read-only GATT inventory")
    parser.add_argument("--timeout", type=float, default=20.0,
                        help="Connection timeout in seconds")
    parser.add_argument("--yes", action="store_true",
                        help="Skip interactive selection confirmation")
    arguments = parser.parse_args()
    if arguments.scan_seconds <= 0 or arguments.timeout <= 0:
        parser.error("--scan-seconds and --timeout must be > 0")
    try:
        raise SystemExit(asyncio.run(main(arguments)))
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled by user.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"BLE error: {type(exc).__name__}: {exc}", file=sys.stderr)
        print("Check Bluetooth privacy permission, E900 power, and GlassX connection.", file=sys.stderr)
        raise SystemExit(1)
