--[[
* Test harness for Casper2.lua (run with LuaJIT, the runtime Ashita v4 uses).
*
* Simulates just enough of Ashita v4 for the addon to load and run:
*   addon table, require 'common', struct.unpack, bit (built into LuaJIT),
*   GetEntity, ashita.events.register, string:args, print.
* Packets are built byte-for-byte using the 0x000E layout documented in XiPackets.
*
* Usage: luajit tests/test_Casper2.lua path/to/Casper2.lua
--]]

local addon_path = assert(arg[1], 'pass the path to Casper2.lua');

----------------------------------------------------------------------------------------------------
-- Ashita simulation
----------------------------------------------------------------------------------------------------

addon = {};
package.preload['common'] = function () return true; end

-- Little-endian struct.unpack for the formats the addon uses ('B', 'H'). Offset is 1-based like Ashita's.
struct = {
    unpack = function (fmt, s, pos)
        if (fmt == 'B') then return s:byte(pos); end
        if (fmt == 'H') then local a, b = s:byte(pos, pos + 1); return a + b * 256; end
        error('unsupported format ' .. fmt);
    end,
};

-- Entity table. Missing slots return nil, as GetEntity does for empty slots.
local entities = {};
function GetEntity(index) return entities[index]; end
local function spawn_entity(index, flags) entities[index] = { Render = { Flags0 = flags or 0 } }; end

local handlers = {};
ashita = { events = { register = function (ev, name, fn) handlers[ev] = handlers[ev] or {}; handlers[ev][name] = fn; end } };
local function fire(ev, e) for _, fn in pairs(handlers[ev] or {}) do fn(e or {}); end end

