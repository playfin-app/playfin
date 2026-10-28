#!/usr/bin/env bash
set -euo pipefail

# scripts/check-hosts.sh
# Verifies that no real hostnames, server addresses, or disallowed IP addresses
# are committed to the codebase.
#
# Rules (docs/pitfalls.md, Pitfall 13):
# - Strict allowlist:
#   - Documentation subnets (RFC 5737: 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24)
#   - IPv6 documentation prefix (RFC 3849: 2001:db8::/32)
#   - Localhost / loopback / unspecified: 127.0.0.0/8, 0.0.0.0, 255.255.255.255, ::1
#   - Allowed domains: *.example.com, *.example.org, *.example.net, *.test, localhost, *.local, srv-a, srv-b
#   - Approved ecosystem/tooling domains (github.com, apple.com, crates.io, etc.)
# - RFC 1918 private subnets (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) are FORBIDDEN globally.
#   They are only permitted in dedicated unit test files for local discovery / address classification tests:
#   - core/src/discovery.rs
#   - core/src/profiles.rs
#   - macos/Tests/*
#   - docs/pitfalls.md
#   - scripts/check-hosts.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT" << 'EOF'
import sys
import os
import re
import ipaddress
import subprocess

root_dir = sys.argv[1]

# File exemptions for RFC 1918 private subnets in tests
RFC1918_EXEMPTIONS = [
    "core/src/discovery.rs",
    "core/src/profiles.rs",
    "macos/Tests/",
    "docs/pitfalls.md",
    "scripts/check-hosts.sh",
]

# Additional file exemptions for unit test public IPs (e.g., 8.8.8.8 used in is_local_address tests)
PUBLIC_IP_EXEMPTIONS = {
    "8.8.8.8": ["core/src/profiles.rs", "scripts/check-hosts.sh"]
}

# Documentation / standard safe subnets
SAFE_NETWORKS = [
    ipaddress.ip_network("192.0.2.0/24"),      # RFC 5737 TEST-NET-1
    ipaddress.ip_network("198.51.100.0/24"),   # RFC 5737 TEST-NET-2
    ipaddress.ip_network("203.0.113.0/24"),    # RFC 5737 TEST-NET-3
    ipaddress.ip_network("2001:db8::/32"),     # RFC 3849 Documentation IPv6
    ipaddress.ip_network("127.0.0.0/8"),       # Loopback
]

SAFE_SINGLE_IPS = {
    ipaddress.ip_address("0.0.0.0"),
    ipaddress.ip_address("255.255.255.255"),
    ipaddress.ip_address("::1"),
}

RFC1918_NETWORKS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
]

ALLOWED_DOMAIN_SUFFIXES = [
    ".example.com",
    ".example.org",
    ".example.net",
    ".test",
    ".local",
]

ALLOWED_EXACT_DOMAINS = {
    "example.com",
    "example.org",
    "example.net",
    "test",
    "localhost",
    "srv-a",
    "srv-b",
    # Ecosystem, standards, and tooling
    "github.com",
    "raw.githubusercontent.com",
    "apple.com",
    "developer.apple.com",
    "crates.io",
    "rust-lang.org",
    "jellyfin.org",
    "repo.jellyfin.org",
    "w3.org",
    "schema.org",
    "spdx.org",
    "gnu.org",
    "mozilla.org",
    "git-scm.com",
    "conventionalcommits.org",
    "www.conventionalcommits.org",
}

BINARY_EXTENSIONS = (
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf",
    ".zip", ".tar", ".gz", ".bz2", ".xz",
    ".dylib", ".a", ".o", ".so", ".xcframework",
    ".bundle", ".DS_Store"
)

# Match IPv4 addresses
IP_RE = re.compile(r"\b(?P<ip>(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})\b")

# Match URLs to inspect hostnames
URL_RE = re.compile(r"(?i)(?:https?|wss?|ftp)://(?P<host>[a-zA-Z0-9.-]+)(?::\d+)?")

def is_rfc1918_exempt(rel_path):
    for exemption in RFC1918_EXEMPTIONS:
        if exemption.endswith("/") and rel_path.startswith(exemption):
            return True
        if rel_path == exemption:
            return True
    return False

def is_domain_allowed(domain):
    domain = domain.lower()
    if domain in ALLOWED_EXACT_DOMAINS:
        return True
    for suffix in ALLOWED_DOMAIN_SUFFIXES:
        if domain.endswith(suffix):
            return True
    # Subdomains of allowed exact domains
    for base in ALLOWED_EXACT_DOMAINS:
        if domain.endswith("." + base):
            return True
    return False

def check_ip(ip_str, rel_path):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return None  # Not a valid IP

    if ip in SAFE_SINGLE_IPS:
        return None

    for net in SAFE_NETWORKS:
        if ip in net:
            return None

    is_rfc1918 = any(ip in net for net in RFC1918_NETWORKS)
    if is_rfc1918:
        if is_rfc1918_exempt(rel_path):
            return None
        return f"RFC 1918 private IP {ip_str} not allowed outside dedicated test files"

    # Check public IP exemptions
    if ip_str in PUBLIC_IP_EXEMPTIONS:
        if any(rel_path == p or rel_path.startswith(p) for p in PUBLIC_IP_EXEMPTIONS[ip_str]):
            return None

    return f"Disallowed IP address: {ip_str}"

def check_host(host_str, rel_path):
    # If host is an IP, validate as IP
    try:
        ip = ipaddress.ip_address(host_str)
        return check_ip(host_str, rel_path)
    except ValueError:
        pass

    if is_domain_allowed(host_str):
        return None

    return f"Disallowed domain/host: {host_str}"

# Get list of files tracked by git
os.chdir(root_dir)
try:
    res = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True)
    tracked_files = [f for f in res.stdout.strip().split("\n") if f]
except Exception as e:
    print(f"Error listing git files: {e}", file=sys.stderr)
    sys.exit(2)

violations = []

for rel_path in tracked_files:
    if rel_path.endswith(BINARY_EXTENSIONS):
        continue
    full_path = os.path.join(root_dir, rel_path)
    if not os.path.isfile(full_path):
        continue

    try:
        with open(full_path, "r", encoding="utf-8", errors="replace") as f:
            for line_no, line in enumerate(f, start=1):
                # 1. Check URLs for disallowed hosts
                for m in URL_RE.finditer(line):
                    host = m.group("host")
                    err = check_host(host, rel_path)
                    if err:
                        violations.append((rel_path, line_no, err, line.strip()))

                # 2. Check all IP addresses
                for m in IP_RE.finditer(line):
                    ip_match = m.group("ip")
                    err = check_ip(ip_match, rel_path)
                    if err:
                        violations.append((rel_path, line_no, err, line.strip()))
    except Exception as e:
        print(f"Error reading {rel_path}: {e}", file=sys.stderr)

if violations:
    print("❌ Security violation: Disallowed hostnames or IP addresses detected:\n", file=sys.stderr)
    for path, line_no, err, line in violations:
        print(f"  {path}:{line_no}: {err}", file=sys.stderr)
        print(f"    Line: {line}\n", file=sys.stderr)
    sys.exit(1)
else:
    print("✔ All hostnames and IP addresses comply with security allowlist.")
    sys.exit(0)
EOF
