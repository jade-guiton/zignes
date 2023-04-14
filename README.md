An NES emulator using SDL2 written in Zig.

Made mostly for fun. Not very accurate, and only supports mappers 0 and 1 for now.

CPU and PPU emulation are decent enough to run Super Mario Bros or The Legend of Zelda without issue. APU emulation is still very incomplete.

Many thanks to the contributors of the NESDev Wiki.

**Requirements:** Zig compiler, SDL2 library in a system-wide location

**Controls:** (for non-QWERTY layouts: same key position but different key)
- P: Pause/unpause
- O: Show debug menu
- I: Step by a single frame
- U: Step by a single CPU instruction
- WASD: Up/Left/Down/Right
- L: A button
- K: B button
- J: Select button
- H: Start button

## Install

`zig build install [-p location]`

## Run directly

`zig build run -- <ROM path>`

## Run automated CPU test (NESTest.nes)

`zig build nestest`
