#!/bin/sh
# Build-time setup script for Dockerfile.claude-custom.
# Holds everything that exists in Dockerfile.claude-custom but NOT in the
# upstream Dockerfile.claude template, so the Dockerfile itself can stay
# close to the template (easier to track upstream changes).
#
# What this does (vs. Dockerfile.claude):
#   1. apt-installs python3 + venv + pip + vim + jq, plus python/pip symlinks.
#   2. Installs uv + uvx (Astral standalone installer) system-wide.
#   3. Writes /usr/local/bin/openab-entrypoint.sh — a per-pod venv setup
#      (PVC-backed, works with readOnlyRootFilesystem=true) plus GitLab
#      credential helper plus ~/.bashrc seeding for interactive shells.
#   4. Writes /usr/local/bin/openab-dispatch.sh — a hybrid dispatcher that
#      prefers a ConfigMap-mounted override at /etc/openab-overrides/
#      entrypoint.sh when present, falling back to the image-baked entrypoint.
#      Mount path is /etc/openab-overrides (NOT /etc/openab/entrypoint.sh)
#      because the chart already mounts a configmap at /etc/openab and a
#      subPath child of that read-only mount fails with "not a directory".
#
# VIRTUAL_ENV is intentionally NOT set as a Dockerfile ENV — letting it leak
# to /opt/venv would make pip try to write there at runtime and fail under
# readOnlyRootFilesystem.

set -eu

# 1. Extra apt packages + python / pip symlinks.
apt-get update
apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv vim jq
rm -rf /var/lib/apt/lists/*
ln -sf /usr/bin/python3 /usr/local/bin/python
ln -sf /usr/bin/pip3 /usr/local/bin/pip

# 2. uv + uvx (Astral standalone installer) system-wide.
curl -LsSf https://astral.sh/uv/install.sh | \
    env UV_INSTALL_DIR=/usr/local/bin UV_UNMANAGED_INSTALL=1 sh
uv --version
uvx --version

# 3. Image-baked entrypoint (default; ConfigMap can override via dispatch).
cat > /usr/local/bin/openab-entrypoint.sh <<'ENTRYPOINT_EOF'
#!/bin/sh
set -e
export VIRTUAL_ENV="${HOME}/venv"
if [ ! -x "${VIRTUAL_ENV}/bin/python" ]; then
  echo "[entrypoint] creating venv at ${VIRTUAL_ENV}"
  /usr/bin/python3 -m venv "${VIRTUAL_ENV}"
  "${VIRTUAL_ENV}/bin/pip" install --upgrade pip setuptools wheel
fi
export PATH="${VIRTUAL_ENV}/bin:${PATH}"

# GitLab HTTPS auth via $GITLAB_TOKEN — applies to current process tree.
git config --global credential.helper '!f() { echo "username=oauth2"; echo "password=$GITLAB_TOKEN"; }; f'

# Seed ~/.bashrc so `kubectl exec -it ... bash` sessions also see the venv
# and inherit the same git credential helper. Idempotent.
BASHRC="${HOME}/.bashrc"
MARKER="# >>> openab venv >>>"
if ! grep -qF "${MARKER}" "${BASHRC}" 2>/dev/null; then
  echo "[entrypoint] seeding ${BASHRC}"
  cat >> "${BASHRC}" <<'BRC'
# >>> openab venv >>>
export VIRTUAL_ENV="${HOME}/venv"
export PATH="${VIRTUAL_ENV}/bin:${PATH}"
git config --global credential.helper '!f() { echo "username=oauth2"; echo "password=$GITLAB_TOKEN"; }; f' >/dev/null 2>&1
# <<< openab venv <<<
BRC
fi

exec "$@"
ENTRYPOINT_EOF
chmod +x /usr/local/bin/openab-entrypoint.sh

# 4. Hybrid dispatcher.
cat > /usr/local/bin/openab-dispatch.sh <<'DISPATCH_EOF'
#!/bin/sh
if [ -f /etc/openab-overrides/entrypoint.sh ]; then
  echo "[dispatch] using ConfigMap-mounted /etc/openab-overrides/entrypoint.sh"
  exec /bin/sh /etc/openab-overrides/entrypoint.sh "$@"
fi
echo "[dispatch] using image-baked /usr/local/bin/openab-entrypoint.sh"
exec /usr/local/bin/openab-entrypoint.sh "$@"
DISPATCH_EOF
chmod +x /usr/local/bin/openab-dispatch.sh

# Ensure node user (runtime UID) owns the scripts.
chown node:node /usr/local/bin/openab-entrypoint.sh /usr/local/bin/openab-dispatch.sh
