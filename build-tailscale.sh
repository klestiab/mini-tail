#!/usr/bin/env bash
# Cross-compile a combined tailscale + tailscaled binary for Teltonika routers
# (linux/mipsle, softfloat). Builds inside the official golang Docker image, so
# no local Go install is needed. Run from Git Bash on Windows, or any Linux/macOS shell.
#
# Usage:   ./build-tailscale.sh [tag]          e.g. ./build-tailscale.sh v1.104.2
# Env:     GOARCH   (default mipsle), GOMIPS (default softfloat)
#          FEATURES comma-separated features to keep in a minimal build (list them with
#                   `go run ./cmd/featuretags --list`); FEATURES=all keeps everything.
# Output:  dist/tailscale-combined_<tag>_linux_<arch>[_small]
set -euo pipefail

TS_VERSION="${1:-v1.104.2}"
GOARCH="${GOARCH:-mipsle}"
GOMIPS="${GOMIPS:-softfloat}"
# build_dist.sh --extra-small (osrouter,nattraversal) plus what a subnet router needs.
FEATURES="${FEATURES:-osrouter,nattraversal,advertiseroutes,iptables,bakedroots,ipnbus}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/build/tailscale-$TS_VERSION"
OUT="$ROOT/dist"
BIN="tailscale-combined_${TS_VERSION}_linux_${GOARCH}"
[ "$FEATURES" = all ] || BIN="${BIN}_small"

if [ ! -d "$SRC/.git" ]; then
  # autocrlf=false: CRLF line endings would break the shell scripts inside the Linux container.
  git -c advice.detachedHead=false clone --depth 1 --branch "$TS_VERSION" \
    -c core.autocrlf=false https://github.com/tailscale/tailscale.git "$SRC"
fi
mkdir -p "$OUT"

GO_VERSION="$(sed -n 's/^go //p' "$SRC/go.mod")"
echo "==> Building $BIN with Go $GO_VERSION (GOMIPS=$GOMIPS, features: $FEATURES)"

# Docker needs Windows paths (C:/...) when called from Git Bash.
host_path() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

# Named volumes keep the module and build caches between runs.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$(host_path "$SRC"):/src" \
  -v "$(host_path "$OUT"):/out" \
  -v tailscale-gomod:/go/pkg/mod \
  -v tailscale-gocache:/root/.cache/go-build \
  -w /src \
  -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH="$GOARCH" -e GOMIPS="$GOMIPS" \
  -e BIN="$BIN" -e FEATURES="$FEATURES" \
  "golang:$GO_VERSION" \
  sh -euc '
    git config --global --add safe.directory /src
    # featuretags runs here in the container, so build it for the host, not the target.
    ft() { GOOS= GOARCH= go run ./cmd/featuretags "$@"; }
    if [ "$FEATURES" = all ]; then
      TAGS=ts_include_cli
    else
      # --add silently ignores unknown names, so catch typos here.
      known=$(ft --list | sed "s/:.*//; s/ //g")
      for f in $(echo "$FEATURES" | tr , " "); do
        echo "$known" | grep -qx "$f" || { echo "unknown feature: $f" >&2; exit 1; }
      done
      TAGS=$(ft --min --add="cli,$FEATURES")
    fi
    # Same as: go build -trimpath -tags "$TAGS" -ldflags="-s -w", plus version stamping.
    TAGS="$TAGS" sh ./build_dist.sh --strip -o "/out/$BIN" ./cmd/tailscaled
    go version -m "/out/$BIN" | grep -E "^/out|GOARCH|GOMIPS"
    echo "version: $(grep -aoE "[0-9]+\.[0-9]+\.[0-9]+-t[0-9a-f]+" "/out/$BIN" | head -1)"
  '

ls -lh "$OUT/$BIN"
