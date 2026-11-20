--[[
* Addons - Copyright (c) 2025 Ashita Development Team
* Contact: https://www.ashitaxi.com/
* Contact: https://discord.gg/Ashita
*
* This file is part of Ashita.
*
* Ashita is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Ashita is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Ashita.  If not, see <https://www.gnu.org/licenses/>.
--]]

--[[
* MODIFICATION NOTICE (required by GPLv3 section 5a)
*
* 2026-11-20: Modified from atom0s' original casper v1.0 and renamed to Casper2.
*   Original source: https://github.com/AshitaXI/Ashita-v4beta
*   (addons/casper/casper.lua, commit a8074265f9be39474d9a5a65c4994a3170b830cb)
*   - Collision is now also removed from NPCs and monsters (packet 0x000E),
*     not only from other players (packet 0x000D).
*   - Doors, elevators/moving platforms and boats/airships are deliberately
*     left solid, because the client relies on touching those to open them
*     or to let you ride them.
*   - Added a /casper2 command to toggle the NPC/mob behaviour at runtime.
*
* Packet layout and SubKind meanings come from atom0s' XiPackets
* documentation (https://github.com/atom0s/XiPackets, world/server/0x000E).
* Only the documented facts were used; no code was copied from it.
--]]

addon.name      = 'Casper2';
addon.author    = 'atom0s (NPC/mob support: modified 2026-11-20)';
addon.version   = '1.0';
addon.desc      = 'Remove collision with other players, NPCs and monsters; walk through them like a ghost.';
addon.link      = 'https://ashitaxi.com/';

require 'common';

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

-- Render.Flags0 bit the original addon sets to make an entity non-blocking.
local FLAG_NOCOLLIDE = 0x40;

-- Incoming packet ids.
local PKT_ZONE_IN   = 0x000A; -- Zone-in: the client rebuilds its entity list.
local PKT_ZONE_OUT  = 0x000B; -- Zone-out / logout.
local PKT_CHAR_PC   = 0x000D; -- Other player update.
local PKT_CHAR_NPC  = 0x000E; -- NPC / monster / door / elevator / ship update.

-- Offsets inside a 0x000E packet (0-based, as documented in XiPackets).
local OFF_ACTINDEX  = 0x08;   -- uint16  entity target index
local OFF_SENDFLG   = 0x0A;   -- uint8   which parts of the packet are populated
local OFF_SUBKIND   = 0x30;   -- uint16  low 3 bits = SubKind, rest = Status (unused)

-- SendFlg bits.
local SEND_NAME     = 0x08;
local SEND_MODEL    = 0x10;
local SEND_DESPAWN  = 0x20;
local SEND_NAME2    = 0x40;
-- SubKind (and the Data that depends on it) is only meaningful when one of these is set.
local SEND_HAS_KIND = bit.bor(SEND_NAME, SEND_MODEL, SEND_NAME2);

-- SubKinds that must stay solid. Everything else (normal NPCs, monsters, pets, etc.) is ghosted.
local KEEP_SOLID = {
    [2] = true, -- doors
    [3] = true, -- elevators and other moving platforms
    [4] = true, -- airships, boats (and some gardening plants)
};

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

local state = {
    npcs    = true, -- Ghost NPCs and monsters? (Players are always ghosted, as in the original.)
    kinds   = {},   -- [index] = last SubKind seen for that NPC slot.
    touched = {},   -- [index] = true if WE turned the no-collide bit on (so we can undo it).
    pending = {},   -- [index] = true if the bit should be re-applied after the client handles the packet.
};

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

--[[
* Sets the no-collide bit on an NPC entity and remembers that we did so.
* Returns quietly if the entity slot does not exist yet.
--]]
local function ghost_npc(index)
    local ent = GetEntity(index);
    if (ent == nil) then return; end
    local flags = ent.Render.Flags0;
    if (bit.band(flags, FLAG_NOCOLLIDE) == 0) then
        ent.Render.Flags0 = bit.bor(flags, FLAG_NOCOLLIDE);
        state.touched[index] = true;
    end
end

--[[
* Clears the no-collide bit on an NPC entity, but only if this addon set it.
* Bits the game set itself are never touched.
--]]
local function restore_npc(index)
    if (not state.touched[index]) then return; end
    state.touched[index] = nil;
    local ent = GetEntity(index);
    if (ent ~= nil) then
        ent.Render.Flags0 = bit.band(ent.Render.Flags0, bit.bnot(FLAG_NOCOLLIDE));
    end
end

--[[
* Forgets everything about an NPC slot (used on despawn).
--]]
local function forget_npc(index)
    restore_npc(index);
    state.kinds[index]   = nil;
    state.pending[index] = nil;
end

--[[
* Clears all tracking. Used on zone change, where the client discards every entity anyway.
--]]
local function reset_tracking()
    state.kinds   = {};
    state.touched = {};
    state.pending = {};
end

--[[
* Undoes every change made to NPCs (used when the NPC option is switched off or the addon unloads).
--]]
local function restore_all_npcs()
    for index, _ in pairs(state.touched) do
        restore_npc(index);
    end
    state.pending = {};
end

local function msg(text)
    print(('\30\81[\30\06Casper2\30\81]\30\01 %s'):format(text));
end

----------------------------------------------------------------------------------------------------
-- Packet handling
----------------------------------------------------------------------------------------------------

--[[
* Handles a 0x000E NPC update.
*
* The SubKind only arrives with name/model updates, so it is cached per slot and reused for the
* frequent position-only updates. An NPC whose kind has not been seen yet is left alone; that keeps
* a moving elevator from ever being ghosted by a position update that arrives first.
--]]
local function handle_npc_packet(data)
    if (#data < OFF_SENDFLG + 1) then return; end

    local index   = struct.unpack('H', data, OFF_ACTINDEX + 1);
    local sendflg = struct.unpack('B', data, OFF_SENDFLG + 1);

    if (bit.band(sendflg, SEND_DESPAWN) ~= 0) then
        forget_npc(index);
        return;
    end

    if (bit.band(sendflg, SEND_HAS_KIND) ~= 0 and #data >= OFF_SUBKIND + 2) then
        state.kinds[index] = bit.band(struct.unpack('H', data, OFF_SUBKIND + 1), 0x07);
    end

    local kind = state.kinds[index];
    if (kind == nil) then return; end

    if (KEEP_SOLID[kind]) then
        -- Slot was reused by a door/elevator/ship: make sure we are not leaving it ghosted.
        restore_npc(index);
        state.pending[index] = nil;
        return;
    end

    -- Kinds are tracked even while the option is off, so switching it back on works immediately.
    if (not state.npcs) then return; end

    ghost_npc(index);
    -- Packet events fire before the client applies the packet. If the client rewrites the flags
    -- while spawning the entity, the bit is set again on the next frame.
    state.pending[index] = true;
end

ashita.events.register('packet_in', 'casper2_packet_in', function (e)
    local id = e.id;

    -- Other players: unchanged from the original addon.
    if (id == PKT_CHAR_PC) then
        local ent = GetEntity(struct.unpack('H', e.data_modified, 0x08 + 1));
        if (ent ~= nil) then
            ent.Render.Flags0 = bit.bor(ent.Render.Flags0, FLAG_NOCOLLIDE);
        end
        return;
    end

    if (id == PKT_ZONE_IN or id == PKT_ZONE_OUT) then
        reset_tracking();
        return;
    end

    if (id == PKT_CHAR_NPC) then
        handle_npc_packet(e.data_modified);
    end
end);

--[[
* Re-applies the bit once the client has processed this frame's packets.
--]]
ashita.events.register('d3d_present', 'casper2_present', function ()
    if (next(state.pending) == nil) then return; end
    local pending = state.pending;
    state.pending = {};
    for index, _ in pairs(pending) do
        local kind = state.kinds[index];
        if (state.npcs and kind ~= nil and not KEEP_SOLID[kind]) then
            ghost_npc(index);
        end
    end
end);

ashita.events.register('unload', 'casper2_unload', function ()
    restore_all_npcs();
end);

----------------------------------------------------------------------------------------------------
-- Command: /casper2 [npc [on|off]]
----------------------------------------------------------------------------------------------------

ashita.events.register('command', 'casper2_command', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1]:lower() ~= '/casper2') then return; end
    e.blocked = true;

    local sub = args[2] and args[2]:lower() or nil;
    if (sub == 'npc' or sub == 'npcs' or sub == 'mob' or sub == 'mobs') then
        local opt = args[3] and args[3]:lower() or nil;
        local enable;
        if (opt == 'on') then enable = true;
        elseif (opt == 'off') then enable = false;
        else enable = not state.npcs; end

        if (state.npcs and not enable) then
            restore_all_npcs();
        end
        state.npcs = enable;
        msg(('NPC/mob ghosting is now %s.'):format(enable and 'ON' or 'OFF'));
        if (enable) then
            msg('NPCs already nearby become passable on their next server update.');
        end
        return;
    end

    msg(('Players: always ghosted. NPCs/mobs: %s.'):format(state.npcs and 'ON' or 'OFF'));
    msg('Usage: /casper2 npc [on|off]  - toggle walking through NPCs and monsters.');
end);
