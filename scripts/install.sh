#!/bin/zsh
# Install Gita.app into /Applications (single-copy, atomic backup + rollback) and open it.
#   scripts/install.sh                  install from build/app.noindex/Gita.app (builds if missing)
#   scripts/install.sh --build          rebuild before installing
#   scripts/install.sh --zip <path>     extract a release ZIP into build/Install.noindex/ and install it
#   scripts/install.sh --no-open        install without launching the app afterwards
# Never installs into or falls back to ~/Applications; detects and removes stale ~/Applications copies.
set -euo pipefail

ROOT=${0:A:h:h}
BUNDLE_ID="dev.clevermechanisms.Gita"
APP="$ROOT/build/app.noindex/Gita.app"
DEST="/Applications/Gita.app"
DO_BUILD=0
NO_OPEN=0
ZIP_PATH=""
OPEN_ARGS=()

while (( $# > 0 )); do
  case "$1" in
    --build)
      DO_BUILD=1
      shift
      ;;
    --zip)
      [[ $# -ge 2 ]] || { echo "Missing path after --zip" >&2; exit 2; }
      ZIP_PATH="$2"
      shift 2
      ;;
    --no-open)
      NO_OPEN=1
      shift
      ;;
    -h|--help)
      echo "Usage: scripts/install.sh [--build | --zip <path>] [--no-open] [-- <open args...>]"
      exit 0
      ;;
    --)
      shift
      OPEN_ARGS+=("$@")
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if (( DO_BUILD )) && [[ -n "$ZIP_PATH" ]]; then
  echo "Cannot combine --build and --zip" >&2
  exit 2
fi

if [[ -n "$ZIP_PATH" ]]; then
  [[ -f "$ZIP_PATH" ]] || { echo "ZIP not found: $ZIP_PATH" >&2; exit 1; }
