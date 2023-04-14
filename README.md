**An NES emulator using SDL2 written in Zig.**

Made mostly for fun. Not very accurate, and only supports mappers 0 and 1 for now.

CPU and PPU emulation are decent enough to run Super Mario Bros or The Legend of Zelda without issue. APU emulation is still very incomplete.

Many thanks to the contributors of the NESDev Wiki.

![Screenshot of a window titled "Zig NES Emulator", showing the start of World 1-1 of Super Mario Bros](/screenshot.png)

**Build requirements:** Zig compiler, SDL2 library in a system-wide location

**Controls:** (for non-QWERTY layouts: same key position but different key)

- P: Pause/unpause
- O: Show debug menu
- I: Step by a single frame
- U: Step by a single CPU instruction
- WASD: Up/Left/Down/Right
- L: A button
- K: B button
- J: Start button
- H: Select button

**Install**:

`zig build install [-p location]`

**Run from source:**

`zig build run -- <ROM path>`

**Run automated CPU test (NESTest.nes):**

`zig build nestest`
