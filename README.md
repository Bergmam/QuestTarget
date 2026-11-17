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

- A movable panel: the header targets any quest mob, and each row below it targets that quest's mobs.
- Mob names come from unfinished kill objectives ("X slain: 3/8").
- With [Questie](https://github.com/Questie/Questie) installed, the mobs that drop the quest items you still need are added too.
- Right-click a quest row to add your own mob names (comma separated, saved per quest).
- Keybinds under **Key Bindings → AddOns → Quest Target**: "Target any quest mob" and "Target mobs of quest #1–#10".
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
| `/qt macro` | Print the combined macro |

## Notes

- Objective parsing assumes the English client.
