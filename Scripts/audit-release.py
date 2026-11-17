#!/usr/bin/env python3
"""Fail closed if a public build contains private endpoints or local build paths.

This is a necessary release gate, not a guarantee that arbitrary source code
contains no secrets. Independently review every diff and asset before posting.
"""
from pathlib import Path
import ipaddress
import re
import sys

ROOT=Path(__file__).resolve().parents[1]
APP=Path(sys.argv[1]) if len(sys.argv)>1 else None

# Generic person-specific paths and private network addresses (no actual
# private addresses or named owner domains are embedded in the audit rules).
SENSITIVE = [
  re.compile(rb'/Users/[A-Za-z0-9._-]+/'),
  re.compile(rb'/home/[A-Za-z0-9._-]+/'),
  re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |)PRIVATE KEY-----'),
  re.compile(rb'(?i)gh[pousr]_[A-Za-z0-9]{28,}'),
]
IPV4 = re.compile(rb'(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)')
# A *generic* network allowlist avoids committing any personal hostname to
# the public scanner. This applies to executable app Swift, not medication
# literature citations stored as data in the bundled catalog.
URL_HOST = re.compile(rb'https?://([A-Za-z0-9][A-Za-z0-9.-]{1,245})', re.I)
ALLOWED_RUNTIME_HOSTS = {'github.com', 'api.github.com', 'your-server.example'}


def audit(path: Path) -> list[str]:
    raw=path.read_bytes()
    reasons=[]
    for rule in SENSITIVE:
        if rule.search(raw): reasons.append('person-specific path or private signing material')
    if path.suffix == '.swift' and ('Native' in path.parts or 'Sources' in path.parts):
        for match in URL_HOST.finditer(raw):
            host = match.group(1).decode('ascii', 'ignore').lower().rstrip('.')
            if host not in ALLOWED_RUNTIME_HOSTS:
                reasons.append('runtime URL host not allowlisted for public iOS build')
                break
    for match in IPV4.finditer(raw):
        try:
            addr=ipaddress.ip_address(match.group().decode())
        except ValueError: continue
        if addr.is_private and not addr.is_loopback:
            reasons.append('private IPv4 literal')
            break
    return reasons


def main():
    files=[]
    for root in ('Native','Resources','Sources','Scripts'):
        files += [p for p in (ROOT/root).rglob('*') if p.is_file()]
    files += [ROOT/'project.yml',ROOT/'README.md',ROOT/'PRIVACY.md',ROOT/'SECURITY.md']
    if APP is not None:
        files += [p for p in APP.rglob('*') if p.is_file()]
    defects={str(path.relative_to(ROOT) if path.is_relative_to(ROOT) else path.name):why
             for path in files if (why:=audit(path))}
    if defects:
        for path,reasons in defects.items():
            print(f'RELEASE_AUDIT_FAILED {path}: {", ".join(reasons)}',file=sys.stderr)
        sys.exit(1)
    print(f'RELEASE_AUDIT_PASSED {len(files)} files scanned; no local-user paths, private IPv4 literals or signing keys')

if __name__=='__main__':main()
