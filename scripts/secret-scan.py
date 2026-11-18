#!/usr/bin/env python3
"""Scan source/docs for key material and prohibited credential-store APIs."""
import pathlib, re, subprocess, sys
files = subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0')
patterns = [r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', r'\bgh[pousr]_[A-Za-z0-9]{30,}', r'\bsk_live_[A-Za-z0-9]{20,}']
failed = []
for name in files:
    path = pathlib.Path(name)
    if not path.is_file() or path.suffix in {'.png', '.icns'}: continue
    text = path.read_text(errors='replace')
    if any(re.search(p, text) for p in patterns): failed.append(name + ': possible secret')
    # The app stores no credential: nothing may import Security or call the Keychain.
    if name.startswith('Sources/') and re.search(r'\bSecItem(?:Add|Update|Delete|CopyMatching)\s*\(|import Security\b', text): failed.append(name + ': prohibited Keychain API')
if failed:
    print('\n'.join(failed)); sys.exit(1)
print('Source secret and Keychain-API scan passed (no Security framework use)')
