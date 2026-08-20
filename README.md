# litecoin-data

Catalog for **ADGL Litecoin AssumeUTXO** snapshot data packages. This repository is not the [ADGL Litecoin](https://github.com/adgl-enterprises/adgl-litecoin) node.
It lists snapshot data files, their hashes, and how to load them with
`loadtxoutset`.

Anyone may host or copy the snapshot data files. GitHub Releases on this repo are
one convenient path, not an exclusive one. A file from a mirror, a friend, or
`dumptxoutset` on your own synced node is fine if it matches the recorded
hashes in the node source.

## What a snapshot is

AssumeUTXO lets a new node skip most of initial block download by loading a
serialized UTXO set (L1 coins plus the MWEB section). The node then:

1. Jumps to the snapshot height.
2. Syncs remaining blocks to the network tip.
3. Background-validates from genesis until the snapshot is proven.

The **security pin** is compiled into the node (`m_assumeutxo_data` in
chainparams). `loadtxoutset` rejects a file whose `txoutset_hash` /
`mweb_hash` / base block hash do not match that pin. SHA-256 checksums in
this repo are a second, file-level check so you notice a bad download before
you wait on RPC.

## Layout

Networks are distinguished by filename
(`ltc-mainnet-…`, `ltc-testnet-…`). Each snapshot is added in its own git
commit and published as its own GitHub Release.


| File | Contents |
| ---- | -------- |
| [PACKAGES.md](PACKAGES.md) | Snapshot metadata (heights, consensus hashes, file sizes) |
| [SHA256SUMS](SHA256SUMS) | SHA-256 of each downloadable `.dat.zst` |
| [load-assumeutxo.sh](load-assumeutxo.sh) | Optional helper that runs the usage steps below |


The `.dat` / `.zst` blobs are **not** stored in git. GitHub rejects files
over 100 MiB in a normal Git push. They are GitHub Release assets (2 GiB
per file) or hosted elsewhere.

## Authentication (reference)

[Using a package](#using-a-package) below walks through verification and
load. Steps 2–5 there include checking the GPG signature on `SHA256SUMS`
and the SHA-256 of the downloaded blob. You do not need this section to
load a snapshot; it records the signer, key fetch, and what each check
proves.

| Layer | What it proves |
| ----- | -------------- |
| Node chainparams (`txoutset_hash`, `mweb_hash`, `blockhash`) | The UTXO/MWEB contents at that height — enforced by `loadtxoutset` |
| SHA-256 in `SHA256SUMS` | The bytes you downloaded match the catalog |
| GPG signature on `SHA256SUMS` | Those checksums came from the expected maintainer key |

Expected signer fingerprint for `SHA256SUMS.asc`:

```
93FBE4A24A3316D4B29D712E74C5616D9F0FA4C6
```

One way to fetch that key is GitHub HTTPS for user `luke-mckay`:

```
curl -fsSL https://github.com/luke-mckay.gpg | gpg --import
gpg --fingerprint 93FBE4A24A3316D4B29D712E74C5616D9F0FA4C6
```

That URL can return more than one key. Only the fingerprint above is the
snapshot signer (uid `Luke E. McKay (GitHub A)`). Confirm it out of band
if you can.

Signed catalog commits and snapshot Releases show a **Verified** badge on
GitHub when the signing key is linked to the maintainer account. That
confirms the git tag or Release origin; it does not replace
`gpg --verify SHA256SUMS.asc SHA256SUMS` or checking the blob hash.

On macOS use `shasum -a 256` instead of `sha256sum`. If `SHA256SUMS` lists
files you did not download, check one line:
`grep ltc-<network>-<height>.dat.zst SHA256SUMS | shasum -a 256 -c -`.

## Using a package

`load-assumeutxo.sh` runs this sequence and will not overwrite files or an
already-loaded snapshot. Pass the same `-testnet` / `-datadir=` flags you
use with the node. The helper loads the highest published height for that
network. Comments in the script explain the same checks as the steps below.

```
./load-assumeutxo.sh
./load-assumeutxo.sh -datadir=/path/to/ibd-mainnet
./load-assumeutxo.sh -testnet
./load-assumeutxo.sh -testnet -datadir=/path/to/ibd-testnet
```

1. Use a node build whose chainparams include the snapshot height. A dump
  is useless to `loadtxoutset` until the node knows that pin.
2. Import the maintainer GPG key from a source you already trust. Use the
  expected fingerprint in [Authentication](#authentication-reference)
  above.
3. From a clone of this repository, fetch the GitHub Release assets into
  the current directory (`.dat.zst`, `SHA256SUMS.asc`, and a copy of
  `SHA256SUMS`). `--skip-existing` will not replace files already on disk:

```
gh release download assumeutxo-<network>-<height> \
  --repo adgl-enterprises/litecoin-data --skip-existing
```

  Tag names match `PACKAGES.md` (for example `assumeutxo-testnet-4859037`).
  Without `gh`, the same files are at
  `https://github.com/adgl-enterprises/litecoin-data/releases/download/<tag>/`.
4. Verify the signature over the checksums:
  `gpg --verify SHA256SUMS.asc SHA256SUMS`
   Prefer the `SHA256SUMS` from this git clone. The `.asc` and the blob
   come from the Release (the helper will fetch them if they are not
   already next to `SHA256SUMS`).
5. Check the SHA-256 of the `.dat.zst` you fetched against [SHA256SUMS](SHA256SUMS)
  (`sha256sum -c SHA256SUMS`, or one line — see Authentication above).
6. Decompress (`zstd -d`, without forcing an overwrite):
  `zstd -d ltc-mainnet-<height>.dat.zst`
7. Start `adgl-litecoind` with the same `-datadir` and network flags you
  will use for the load. Wait until **headers** have reached the snapshot
  height (`getchainstates`). A header is ~80 bytes; header sync is not
  IBD. `loadtxoutset` needs that header in the block index so it knows the
  snapshot block is on the best chain. It does **not** need block bodies
  from genesis to that height — those bodies are what the snapshot skips.
  For MWEB snapshots it also needs the **single** snapshot-base block body
  (extension header + PMMR roots). If that body is not on disk, the node
  fetches it out of order from a connected `NODE_MWEB` peer. Stay connected
  to such a peer; do not wait for IBD to the snapshot height, and do not
  use `getblockhash` as a readiness probe (that RPC only works on the
  validated active chain). After load, the node downloads blocks from the
  snapshot height to the tip, and separately proves the snapshot by
  validating genesis → snapshot in the background.
8. If `chainstate_snapshot` already exists under that datadir, stop. The
  snapshot is already loaded; do not replace it.
9. Load the uncompressed file (use a large RPC timeout; `0` is treated as
  an immediate failure on this CLI):

```
adgl-litecoin-cli -rpcclienttimeout=3600 loadtxoutset /path/to/ltc-mainnet-<height>.dat
adgl-litecoin-cli -testnet -rpcclienttimeout=3600 loadtxoutset /path/to/ltc-testnet-<height>.dat
```

10. Watch `getchainstates` until the snapshot chain is at the tip and
  background validation completes.

New empty wallets work during this process. Restoring a wallet whose
history is *before* the snapshot height must wait until background sync
has those blocks; then rescan.

## Publishing a snapshot

One git commit and one annotated, GPG-signed tag per snapshot. Do not
publish mainnet and testnet in the same commit or Release.

1. Dump on a synced node: `dumptxoutset <file> latest`. Do not use
  `rollback=<height>`. That path copies the UTXO set into a temporary
  coins DB and walks `DisconnectBlock` back to a historical height.
  Disconnecting an MWEB block needs the MWEB undo/cache view; the
  temporary DB has none, so rollback dies with
  `DisconnectBlock(): MWEB undo required but MWEB cache view is missing`.
  Until that is fixed, published heights are the live tip at dump time.
2. Name the file `ltc-<network>-<height>.dat`.
3. Compress it the same way every time:
  `zstd -T0 -19 -k ltc-<network>-<height>.dat`
4. Record the fields in [PACKAGES.md](PACKAGES.md).
5. Add one `SHA256SUMS` line for the downloadable `.dat.zst`.
6. Commit those catalog updates.
7. Detach-sign the checksums:
  `gpg --detach-sign -u 93FBE4A24A3316D4B29D712E74C5616D9F0FA4C6 -a SHA256SUMS`
8. Create an annotated GPG-signed tag `assumeutxo-<network>-<height>` and
  a GitHub Release whose assets are the `.dat.zst`, `SHA256SUMS`, and
   `SHA256SUMS.asc`.

The node still trusts chainparams, not this repo.
