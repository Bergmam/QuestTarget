# Quest Target

A World of Warcraft addon that gives every quest in your log a button (and a keybind) that targets the nearest living mob for that quest.

Each button runs a macro like:

```
/cleartarget
/target [noexists][dead] Bloodfury Harpy
/target [noexists][dead] Bloodfury Ambusher
/cleartarget [dead]
```

## Features

- A movable panel with one row per quest; each row targets only that quest's mobs. Quests are never combined into one macro.
- Mob names come from unfinished kill objectives ("X slain: 3/8").
- With [Questie](https://github.com/Questie/Questie) installed, the mobs that drop the quest items you still need are added too.
- Shift-right-click a quest row to add your own mob names (comma separated, saved per quest).
- Keybinds under **Key Bindings → AddOns → Quest Target**: "Target mobs of quest #1–#10". Slot numbers follow the panel rows.
- Right-click a quest row to pin it to its current slot (its number turns orange), so that keybind keeps targeting that quest while other quests come and go. Right-click again to unpin. Pins are per character and are cleared when the quest is turned in or abandoned.
- Shows an error when a button finds no living mob to target.
- The game limits secure macros to 255 characters, so a quest with many mobs gets its macro split into up to 6 chained parts (hidden buttons, `/click [noexists][dead] ...`). Each part only runs if nothing living was targeted yet.
- Highlights the quest rows whose mobs include your current target.
- When your targeted quest mob is too far away to have a nameplate, an arrow above your character points toward it. Addons can't read other units' positions, so the arrow points at the nearest known spawn point of that mob in your zone (from Questie's database) and is approximate. It needs Questie.
- Buttons can't be changed in combat, so the list refreshes when combat ends. Pressing the buttons works in combat.

## Install

Copy this folder into `World of Warcraft/<flavor>/Interface/AddOns/QuestTarget`.

## Commands

| Command | Effect |
| --- | --- |
| `/qt` | Show/hide the panel (keybinds still work while hidden) |
| `/qt lock` | Lock/unlock the panel position |
| `/qt watched` | Only list watched quests |
| `/qt reset` | Reset the panel position |
| `/qt autopin` | Toggle auto-pinning (on by default): killing a quest's mob pins that quest to its current slot |
| `/qt arrow` | Toggle the direction arrow (on by default) |
| `/qt unpin` | Unpin all quests |
| `/qt macro <slot>` | Print the macro parts for the quest in that slot |

## Notes

- Objective parsing assumes the English client.
