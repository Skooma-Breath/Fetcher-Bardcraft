# Fetcher Bardcraft multiplayer compatibility patch

This repository owns the versioned builder, runtime applier, and stable release
for the Fetcher Bardcraft multiplayer compatibility patch. Keeping it separate
from Fetcher Simulator lets Bardcraft fixes ship without republishing the full
portable OpenMW client. The generated archive does not contain a standalone
copy of Bardcraft.

The builder requires:

- an unmodified Nexus Bardcraft `scripts/Bardcraft` directory;
- the Fetcher-modified client script directory;
- pristine and Fetcher copies of any data-root files patched with `--extra-file`;
- the previous released patch manifest when building an in-place upgrade.

Example:

```powershell
python .\build_patch.py `
  --vanilla-root C:\path\to\vanilla\scripts\Bardcraft `
  --fetcher-root C:\path\to\fetcher\scripts\Bardcraft `
  --output-dir C:\path\to\patch-output `
  --version 2.0.4 `
  --applier .\Apply-Fetcher-Bardcraft-MPPatch.ps1 `
  --previous-manifest C:\path\to\previous\fetcher-bardcraft-mp-patch.json `
  --extra-file Bardcraft.omwscripts `
    C:\path\to\vanilla\Bardcraft.omwscripts `
    C:\path\to\fetcher\Bardcraft.omwscripts `
  --extra-file Bardcraft.ESP `
    C:\path\to\vanilla\Bardcraft.ESP `
    C:\path\to\fetcher\Bardcraft.ESP
```

`priorOutputSha256` records allow known previous patch outputs to upgrade. The
builder carries that ancestry forward transitively, so users can skip patch
releases without being rejected as locally modified. When repairing ancestry
from an older non-transitive manifest, pass every affected released manifest
with repeated `--previous-manifest` arguments. The applier reconstructs
modified upstream files from hash-verified pristine backups and refuses
unknown or locally modified script hashes.

Normal records target `scripts/Bardcraft`. `--extra-file` creates an explicit
`targetBase: data` record for files such as `Bardcraft.omwscripts` and
`Bardcraft.ESP`; target paths are validated and cannot escape the Bardcraft
data root. Binary files are stored as hash-gated deltas, not as independently
usable upstream assets.

The builder writes a payload directory containing the manifest, applier, and
README. After verifying that payload against a local tester installation,
publish it from a clean worktree with:

```powershell
.\release\Publish-FetcherBardcraftPatch.ps1 `
  -PatchDirectory C:\path\to\verified-patch-output
```

The stable prerelease tag and asset name remain
`fetcher-bardcraft-mp-patch-v2` and `fetcher-bardcraft-mp-patch-v2.zip` so the
Fetcher updater can track asset digests without downloading a full client.
