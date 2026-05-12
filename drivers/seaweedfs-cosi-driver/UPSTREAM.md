# Upstream

Imported from `github.com/seaweedfs/seaweedfs-cosi-driver` tag `v0.3.0`
at commit `49c680807dbafe8c1b81fcb44d046f8c875c3ef0`.

Local changes:

- `Dockerfile` uses the repo's precompiled multiarch driver pattern instead
  of building Go code inside the container image.
- `docker/var-lib-cosi/.gitkeep` keeps the COSI socket mount point present in
  the distroless runtime image.
- `.gitignore` also ignores `dist/` CI cross-compile artifacts.
