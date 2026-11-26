#!/usr/bin/env bash
set -euo pipefail

# Dev loop for the LG TV, run from the Mac (no copy-paste into webOS Dev Manager).
#
#   ./scripts/webos-dev.sh build     build the .ipk on this Mac (Docker / OrbStack, no push needed)
#   ./scripts/webos-dev.sh fetch     wait for the CI build of HEAD and download its .ipk
#   ./scripts/webos-dev.sh install   install the downloaded .ipk on the TV
#   ./scripts/webos-dev.sh launch    (re)start Playfin with the params in webos/dev-params.json
#   ./scripts/webos-dev.sh logs      print the app log from the TV (add -f to follow it)
#   ./scripts/webos-dev.sh close     close Playfin on the TV
#   ./scripts/webos-dev.sh dev       build + install + launch + logs   (local, fastest)
#   ./scripts/webos-dev.sh all       fetch + install + launch + logs   (from CI)
#
# Needs: gh (signed in), ares (@webos-tools/cli) with a working device, see TV_DEVICE.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TV_DEVICE="${TV_DEVICE:-c1}"
APP_ID="com.playfin.webos"
IPK_DIR="$ROOT/build/webos"
PARAMS_FILE="$ROOT/webos/dev-params.json"
APP_DATA="/media/developer/apps/usr/palm/applications/$APP_ID/.local/share/playfin"

fetch() {
    local sha run_id
    sha="$(git -C "$ROOT" rev-parse HEAD)"
    if ! git -C "$ROOT" branch -r --contains "$sha" | grep -q .; then
        echo "ERROR: HEAD ($sha) is not pushed. Push it first so CI builds it." >&2
        exit 1
    fi

    echo "▶ Waiting for the webOS CI run of ${sha:0:7}"
    run_id=""
    for _ in $(seq 1 30); do
        run_id="$(gh run list --workflow webos.yml --commit "$sha" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
        [[ -n "$run_id" ]] && break
        sleep 10
    done
    if [[ -z "$run_id" ]]; then
        echo "ERROR: no webOS CI run found for ${sha:0:7}." >&2
        exit 1
    fi

    if ! gh run watch "$run_id" --exit-status --interval 20 >/dev/null; then
        echo "ERROR: the CI run failed. Why: gh run view $run_id --log-failed" >&2
        exit 1
    fi

    echo "▶ Downloading the .ipk"
    rm -rf "$IPK_DIR"
    mkdir -p "$IPK_DIR"
    gh run download "$run_id" --name playfin-webos-ipk --dir "$IPK_DIR"
    ls "$IPK_DIR"/*.ipk
}

build_local() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "ERROR: Docker is not running. Open OrbStack (or Docker Desktop) first." >&2
        exit 1
    fi
    # The image only holds the toolchain (no COPY), so build it without a context: sending
    # webos/target to the daemon would be slow. Cached after the first run.
    echo "▶ Preparing the webOS toolchain image"
    docker build -q -t playfin-webos-sdk - < "$ROOT/webos/Dockerfile" >/dev/null

    echo "▶ Building the .ipk locally"
    rm -rf "$IPK_DIR"
    docker run --rm \
        -v "$ROOT":/workspace \
        -v playfin-cargo-registry:/usr/local/cargo/registry \
        -w /workspace \
        playfin-webos-sdk ./scripts/package-webos-ipk.sh
}

install_ipk() {
    local ipk
    ipk="$(ls "$IPK_DIR"/*.ipk 2>/dev/null | head -1 || true)"
    if [[ -z "$ipk" ]]; then
        echo "ERROR: no .ipk in $IPK_DIR. Run 'fetch' first." >&2
        exit 1
    fi
    echo "▶ Installing $(basename "$ipk") on $TV_DEVICE"
    ares-install -d "$TV_DEVICE" "$ipk"
}

close_app() {
    ares-launch -d "$TV_DEVICE" --close "$APP_ID" >/dev/null 2>&1 || true
}

launch() {
    # Close first: launching an app that is already open only brings it back, without new params.
    close_app
    sleep 1
    if [[ -f "$PARAMS_FILE" ]]; then
        echo "▶ Launching $APP_ID with webos/dev-params.json"
        ares-launch -d "$TV_DEVICE" "$APP_ID" --params "$(tr -d '\n' < "$PARAMS_FILE")"
    else
        echo "▶ Launching $APP_ID (no webos/dev-params.json)"
        ares-launch -d "$TV_DEVICE" "$APP_ID"
    fi
}

logs() {
    if [[ "${1:-}" == "-f" ]]; then
        ares-novacom -d "$TV_DEVICE" --run "tail -n 100 -f $APP_DATA/playfin.log"
    else
        ares-novacom -d "$TV_DEVICE" --run "cat $APP_DATA/playfin.log"
    fi
}

case "${1:-}" in
    build) build_local ;;
    fetch) fetch ;;
    install) install_ipk ;;
    launch) launch ;;
    logs) logs "${2:-}" ;;
    close) close_app ;;
    dev)
        build_local
        install_ipk
        launch
        sleep 5
        logs
        ;;
    all)
        fetch
        install_ipk
        launch
        sleep 5
        logs
        ;;
    *)
        sed -n '4,14p' "$0"
        exit 1
        ;;
esac
