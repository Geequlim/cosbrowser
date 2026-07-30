#!/usr/bin/env bash
set -euo pipefail

# Update cosbrowser-bin AUR package from the official Tencent Cloud "latest"
# Linux zip. There is no versioned download URL and no GitHub release assets,
# so the real version is read from the AppImage filename inside the zip, and
# a change is detected by comparing the zip's sha256 against the one recorded
# in PKGBUILD.

usage() {
  cat <<'EOF'
Usage: ./scripts/update.sh [--check-only] [--format plain|json]

Options:
  --check-only     Only detect whether an update is available.
  --format         Output format for --check-only. Defaults to plain.
  -h, --help       Show this help.
EOF
}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

CHANGELOG_URL="https://raw.githubusercontent.com/TencentCloud/cosbrowser/master/changelog.md"
ZIP_URL="https://cosbrowser.cloud.tencent.com/cosbrowser-latest-linux.zip"
CURL_RETRY_ARGS=(--http1.1 --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30)
ARIA2_MIN_SPLIT_SIZE="${ARIA2_MIN_SPLIT_SIZE:-5M}"

detect_download_connections() {
  local configured="${ARIA2_CONNECTIONS:-}"
  local cpu_count
  local connections

  if [[ -n "$configured" ]]; then
    printf '%s' "$configured"
    return
  fi

  cpu_count="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  if ! [[ "$cpu_count" =~ ^[0-9]+$ ]] || [[ "$cpu_count" -lt 1 ]]; then
    cpu_count=2
  fi

  connections=$(( cpu_count * 2 ))
  if [[ "$connections" -lt 4 ]]; then
    connections=4
  elif [[ "$connections" -gt 16 ]]; then
    connections=16
  fi

  printf '%s' "$connections"
}

download_file() {
  local url="$1"
  local dest="$2"
  local dir_path
  local file_name
  local connections
  local cpu_count

  dir_path="$(dirname "$dest")"
  file_name="$(basename "$dest")"

  if command -v aria2c >/dev/null 2>&1; then
    connections="$(detect_download_connections)"
    cpu_count="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
    echo "Using downloader: aria2c (cpu_count=${cpu_count}, connections=${connections}, min_split_size=${ARIA2_MIN_SPLIT_SIZE})"
    aria2c \
      --allow-overwrite=true \
      --auto-file-renaming=false \
      --continue=true \
      --max-tries=5 \
      --retry-wait=2 \
      --connect-timeout=30 \
      --timeout=30 \
      --summary-interval=0 \
      --console-log-level=warn \
      --file-allocation=none \
      --split="${connections}" \
      --max-connection-per-server="${connections}" \
      --min-split-size="${ARIA2_MIN_SPLIT_SIZE}" \
      --dir="$dir_path" \
      --out="$file_name" \
      "$url"
    return
  fi

  echo "Using downloader: curl"
  curl "${CURL_RETRY_ARGS[@]}" -fL "$url" -o "$dest"
}

# Inspect a downloaded zip without extracting the ~125MB AppImage: list its
# entries and pull the version out of the cosbrowser-<ver>.AppImage filename.
version_from_zip() {
  local zip="$1"
  local entry
  entry=$(bsdtar -tf "$zip" 2>/dev/null \
    | grep -E 'cosbrowser-[0-9][0-9.]*\.AppImage$' \
    | grep -v '__MACOSX' \
    | head -n1 || true)
  if [[ -z "$entry" ]]; then
    return 1
  fi
  # cosbrowser-2.11.26.AppImage -> 2.11.26
  printf '%s' "$entry" | sed -E 's#.*cosbrowser-([0-9][0-9.]+)\.AppImage.*#\1#'
}

changelog_latest_version() {
  # First "## vX.Y.Z - <date>" heading in changelog.md.
  curl "${CURL_RETRY_ARGS[@]}" -fsSL "$CHANGELOG_URL" \
    | grep -E '^## v[0-9]' \
    | head -n1 \
    | sed -E 's/^## v([0-9][0-9.]+).*/\1/' \
    || true
}

FORCE="${FORCE:-false}"
CACHE_DIR="${CACHE_DIR:-}"
CHECK_ONLY=false
OUTPUT_FORMAT="plain"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=true
      ;;
    --format)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --format" >&2
        exit 1
      fi
      OUTPUT_FORMAT="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$OUTPUT_FORMAT" != "plain" && "$OUTPUT_FORMAT" != "json" ]]; then
  echo "Unsupported format: $OUTPUT_FORMAT" >&2
  exit 1
fi

print_detection_result() {
  local status="$1"
  local reason="$2"
  local current_ver="$3"
  local current_sha="$4"
  local latest_ver="$5"
  local latest_sha="$6"
  local changelog_ver="$7"
  local needs_update="$8"

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc \
      --arg status "$status" \
      --arg reason "$reason" \
      --arg current_ver "$current_ver" \
      --arg current_sha "$current_sha" \
      --arg latest_ver "$latest_ver" \
      --arg latest_sha "$latest_sha" \
      --arg changelog_ver "$changelog_ver" \
      --arg FORCE "$FORCE" \
      --argjson needs_update "$needs_update" \
      '{
        status: $status,
        reason: $reason,
        current_ver: $current_ver,
        current_sha: $current_sha,
        latest_ver: $latest_ver,
        latest_sha: $latest_sha,
        changelog_ver: $changelog_ver,
        FORCE: ($FORCE == "true"),
        needs_update: $needs_update
      }'
    return
  fi

  cat <<EOF
status=${status}
reason=${reason}
needs_update=${needs_update}
current_ver=${current_ver}
current_sha=${current_sha}
latest_ver=${latest_ver}
latest_sha=${latest_sha}
changelog_ver=${changelog_ver}
FORCE=${FORCE}
EOF
}

