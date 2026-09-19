package.path = assert(arg[1], 'server scripts directory required') .. '/?.lua;' .. package.path
local clock, sends, scans, reads = 0, {}, 0, 0
local payload = string.rep('m', 40000)
package.preload.mp = function() return {
    getUptime = function() return clock end,
    listBardcraftHostedMidiFiles = function()
        scans = scans + 1
        return {{name = 'large.mid', size = #payload}}
    end,
    readBardcraftHostedMidiFile = function(name)
        assert(name == 'large.mid')
        reads = reads + 1
        return payload
    end,
    send = function(guid, event, data) sends[#sends + 1] = {guid = guid, event = event, data = data} end,
} end
local delivery = require('bardcraft_hosted_midi')
delivery.request(1, {token = 'one', names = {'large.mid', 'large.mid', '../unknown'}})
delivery.request(2, {token = 'two', names = {'large.mid'}})
local received = {[1] = '', [2] = ''}
local ended = {}
for tick = 1, 12 do
    clock = clock + 0.025
    local before = #sends
    delivery.tick(true)
    assert(#sends - before <= 1, 'more than one event per shared tick budget')
    if #sends > before then
        local message = sends[#sends]
        if message.event == 'BC_BardcraftServerSongFileChunk' then
            assert(#message.data.bytes <= 16384)
            assert(message.data.offset == #received[message.guid])
            received[message.guid] = received[message.guid] .. message.data.bytes
        else ended[message.guid] = true end
    end
    delivery.tick(true)
    assert(#sends - before <= 1, 'rate limit allowed a second send at the same time')
end
assert(received[1] == payload and received[2] == payload and ended[1] and ended[2])
assert(sends[1].guid ~= sends[2].guid, 'receivers did not alternate')
assert(scans == 1 and reads == 1, 'simultaneous joins repeated disk work')
delivery.request(1, {token = 'cancel', names = {'large.mid'}})
delivery.cancel(1)
local count = #sends
clock = clock + 1
delivery.tick(true)
assert(#sends == count, 'disconnected player still received bytes')
delivery.request(2, {token = 'off', names = {'large.mid'}})
clock = clock + 1
delivery.tick(false)
assert(sends[#sends].data.disabled and sends[#sends].event == 'BC_BardcraftServerSongFilesEnd')
delivery.request(2, {token = 'old', names = {'large.mid'}})
delivery.request(2, {token = 'new', names = {'large.mid'}})
clock = clock + 1
delivery.tick(true)
assert(sends[#sends].data.token == 'new', 'superseded request survived')
print('PASS: bounded delivery, fair simultaneous joins, cache reuse, cancellation, policy-off, request replacement')

delivery.reset()
local manifests = {}
local function reply(guid, token, files, err)
    manifests[#manifests + 1] = {guid = guid, token = token, files = files, error = err}
end
local function pumpScan(count)
    for _ = 1, 10000 do
        clock = clock + 0.025
        delivery.tick(true)
        if #manifests >= count then return end
    end
    error('catalog scan did not finish')
end
local beforeScans, beforeReads = scans, reads
delivery.requestCatalog(1, 'scan-one', true, reply)
delivery.requestCatalog(2, 'scan-two', true, reply)
assert(scans == beforeScans and reads == beforeReads, 'scan ran in event callback')
pumpScan(2)
assert(scans == beforeScans + 1 and reads == beforeReads + 1, 'concurrent scans duplicated disk work')
local fingerprint = manifests[1].files[1].fingerprint
delivery.requestCatalog(3, 'cached', false, reply)
assert(#manifests == 3 and scans == beforeScans + 1)
-- Same byte count, different content; manual scans bypass the 10-second TTL.
payload = string.rep('n', #payload)
delivery.requestCatalog(3, 'fresh', true, reply)
pumpScan(4)
assert(manifests[4].files[1].fingerprint ~= fingerprint, 'same-size replacement missed')
assert(scans == beforeScans + 2)
delivery.requestCatalog(3, 'disabled', true, reply)
delivery.tick(false)
assert(manifests[#manifests].error and not manifests[#manifests].files)
delivery.requestCatalog(3, 'disconnected', true, reply)
delivery.cancel(3)
local countBeforeCancel = #manifests
for _ = 1, 100 do delivery.tick(true) end
assert(#manifests == countBeforeCancel)
local mp = require('mp')
mp.readBardcraftHostedMidiFile = function() return nil end
delivery.requestCatalog(4, 'unreadable', true, reply)
pumpScan(countBeforeCancel + 1)
assert(manifests[#manifests].error and not manifests[#manifests].files, 'partial scan reported authoritative removal')
print('PASS: incremental fingerprint scans, TTL bypass, concurrent coalescing, same-size updates, disabled/cancelled/failed scans')

-- Exercise the production command route and persistence wire adapter too.
local function readSource(name)
    local file = assert(io.open(arg[1] .. '/' .. name, 'rb'))
    local text = file:read('*a'):gsub('\r\n', '\n'); file:close()
    return text
end
local core = readSource('core.lua')
local routeFirst = assert(core:find('    if msg == COMMAND_PREFIX .. "bcrescan" then', 1, true))
local routeLast = assert(core:find('    end', routeFirst, true)) + #'    end'
local routeEnv = setmetatable({COMMAND_PREFIX = '/', mp = mp}, {__index = _G})
local routeChunk = assert(loadstring('return function(msg, player)\n' .. core:sub(routeFirst, routeLast) .. '\nend'))
setfenv(routeChunk, routeEnv)
local route = routeChunk()
assert(route('/bcrescan', {guid = 88}) == false)
assert(sends[#sends].guid == 88 and sends[#sends].event == 'BC_RescanBardcraftServerSongs')
local registry = require('command_registry')
local help = {}
registry.sendHelp({sendMessage = function(_, text) help[#help + 1] = text end}, '/', false)
assert(table.concat(help):find('/bcrescan', 1, true), 'rescan missing from non-admin help')
local persistence = readSource('bardcraft_persistence.lua')
local adapterFirst = assert(persistence:find('local function makeHostedMidiManifest', 1, true))
local adapterLast = assert(persistence:find('local function requestedNameSet', adapterFirst, true))
local handlerFirst = assert(persistence:find('    BC_RequestBardcraftServerSongs = function(data)', 1, true))
local handlerLast = assert(persistence:find('    BC_RequestBardcraftServerSongFiles =', handlerFirst, true))
local policy = {allowServerHostedMidiDownloads = true}
mp.log = function() end
local adapterEnv = setmetatable({mp = mp, hostedMidi = delivery,
    bardcraftNetworkPolicy = policy,
    applyNetworkPolicyFields = function(payload) payload.networkPolicy = policy; return payload end,
    senderGuid = function(data) return data.pid end,
    tableCount = function(entries) return #entries end,
}, {__index = _G})
local adapterChunk = assert(loadstring(persistence:sub(adapterFirst, adapterLast - 1)
    .. '\nreturn {\n' .. persistence:sub(handlerFirst, handlerLast - 1) .. '}'))
setfenv(adapterChunk, adapterEnv)
local handlers = adapterChunk()
delivery.reset()
mp.readBardcraftHostedMidiFile = function() return payload end
handlers.BC_RequestBardcraftServerSongs({pid = 88, token = 'adapter', rescan = true})
local sentBefore = #sends
for _ = 1, 10000 do
    delivery.tick(true)
    if #sends > sentBefore then break end
end
local response = sends[#sends]
assert(response.event == 'BC_BardcraftServerSongs' and response.data.token == 'adapter')
assert(response.data.files[1].fingerprint and response.data.files[1].size == #payload)
policy.allowServerHostedMidiDownloads = false
handlers.BC_RequestBardcraftServerSongs({pid = 88, token = 'off', rescan = true})
assert(sends[#sends].data.disabled and sends[#sends].data.token == 'off')
print('PASS: /bcrescan chat routing, non-admin help, production manifest adapter, fingerprints and tokens on wire, disabled policy')
