local root = assert(arg[1], 'Bardcraft data root required')
package.path = root .. '/?.lua;' .. package.path
local values, sent, messages = {}, {}, {}
local payloadWrites = 0
local clockOffset = 0
local section = {
    get = function(_, key) return values[key] end,
    getCopy = function(_, key) return values[key] end,
    set = function(_, key, value)
        values[key] = value
        if key:find('songs/serverCustomRecord:', 1, true) then payloadWrites = payloadWrites + 1 end
    end,
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
    core = {getRealTime = function() return os.clock() + clockOffset end, sendGlobalEvent = function() end},
    ui = {showMessage = function(message) messages[#messages + 1] = message end},
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
env.RemoteBardcraftPlayback = remote
local policyFirst = assert(source:find('function RemoteBardcraftPlayback.normalizedNetworkPolicy', 1, true))
local policyLast = assert(source:find('function RemoteBardcraftPlayback.showMissingSong', policyFirst, true))
local policyChunk = assert(loadstring(source:sub(policyFirst, policyLast - 1)))
setfenv(policyChunk, env); policyChunk()
local enabled = {networkPolicy = {communitySongSharingMode = true, allowServerHostedMidiDownloads = true}}
remote.applyNetworkPolicy(enabled)
local parses = 0
local originalParse = env.MIDI.ParseMidiBytes
env.MIDI.ParseMidiBytes = function(...)
    parses = parses + 1
    return originalParse(...)
end
local chunk = assert(loadstring(source:sub(first, last - 1) .. '\nreturn applyHostedServerSongFiles'))
setfenv(chunk, env)
local receiveLegacy = chunk()
-- Server events enter the global script before reaching the local player.
local globalFile = assert(io.open(root .. '/scripts/Bardcraft/globalevents.lua', 'rb'))
local globalSource = globalFile:read('*a'):gsub('\r\n', '\n'); globalFile:close()
local relay = assert(globalSource:match("(BC_RescanBardcraftServerSongs = function%(data%).-\n        end,)"), 'missing global rescan relay')
local localHandler = assert(source:match("(BC_RescanBardcraftServerSongs = function%(%).-\n        end,)"))
local localChunk = assert(loadstring('return {' .. localHandler .. '}'))
setfenv(localChunk, env)
local localEvents = localChunk()
local relayEnv = setmetatable({forwardBardcraftPlayerEvent = function(event, data)
    return assert(localEvents[event], 'missing local rescan handler')(data)
end}, {__index = _G})
local relayChunk = assert(loadstring('return {' .. relay .. '}'))
setfenv(relayChunk, relayEnv)
relayChunk().BC_RescanBardcraftServerSongs({})
assert(remote.hostedLoader.manual and sent[#sent].event == 'BC_RequestBardcraftServerSongs', 'rescan did not cross global/player bridge')
remote.hostedLoader = {}
table.remove(sent)
local midiFile = assert(io.open(root .. '/midi/Bardcraft/preset/greensleeves.mid', 'rb'))
local bytes = midiFile:read('*a'); midiFile:close()
local catalog = {files = {{name = 'a.mid', size = #bytes}, {name = 'b.mid', size = #bytes}}}
local function request(manifest, manual)
    assert(remote.requestHostedManifest(manual))
    assert(sent[#sent].event == 'BC_RequestBardcraftServerSongs')
    table.remove(sent) -- Keep the existing transfer assertions focused on file requests.
    manifest.token = remote.hostedLoader.token
    remote.queueHostedManifest(manifest)
end
request(catalog)
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
assert(not Store.isRecordDecoded('songs/serverCustom', firstRecord), 'import retained decoded MIDI')
local decoded = Store.decodeRecord('songs/serverCustom', firstRecord)
-- An older server can still answer with the unchunked event, without a token.
receiveLegacy({files = {{name = 'b.mid', bytes = bytes}}})
pumpUntil(function() return not remote.hostedLoader.active end)
assert(Store.decodeRecord('songs/serverCustom', firstRecord) == decoded, 'second import evicted first playback cache')
local requests = #sent
request(catalog, true)
assert(not remote.requestHostedManifest(true), 'duplicate scan accepted')
pumpUntil(function() return not remote.hostedLoader.active end)
assert(#sent == requests, 'unchanged catalog downloaded songs again')
assert(parses == 2 and messages[#messages]:find('no changes (2 cached)', 1, true))
local revision = values['songs/serverCustomRevision']
remote.applyNetworkPolicy({})
assert(#Store.getRecords('songs/serverCustom') == 0, 'disabled songs exposed')
assert(Store.decodeRecord('songs/serverCustom', firstRecord) == nil, 'disabled song decoded')
assert(#Store.getRecords('songs/serverCustom', true) == 2, 'disabled policy purged persistent cache')
assert(values['songs/serverCustomRevision'] == revision and values['songs/serverCustomManifest']['a.mid'])
assert(not remote.requestHostedManifest(true) and messages[#messages]:find('disabled'))
remote.queueHostedManifest(catalog)
assert(not remote.hostedLoader.manifest, 'late manifest revived disabled loader')
remote.applyNetworkPolicy(enabled)
request(catalog, true)
pumpUntil(function() return not remote.hostedLoader.active end)
assert(#sent == requests and parses == 2, 'OFF/ON reimported unchanged cache')
request({files = {{name = 'a.mid', size = #bytes, fingerprint = 'first'}}}, true)
pumpUntil(function() return not remote.hostedLoader.active end)
assert(#Store.getRecords('songs/serverCustom') == 1, 'removed song survived catalog refresh')
assert(parses == 2, 'legacy fingerprint adoption reparsed unchanged songs')
local changed = {files = {{name = 'a.mid', size = #bytes, fingerprint = 'changed'}, {name = 'new.mid', size = #bytes, fingerprint = 'new'}}}
request(changed, true)
pumpUntil(function() return #sent == requests + 1 end)
assert(sent[#sent].data.names[1] == 'a.mid', 'same-size change not requested')
-- Failed replacement must preserve the old payload AND its old manifest version.
receiveLegacy({files = {}})
pumpUntil(function() return #sent == requests + 2 end)
assert(Store.getRecords('songs/serverCustom')[1] == firstRecord)
assert(values['songs/serverCustomManifest']['a.mid'].fingerprint == 'first')
receiveLegacy({files = {{name = 'new.mid', bytes = bytes}}})
pumpUntil(function() return not remote.hostedLoader.active end)
assert(messages[#messages]:find('new=1 updated=1 removed=0 failed=1', 1, true))
request(changed, true)
pumpUntil(function() return #sent == requests + 3 end)
assert(sent[#sent].data.names[1] == 'a.mid', 'failed change not retried')
receiveLegacy({files = {{name = 'a.mid', bytes = bytes}}})
pumpUntil(function() return not remote.hostedLoader.active end)
assert(parses == 4, 'unchanged new song reparsed')
assert(values['songs/serverCustomManifest']['a.mid'].fingerprint == 'changed')
request(changed, true)
pumpUntil(function() return not remote.hostedLoader.active end)
assert(parses == 4 and messages[#messages]:find('no changes (2 cached)', 1, true))
-- Cancellation drops the in-flight request; tokens isolate the next scan.
request({files = {{name = 'pending.mid', size = #bytes}}}, true)
pumpUntil(function() return remote.hostedLoader.inFlight end)
local cancelledToken = remote.hostedLoader.token
remote.applyNetworkPolicy({})
remote.receiveHostedSongChunk({token = cancelledToken, name = 'pending.mid', size = #bytes, offset = 0, bytes = bytes})
remote.finishHostedSongChunks({token = cancelledToken})
assert(not remote.hostedLoader.active and not remote.hostedLoader.chunks)
remote.applyNetworkPolicy(enabled)
assert(remote.requestHostedManifest(true))
remote.queueHostedManifest({token = cancelledToken, files = {}})
assert(remote.hostedLoader.awaitingManifest, 'stale manifest accepted')
clockOffset = 121
remote.tickHostedSongLoading()
assert(not remote.hostedLoader.active and messages[#messages]:find('timed out'))
assert(remote.requestHostedManifest(true), 'timeout prevented retry')
remote.queueHostedManifest({token = remote.hostedLoader.token, disabled = true, files = {}})
pumpUntil(function() return not remote.hostedLoader.active end)
assert(messages[#messages]:find('disabled'))
request({files = {{name = 'invalid.mid', size = 7}}}, true)
pumpUntil(function() return remote.hostedLoader.inFlight end)
receiveLegacy({files = {{name = 'invalid.mid', bytes = 'invalid'}}})
pumpUntil(function() return not remote.hostedLoader.active end)
assert(messages[#messages]:find('failed=1', 1, true), 'invalid MIDI not counted as failed')
assert(not values['songs/serverCustomManifest']['invalid.mid'], 'invalid MIDI committed as cached')

-- Model the reported catalog size using real compact payloads, not expanded songs.
local largeCatalog, largeRecords, largeManifest = {files = {}}, {}, {}
for i = 1, 442 do
    local name = 'catalog-' .. i .. '.mid'
    local record = {}
    for key, value in pairs(firstRecord) do record[key] = value end
    record.id, record.sourceFile = 'server:' .. name, name
    largeRecords[i] = record
    largeCatalog.files[i] = {name = name, size = #bytes, fingerprint = 'unchanged'}
    largeManifest[name] = {size = #bytes, fingerprint = 'unchanged'}
end
Store.setRecords('songs/serverCustom', largeRecords)
section:set('songs/serverCustomManifest', largeManifest)
collectgarbage('collect')
local heapBefore = collectgarbage('count')
local requestsBefore, parsesBefore, writesBefore = #sent, parses, payloadWrites
request(largeCatalog, true)
pumpUntil(function() return not remote.hostedLoader.active end)
assert(#sent == requestsBefore and parses == parsesBefore and payloadWrites == writesBefore)
assert(messages[#messages]:find('no changes (442 cached)', 1, true))
remote.applyNetworkPolicy({})
assert(#Store.getRecords('songs/serverCustom', true) == 442)
remote.applyNetworkPolicy(enabled)
request(largeCatalog, true)
pumpUntil(function() return not remote.hostedLoader.active end)
assert(#sent == requestsBefore and parses == parsesBefore and payloadWrites == writesBefore)
largeCatalog.files[443] = {name = 'one-new.mid', size = #bytes, fingerprint = 'new'}
request(largeCatalog, true)
pumpUntil(function() return remote.hostedLoader.inFlight end)
assert(#sent == requestsBefore + 1 and sent[#sent].data.names[1] == 'one-new.mid')
receiveLegacy({files = {{name = 'one-new.mid', bytes = bytes}}})
pumpUntil(function() return not remote.hostedLoader.active end)
assert(parses == parsesBefore + 1 and payloadWrites == writesBefore + 1)
for _, record in ipairs(Store.getRecords('songs/serverCustom')) do
    assert(not Store.isRecordDecoded('songs/serverCustom', record), 'large catalog eagerly decoded')
end
collectgarbage('collect')
print(string.format('PASS: 442-song unchanged scan and OFF/ON: zero downloads/parses/payload rewrites; adding one: one download/parse/write; Lua heap %.1f -> %.1f KB',
    heapBefore, collectgarbage('count')))
print('PASS: deferred import, weak decoded cache, OFF/ON preservation/visibility, differential rescans, same-size updates, failures, cancellation, stale tokens, timeout, disabled scans')