for cmd in jq curl bsdtar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required" >&2
    exit 1
  fi
done

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# The latest zip is the single source of truth for the actual shippable build.
zip_path="$workdir/cosbrowser-linux.zip"

# ---------- zip cache (so re-runs/CI don't redownload 125MB) ----------
cached_zip=""
if [[ -n "$CACHE_DIR" ]]; then
  mkdir -p "$CACHE_DIR"
  cached_zip="${CACHE_DIR}/cosbrowser-latest-linux.zip"
fi

if [[ "$FORCE" != "true" && -n "$cached_zip" && -s "$cached_zip" ]]; then
  # Probe: only reuse the cache if its sha256 still matches the upstream zip.
  echo "Probing upstream zip to validate cache..."
  probe="$workdir/probe.zip"
  if download_file "$ZIP_URL" "$probe"; then
    probe_sha="$(sha256sum "$probe" | awk '{print $1}')"
    cache_sha="$(sha256sum "$cached_zip" | awk '{print $1}')"
    if [[ "$probe_sha" == "$cache_sha" ]]; then
      echo "Using cached zip (sha256 matches upstream): $cached_zip"
      cp -f "$cached_zip" "$zip_path"
    else
      echo "Cache stale (upstream sha256 differs); redownloading."
      cp -f "$probe" "$zip_path"
      cp -f "$zip_path" "$cached_zip"
    fi
  else
    echo "Probe download failed; falling back to cache if present." >&2
    cp -f "$cached_zip" "$zip_path"
  fi
else
  if [[ "$FORCE" == "true" && -n "$cached_zip" && -e "$cached_zip" ]]; then
    echo "[FORCE] Skipping cached zip restore: $cached_zip"
  fi
  echo "Downloading latest zip: $ZIP_URL"
  if ! download_file "$ZIP_URL" "$zip_path"; then
    echo "Failed to download zip: $ZIP_URL" >&2
    exit 1
  fi
  if [[ -n "$cached_zip" ]]; then
    cp -f "$zip_path" "$cached_zip"
    echo "Saved zip to cache: $cached_zip"
  fi
fi

latest_sha="$(sha256sum "$zip_path" | awk '{print $1}')"
latest_ver="$(version_from_zip "$zip_path" || true)"
changelog_ver="$(changelog_latest_version || true)"

if [[ -z "$latest_ver" ]]; then
  echo "Failed to detect version from zip contents" >&2
  exit 1
fi

if [[ -n "$changelog_ver" && "$changelog_ver" != "$latest_ver" ]]; then
  echo "Note: changelog.md top version (${changelog_ver}) differs from the version actually shipped in the latest zip (${latest_ver}). Using the zip version (${latest_ver})." >&2
fi

pkgver=${latest_ver//-/_}

current_ver=$(sed -n 's/^_upstream_ver=//p' PKGBUILD | head -n1 || true)
current_sha=$(sed -n "s/^sha256sums=('\\([0-9a-f]*\\)'.*/\\1/p" PKGBUILD | head -n1 || true)
current_pkgrel=$(sed -n 's/^pkgrel=//p' PKGBUILD | head -n1 || true)

status="up-to-date"
reason="no_change"
needs_update=false

if [[ "$current_ver" != "$latest_ver" || "$current_sha" != "$latest_sha" ]]; then
  status="update-available"
  reason="upstream_changed"
  needs_update=true
elif [[ "$FORCE" == "true" ]]; then
  status="update-available"
  reason="FORCE"
  needs_update=true
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  print_detection_result "$status" "$reason" "$current_ver" "$current_sha" "$latest_ver" "$latest_sha" "${changelog_ver:-}" "$needs_update"
  exit 0
fi

echo "Detection result: status=${status}, reason=${reason}, current=${current_ver:-unknown}@${current_sha:-none}, latest=${latest_ver}@${latest_sha}"

if [[ "$needs_update" != "true" ]]; then
  echo "Already up to date: ${latest_ver}"
  exit 0
fi

if [[ "$reason" == "FORCE" ]]; then
  echo "[FORCE] Upstream unchanged, but forcing refresh for CI test."
fi

pkgrel=1
if [[ "$FORCE" == "true" && "$current_ver" == "$latest_ver" && "$current_sha" == "$latest_sha" ]]; then
  if [[ "$current_pkgrel" =~ ^[0-9]+$ && "$current_pkgrel" -ge 1 ]]; then
    pkgrel=$((current_pkgrel + 1))
  fi
  echo "Refreshing same upstream version; bumping pkgrel to ${pkgrel} so AUR users see a new package revision."
fi

sed -i "s/^_upstream_ver=.*/_upstream_ver=${latest_ver}/" PKGBUILD
sed -i "s/^pkgver=.*/pkgver=${pkgver}/" PKGBUILD
sed -i "s/^pkgrel=.*/pkgrel=${pkgrel}/" PKGBUILD
sed -i "s#^_zip_url=.*#_zip_url=${ZIP_URL}#" PKGBUILD
sed -i "s/^sha256sums=.*/sha256sums=('${latest_sha}')/" PKGBUILD

# Ensure FORCE runs produce a diff, without affecting packaging behavior.
if [[ "$FORCE" == "true" ]]; then
  ts="$(date -u +%Y%m%d%H%M%S)"
  if grep -q '^_FORCE_ts=' PKGBUILD; then
    sed -i "s/^_FORCE_ts=.*/_FORCE_ts=${ts}/" PKGBUILD
  else
    sed -i "1i_FORCE_ts=${ts}" PKGBUILD
  fi
fi

makepkg --printsrcinfo > .SRCINFO

echo "Updated to ${latest_ver}"
