#!/usr/bin/env bash
# Download (if needed), verify, and load an ADGL Litecoin AssumeUTXO snapshot.
#
# AssumeUTXO loads a serialized UTXO set (L1 coins plus the MWEB section) so a
# new node can skip most of initial block download. After loadtxoutset:
#   1. The node jumps to the snapshot height.
#   2. It syncs remaining blocks to the network tip.
#   3. It background-validates from genesis until the snapshot is proven.
#
# Security is layered. This script checks the catalog and the download; the
# node checks the dump contents:
#   - chainparams (txoutset_hash / mweb_hash / blockhash): consensus pin.
#     loadtxoutset rejects a mismatch. A dump is useless until the running
#     node build includes that height.
#   - SHA256SUMS: SHA-256 of the downloadable .dat.zst (file-level check).
#   - SHA256SUMS.asc: GPG signature over SHA256SUMS from the expected key.
#
# This script will not overwrite snapshot files that already exist, and it
# will not call loadtxoutset if that datadir already has a snapshot loaded.
# It selects the highest published height for the chosen network.
#
# The node must already be running with the same -datadir and network flags.
set -euo pipefail
LC_ALL=C
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SHA256SUMS_FILE="$SCRIPT_DIR/SHA256SUMS"

# Expected fingerprint of SHA256SUMS.asc. Confirm independently (see README).
# One fetch path: https://github.com/luke-mckay.gpg
DEFAULT_SIGNER='93FBE4A24A3316D4B29D712E74C5616D9F0FA4C6'
GITHUB_REPO='adgl-enterprises/litecoin-data'
CLI_BIN='adgl-litecoin-cli'
# loadtxoutset takes a long time. adgl-litecoin-cli treats -rpcclienttimeout=0
# as an immediate failure, so use a large finite value.
RPC_TIMEOUT=86400

NETWORK='main'
DATADIR=''
SNAPSHOTDIR="$SCRIPT_DIR"
SIGNER="$DEFAULT_SIGNER"
CLI_PATH=''
CONF=''
RPCCONNECT=''
RPCPORT=''
RPCUSER=''
RPCPASSWORD=''
RPCCOOKIEFILE=''

