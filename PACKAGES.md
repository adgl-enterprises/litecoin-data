# Snapshot package catalog

Facts recorded for each published AssumeUTXO dump. Load and verify steps
are in [`README.md`](README.md).

Consensus is the `txoutset_hash` / `mweb_hash` / `blockhash` compiled into
the node. File SHA-256 values here only identify the published bytes.

## Fields

| Field | Meaning |
|-------|---------|
| `network` | `mainnet` or `testnet` |
| `height` | Snapshot base height (`dumptxoutset` `base_height`) |
| `blockhash` | Hash of the base block (`base_hash`) |
| `txoutset_hash` | Serialized L1 UTXO-set hash (`hash_serialized` in chainparams) |
| `mweb_hash` | MWEB chainstate content hash |
| `nchaintx` | Cumulative transaction count through the base block |
| `coins_written` | Number of L1 coins in the dump |
| `mweb_coins_written` | MWEB coins in the dump |
| `mweb_leafdb_entries_written` | MWEB leaf DB entries in the dump |
| `mweb_o_dat_bytes` | Bytes written from O.dat |
| `mweb_leaf_dat_bytes` | Bytes written from leaf.dat |
| `mweb_prun_dat_bytes` | Bytes written from prun.dat |
| `dumped` | UTC date and method (`dumptxoutset latest` / `rollback`) |
| `file_uncompressed` | `loadtxoutset` input: filename, byte size, SHA-256 |
| `file_compressed` | GitHub Release asset: filename, byte size, SHA-256 |

## Testnet — height 4859037

| Field | Value |
|-------|--------|
| `network` | testnet |
| `height` | 4859037 |
| `blockhash` | `783c629cf938bb949e1e53ce63e7e2b88671d0c50f0be51759792639bdc181e3` |
| `txoutset_hash` | `117cb91d9eb0bd77529fc97d652294251ed1afa2ca87e7a111104c6e3ae59d6c` |
| `mweb_hash` | `1649b6c5a48efc44cc76fc55f7495423319ea18174520915008fba7f873ca354` |
| `nchaintx` | 12991192 |
| `coins_written` | 8402278 |
| `mweb_coins_written` | 1573 |
| `mweb_leafdb_entries_written` | 1573 |
| `mweb_o_dat_bytes` | 480896 |
| `mweb_leaf_dat_bytes` | 948 |
| `mweb_prun_dat_bytes` | 0 |
| `dumped` | 2026-08-20, `dumptxoutset rollback=4859037` (ibd-testnet tip ~4860418) |
| `file_uncompressed` | `ltc-testnet-4859037.dat` — 397 MiB (416310767 bytes) — `0365faf8caf7bbfb4ab163b2458fb8d26463d6b5a3f5aa3e9f70bf663dbf532d` |
| `file_compressed` | `ltc-testnet-4859037.dat.zst` — 255 MiB (267855219 bytes) — `c3949e721e993c1440eca6b9ce4bf645b9d33efc75d78cf938be744c165e0f94` |
