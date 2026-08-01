# Third-party provenance

This project downloads tools and artifacts at runtime. None of the listed binaries are committed to this repository.

- Android SDK Platform-Tools 37.0.1: Google Android SDK license. Downloaded from the official Android repository with a pinned size and SHA-256.
- Magisk 30.7: GPL-3.0, maintained by topjohnwu. Its unmodified APK supplies the boot patch script and native binaries used on the connected device.
- `bkerler/edl`: GPL-3.0. The setup command checks out commit `51e11022455d26bcf0b8305b930c474e9b3c81ad` into `.tools/`; this repository does not copy or modify its source.
- `bkerler/Loaders`: the pinned SM_BITRA Firehose loader is downloaded from commit `01c2eb21f52b058a43c31c2c1a1c658abe45a2f1`.
- The full-backup gate, inactive-slot write/read gate, prefix comparison, and validated Qualcomm `devinfo` offsets were adapted from `spavikevik/palma2pro-eos` commit `fc004e35b2fa705a6032929fce951f3b906e1fe3`, licensed Apache-2.0 OR MIT. That project targets the Palma 2 Pro; this implementation independently checks the Note Air 5C model, GPT, magic bytes, field values, active slot, and every write at runtime rather than assuming the layouts match.
- Optional `frp_oemunlock.zip` and `ablmod.zip` recovery artifacts are community attachments from `jdkruzr/BooxPalma2RootGuide` issue 9. They are never downloaded or used unless `-AcceptCommunityArtifacts` is supplied. The normal rooting path does not use them.
- Privacy endpoint and package classifications were researched against `jdkruzr/BOOX_SECURITY.md` (Palma 2 Pro application analysis, 2026), fardjad's `Taming an Onyx Tablet`, quells' BOOX DNS blacklist, and the Universal Android Debloater Next Generation documentation. The optional APK overlay follows Magisk's documented `.replace` module behavior. Their code is not copied. The firewall module and reversible state/restore implementation in this project are original; source URLs and the resulting policy are documented in `README.md` and `config/privacy-policy.json`.

Onyx partition images are always read from the user's own connected device. They are private, device-specific, and must not be redistributed.