elif (( DO_BUILD )) || [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build.sh"
fi

python3 - "$ROOT" "$APP" "$ZIP_PATH" "$BUNDLE_ID" <<'PY'
import datetime
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys
import time

root = pathlib.Path(sys.argv[1])
default_app = pathlib.Path(sys.argv[2])
zip_path = pathlib.Path(sys.argv[3]).resolve() if sys.argv[3] else None
expected_bundle_id = sys.argv[4]

dest_dir = pathlib.Path('/Applications')
if not dest_dir.is_dir() or not os.access(dest_dir, os.W_OK):
    raise SystemExit('/Applications is not writable; refusing to fall back to ~/Applications.')

destination = dest_dir / 'Gita.app'
workspace = root / 'build/Install.noindex'
backups_dir = root / 'build/Backups.noindex'
lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
unregister_script = str(root / 'scripts/unregister-build-apps.sh')


def unregister(*paths):
    items = [str(p) for p in paths if p and pathlib.Path(p).exists()]
    if items:
        subprocess.run([unregister_script, *items], check=False)


def read_info(bundle: pathlib.Path) -> dict:
    plist_path = bundle / 'Contents/Info.plist'
    if not plist_path.is_file():
        raise RuntimeError(f'Missing Info.plist in {bundle}')
    with plist_path.open('rb') as stream:
        value = plistlib.load(stream)
    if value.get('CFBundleIdentifier') != expected_bundle_id:
        raise RuntimeError(
            f'Refusing to touch bundle with CFBundleIdentifier={value.get("CFBundleIdentifier")!r} '
            f'(expected {expected_bundle_id!r}): {bundle}'
        )
    return value


def verify(bundle: pathlib.Path) -> dict:
    value = read_info(bundle)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    return value


def matching_pids(app_paths) -> list[int]:
    prefixes = [f'{path}/Contents/MacOS/' for path in app_paths]
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    pids = []
    for row in rows:
        parts = row.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid_str, comm = parts
        is_same_bundle = any(comm.startswith(prefix) for prefix in prefixes)
        is_translocated = (
            '/AppTranslocation/' in comm
            and comm.endswith('/Gita.app/Contents/MacOS/Gita')
        )
        if is_same_bundle or is_translocated:
            try:
                pid = int(pid_str)
            except ValueError:
                continue
            if pid != os.getpid():
                pids.append(pid)
    return sorted(set(pids))


workspace.mkdir(parents=True, exist_ok=True)
backups_dir.mkdir(parents=True, exist_ok=True)
extract_dir = workspace / 'extract'
stage = workspace / 'Gita.staged.app'

try:
    if extract_dir.exists():
        for extracted in extract_dir.glob('*.app'):
            unregister(extracted)
        shutil.rmtree(extract_dir)
    if stage.exists():
        unregister(stage)
        shutil.rmtree(stage)

    if zip_path is not None:
        extract_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(zip_path), str(extract_dir)], check=True)
        source = extract_dir / 'Gita.app'
        if not source.is_dir():
            candidates = list(extract_dir.glob('*.app'))
            if len(candidates) == 1:
                source = candidates[0]
            else:
                raise SystemExit(f'ZIP did not contain Gita.app: {zip_path}')
    else:
        source = default_app
        if not source.is_dir():
            raise SystemExit(f'App bundle not found: {source}. Build first with scripts/build.sh.')

    verify(source)
    subprocess.run(['/usr/bin/ditto', str(source), str(stage)], check=True)
    verify(stage)

    # Check both /Applications and ~/Applications so single-copy holds and stale user installs are cleaned up.
    existing_candidates = [
        folder / 'Gita.app'
        for folder in (dest_dir, pathlib.Path.home() / 'Applications')
        if (folder / 'Gita.app').exists()
    ]
    for path in existing_candidates:
        read_info(path)

    stop_targets = existing_candidates if existing_candidates else [destination]
    pids = matching_pids(stop_targets)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 10.0
    while matching_pids(stop_targets) and time.monotonic() < deadline:
        time.sleep(0.2)
    remaining = matching_pids(stop_targets)
    if remaining:
        raise SystemExit(
            f'Gita is still running (PIDs: {remaining}); '
            'the installed application has not been replaced.'
        )

    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    moved = []
    installing = False
    try:
        for index, path in enumerate(existing_candidates):
            backup = backups_dir / f'Gita-{stamp}-{index}.app'
            if backup.exists():
                read_info(backup)
                unregister(backup)
                shutil.rmtree(backup)
            unregister(path)
            shutil.move(str(path), str(backup))
            unregister(backup)
            moved.append((path, backup))

        installing = True
        shutil.move(str(stage), str(destination))
        verify(destination)
    except BaseException:
        if installing and destination.exists():
            if not stage.exists():
                shutil.move(str(destination), str(stage))
            else:
                unregister(destination)
                shutil.rmtree(destination)
        for path, backup in reversed(moved):
            if backup.exists():
                shutil.move(str(backup), str(path))
                if path == destination:
                    subprocess.run([lsregister, '-f', str(path)], check=False)
        raise

    # Archive moved backups as ZIPs and delete the temporary .app copies ONLY when ditto succeeds
    # and produces a non-empty archive so Spotlight/Launch Services never see a second .app bundle
    # in build/, keeping the 3 most recent backup archives.
    for _, backup in moved:
        if backup.is_dir():
            unregister(backup)
            archive = backups_dir / f'{backup.name}.zip'
            result = subprocess.run(
                ['/usr/bin/ditto', '-c', '-k', '--keepParent', str(backup), str(archive)],
                check=False,
            )
            if result.returncode == 0 and archive.is_file() and archive.stat().st_size > 0:
                shutil.rmtree(backup, ignore_errors=True)
            else:
                if archive.exists():
                    try:
                        archive.unlink()
                    except OSError:
                        pass
                print(
                    f'Warning: failed to archive backup {backup} (ditto exited {result.returncode}); keeping backup directory.',
                    file=sys.stderr,
                )

    backups = sorted(
        (p for p in backups_dir.glob('Gita-*.zip') if p.is_file()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for stale_backup in backups[3:]:
        try:
            stale_backup.unlink()
        except Exception:
            pass

    subprocess.run([lsregister, '-f', str(destination)], check=True)
    unregister(default_app)

    info = read_info(destination)
    print(f'==> Installed {destination} ({info.get("CFBundleShortVersionString", "?")} build {info.get("CFBundleVersion", "?")})')
finally:
    for item in (stage, extract_dir / 'Gita.app'):
        unregister(item)
    if workspace.exists():
        shutil.rmtree(workspace, ignore_errors=True)
PY

if (( ! NO_OPEN )); then
  echo "==> Launching"
  open "$DEST" "${OPEN_ARGS[@]}"
fi

"$ROOT/scripts/check-one-copy.sh" "$BUNDLE_ID"
