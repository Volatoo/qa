#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess


DIGEST = re.compile(r"^[0-9a-f]{64}$")
VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$")
TOP_FIELDS = {"schema", "architecture", "channel", "build_id", "release_index", "installer", "keyring"}
INDEX_FIELDS = {"file", "size", "sha256", "format"}
INSTALLER_FIELDS = {"version", "url", "size", "sha256", "format"}
KEY_FIELDS = {"url", "size", "sha256", "format"}


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def safe_file(path: Path, description: str, maximum: int) -> None:
    if path.is_symlink() or not path.is_file():
        fail(f"{description} is not a regular non-symlink file")
    size = path.stat().st_size
    if size <= 0 or size > maximum:
        fail(f"{description} size is outside the accepted range")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def strict_object(value: object, fields: set[str], description: str) -> dict:
    if not isinstance(value, dict) or set(value) != fields:
        fail(f"{description} fields are invalid")
    return value


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON member {key!r}")
        result[key] = value
    return result


def artifact(value: object, expected_format: str, description: str) -> tuple[dict, Path]:
    record = strict_object(value, KEY_FIELDS if description == "release key" else INSTALLER_FIELDS, description)
    digest = record.get("sha256")
    size = record.get("size")
    url = record.get("url")
    if (
        not isinstance(digest, str)
        or not DIGEST.fullmatch(digest)
        or not isinstance(size, int)
        or isinstance(size, bool)
        or size <= 0
        or not isinstance(url, str)
        or url != f"../../../../objects/sha256/{digest[:2]}/{digest}"
        or record.get("format") != expected_format
    ):
        fail(f"{description} metadata is invalid")
    path = Path("/publication") / "objects" / "sha256" / digest[:2] / digest
    safe_file(path, f"{description} object", 64 * 1024 * 1024)
    if path.stat().st_size != size or sha256_file(path) != digest:
        fail(f"{description} object differs from signed metadata")
    return record, path


def validate_elf(path: Path) -> None:
    size = path.stat().st_size
    with path.open("rb") as executable:
        header = executable.read(64)
        if len(header) != 64 or header[:7] != b"\x7fELF\x02\x01\x01":
            fail("installer is not a little-endian ELF64 executable")
        if struct.unpack_from("<H", header, 16)[0] not in (2, 3):
            fail("installer ELF type is not executable")
        if struct.unpack_from("<H", header, 18)[0] != 62:
            fail("installer is not amd64")
        offset = struct.unpack_from("<Q", header, 32)[0]
        entry_size = struct.unpack_from("<H", header, 54)[0]
        count = struct.unpack_from("<H", header, 56)[0]
        if entry_size < 56 or count == 0 or count > 128 or offset > size or count > (size - offset) // entry_size:
            fail("installer ELF program-header table is invalid")
        executable.seek(offset)
        for _ in range(count):
            header = executable.read(entry_size)
            if len(header) != entry_size or struct.unpack_from("<I", header, 0)[0] == 3:
                fail("installer is truncated or dynamically linked")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--document", required=True, type=Path)
    parser.add_argument("--signature", required=True, type=Path)
    parser.add_argument("--trusted-key", required=True, type=Path)
    parser.add_argument("--installer", required=True, type=Path)
    parser.add_argument("--keyring-output", required=True, type=Path)
    args = parser.parse_args()

    safe_file(args.document, "live-media input document", 1024 * 1024)
    safe_file(args.signature, "live-media input signature", 64 * 1024)
    safe_file(args.trusted_key, "bootstrap release key", 64 * 1024)
    safe_file(args.installer, "locally built installer", 64 * 1024 * 1024)
    try:
        subprocess.run(
            ["signify", "-V", "-p", str(args.trusted_key), "-m", str(args.document), "-x", str(args.signature)],
            check=True,
        )
    except subprocess.CalledProcessError:
        fail("live-media input signature verification failed")

    try:
        document = json.loads(
            args.document.read_text(encoding="utf-8"), object_pairs_hook=unique_object
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        fail(f"live-media input document is invalid JSON: {error}")
    top = strict_object(document, TOP_FIELDS, "live-media input document")
    if (
        top["schema"] != "org.volatoo.live-media-inputs/v1"
        or top["architecture"] != "amd64"
        or top["channel"] != "v0.1-dev"
        or not isinstance(top["build_id"], str)
        or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", top["build_id"])
    ):
        fail("live-media input identity is invalid")
    canonical = (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if args.document.read_bytes() != canonical:
        fail("live-media input document is not canonical JSON")

    release_index = strict_object(top["release_index"], INDEX_FIELDS, "release index binding")
    index_path = args.document.with_name("index.json")
    if (
        release_index.get("file") != "index.json"
        or release_index.get("format") != "release-index-v1"
        or not isinstance(release_index.get("size"), int)
        or isinstance(release_index.get("size"), bool)
        or release_index["size"] <= 0
        or not isinstance(release_index.get("sha256"), str)
        or not DIGEST.fullmatch(release_index["sha256"])
    ):
        fail("release index binding metadata is invalid")
    safe_file(index_path, "bound release index", 16 * 1024 * 1024)
    if (
        index_path.stat().st_size != release_index["size"]
        or sha256_file(index_path) != release_index["sha256"]
    ):
        fail("release index differs from the signed live-media binding")

    installer, installer_object = artifact(top["installer"], "elf64-static", "installer")
    version = installer.get("version")
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        fail("installer version is invalid")
    validate_elf(installer_object)
    validate_elf(args.installer)
    if (
        args.installer.stat().st_size != installer["size"]
        or sha256_file(args.installer) != installer["sha256"]
    ):
        fail("locally built installer differs from the signed live-media input")
    try:
        actual_version = subprocess.run(
            [str(args.installer), "version"], check=True, capture_output=True, text=True
        ).stdout.strip()
    except subprocess.CalledProcessError:
        fail("locally built installer could not report its version")
    if actual_version != version:
        fail("locally built installer version differs from signed metadata")

    keyring = top["keyring"]
    if not isinstance(keyring, list) or len(keyring) != 1:
        fail("live-media keyring must contain exactly one release key")
    _, key_object = artifact(keyring[0], "signify-public-key", "release key")
    if key_object.read_bytes() != args.trusted_key.read_bytes():
        fail("signed live-media key differs from the bootstrap release key")
    if args.keyring_output.exists() or args.keyring_output.is_symlink():
        fail("keyring output already exists")
    args.keyring_output.mkdir(mode=0o755)
    destination = args.keyring_output / f"{sha256_file(key_object)}.pub"
    with key_object.open("rb") as source, destination.open("xb") as output:
        shutil.copyfileobj(source, output)
    os.chmod(destination, 0o644)
    print(f"verified signed live-media inputs for installer {version}")


if __name__ == "__main__":
    main()
