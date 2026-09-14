local dataRoot = assert(arg[1], 'Bardcraft data root required')
package.path = dataRoot .. '/?.lua;' .. package.path
local values, writes = {}, {}
local section = {
    get = function(_, key) return values[key] end,
    getCopy = function(_, key) return values[key] end,
    set = function(_, key, value) values[key] = value; writes[key] = (writes[key] or 0) + 1 end,
}
package.preload['openmw.storage'] = function() return {playerSection = function() return section end} end
package.preload['openmw.core'] = function() return {l10n = function() return function(key) return key end end} end
package.preload['openmw.vfs'] = function() return {fileExists = function() return false end} end
local Work = require('scripts.Bardcraft.util.work')
local MIDI = require('scripts.Bardcraft.util.midi')
local Song = require('scripts.Bardcraft.util.song').Song
local Store = require('scripts.Bardcraft.util.songstorage')

-- Exact equal-key sort compatibility, including arrays which partition repeatedly.
math.randomseed(21)
for size = 0, 400 do
    local a, b = {}, {}
    for i = 1, size do a[i] = {key = math.random(1, 13), id = i}; b[i] = a[i] end
    local less = function(x, y) return x.key < y.key end
    table.sort(a, less)
    Work.sort(b, less, function() end)
    for i = 1, size do assert(a[i] == b[i], 'sort order changed at ' .. size .. ':' .. i) end
end

local function bigEndian(n, length)
    local bytes = {}
    for i = length, 1, -1 do bytes[i] = string.char(n % 256); n = math.floor(n / 256) end
    return table.concat(bytes)
end
local events = {string.char(0, 192, 0)}
for i = 1, 30000 do
    events[#events + 1] = string.char(0, 144, 48 + i % 24, 90, 1, 128, 48 + i % 24, 0)
end
events[#events + 1] = string.char(0, 255, 47, 0)
local track = table.concat(events)
local midi = 'MThd' .. bigEndian(6, 4) .. bigEndian(0, 2) .. bigEndian(1, 2) .. bigEndian(96, 2)
    .. 'MTrk' .. bigEndian(#track, 4) .. track

local function convert(checkpoint)
    local parser = assert(MIDI.ParseMidiBytes('stress.mid', midi, checkpoint))
    local song = Song.fromMidiParser(parser)
    song.id, song.sourceFile = 'server:stress.mid', 'stress.mid'
    song.serverHosted, song.isServerCustom = true, true
    return {song = song, record = assert(Store.toRecord(song, checkpoint))}
end
local started = os.clock()
local expected = convert()
local synchronous = os.clock() - started
if arg[2] then
    local base = arg[2] .. '/scripts/Bardcraft/'
    local oldSong = assert(loadfile(base .. 'util/song.lua'))()
    local oldMidi = assert(loadfile(base .. 'util/midi.lua'))()
    local currentSong = package.loaded['scripts.Bardcraft.util.song']
    package.loaded['scripts.Bardcraft.util.song'] = oldSong
    local oldStore = assert(loadfile(base .. 'util/songstorage.lua'))()
    package.loaded['scripts.Bardcraft.util.song'] = currentSong
    local old = oldSong.Song.fromMidiParser(assert(oldMidi.ParseMidiBytes('stress.mid', midi)))
    old.id, old.sourceFile = 'server:stress.mid', 'stress.mid'
    old.serverHosted, old.isServerCustom = true, true
    local previous = oldStore.setRecords('songs/serverCustom', {old}, {compact = true})[1]
    assert(previous.contentHash == expected.record.contentHash, '2.0.22 content hash changed')
    assert(previous.segmentRevision == expected.record.segmentRevision, '2.0.22 notes changed')
    values, writes = {}, {}
end
local job = Work.newJob(convert, os.clock, 0.002)
local steps, maxStep, result = 0, 0, nil
repeat
    local before = os.clock()
    local done, value, err = job:step()
    maxStep = math.max(maxStep, os.clock() - before)
    steps = steps + 1
    assert(not err, err)
    if done then result = assert(value); break end
    assert(steps < 100000, 'job did not finish')
until false
assert(steps > 2, 'large import did not yield')
assert(expected.record.contentHash == result.record.contentHash, 'content hash changed')
assert(expected.record.segmentRevision == result.record.segmentRevision, 'note data changed')
assert(#expected.song.notes == #result.song.notes)
Store.setRecords('songs/serverCustom', {result.record})
Store.cacheDecodedSong('songs/serverCustom', result.record, result.song)
Store.setRecords('songs/serverCustom', {result.record}, {preserveDecoded = true})
assert(Store.decodeRecord('songs/serverCustom', result.record) == result.song, 'unchanged decoded cache lost')
assert(Store.contentHash(result.song) == expected.record.contentHash)
local recordWrites = writes['songs/serverCustomRecord:' .. result.record.id]
Store.setRecords('songs/serverCustom', {result.record}, {preserveDecoded = true})
assert(writes['songs/serverCustomRecord:' .. result.record.id] == recordWrites, 'unchanged song serialized again')
assert(values['songs/serverCustom'] == nil and #values['songs/serverCustomIndex'] == 1)
Store.setRecords('songs/serverCustom', {})
assert(values['songs/serverCustomRecord:' .. result.record.id] == nil and #Store.getRecords('songs/serverCustom') == 0)
-- Read an old array-format cache, then migrate without losing its note payload.
values, writes = {['songs/serverCustom'] = {result.record}}, {}
package.loaded['scripts.Bardcraft.util.songstorage'] = nil
local migrated = require('scripts.Bardcraft.util.songstorage')
local oldRecords = migrated.getRecords('songs/serverCustom')
assert(oldRecords[1].contentHash == result.record.contentHash)
migrated.setRecords('songs/serverCustom', oldRecords, {preserveDecoded = true})
assert(values['songs/serverCustomRecord:' .. result.record.id].contentHash == result.record.contentHash)
assert(values['songs/serverCustom'] == nil)
local malformed = Work.newJob(function(checkpoint)
    assert(MIDI.ParseMidiBytes('bad.mid', 'invalid', checkpoint), 'malformed MIDI')
end, os.clock)
local done, _, err = malformed:step()
assert(done and err, 'malformed job was not contained')
print(string.format('PASS: %d MIDI bytes, %d note events; synchronous %.1f ms; %d background steps, longest %.2f ms',
    #midi, #result.song.notes, synchronous * 1000, steps, maxStep * 1000))
