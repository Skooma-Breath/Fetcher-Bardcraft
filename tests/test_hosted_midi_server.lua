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
