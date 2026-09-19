# Hosted-song cache lifecycle patch — 2026-09-18

Implemented in the local Fetcher runtime. No production changes, commits, pushes,
deployment, engine changes, Held Light Boost changes, or settings changes.

## Root causes and resulting behavior

- Policy OFF formerly called `setRecords('songs/serverCustom', {})`, deleting the
  persistent index and payloads. Both policy and disabled-manifest purge paths
  are removed. OFF drops the loader/coroutine/chunks/queues and hides hosted
  records and decoding through SongStorage. Persistent payloads and manifest
  versions survive. OFF/ON requests a fresh comparison against that cache.
- Imports formerly retained the expanded song in `decodedCache` after compacting
  it. Imports now persist only compact records. Hosted decoded buckets use weak
  values, including after `preserveDecoded`, so active playback/editor owners
  retain their songs and unowned songs can be collected. Other storage modes
  retain their existing cache behavior.
- `/bcrescan` is available to ordinary players in command help. It asks the
  client to issue the existing manifest request with a new token and explicit
  rescan flag. It ignores the startup-only `serverSongsRequested` gate, prevents
  concurrent client scans, rejects stale tokened responses, times out stalled
  requests, and reports completion/failure. It never enables community mode.
- Reconciliation keeps unchanged records and decoded owners, removes records
  absent from the authoritative catalog, and downloads only changed/missing
  entries through the existing incremental import worker. Failed replacements
  retain the previous compact song and its previous manifest version for retry.
- Server scans fingerprint raw MIDI bytes without parsing notes, using a shared
  coroutine with a 2 ms CPU budget and 4096-byte checkpoints. Manual scans bypass
  the catalog TTL; concurrent clients share the scan. Fingerprints detect later
  same-size replacements. Unreadable files abort the scan instead of publishing
  a partial catalog that would remove cached songs.

## Modified files

Runtime client:

- [player.lua](<C:/serena_workspaces_directory/fetcher-simulator/Data Files/fetcher-simulator/Gameplay/BardcraftOpenMW/scripts/Bardcraft/player.lua>)
- [globalevents.lua](<C:/serena_workspaces_directory/fetcher-simulator/Data Files/fetcher-simulator/Gameplay/BardcraftOpenMW/scripts/Bardcraft/globalevents.lua>)
- [util/songstorage.lua](<C:/serena_workspaces_directory/fetcher-simulator/Data Files/fetcher-simulator/Gameplay/BardcraftOpenMW/scripts/Bardcraft/util/songstorage.lua>)

Local server scripts:

- [core.lua](C:/serena_workspaces_directory/fetcher-simulator/server-scripts/core.lua)
- [command_registry.lua](C:/serena_workspaces_directory/fetcher-simulator/server-scripts/command_registry.lua)
- [bardcraft_persistence.lua](C:/serena_workspaces_directory/fetcher-simulator/server-scripts/bardcraft_persistence.lua)
- [bardcraft_hosted_midi.lua](C:/serena_workspaces_directory/fetcher-simulator/server-scripts/bardcraft_hosted_midi.lua)

Existing harnesses and documentation:

- [test_hosted_song_client.lua](C:/serena_workspaces_directory/Fetcher-Bardcraft/tests/test_hosted_song_client.lua)
- [test_hosted_midi_server.lua](C:/serena_workspaces_directory/Fetcher-Bardcraft/tests/test_hosted_midi_server.lua)
- [test_song_loading.lua](C:/serena_workspaces_directory/Fetcher-Bardcraft/tests/test_song_loading.lua)
- [tests/README.md](C:/serena_workspaces_directory/Fetcher-Bardcraft/tests/README.md)
- This review report.

Original runtime files and tests are backed up under
`C:\serena_workspaces_directory\backups\bardcraft-hosted-lifecycle-20260918`.
`runtime.patch` in that directory records all seven runtime diffs.

## Verification

All three hosted/loading Lua 5.1 harnesses pass against the actual runtime paths.
The harnesses mock OpenMW APIs and execute the production functions.

- 442 compact records: unchanged scan and OFF/ON produce zero downloads, zero
  MIDI parses, and zero payload rewrites. Adding one file produces exactly one
  download, parse, and payload write. No catalog records become eagerly decoded.
- Same-size changed fingerprints, authoritative removals, failed replacements,
  malformed MIDI, duplicate scans, disabled scans, cancellation, stale tokens,
  timeout/retry, and legacy file responses pass.
- Server command routing, non-admin help, production manifest serialization,
  fingerprint/token propagation, incremental scans, coalescing, freshness,
  disabled/failed scans, transfer fairness and chunk limits pass.