-- string:args() from Ashita's common lib (simple whitespace split is enough here).
function string:args() local t = {}; for w in self:gmatch('%S+') do t[#t + 1] = w; end return t; end

local printed = {};
print = function (s) printed[#printed + 1] = s; end

----------------------------------------------------------------------------------------------------
-- Packet builders
----------------------------------------------------------------------------------------------------

local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256); end

-- Builds a 0x000E packet. size covers the header up to and including SubKind (0x32 bytes) plus a model id.
local function npc_packet(index, sendflg, subkind, status_bits, short)
    local b = {};
    b[1] = u16(0x000E) .. u16(0);            -- 0x00 id/size, sync
    b[2] = string.char(1, 0, 0, 0);          -- 0x04 UniqueNo
    b[3] = u16(index);                       -- 0x08 ActIndex
    b[4] = string.char(sendflg, 0);          -- 0x0A SendFlg, dir
    b[5] = string.rep('\0', 0x30 - 0x0C);    -- 0x0C .. 0x2F position/flags/etc
    local p = table.concat(b);
    assert(#p == 0x30, 'builder offset error');
    if (short) then return p; end
    return p .. u16(bit.bor(subkind or 0, (status_bits or 0) * 8)) .. u16(0x1234);
end

local function pc_packet(index)
    return u16(0x000D) .. u16(0) .. string.char(1, 0, 0, 0) .. u16(index) .. string.rep('\0', 0x40);
end

local function packet(id, data) fire('packet_in', { id = id, data_modified = data }); end
local function present() fire('d3d_present'); end
local function command(text) local e = { command = text, blocked = false }; fire('command', e); return e.blocked; end
local function ghosted(index) return bit.band(entities[index].Render.Flags0, 0x40) ~= 0; end
-- Simulates the client re-initialising an entity's render flags while it handles a spawn packet.
local function client_wipes(index) entities[index].Render.Flags0 = 0; end

----------------------------------------------------------------------------------------------------
-- Tests
----------------------------------------------------------------------------------------------------

dofile(addon_path);

local passed, failed = 0, 0;
local function test(name, fn)
    -- Fresh world for every test; addon state is reset by a zone-in packet.
    entities = {}; printed = {};
    packet(0x000A, string.rep('\0', 8));
    command('/casper2 npc on'); printed = {};
    local ok, err = pcall(fn);
    if (ok) then passed = passed + 1; io.stdout:write('PASS  ', name, '\n');
    else failed = failed + 1; io.stdout:write('FAIL  ', name, '\n      ', tostring(err), '\n'); end
end

local FULL = 0x1F; -- Position|Claim|General|Name|Model
local POS  = 0x01;

test('addon metadata is set', function ()
    assert(addon.name == 'Casper2' and addon.version == '1.0');
end);

test('players are ghosted exactly as before (0x000D)', function ()
    spawn_entity(1100);
    packet(0x000D, pc_packet(1100));
    assert(ghosted(1100));
end);

test('players stay ghosted even with NPC option off', function ()
    command('/casper2 npc off');
    spawn_entity(1100);
    packet(0x000D, pc_packet(1100));
    assert(ghosted(1100));
end);

test('monster / normal NPC (SubKind 0,1,5,6,7) is ghosted on spawn', function ()
    for i, kind in ipairs({ 0, 1, 5, 6, 7 }) do
        spawn_entity(100 + i);
        packet(0x000E, npc_packet(100 + i, FULL, kind));
        assert(ghosted(100 + i), 'kind ' .. kind);
    end
end);

test('doors, elevators and ships (SubKind 2,3,4) stay solid', function ()
    for i, kind in ipairs({ 2, 3, 4 }) do
        spawn_entity(200 + i);
        packet(0x000E, npc_packet(200 + i, FULL, kind));
        present();
        assert(not ghosted(200 + i), 'kind ' .. kind);
    end
end);

test('Status bits above SubKind are masked off', function ()
    spawn_entity(300); spawn_entity(301);
    packet(0x000E, npc_packet(300, FULL, 0, 0x1FFF)); -- mob with all Status bits set
    packet(0x000E, npc_packet(301, FULL, 2, 0x1FFF)); -- door with all Status bits set
    assert(ghosted(300) and not ghosted(301));
end);

test('bit is re-applied next frame if the client wipes flags on spawn', function ()
    spawn_entity(400);
    packet(0x000E, npc_packet(400, FULL, 0));
    client_wipes(400);
    assert(not ghosted(400));
    present();
    assert(ghosted(400));
end);

test('position-only update for a known mob re-ghosts it', function ()
    spawn_entity(401);
    packet(0x000E, npc_packet(401, FULL, 0));
    client_wipes(401);
    packet(0x000E, npc_packet(401, POS, 0, 0, true)); -- short packet, no SubKind
    assert(ghosted(401));
end);

test('position-only update for an unknown entity does nothing (elevator safety)', function ()
    spawn_entity(402);
    packet(0x000E, npc_packet(402, POS, 0));
    present();
    assert(not ghosted(402));
end);

test('known elevator receiving position updates stays solid', function ()
    spawn_entity(403);
    packet(0x000E, npc_packet(403, FULL, 3));
    packet(0x000E, npc_packet(403, POS, 0)); -- SubKind field garbage/0 on pos updates
    present();
    assert(not ghosted(403));
end);

test('slot reused by a door without despawn is restored to solid', function ()
    spawn_entity(404);
    packet(0x000E, npc_packet(404, FULL, 0));
    assert(ghosted(404));
    packet(0x000E, npc_packet(404, FULL, 2));
    present();
    assert(not ghosted(404));
end);

test('despawn clears our bit and forgets the slot', function ()
    spawn_entity(405);
    packet(0x000E, npc_packet(405, FULL, 0));
    packet(0x000E, npc_packet(405, 0x20, 0, 0, true));
    assert(not ghosted(405));
    packet(0x000E, npc_packet(405, POS, 0, 0, true)); -- kind forgotten -> untouched
    present();
    assert(not ghosted(405));
end);

test('toggle off restores NPCs we changed but not bits the game set', function ()
    spawn_entity(500); spawn_entity(501, 0x40);
    packet(0x000E, npc_packet(500, FULL, 0));
    packet(0x000E, npc_packet(501, FULL, 0)); -- already had the bit from the game
    assert(command('/casper2 npc off'));
    assert(not ghosted(500), 'ours should be cleared');
    assert(ghosted(501), "game's own bit must be preserved");
    packet(0x000E, npc_packet(500, POS, 0, 0, true));
    present();
    assert(not ghosted(500), 'must stay solid while off');
end);

test('toggle back on applies on the next update without re-zoning', function ()
    spawn_entity(502);
    command('/casper2 npc off');
    packet(0x000E, npc_packet(502, FULL, 0)); -- seen while off: tracked, not ghosted
    assert(not ghosted(502));
    command('/casper2 npc on');
    packet(0x000E, npc_packet(502, POS, 0, 0, true));
    assert(ghosted(502));
end);

test('bare toggle flips the option', function ()
    command('/casper2 npc');
    assert(printed[1]:find('OFF'), printed[1]);
    command('/casper2 mobs');
    assert(printed[2]:find('ON'), printed[2]);
end);

test('zone change clears tracking', function ()
    spawn_entity(600);
    packet(0x000E, npc_packet(600, FULL, 0));
    packet(0x000B, string.rep('\0', 8));
    entities = {}; spawn_entity(600);         -- new zone, same slot index
    packet(0x000E, npc_packet(600, POS, 0, 0, true));
    present();
    assert(not ghosted(600));
end);

test('unload restores every NPC we changed', function ()
    spawn_entity(700); spawn_entity(701);
    packet(0x000E, npc_packet(700, FULL, 0));
    packet(0x000E, npc_packet(701, FULL, 5));
    fire('unload');
    assert(not ghosted(700) and not ghosted(701));
end);

test('missing entity slots and truncated packets do not error', function ()
    packet(0x000E, npc_packet(800, FULL, 0));            -- no entity yet
    present();
    packet(0x000E, string.rep('\0', 6));                 -- too short to read SendFlg
    packet(0x000E, npc_packet(801, FULL, 0, 0, true));   -- name/model flag but too short for SubKind
    packet(0x000D, pc_packet(802));                      -- player with no entity
end);

test('/casper2 prints status; other commands are not swallowed', function ()
    assert(command('/casper2'));
    assert(printed[1]:find('NPCs/mobs: ON'));
    assert(not command('/echo hi'));
    assert(not command('/casper2x'));
end);

test('other packets are ignored', function ()
    spawn_entity(900);
    packet(0x0028, npc_packet(900, FULL, 0));
    assert(not ghosted(900));
end);

io.stdout:write(('\n%d passed, %d failed\n'):format(passed, failed));
os.exit(failed == 0 and 0 or 1);