usage() {
    cat <<EOF
Load an AssumeUTXO snapshot after verifying SHA256SUMS and its GPG signature.

Usage:
  load-assumeutxo.sh [options]

This script will not overwrite snapshot files that already exist, and it will
not call loadtxoutset if that datadir already has a snapshot loaded.

Options:
  -help                    Print this message and exit
  -testnet                 Use the public testnet
  -datadir=<dir>           Specify data directory (same meaning as adgl-litecoind)
  -snapshotdir=<dir>       Directory for snapshot files (default: this repository)
  -signer=<fingerprint>    Expected GPG fingerprint of SHA256SUMS.asc
  -cli=<path>              Path to adgl-litecoin-cli (default: from PATH)
  -conf=<file>             Specify configuration file (passed to adgl-litecoin-cli)
  -rpcconnect=<ip>         Send RPC commands to this host
  -rpcport=<port>          Connect to JSON-RPC on <port>
  -rpcuser=<user>          Username for JSON-RPC connections
  -rpcpassword=<pw>        Password for JSON-RPC connections
  -rpccookiefile=<path>    Location of the auth cookie (default: from datadir)
  -rpcclienttimeout=<n>    Timeout in seconds for loadtxoutset (default: $RPC_TIMEOUT)

The node must already be running with the same -datadir and network flags.
Import the maintainer GPG key yourself before running (this script will not
fetch keys). See README.md for fingerprint, key fetch, and the matching
manual steps.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

abs_path() {
    local target=$1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$target"
    else
        local dir base
        dir=$(dirname -- "$target")
        base=$(basename -- "$target")
        (cd -- "$dir" && printf '%s/%s\n' "$(pwd)" "$base")
    fi
}

opt_value() {
    # Sets OPT_VALUE from $1 (current argv) and optional $2 (next argv).
    # Sets OPT_SHIFT=1 when the value was taken from $2.
    local arg=$1
    OPT_SHIFT=0
    if [[ "$arg" == *=* ]]; then
        OPT_VALUE=${arg#*=}
        [[ -n "$OPT_VALUE" ]] || die "missing value for ${arg%%=*}"
        return
    fi
    if [[ $# -lt 2 || -z "${2-}" || "$2" == -* ]]; then
        die "missing value for $arg"
    fi
    OPT_VALUE=$2
    OPT_SHIFT=1
}

parse_args() {
    local arg
    while [[ $# -gt 0 ]]; do
        arg=$1
        case "$arg" in
            -help|--help|-h|-\?)
                usage
                exit 0
                ;;
            -testnet|-testnet=1)
                NETWORK='test'
                ;;
            -testnet=0|-notestnet)
                NETWORK='main'
                ;;
            -testnet4|-signet|-regtest|-testnet4=*|-signet=*|-regtest=*)
                die "no AssumeUTXO package is published for ${arg%%=*}"
                ;;
            -chain=main|-chain=mainnet)
                NETWORK='main'
                ;;
            -chain=test|-chain=testnet)
                NETWORK='test'
                ;;
            -chain=*)
                die "no AssumeUTXO package is published for -chain=${arg#*=}"
                ;;
            -chain)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                case "$OPT_VALUE" in
                    main|mainnet) NETWORK='main' ;;
                    test|testnet) NETWORK='test' ;;
                    *) die "no AssumeUTXO package is published for -chain=$OPT_VALUE" ;;
                esac
                ;;
            -datadir|-datadir=* )
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                DATADIR=$OPT_VALUE
                ;;
            -snapshotdir|-snapshotdir=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                SNAPSHOTDIR=$OPT_VALUE
                ;;
            -signer|-signer=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                SIGNER=$OPT_VALUE
                ;;
            -cli|-cli=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                CLI_PATH=$OPT_VALUE
                ;;
            -conf|-conf=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                CONF=$OPT_VALUE
                ;;
            -rpcconnect|-rpcconnect=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                RPCCONNECT=$OPT_VALUE
                ;;
            -rpcport|-rpcport=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                RPCPORT=$OPT_VALUE
                ;;
            -rpcuser|-rpcuser=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                RPCUSER=$OPT_VALUE
                ;;
            -rpcpassword|-rpcpassword=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                RPCPASSWORD=$OPT_VALUE
                ;;
            -rpccookiefile|-rpccookiefile=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                RPCCOOKIEFILE=$OPT_VALUE
                ;;
            -rpcclienttimeout|-rpcclienttimeout=*)
                opt_value "$1" "${2-}"
                shift "$OPT_SHIFT"
                RPC_TIMEOUT=$OPT_VALUE
                ;;
            -*)
                die "unknown option: $arg (see -help)"
                ;;
            *)
                die "unexpected argument: $arg (see -help)"
                ;;
        esac
        shift
    done
}

normalize_fpr() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]'
}

default_datadir() {
    if [[ "$(uname -s)" == Darwin ]]; then
        printf '%s\n' "$HOME/Library/Application Support/ADGL-Litecoin"
    else
        printf '%s\n' "$HOME/.adgl-litecoin"
    fi
}

network_datadir() {
    # Same subdirectory names adgl-litecoind uses. -testnet stores data under
    # testnet4/; that is the node's layout, not a different network flag.
    local base=$1
    case "$NETWORK" in
        main) printf '%s\n' "$base" ;;
        test) printf '%s/testnet4\n' "$base" ;;
        *) die "internal error: unknown network $NETWORK" ;;
    esac
}

file_sha256() {
    local path=$1 digest
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum -- "$path")
    else
        digest=$(shasum -a 256 -- "$path")
    fi
    printf '%s\n' "${digest%% *}" | tr '[:upper:]' '[:lower:]'
}

