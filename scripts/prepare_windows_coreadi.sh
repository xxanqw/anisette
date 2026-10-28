#!/usr/bin/env bash
# Extract the native Windows CoreADI library from Apple's official iTunes installer.
# Apple's proprietary DLLs remain local and are not packaged in Git or Docker.
set -euo pipefail

for tool in curl 7z msiextract sha256sum find cp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing dependency: %s\n' "$tool" >&2
    printf 'Install curl, p7zip (7z), and msitools on the host.\n' >&2
    exit 1
  fi
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname -- "$script_dir")"
destination="$project_dir/apple-windows"

if [ -e "$destination" ]; then
  printf 'Refusing to overwrite existing directory: %s\n' "$destination" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

printf 'Downloading iTunes 64-bit directly from Apple...\n'
curl --fail --location --retry 3 --output "$work_dir/iTunes64Setup.exe" \
  'https://www.apple.com/itunes/download/win64'

printf 'Downloaded installer SHA-256: '
sha256sum "$work_dir/iTunes64Setup.exe"

mkdir -p "$work_dir/setup" "$work_dir/extracted"
7z x -y "-o$work_dir/setup" "$work_dir/iTunes64Setup.exe" >/dev/null

mapfile -d '' -t msi_packages < <(find "$work_dir/setup" -type f -iname '*.msi' -print0)
if [ "${#msi_packages[@]}" -eq 0 ]; then
  printf 'The Apple installer did not contain any MSI packages.\n' >&2
  exit 1
fi

# Newer iTunes installers integrate Apple Application Support into other MSIs.
# Inspect every embedded package instead of assuming a specific filename.
for msi in "${msi_packages[@]}"; do
  msi_name="$(basename -- "$msi")"
  extraction_dir="$work_dir/extracted/$msi_name"
  mkdir -p "$extraction_dir"
  printf 'Inspecting Apple MSI: %s\n' "$msi_name"
  if ! msiextract -C "$extraction_dir" "$msi" >/dev/null; then
    printf 'Warning: could not unpack %s; continuing.\n' "$msi_name" >&2
  fi
done

dll="$(find "$work_dir/extracted" -type f -iname 'CoreADI64.dll' -print -quit)"
if [ -z "$dll" ]; then
  printf 'CoreADI64.dll not found in the extracted installer.\n' >&2
  exit 1
fi

mkdir -p "$destination"
cp -a -- "$(dirname -- "$dll")/." "$destination/"
# DLLs are not credentials; the unprivileged container must be able to read them.
chmod -R a+rX "$destination"

printf 'Prepared %s\n' "$destination/CoreADI64.dll"
printf 'Apple DLLs stay local. Start the experiment using:\n'
printf '  docker compose -f compose.windows.yaml up --build -d\n'
