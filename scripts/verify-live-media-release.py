#!/usr/bin/env python3

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


DIGEST = re.compile(r"^[0-9a-f]{64}$")
TOP_FIELDS = {
    "schema", "architecture", "channel", "build_id", "init_system", "iso",
    "build_manifest", "release_index", "live_media_inputs",
}
ARTIFACT_FIELDS = {"file", "format", "size", "sha256"}
MANIFEST_FIELDS = {
    "schema", "channel", "init_system", "iso_file", "iso_size",
    "iso_sha256", "rootfs_sha256", "release_index_sha256",
    "installer_sha256", "release_key_sha256",
}


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def safe_file(path: Path, description: str, maximum: int) -> None:
    if path.is_symlink() or not path.is_file():
        fail(f"{description} is not a regular non-symlink file")
    size = path.stat().st_size
    if size <= 0 or size > maximum:
        fail(f"{description} size is outside the accepted range")


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON member {key!r}")
        result[key] = value
    return result


def exact(value: object, fields: set[str], description: str) -> dict:
    if not isinstance(value, dict) or set(value) != fields:
        fail(f"{description} fields are invalid")
    return value


def parse_manifest(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or "=" not in line:
            fail("live ISO manifest contains an invalid record")
        key, value = line.split("=", 1)
        if not key or not value or key in values:
            fail("live ISO manifest contains an invalid or duplicate field")
        values[key] = value
    if set(values) != MANIFEST_FIELDS:
        fail("live ISO manifest fields are invalid")
    return values


def validate_artifact(
    value: object,
    path: Path,
    expected_file: str,
    expected_format: str,
    description: str,
) -> dict:
    artifact = exact(value, ARTIFACT_FIELDS, description)
    if (
        artifact["file"] != expected_file
        or artifact["format"] != expected_format
        or not isinstance(artifact["size"], int)
        or isinstance(artifact["size"], bool)
        or artifact["size"] != path.stat().st_size
        or not isinstance(artifact["sha256"], str)
        or not DIGEST.fullmatch(artifact["sha256"])
        or artifact["sha256"] != digest_file(path)
    ):
        fail(f"{description} differs from its signed release descriptor")
    return artifact


def main() -> None:
    iso = Path("/input/live.iso")
    manifest_path = Path("/input/live.iso.manifest")
    descriptor_path = Path("/input/live-media.json")
    signature_path = Path("/input/live-media.json.sig")
    public_key = Path("/input/release.pub")
    for path, description, maximum in (
        (iso, "live ISO", 16 * 1024 * 1024 * 1024),
        (manifest_path, "live ISO manifest", 1024 * 1024),
        (descriptor_path, "live-media descriptor", 1024 * 1024),
        (signature_path, "live-media signature", 1024 * 1024),
        (public_key, "release public key", 1024 * 1024),
    ):
        safe_file(path, description, maximum)
    try:
        subprocess.run(
            ["signify", "-V", "-p", str(public_key), "-m", str(descriptor_path),
             "-x", str(signature_path)],
            check=True,
        )
    except subprocess.CalledProcessError:
        fail("live-media signature verification failed")

    raw = descriptor_path.read_bytes()
    try:
        document = json.loads(raw.decode(), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"live-media descriptor is invalid JSON: {error}")
    if raw != (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode():
        fail("live-media descriptor is not canonical JSON")
    top = exact(document, TOP_FIELDS, "live-media descriptor")
    if (
        top["schema"] != "org.volatoo.live-media-release/v1"
        or top["architecture"] != "amd64"
        or top["channel"] != "v0.1-dev"
        or not isinstance(top["build_id"], str)
        or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", top["build_id"])
        or top["init_system"] not in ("openrc", "systemd")
    ):
        fail("live-media descriptor identity is invalid")

    iso_name = os.environ.get("ISO_NAME", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.iso", iso_name):
        fail("live ISO filename is invalid")
    iso_artifact = validate_artifact(
        top["iso"], iso, iso_name, "iso9660-hybrid", "live ISO"
    )
    manifest_artifact = validate_artifact(
        top["build_manifest"], manifest_path, iso_name + ".manifest",
        "live-media-manifest-v1", "live ISO manifest",
    )
    index = exact(top["release_index"], ARTIFACT_FIELDS, "release index")
    live_inputs = exact(
        top["live_media_inputs"], ARTIFACT_FIELDS, "live-media inputs"
    )
    for artifact, expected_file, expected_format, description in (
        (index, "index.json", "release-index-v1", "release index"),
        (live_inputs, "live-media-inputs.json", "live-media-inputs-v1", "live-media inputs"),
    ):
        if (
            artifact["file"] != expected_file
            or artifact["format"] != expected_format
            or not isinstance(artifact["size"], int)
            or isinstance(artifact["size"], bool)
            or artifact["size"] <= 0
            or not isinstance(artifact["sha256"], str)
            or not DIGEST.fullmatch(artifact["sha256"])
        ):
            fail(f"{description} binding is invalid")

    manifest = parse_manifest(manifest_path)
    try:
        manifest_iso_size = int(manifest["iso_size"])
    except ValueError:
        fail("live ISO manifest size is invalid")
    if (
        manifest["schema"] != "org.volatoo.live-media/v1"
        or manifest["channel"] != top["channel"]
        or manifest["init_system"] != top["init_system"]
        or manifest["iso_file"] != iso_name
        or manifest_iso_size != iso_artifact["size"]
        or manifest["iso_sha256"] != iso_artifact["sha256"]
        or manifest["release_index_sha256"] != index["sha256"]
        or manifest["release_key_sha256"] != digest_file(public_key)
        or manifest_artifact["sha256"] != digest_file(manifest_path)
    ):
        fail("live ISO manifest differs from its signed release descriptor")
    print("verified signed live-media release descriptor")


if __name__ == "__main__":
    main()
