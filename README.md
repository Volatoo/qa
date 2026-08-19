# Volatoo quality assurance

Cross-repository qualification for complete Volatoo systems and releases.

## Owns

- QEMU BIOS/UEFI and OpenRC/systemd compatibility matrices;
- upgrade, rollback, persistence, installer, and failure-recovery scenarios;
- reference-hardware qualification and performance baselines;
- release-candidate evidence formats and cross-repository contract tests.

Unit and component integration tests stay with their source repositories. This
repository owns tests only when the subject is a complete composed system or a
contract between independently versioned repositories.

Existing end-to-end tests remain in `Volatoo/Volatoo` until their fixtures and
inputs can pin released revisions of every participating repository.

## Installer release Gate

The first cross-repository Gate consumes a signed releng publication. It first
verifies the separate live-media-inputs v1 signature, checks that its CAS
installer is byte-identical to the independently built installer repository,
checks that the document is bound to the exact release index, and materializes
the authenticated release keyring. It then runs the formal installer against
explicit loop devices and boots both resulting raw disks through the main
repository's BIOS and UEFI OrbStack QEMU runner:

```sh
scripts/test-installer-release-docker.sh \
  --installer-repo /path/to/installer \
  --volatoo-repo /path/to/Volatoo \
  --publication /path/to/releng-publication \
  --trusted-key /path/to/release.pub \
  out/installed-release
```

Every repository path is explicit. The Gate never selects a host disk and the
only destructive targets are loop devices backed by new files in its private
staging directory.

## Live-media installer Gate

The live-media Gate boots an authenticated hybrid ISO in the OrbStack QEMU
runner, reaches it with a QA-only key supplied through a separate state image,
and invokes the installer shipped inside the live system. Installation uses the
ISO-local signed release index and CAS publication without network access. The
new explicit target image is then booted under BIOS and UEFI:

```sh
scripts/test-live-installer-docker.sh \
  --volatoo-repo /path/to/Volatoo \
  --iso /path/to/volatoo-live-openrc.iso \
  --state /path/to/qa-live-state.ext4 \
  --descriptor /path/to/live-media.json \
  --signature /path/to/live-media.json.sig \
  --trusted-key /path/to/release.pub \
  --ssh-private-key /path/to/qa-key \
  --init-system openrc \
  out/installed-openrc.img
```

Run the same Gate with `--init-system systemd` to qualify the systemd object
from the same signed publication. The QA key is never embedded in production
media, and every destructive operation remains confined to the newly created
target image.

Before QEMU starts, the Gate verifies the releng signature over the canonical
live-media release descriptor and checks the complete ISO and build-manifest
digests. A modified ISO is therefore rejected before any guest or target disk
is created.
