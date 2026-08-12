#!/usr/bin/env python3
"""redact.py - deterministic secret scrubbing (design spec section 10). Pure stdlib."""
import re, sys

_R = r"[REDACTED"
RULES = [
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)"), "[REDACTED:private-key]"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\b"), "[REDACTED:jwt]"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{16,}\b"), "[REDACTED:api-key]"),
    (re.compile(r"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}\b"), "[REDACTED:vendor-key]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[REDACTED:aws-key-id]"),
    (re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,})\b"), "[REDACTED:vcs-token]"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"), "[REDACTED:slack-token]"),
    (re.compile(r"https://hooks\.slack\.com/services/\S+"), "[REDACTED:slack-webhook]"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), "[REDACTED:api-key]"),
    (re.compile(r"\bnpm_[A-Za-z0-9]{36}\b"), "[REDACTED:api-key]"),
    (re.compile(r"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"), "[REDACTED:api-key]"),
    (re.compile(r"\bhf_[A-Za-z0-9]{20,}\b"), "[REDACTED:api-key]"),
    (re.compile(r"\bdop_v1_[a-f0-9]{16,}\b"), "[REDACTED:api-key]"),
    (re.compile(r"(AWS4-HMAC-SHA256\b[^\n]{0,512}?Signature=)[0-9a-f]{8,}"), r"\1[REDACTED]"),
    (re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"), "Bearer [REDACTED]"),
    (re.compile(r"(?i)(?<![A-Za-z0-9])([A-Za-z0-9_.-]*(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|auth|credential)s?[A-Za-z0-9_.-]*)(\s*[=:]\s*)(\"[^\"]{0,256}\"|'[^']{0,256}'|[^\s'\";&|]{1,256})"), r"\1\2[REDACTED]"),
    (re.compile(r"://([^/\s:@]{1,64}):([^@\s/]{1,256})@"), r"://\1:[REDACTED]@"),
]
ENTROPY_A = re.compile(r"(?<![A-Za-z0-9+=_-])[A-Za-z0-9+=_-]{32,}(?![A-Za-z0-9+=_-])")
ENTROPY_B = re.compile(r"(?<![A-Za-z0-9+/=])(?!/)[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/=])")
_HEX = re.compile(r"^[0-9a-fA-F]+$")

def _keep_a(tok: str) -> bool:
    if _HEX.match(tok):
        if tok.isdigit():
            return True                      # all-digits: big numbers keep (design 10.2)
        return len(tok) in (40, 64)          # CT-15 git-SHA exemption; 32-hex redacts
    has_digit = any(c.isdigit() for c in tok)
    has_alpha = any(c.isalpha() for c in tok)
    if not has_digit or not has_alpha:
        return True                           # long words / big numbers
    return False

def _keep_b(tok: str) -> bool:
    if tok.startswith(("/", "./", "~/")):     return True
    if tok.count("/") >= 4:                   return True
    if tok == tok.lower():                    return True   # paths/hosts; documented residual
    if _HEX.match(tok):                       return _keep_a(tok)
    return False

def redact(s: str) -> str:
    for pat, rep in RULES:
        s = pat.sub(rep, s)
    s = ENTROPY_A.sub(lambda m: m.group(0) if _keep_a(m.group(0)) else "[REDACTED:high-entropy]", s)
    s = ENTROPY_B.sub(lambda m: m.group(0) if _keep_b(m.group(0)) else "[REDACTED:high-entropy]", s)
    return s

if __name__ == "__main__":
    sys.stdout.write(redact(sys.stdin.read()))
