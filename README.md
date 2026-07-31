# cosbrowser-bin

Repackage the official Tencent Cloud **COSBrowser** client into an Arch Linux
package and publish to AUR.

COSBrowser ships as an AppImage bundled inside a `cosbrowser-latest-linux.zip`.
This package extracts that AppImage, installs the unpacked app into
`/opt/cosbrowser`, and wires up a desktop entry, a hicolor icon, and a
`cosbrowser` wrapper script.

## How it works

Because Tencent does **not** publish versioned download URLs or GitHub release
assets, the updater works in two stages:

1. **Fast probe**: issue a lightweight `HEAD` against the latest zip and
   compare the upstream `ETag`/`Last-Modified` with the values recorded in
   `.upstream-probe`. If they match, the zip is unchanged and the run
   short-circuits **without downloading the ~119MB file** — the nightly check
   stays cheap.
2. **Full check** (only when the probe sees a change): download
   `https://cosbrowser.cloud.tencent.com/cosbrowser-latest-linux.zip`, read the
   real version from the `cosbrowser-<ver>.AppImage` filename inside it, and
   detect changes by comparing the zip's `sha256` against the value recorded in
   `PKGBUILD`. The probe state is then refreshed in `.upstream-probe`.

For a human-readable reference version it also peeks at the top of
`https://github.com/TencentCloud/cosbrowser/blob/master/changelog.md`.

> **Note:** the `latest` zip sometimes lags behind `changelog.md`'s top entry
> (e.g. the changelog may announce `2.12.2` while the zip still ships
> `2.11.26`). The package always uses the version actually present in the zip,
> since that is what users will actually run.

The wrapper script (`/usr/bin/cosbrowser`) launches the app with both required
flags: `--no-sandbox` (no SUID `chrome-sandbox` under `/opt`) and
`--disable-gpu` (avoids GPU init failures / blank window on some setups). It
also prefers XWayland on hybrid-GPU Wayland sessions, mirroring the
`layaair-ide` workaround for black-window Electron bugs.

## Local update

```bash
./scripts/update.sh
```

Check only, without downloading:

```bash
./scripts/update.sh --check-only
./scripts/update.sh --check-only --format json
```

Large zip downloads prefer `aria2c` automatically when available. You can
override the auto-detected parallel connections with `ARIA2_CONNECTIONS`, and
tune split size with `ARIA2_MIN_SPLIT_SIZE`.

## GitHub Actions (nightly)

The workflow runs every night and pushes updates to GitHub and AUR.

If upstream silently replaces the zip without changing its contents/version,
run the workflow manually with `force=true` to force a redownload, recompute
`sha256sums`, and bump `pkgrel` for a new AUR revision.

Required secrets:

- `AUR_SSH_PRIVATE_KEY` (private key with access to `aur.archlinux.org`)

Optional:

- If you change the AUR package name, update `AUR_PKGNAME` in
  `.github/workflows/auto-update.yml`.
