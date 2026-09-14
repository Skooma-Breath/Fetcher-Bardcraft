# Changelog

## 2.0.23

- Load community MIDI songs incrementally with a 2 ms cooperative frame budget,
  including MIDI parsing, note conversion/sorting, compact encoding, and hashing.
- Keep note ordering and song content hashes compatible with existing clients.
- Store hosted songs individually and retain decoded playback caches as the
  library grows, avoiding repeated full-library serialization during downloads.
- Request one hosted song at a time. With the matching server scripts, receive
  paced 16 KiB chunks shared fairly between downloading clients; retain support
  for older servers' full-file responses.
- Ignore stale transfer tokens and reuse unchanged locally cached songs.
- Reduce MIDI import allocation pressure by batching checkpoint checks, allocating raw event tables only for retained events, reusing parsed note-event tables in `getNotes()`, and materializing paired note events with compact sort tokens instead of temporary tables.

## 2.0.22

- Fix remote-player Bardcraft relay resolution so a sender-local actor ID can never resolve to the receiving client's own player.
- Keep player performance relays pending until the remote performer is resolved by authoritative GUID or display name.

## 2.0.21

- Fix first-person, third-person, and hold-to-preview camera switching while the local player is performing.
- Give Bardcraft exclusive camera-mode control only for the duration of a performance, then restore OpenMW's normal camera controller afterward.
- Restart instrument animation and VFX after completed camera-mode changes without racing OpenMW's queued camera state.

## 2.0.20

- Allow band leaders to start NPC-only or other-player-only performances without assigning an instrument to themselves.
- Keep multiple performers on the same part audible as synchronized positional 3D sources.
- Fix multiplayer join relays so joining players no longer replace an NPC performer on remote clients.
- Show remote band members in the performance editor and allow explicit instrument assignment.
- Add generated-bard stay/follow dialogue and synchronize the resulting follower state.
- Fix the generated-bard trade-choice dialogue loop.
- Include a hash-gated `Bardcraft.ESP` delta so dialogue fixes ship through the standalone patch release.
