local root = assert(arg[1], 'Bardcraft data root required')
package.path = root .. '/?.lua;' .. package.path
local values, sent = {}, {}
local section = {
    get = function(_, key) return values[key] end,
    getCopy = function(_, key) return values[key] end,
    set = function(_, key, value) values[key] = value end,
}
package.preload['openmw.storage'] = function() return {playerSection = function() return section end} end
package.preload['openmw.core'] = function() return {l10n = function() return function(key) return key end end} end
package.preload['openmw.vfs'] = function() return {fileExists = function() return false end} end
local Store = require('scripts.Bardcraft.util.songstorage')
local f = assert(io.open(root .. '/scripts/Bardcraft/player.lua', 'rb'))
local source = f:read('*a'):gsub('\r\n', '\n'); f:close()
local first = assert(source:find('local function serverCustomSongMap()', 1, true))
local last = assert(source:find('local function copySongManifestRecord', first, true))
-- Exercise the actual production download handlers and frame worker with engine APIs mocked.
local env = setmetatable({
    core = {getRealTime = os.clock, sendGlobalEvent = function() end},
    self = {id = 'tester'},
    storage = {playerSection = function() return section end},
    SongStorage = Store,
    Song = require('scripts.Bardcraft.util.song').Song,
    MIDI = require('scripts.Bardcraft.util.midi'),
    bardcraftPersistence = {loaded = true},
    mpPersistenceAvailable = function() return true end,
    getServerCustomSongs = function() return Store.getRecords('songs/serverCustom') end,
    invalidateEditorPerformanceSongCache = function() end,
    reconcileKnownSongsWithCurrentSongs = function() end,
    refreshEditorIfActive = function() end,
    print = function() end,
    mp = {sendToServer = function(event, data) sent[#sent + 1] = {event = event, data = data} end},
}, {__index = _G})
local remote = {hostedWork = require('scripts.Bardcraft.util.work'), hostedLoader = {}, networkPolicy = {allowServerHostedMidiDownloads = true}}
remote.applyNetworkPolicy = function() end
env.RemoteBardcraftPlayback = remote
local chunk = assert(loadstring(source:sub(first, last - 1) .. '\nreturn applyHostedServerSongFiles'))
setfenv(chunk, env)
local receiveLegacy = chunk()
local midiFile = assert(io.open(root .. '/midi/Bardcraft/preset/greensleeves.mid', 'rb'))
local bytes = midiFile:read('*a'); midiFile:close()
local catalog = {files = {{name = 'a.mid', size = #bytes}, {name = 'b.mid', size = #bytes}}}
remote.queueHostedManifest(catalog)
local function pumpUntil(predicate)
    for _ = 1, 50000 do
        remote.tickHostedSongLoading()
        if predicate() then return end
    end
    error('client worker did not complete')
end
pumpUntil(function() return #sent == 1 end)
assert(#sent[1].data.names == 1, 'more than one MIDI requested before parsing')
local token = sent[1].data.token
remote.receiveHostedSongChunk({token = 'stale', name = 'a.mid', size = #bytes, offset = 0, bytes = bytes:sub(1, 16)})
assert(not remote.hostedLoader.chunks, 'stale response accepted')
for offset = 0, #bytes - 1, 16384 do
    remote.receiveHostedSongChunk({token = token, name = 'a.mid', size = #bytes, offset = offset, bytes = bytes:sub(offset + 1, offset + 16384)})
end
remote.finishHostedSongChunks({token = token})
assert(#Store.getRecords('songs/serverCustom') == 0, 'receive event parsed the MIDI synchronously')
pumpUntil(function() return #sent == 2 end)
local firstRecord = assert(Store.getRecords('songs/serverCustom')[1])
assert(Store.isRecordDecoded('songs/serverCustom', firstRecord))
local decoded = Store.decodeRecord('songs/serverCustom', firstRecord)
-- An older server can still answer with the unchunked event, without a token.
receiveLegacy({files = {{name = 'b.mid', bytes = bytes}}})
pumpUntil(function() return #Store.getRecords('songs/serverCustom') == 2 and not remote.hostedLoader.batchReady and not remote.hostedLoader.job end)
assert(Store.decodeRecord('songs/serverCustom', firstRecord) == decoded, 'second import evicted first playback cache')
local requests = #sent
remote.queueHostedManifest(catalog)
pumpUntil(function() return not remote.hostedLoader.manifest and not remote.hostedLoader.job end)
assert(#sent == requests, 'unchanged catalog downloaded songs again')
remote.queueHostedManifest({files = {{name = 'a.mid', size = #bytes}}})
pumpUntil(function() return not remote.hostedLoader.manifest and not remote.hostedLoader.job end)
assert(#Store.getRecords('songs/serverCustom') == 1, 'removed song survived catalog refresh')
print('PASS: actual client handlers, deferred parsing, chunk assembly, stale tokens, old server responses, cache reuse, catalog refresh/removal')
