# Casper2

An [Ashita v4](https://www.ashitaxi.com/) addon for Final Fantasy XI that lets you walk through
other players, **NPCs and monsters**, without the short pause the game normally makes you wait.

Casper2 is a modified version of **casper** by **atom0s** (Ashita Development Team), which
removes collision with other players only. See [CHANGES.md](CHANGES.md) for exactly what was
changed.

## Features
- **Players:** same as the original casper.
- **NPCs and monsters:** collision removed as well.
- **Doors, elevators/moving platforms and boats/airships stay solid** on purpose, because the
  game needs you to touch them to open or ride them.
- Toggle NPC/mob ghosting in game without reloading.

## Installation
1. Copy the `Casper2` folder into your Ashita `addons` folder.
2. In game:

       /addon unload casper
       /addon load Casper2

Casper2 does everything the original casper does, so you only need Casper2 loaded. If your
launcher loads `casper` automatically, replace it with `Casper2` in your startup script
(for example `scripts/default.txt`).

## Commands
| Command | Effect |
| --- | --- |
| `/casper2` | Show current status |
| `/casper2 npc` | Toggle NPC/mob ghosting |
| `/casper2 npc on` / `/casper2 npc off` | Set NPC/mob ghosting |

Turning NPC/mob ghosting off puts back only the collision Casper2 removed. It is on by default
each time the addon loads. Players are always passable, as in the original.

## How it works
- Player updates (packet `0x000D`) are handled exactly like the original casper: the entity's
  `Render.Flags0` bit `0x40` is set, making it non-blocking.
- NPC updates (packet `0x000E`) get the same bit, except when the packet's `SubKind` marks the
  entity as a door (2), elevator/moving platform (3) or ship (4). The `SubKind` is cached per
  entity slot because position-only updates don't carry it; entities whose kind is unknown are
  left alone. The bit is applied again on the next frame in case the client rewrites it while
  spawning the entity.

## Testing
`tests/test_Casper2.lua` runs the addon under LuaJIT (the Lua runtime Ashita uses) against a
simulated Ashita API and byte-accurate `0x000E` packets. Its 20 tests cover players, every NPC
`SubKind`, position-only updates, despawn, slot reuse, zoning, toggling, unloading and
malformed packets.

    luajit tests/test_Casper2.lua Casper2/Casper2.lua

## Credits
- **casper** (the original addon): atom0s, Ashita Development Team.
  Copyright (c) 2025 Ashita Development Team.
  https://www.ashitaxi.com/ · https://discord.gg/Ashita ·
  Source: https://github.com/AshitaXI/Ashita-v4beta (`addons/casper/casper.lua`)
- Packet layout and `SubKind` meanings: atom0s' **XiPackets** documentation,
  https://github.com/atom0s/XiPackets (AGPL-3.0). Only the documented facts were used; no code
  was copied from it.

## License
Ashita and the original casper addon are released under the GNU General Public License v3.
Casper2 is a modified version and is released under the same license; see [LICENSE](LICENSE).

As required by Ashita's license terms:
- All original copyright notices, credits, information and links are kept intact
  (see the header of `Casper2/Casper2.lua` and the credits above).
- The full source code of all modifications is in this repository.
- All major changes to the original work are listed in [CHANGES.md](CHANGES.md) and in the
  modification notice at the top of `Casper2/Casper2.lua`.
- The license has not been altered or sub-licensed.
- The Ashita Development Team and its contributors are not liable for any damages arising from
  the use of Casper2. This program is distributed WITHOUT ANY WARRANTY; see the GPLv3 for details.