expected_hash() {
    local name=$1 hash
    hash=$(awk -v f="$name" '
        /^[ \t]*#/ || NF == 0 { next }
        {
            n = $2
            sub(/^\*/, "", n)
            if (n == f) { print $1; found = 1; exit }
        }
        END { if (!found) exit 1 }
    ' "$SHA256SUMS_FILE") || die "no SHA256SUMS entry for $name"
    printf '%s\n' "$hash" | tr '[:upper:]' '[:lower:]'
}

# SHA-256 of a named downloadable file against SHA256SUMS (the .dat.zst).
# Detects a truncated or swapped download before loadtxoutset spends time on it.
verify_named_hash() {
    local path=$1 name=$2 expected actual
    expected=$(expected_hash "$name")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "malformed SHA256SUMS hash for $name"
    actual=$(file_sha256 "$path")
    if [[ "$actual" != "$expected" ]]; then
        die "SHA-256 mismatch for $name
  expected: $expected
  actual:   $actual
Refusing to use or overwrite this file."
    fi
    printf 'ok: %s matches SHA256SUMS\n' "$name"
}

# SHA256SUMS lives in this git clone (the catalog you reviewed).
# SHA256SUMS.asc is the detached signature, usually a GitHub Release asset.
# A valid signature from some other key is not acceptance.
verify_gpg() {
    local sums=$1 asc=$2 status_file signer_norm line fpr primary found=0
    signer_norm=$(normalize_fpr "$SIGNER")
    [[ "$signer_norm" =~ ^[0-9A-F]{40}$ ]] || die "-signer must be a 40-character GPG fingerprint"

    status_file=$(mktemp)
    # gpg exits non-zero when the key is untrusted even if the signature is valid.
    # Trust is the fingerprint check below, not gpg's web-of-trust bits.
    gpg --status-fd 1 --verify "$asc" "$sums" >"$status_file" || true

    while IFS= read -r line; do
        case "$line" in
            '[GNUPG:] EXPKEYSIG '*|'[GNUPG:] REVKEYSIG '*|'[GNUPG:] BADSIG '*|'[GNUPG:] ERRSIG '*)
                rm -f "$status_file"
                die "GPG signature check failed: $line"
                ;;
            '[GNUPG:] VALIDSIG '*)
                # VALIDSIG <fpr> ... <primary-key-fpr> ...
                fpr=$(normalize_fpr "$(printf '%s\n' "$line" | awk '{print $3}')")
                primary=$(normalize_fpr "$(printf '%s\n' "$line" | awk '{print $12}')")
                if [[ "$fpr" == "$signer_norm" || "$primary" == "$signer_norm" ]]; then
                    found=1
                else
                    rm -f "$status_file"
                    die "SHA256SUMS.asc is signed by $fpr, not the expected fingerprint $signer_norm
Confirm the signer independently. Do not take a key from this repository or GitHub on faith."
                fi
                ;;
        esac
    done <"$status_file"
    rm -f "$status_file"

    [[ "$found" -eq 1 ]] || die "no valid GPG signature from $signer_norm over SHA256SUMS
Import that key yourself from a source you already trust, then re-run.
This script will not fetch keys."
    printf 'ok: SHA256SUMS is signed by %s\n' "$signer_norm"
}

download_https() {
    local url=$1 dest=$2 tmp
    tmp=$dest.incomplete
    printf 'downloading %s\n' "$url"
    # Resume only the incomplete file. Never write onto a completed dest.
    curl --fail --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --continue-at - \
        --output "$tmp" \
        -- "$url"
    mv "$tmp" "$dest"
}

