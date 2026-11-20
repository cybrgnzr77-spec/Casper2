# Changes from the original casper

Base: `addons/casper/casper.lua` (casper v1.0 by atom0s) from
https://github.com/AshitaXI/Ashita-v4beta, commit `a8074265f9be39474d9a5a65c4994a3170b830cb`.

## Casper2 1.0 (2026-11-20)
- **Renamed** to Casper2 (`addon.name = 'Casper2'`, folder and file `Casper2/Casper2.lua`),
  version reset to 1.0. The description now mentions NPCs and monsters.
- **NPC and monster collision removed:** the addon now also handles incoming packet `0x000E`
  (NPC/monster updates) and sets the same `Render.Flags0` bit (`0x40`) the original sets on
  players.
- **Doors, elevators/moving platforms and ships kept solid:** entities whose packet `SubKind`
  is 2, 3 or 4 are never changed, so doors still open and elevators/boats can still be ridden.
- **Per-entity tracking:** the `SubKind` is cached per entity slot (position-only updates do not
  carry it), cleared on despawn and on zone in/out (`0x000A`/`0x000B`). Entities of unknown kind
  are left alone.
- **Re-apply on the next frame:** a `d3d_present` handler sets the bit again after the client
  has processed the packet, in case it rewrites the flags while spawning the entity.
- **Undo support:** the addon remembers which NPCs it changed and clears the bit only on those
  when NPC ghosting is switched off, the slot is reused by a door/elevator/ship, the entity
  despawns, or the addon unloads. Bits set by the game itself are never cleared.
- **New command:** `/casper2 [npc [on|off]]`.
- **Player behaviour unchanged:** the `0x000D` handling is the original logic.
- **Added** a GPLv3 modification notice to the source header (original header kept intact),
  a README, this change log, the full GPLv3 license text, and a LuaJIT test suite.