- Twelve independent 60,000-note decodes: only the actively owned song survives
  collection; releasing it leaves none. Lua heap: 38,828.6 KB before versus
  38,585.5 KB after collection. This is harness memory, not OpenMW profiler data.
- Synthetic 442-record test: 1,555.0 KB before versus 1,640.9 KB after adding one
  song and collecting. Fixtures reuse compact note payloads; this does not
  represent the RAM footprint of the real 442-song library.
- 240,029-byte MIDI / 60,000 events: 416 background steps, longest 4.00 ms in the
  final run; synchronous conversion 618 ms. Timing is machine/run dependent.
- Lua 5.1 syntax checks pass for all seven changed runtime files.
- Python builder tests: 3 passed. Client generated metadata test: passed.
- Additional generated-bards harness fails at its initialization assertion
  (`tools/bardcraft_patch/tests/test_bardcraft_generated_bards.lua:54`). Its
  engine mock lacks `mp.hasStaticNpcRecord`, now required by the unchanged
  `bardcraft_generated_bards.lua`. This unrelated test/module was not altered.

## Live acceptance validation — 2026-09-18

The local 436-file hosted library was validated with the patched server and a
relogged Sith Soldier client. The global `BC_RescanBardcraftServerSongs` relay
was added after the first live `/bcrescan` exposed the missing global-to-player
bridge; the hosted-client harness now exercises that bridge.

- Initial full import from an empty client cache: 435 parsed, 1 failed
  (`MMcredits.mid`), 8,896 background steps, 10.11 ms maximum step.
- Relog with community mode initially OFF preserved all compact hosted records.
  After `/login changeme` and `/bccommunity on`, the first manifest reported
  `files=436 cached=435 missing=1`; it parsed zero valid songs and retried only
  the known invalid MIDI.
- Manual `/bcrescan`: `server=436 cached=435 new=1 updated=0 removed=0 failed=1`;
  zero valid parses, with the sole `new`/failed entry being the still-uncached
  invalid `MMcredits.mid`. Maximum background step was 3.47 ms.
- `/bccommunity off` followed by `/bccommunity on` did not purge the cache. The
  next manifest again reported `cached=435 missing=1` and parsed zero valid
  songs. A second manual rescan likewise parsed zero valid songs (3.68 ms max).
- Adding one temporary valid MIDI produced `files=437 cached=435 missing=2`; the
  loader parsed exactly one valid song and failed only `MMcredits.mid`
  (`parsed=1 failed=1`, 5.62 ms max). Removing that file and rescanning produced
  `removed=1`, restored the authoritative 436-file catalog, and parsed zero
  valid songs. The temporary file was removed afterward.
- Earlier live Lua-profiler observations during/after the initial import were
  128 MB and 137 MB. After the relog, rescans, OFF→ON cycle, add/remove test, and
  cleanup, the F3 Lua profiler reported `Memory allocations > 128 bytes: 94 MB`,
  `Lua: 1.22 ms`, and `LuaSync: 0.51 ms`. Sith Soldier's process memory was flat
  across a short sample at about 3.83 GB private / 2.88 GB working set. This is
  far below the prior ~1 GB Lua-memory failure mode that accompanied the hitch.
- A live hosted playback of `Metroid NES - Brinstar.mid` was observed. The F3
  profiler showed 95 MB of tracked allocations over 128 bytes while playing,
  versus 94 MB before playback. After `PerformStop`, it still rounded to 95 MB,
  while process memory eased from roughly 3574 to 3564 MB working set and 4605
  to 4603 MB private. There was no visible retained-memory ratchet from the
  playback.

The cache/rescan lifecycle live acceptance sequence therefore passes. The live
profiler reports whole-megabyte totals, so one song's weak-cache collection
cannot be proven from that coarse number alone; the focused Lua harness remains
the definitive check that the hosted decoded weak value becomes collectible
after its strong owner is released.

## Remaining checks before release

Legacy stored manifests contain sizes only. Their first fingerprint is adopted
without forcing a full-library download. A same-size edit predating that first
adoption cannot be detected reliably. Subsequent scans compare fingerprints.
An unpatched server remains size-only and does not supply `/bcrescan` routing.
Fingerprint scanning reads raw files incrementally on the server; individual
filesystem reads remain synchronous. The known invalid `MMcredits.mid` is not
fixed and will continue to count as missing/failed if still invalid.

The runtime is not a Git repository. The Fetcher-Bardcraft Git changes cover the
tests/documentation; the runtime patch and backup preserve the implementation
for review and later packaging. No release archive was rebuilt or published.
