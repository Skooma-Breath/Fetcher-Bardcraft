# Bardcraft song-loading regression checks

Run from `C:\serena_workspaces_directory` with Lua 5.1 (the sort compatibility
check intentionally compares against Lua 5.1/LuaJIT ordering):

```powershell
$bardcraftData = 'fetcher-simulator/Data Files/fetcher-simulator/Gameplay/BardcraftOpenMW'
lua Fetcher-Bardcraft/tests/test_song_loading.lua $bardcraftData
lua Fetcher-Bardcraft/tests/test_hosted_song_client.lua $bardcraftData
lua Fetcher-Bardcraft/tests/test_hosted_midi_server.lua openmw/apps/openmw-server/scripts
python -m unittest discover -s Fetcher-Bardcraft/tests -p test_build_patch.py
```

`test_song_loading.lua` covers exact equal-key sort ordering, a 240 KB synthetic
MIDI with 60,000 note events, incremental conversion, content hashes, decoded
cache retention, per-song storage writes, legacy cache migration, and malformed
input. Its optional second argument is a baseline data root containing the
2.0.22 `scripts/Bardcraft` tree; it then compares the original content hash and
note segments as well.

`test_hosted_song_client.lua` executes the production hosted-download handlers
with mocked engine APIs. It covers deferred parsing, chunk assembly, stale
tokens, older server responses, sequential requests, cache reuse, and catalog
removal. It uses the locally installed Greensleeves MIDI as a fixture.

`test_hosted_midi_server.lua` checks the shared transfer budget, alternating
receivers, cached disk reads, disconnect cancellation, disabled policy, and
replacement of an older transfer.

These checks do not measure actual OpenMW frame times or network conditions.
The in-game acceptance check is `/bccommunity on` with an uncached character,
then joining a second uncached character while the first continues playing.
Look for the client log line `background song loading complete`, which reports
the number of imported/failed songs and the largest background step in ms.

The v2.0.23 candidate and source comparison are under
`dist/build-v2.0.23-work`. Its `payload-final` directory is the release payload.
The matching server update consists of `bardcraft_persistence.lua` and the new
`bardcraft_hosted_midi.lua`; `release-files.txt` includes the new module.
Server script changes take effect after a server restart. This candidate has
not been published or deployed to the VPS.