select_package() {
    # Highest .dat.zst height for this network in SHA256SUMS. Release tag is
    # assumeutxo-<network>-<height> (one snapshot per commit / Release).
    local prefix height cand max_height=''
    case "$NETWORK" in
        main) prefix='ltc-mainnet-' ;;
        test) prefix='ltc-testnet-' ;;
    esac

    while IFS= read -r cand; do
        height=${cand#"$prefix"}
        height=${height%.dat.zst}
        [[ "$height" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$max_height" || "$height" -gt "$max_height" ]]; then
            max_height=$height
        fi
    done < <(awk -v p="$prefix" '
        /^[ \t]*#/ || NF == 0 { next }
        {
            n = $2
            sub(/^\*/, "", n)
            if (index(n, p) == 1 && n ~ /\.dat\.zst$/) print n
        }
    ' "$SHA256SUMS_FILE")

    [[ -n "$max_height" ]] || die "SHA256SUMS has no $prefix*.dat.zst entry"

    HEIGHT=$max_height
    DAT_NAME="${prefix}${HEIGHT}.dat"
    ZST_NAME="${DAT_NAME}.zst"
    if [[ "$NETWORK" == test ]]; then
        TAG="assumeutxo-testnet-${HEIGHT}"
    else
        TAG="assumeutxo-mainnet-${HEIGHT}"
    fi
}

rpc() {
    local -a cmd
    cmd=("$CLI_PATH")
    [[ "$NETWORK" == test ]] && cmd+=(-testnet)
    [[ -n "$DATADIR" ]] && cmd+=(-datadir="$DATADIR")
    [[ -n "$CONF" ]] && cmd+=(-conf="$CONF")
    [[ -n "$RPCCONNECT" ]] && cmd+=(-rpcconnect="$RPCCONNECT")
    [[ -n "$RPCPORT" ]] && cmd+=(-rpcport="$RPCPORT")
    [[ -n "$RPCUSER" ]] && cmd+=(-rpcuser="$RPCUSER")
    [[ -n "$RPCPASSWORD" ]] && cmd+=(-rpcpassword="$RPCPASSWORD")
    [[ -n "$RPCCOOKIEFILE" ]] && cmd+=(-rpccookiefile="$RPCCOOKIEFILE")
    cmd+=(-rpcclienttimeout="$RPC_TIMEOUT")
    "${cmd[@]}" "$@"
}

json_get() {
    python3 -c 'import json,sys
d=json.load(sys.stdin)
expr=sys.argv[1]
if expr=="headers":
    print(d.get("headers", -1))
elif expr=="max_blocks":
    blocks=[(cs.get("blocks") or 0) for cs in (d.get("chainstates") or [])]
    print(max(blocks) if blocks else 0)
elif expr=="snapshot_blockhash":
    hashes=[cs.get("snapshot_blockhash") for cs in d.get("chainstates") or [] if cs.get("snapshot_blockhash")]
    print(hashes[0] if hashes else "")
' "$1"
}

already_applied() {
    local netdir=$1
    [[ -e "$netdir/chainstate_snapshot" ]]
}

main() {
    parse_args "$@"

    need_cmd curl
    need_cmd gpg
    need_cmd python3
    if ! command -v sha256sum >/dev/null 2>&1; then
        need_cmd shasum
    fi

    # Catalog SHA256SUMS must be the copy from this clone, not a file fetched
    # with the blob. Review it (and its git history) before running.
    [[ -f "$SHA256SUMS_FILE" ]] || die "SHA256SUMS not found at $SHA256SUMS_FILE
Run this script from a clone of $GITHUB_REPO so the catalog file is the one you reviewed."

    if [[ -n "$CLI_PATH" ]]; then
        [[ -x "$CLI_PATH" ]] || die "not executable: $CLI_PATH"
    else
        CLI_PATH=$(command -v "$CLI_BIN" 2>/dev/null || true)
        if [[ -z "$CLI_PATH" ]]; then
            # Try common install locations before failing
            for candidate in \
                /usr/local/bin/adgl-litecoin-cli \
                /usr/bin/adgl-litecoin-cli \
                "$(dirname -- "${BASH_SOURCE[0]}")/../bitcoin/build/bin/adgl-litecoin-cli"; do
                if [[ -x "$candidate" ]]; then
                    CLI_PATH=$candidate
                    break
                fi
            done
        fi
        [[ -n "$CLI_PATH" ]] || die "$CLI_BIN not found in PATH and not in common locations.
Pass -cli=/path/to/adgl-litecoin-cli"
    fi

    SNAPSHOTDIR=$(abs_path "$SNAPSHOTDIR")
    mkdir -p -- "$SNAPSHOTDIR"

    local base_datadir net_datadir
    if [[ -n "$DATADIR" ]]; then
        base_datadir=$(abs_path "$DATADIR")
        [[ -d "$base_datadir" ]] || die "-datadir is not a directory: $base_datadir"
    else
        base_datadir=$(default_datadir)
    fi
    net_datadir=$(network_datadir "$base_datadir")

    select_package
    local dat_path zst_path asc_path release_base
    dat_path="$SNAPSHOTDIR/$DAT_NAME"
    zst_path="$SNAPSHOTDIR/$ZST_NAME"
    release_base="https://github.com/${GITHUB_REPO}/releases/download/${TAG}"

    if [[ -e "$SCRIPT_DIR/SHA256SUMS.asc" ]]; then
        asc_path="$SCRIPT_DIR/SHA256SUMS.asc"
    else
        asc_path="$SNAPSHOTDIR/SHA256SUMS.asc"
    fi

    # Do not replace a snapshot already in this datadir (chainstate_snapshot)
    # or leftover debris from a failed load.
    if [[ -e "$net_datadir/chainstate_snapshot_INVALID" ]]; then
        die "found $net_datadir/chainstate_snapshot_INVALID from a previous failed load.
Inspect or remove that directory yourself; this script will not replace it."
    fi
    if already_applied "$net_datadir"; then
        printf 'snapshot already present under %s; not replacing it\n' "$net_datadir"
        exit 0
    fi

    # Detached signature over the clone's SHA256SUMS. Fetch the .asc from the
    # Release if it is not already next to SHA256SUMS. This is a signature,
    # not a public key; import the key yourself first.
    if [[ ! -f "$asc_path" ]]; then
        download_https "$release_base/SHA256SUMS.asc" "$asc_path"
    else
        printf 'using existing %s\n' "$asc_path"
    fi
    verify_gpg "$SHA256SUMS_FILE" "$asc_path"

    # Download the compressed blob if needed. Never overwrite a completed file.
    # Manual equivalent: gh release download "$TAG" --repo "$GITHUB_REPO" --skip-existing
    # Verify the .zst against SHA256SUMS, then decompress to the .dat that
    # loadtxoutset consumes. zstd without -f will not clobber an existing .dat.
    if [[ -e "$dat_path" ]]; then
        printf 'using existing %s (will not overwrite)\n' "$dat_path"
    else
        if [[ -e "$zst_path" ]]; then
            printf 'using existing %s (will not overwrite)\n' "$zst_path"
        else
            download_https "$release_base/$ZST_NAME" "$zst_path"
        fi
        verify_named_hash "$zst_path" "$ZST_NAME"
        need_cmd zstd
        printf 'decompressing %s\n' "$ZST_NAME"
        zstd -d -k -o "$dat_path" -- "$zst_path"
    fi

    local chainstates headers max_blocks snap_hash
    if ! chainstates=$(rpc getchainstates); then
        die "cannot reach the node. Start adgl-litecoind with the same -datadir and network flags, then re-run."
    fi
    headers=$(printf '%s\n' "$chainstates" | json_get headers)
    max_blocks=$(printf '%s\n' "$chainstates" | json_get max_blocks)
    snap_hash=$(printf '%s\n' "$chainstates" | json_get snapshot_blockhash)

    if [[ -n "$snap_hash" ]]; then
        printf 'snapshot already loaded (snapshot_blockhash=%s); not replacing it\n' "$snap_hash"
        exit 0
    fi
    if [[ "$max_blocks" -ge "$HEIGHT" ]]; then
        die "this datadir already has $max_blocks blocks (snapshot height is $HEIGHT). Not loading a snapshot over an existing fully-synced chainstate."
    fi

    # loadtxoutset needs the snapshot *header* in the block index so it knows
    # that block is on the best chain. A header is ~80 bytes; header sync is
    # not IBD. Block bodies from genesis to that height are what the snapshot
    # skips. For MWEB snapshots the node also needs the single snapshot-base
    # block body; if it is missing, loadtxoutset fetches that one block from a
    # connected NODE_MWEB peer. Do not wait for IBD to $HEIGHT, and do not use
    # getblockhash as a HAVE_DATA probe. After load, the node downloads bodies
    # from the snapshot height to the tip, and separately proves the snapshot
    # by validating genesis → snapshot in the background.
    # New empty wallets work during this process. Restoring a wallet whose
    # history is before the snapshot height must wait until background sync
    # has those blocks; then rescan.
    if [[ "$headers" -lt "$HEIGHT" ]]; then
        die "headers are at $headers; need at least $HEIGHT before loadtxoutset. Let the node finish header sync, then re-run. Stay connected to a NODE_MWEB peer so the snapshot-base block can be fetched."
    fi

    printf 'loading %s via loadtxoutset (timeout %ss)\n' "$DAT_NAME" "$RPC_TIMEOUT"
    rpc loadtxoutset "$(abs_path "$dat_path")"
    # Watch getchainstates until the snapshot chain is at the tip and
    # background validation completes.
    rpc getchainstates
}

main "$@"
