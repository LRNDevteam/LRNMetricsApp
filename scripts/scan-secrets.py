#!/usr/bin/env python3
"""
Scan every git-TRACKED file for credential-shaped strings.

    python scripts/scan-secrets.py            # report
    python scripts/scan-secrets.py --ci       # exit 1 if anything actionable is found

Only tracked files are scanned. A file on somebody's disk is not a repository exposure, and
including build output buries the real findings.

Values are always masked. The report answers "which file, which line, what kind" - anyone entitled
to the value already has the file.

The patterns are deliberately anchored to the shape a credential takes in configuration rather than
to the word alone. "password" appears constantly in ordinary code - `var pwd = getElementById(...)`,
a `Password` model property, a column name - and a scanner that reports all of it gets ignored,
which is worse than no scanner.
"""
import argparse
import collections
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

PATTERNS = [
    # Connection-string credential: the value must be closed by ';' or a quote, which is what
    # separates "Password=abc;" in a connection string from "pwd = document.getElementById(...)".
    ('password', re.compile(r'''(?i)\b(?:password|pwd)\s*=\s*(?P<v>[^;"'\s,}\\]+)\s*(?=[;"'])''')),

    # The rest only count as findings when written as a JSON/config assignment.
    ('api key',         re.compile(r'(?i)"(?:ImportApiKey|ApiKey|Api_Key)"\s*:\s*"(?P<v>[^"]{4,})"')),
    ('jwt signing key', re.compile(r'(?i)"JwtSigningKey"\s*:\s*"(?P<v>[^"]{4,})"')),
    ('secret hash',     re.compile(r'(?i)"SecretHash"\s*:\s*"(?P<v>[^"]{4,})"')),
    ('client secret',   re.compile(r'(?i)"ClientSecret"\s*:\s*"(?P<v>[^"]{4,})"')),
    ('storage key',     re.compile(r'(?i)\bAccountKey\s*=\s*(?P<v>[^;"\s]{8,})')),
    ('sas token',       re.compile(r'(?i)\bSharedAccessSignature\s*=\s*(?P<v>[^;"\s]{8,})')),

    # Not a secret, but it defeats the encryption the connection claims to have: the certificate
    # is never validated, so anything in the network path can read the traffic.
    ('cert check off',  re.compile(r'(?i)\b(?:TrustServerCertificate)\s*=\s*(?P<v>True)\b')),
]

# Anything that is plainly a stand-in rather than a live value.
PLACEHOLDER = re.compile(
    r'''(?ix)
    ^(
        | ""|'' | \*+ | x+
        | placeholder | changeme | todo | none | null | empty
        | your[-_ ]?\w* | YOUR_[A-Z_]+
        | PUT_[A-Z_]+ | [A-Z_]{6,}_HERE
        | <[^>]*>                      # <demo-password>
        | \{\{?[^}]*\}?\}              # {{ secret }}
        | \$\([^)]*\) | \$\w+          # $(Password), $Password - a variable, not a value
        | %[A-Z_]+%
        | set[-_ ]?in[-_ ]?\w+ | from[-_ ]?vault
        | \*\*\*MASKED\*\*\* | MASKED
    )$''')

# A value that is an expression rather than a literal. The password pattern has to stay loose
# enough to catch "Password=abc;" inside a connection string, which means it also reaches
# "var pwd = document.getElementById('Password');" - the assignment ends in a quote either way.
# Brackets are the tell: no credential contains them, and every function call does.
CODE_LIKE = re.compile(r'[()\[\]]|=>|\+\s*$')

# Documentation and tests are allowed to show the shape of a secret.
DOC_SUFFIX = ('.md', '.example.json', '.sample.json', '.template', '.template.json')
DOC_PREFIX = ('docs/', 'tests/')

# The one place a relaxed certificate check is acceptable.
DEV_CONFIG = 'appsettings.development.json'

MAX_BYTES = 4_000_000


def tracked_files():
    out = subprocess.run(['git', 'ls-files'], cwd=ROOT,
                         capture_output=True, text=True, check=True).stdout
    return [line.strip() for line in out.splitlines() if line.strip()]


def mask(value: str) -> str:
    if len(value) <= 4:
        return '***'
    return f'{value[:2]}***{value[-1]} ({len(value)} chars)'


def scan():
    findings = collections.defaultdict(set)

    self_path = pathlib.Path(__file__).resolve()

    for rel in tracked_files():
        path = ROOT / rel

        # The scanner's own regexes and docstring contain every pattern it looks for, so it
        # matches itself. Skipping it is not a blind spot: there is nothing in here to leak.
        if path.resolve() == self_path:
            continue
        if not path.is_file() or path.stat().st_size > MAX_BYTES:
            continue
        try:
            text = path.read_text(encoding='utf-8-sig', errors='ignore')
        except OSError:
            continue

        posix = rel.replace('\\', '/')
        is_doc = posix.endswith(DOC_SUFFIX) or posix.startswith(DOC_PREFIX)
        is_dev = DEV_CONFIG in posix.lower()

        for lineno, line in enumerate(text.splitlines(), 1):
            for kind, pattern in PATTERNS:
                for match in pattern.finditer(line):
                    value = (match.group('v') or '').strip().strip('"\'')
                    if PLACEHOLDER.match(value) or CODE_LIKE.search(value):
                        continue

                    if kind == 'cert check off':
                        # A document explaining why the setting is dangerous has to quote it.
                        bucket = ('ALLOWED (Development)' if is_dev
                                  else 'DOC/TEST' if is_doc
                                  else 'ACTIONABLE')
                        shown = 'True'
                    else:
                        bucket = 'DOC/TEST' if is_doc else 'ACTIONABLE'
                        shown = mask(value)

                    findings[bucket].add(f'{posix}:{lineno}  [{kind}]  {shown}')

    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ci', action='store_true',
                        help='exit 1 when anything actionable is found')
    args = parser.parse_args()

    findings = scan()

    print('=' * 90)
    print('TRACKED-FILE SECRET SCAN')
    print('=' * 90)

    for bucket in ('ACTIONABLE', 'DOC/TEST', 'ALLOWED (Development)'):
        hits = sorted(findings.get(bucket, ()))
        print(f'\n{bucket}: {len(hits)}')
        for hit in hits:
            print(f'    {hit}')

    actionable = len(findings.get('ACTIONABLE', ()))
    print(f'\nActionable findings: {actionable}')

    if args.ci and actionable:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
