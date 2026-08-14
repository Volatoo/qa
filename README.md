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
