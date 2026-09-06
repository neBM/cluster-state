#!/usr/bin/env python3
"""Credential-free local readiness probe for the workspace daemon."""

from __future__ import annotations

import socket
import sys


def main() -> int:
    try:
        with socket.create_connection(("127.0.0.1", 2222), timeout=2.0) as connection:
            connection.settimeout(2.0)
            banner = connection.recv(255)
    except OSError as error:
        print(f"Workspace health check failed: {error}", file=sys.stderr)
        return 1

    if not banner.startswith(b"SSH-2.0-"):
        print("Workspace health check failed: invalid protocol banner", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
