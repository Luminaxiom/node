#!/bin/bash
set -o pipefail

LOG=/home/chronos/user/MyFiles/Downloads/crosfix.log
mkdir -p /home/chronos/user/MyFiles/Downloads 2>/dev/null || true
exec > >(tee "$LOG") 2>&1

echo "=== ChromeOS dev_install / Node bootstrap ==="
echo "Log: $LOG"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run this from the VT-2 root shell."
  exit 1
fi

source /etc/profile 2>/dev/null || true
export PATH="/usr/local/sbin:/usr/local/bin:$PATH"

echo
echo "[1/6] Repairing the Portage LD_LIBRARY_PATH handoff"

P="$(find /usr/local/lib* -path '*/site-packages/portage/package/ebuild/_config/special_env_vars.py' -print -quit 2>/dev/null || true)"
if [ -z "$P" ]; then
  echo "ERROR: special_env_vars.py was not found under /usr/local."
  exit 2
fi

echo "Portage file: $P"
grep -n 'environ_whitelist' "$P" || true

if grep -q 'environ_whitelist.*LD_LIBRARY_PATH' "$P"; then
  echo "LD_LIBRARY_PATH is already whitelisted."
elif grep -qx 'environ_whitelist = \[\]' "$P"; then
  cp -p "$P" "$P.pre-crosfix"
  sed -i "s/^environ_whitelist = \[\]$/environ_whitelist = ['LD_LIBRARY_PATH']/" "$P"
  echo "Patched environ_whitelist to preserve LD_LIBRARY_PATH."
else
  echo "ERROR: environ_whitelist has an unexpected format. Nothing was modified."
  grep -n 'environ_whitelist' "$P" || true
  exit 3
fi

echo
echo "[2/6] Restoring the ChromeOS binary-package host"

get_lsb() {
  grep -m1 "^$1=" /etc/lsb-release | cut -d= -f2- | sed 's/^"//;s/"$//'
}

BOARD="$(get_lsb CHROMEOS_RELEASE_BOARD)"
BOARD="${BOARD%%-signed-*}"
VER="$(get_lsb CHROMEOS_RELEASE_VERSION)"
DEVSERVER="$(get_lsb CHROMEOS_DEVSERVER)"

if [ -z "$BOARD" ] || [ -z "$VER" ]; then
  echo "ERROR: Could not determine ChromeOS board/version from /etc/lsb-release."
  exit 4
fi

if [ -n "$DEVSERVER" ]; then
  BINHOST="$DEVSERVER/static/pkgroot/$BOARD/packages"
else
  BINHOST="https://commondatastorage.googleapis.com/chromeos-dev-installer/board/$BOARD/$VER/packages"
fi
CONF=/usr/local/etc/portage/make.conf
mkdir -p /usr/local/etc/portage

if [ ! -f "$CONF" ]; then
  printf 'ROOT="/usr/local"\nPORTAGE_BINHOST="%s"\n' "$BINHOST" > "$CONF"
else
  grep -q '^ROOT=' "$CONF" || echo 'ROOT="/usr/local"' >> "$CONF"
  if grep -q '^PORTAGE_BINHOST=' "$CONF"; then
    sed -i "s|^PORTAGE_BINHOST=.*|PORTAGE_BINHOST=\"$BINHOST\"|" "$CONF"
  else
    echo "PORTAGE_BINHOST=\"$BINHOST\"" >> "$CONF"
  fi
fi

export PORTAGE_BINHOST="$BINHOST"
echo "Board:   $BOARD"
echo "Version: $VER"
echo "Binhost: $BINHOST"

echo
echo "[3/6] Verifying Python can see its shared library"

LIBPY="$(find /usr/local -name 'libpython3.11.so.1.0' -print -quit 2>/dev/null || true)"
if [ -z "$LIBPY" ]; then
  echo "ERROR: libpython3.11.so.1.0 is not present under /usr/local."
  exit 5
fi

LIBPYDIR="${LIBPY%/*}"
case ":${LD_LIBRARY_PATH:-}:" in
  *":$LIBPYDIR:"*) ;;
  *) export LD_LIBRARY_PATH="$LIBPYDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
esac

echo "libpython: $LIBPY"
echo "LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-<empty>}"

if ! /usr/local/bin/python3.11 -V; then
  echo "ERROR: /usr/local/bin/python3.11 still cannot start."
  exit 6
fi

echo
echo "[4/6] Retrying only the package that actually failed"

if ! emerge --jobs=1 sys-apps/flashrom-tester; then
  echo "ERROR: flashrom-tester still fails. Stopping here rather than rerunning all 226 packages."
  exit 7
fi

echo "flashrom-tester succeeded."

echo
echo "[5/6] Completing virtual/target-os-dev"

if ! emerge --jobs=4 virtual/target-os-dev; then
  echo "ERROR: target-os-dev still has another failure. See $LOG."
  exit 8
fi

echo
echo "[6/6] Installing Node.js 26.13.0 and an RDC launcher"

LIBATOMIC="$(find /usr/local /usr/lib /lib -name 'libatomic.so.1*' -print -quit 2>/dev/null || true)"
if [ -z "$LIBATOMIC" ]; then
  echo "ERROR: target-os-dev completed, but libatomic.so.1 is still unavailable."
  echo "Node 26 is not being installed until that dependency is resolved."
  exit 9
fi

echo "libatomic: $LIBATOMIC"

NODEVER=v26.13.0
NODEFILE="node-$NODEVER-linux-x64.tar.xz"
NODEURL="https://nodejs.org/dist/$NODEVER/$NODEFILE"
SUMURL="https://nodejs.org/dist/$NODEVER/SHASUMS256.txt"

rm -f "/tmp/$NODEFILE" /tmp/SHASUMS256.txt
curl -fL "$NODEURL" -o "/tmp/$NODEFILE" || exit 10
curl -fL "$SUMURL" -o /tmp/SHASUMS256.txt || exit 11

if command -v sha256sum >/dev/null 2>&1; then
  (
    cd /tmp || exit 1
    grep "  $NODEFILE$" SHASUMS256.txt | sha256sum -c -
  ) || exit 12
fi

rm -rf /usr/local/node "/usr/local/node-$NODEVER-linux-x64"
tar -xJf "/tmp/$NODEFILE" -C /usr/local || exit 13
mv "/usr/local/node-$NODEVER-linux-x64" /usr/local/node || exit 14

ln -sf /usr/local/node/bin/node /usr/local/bin/node
ln -sf /usr/local/node/bin/npm /usr/local/bin/npm
ln -sf /usr/local/node/bin/npx /usr/local/bin/npx

/usr/local/bin/node -v || exit 15
/usr/local/bin/npm -v || exit 16
/usr/local/bin/npx -v || exit 17

cat > /usr/local/bin/rdc <<'EOF'
#!/bin/sh
PATH=/usr/local/node/bin:/usr/local/bin:$PATH
export PATH
exec /usr/local/node/bin/npx --yes @wonderwhy-er/desktop-commander@latest remote "$@"
EOF
chmod +x /usr/local/bin/rdc

echo
echo "=== COMPLETE ==="
echo "Return to crosh -> shell and run: rdc"
echo "Full log: $LOG"
