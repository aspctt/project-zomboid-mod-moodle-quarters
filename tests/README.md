# Tests

Runs the mod's real Lua against Project Zomboid's own VM, without launching the game.

```bash
pwsh tests/run-tests.ps1
```

A full run takes a couple of seconds. Set `PZ_DIR` to point at an install this does not
find on its own.

## How it works

`projectzomboid.jar` contains Kahlua, the Lua 5.1 VM the game runs mods on. The runner
boots that same VM outside the game, installs a stubbed game API, loads the real mod
source, and drives it frame by frame. Because it is the shipped VM, the tests break when
a game update changes the API rather than silently passing against a hand-written
imitation.

Load order, assembled by `run-tests.ps1`:

| Layer | Source |
| --- | --- |
| Game API stubs | `harness/pz_stubs.lua` |
| The UI this mod replaces | `harness/mq_stubs.lua` |
| Mod options API | the real one from the game install |
| Assertions | `harness/test_lib.lua` |
| Code under test | every `.lua` in `42/media/lua` |
| Specs | `specs/*_spec.lua` |

Each test runs in a completely fresh environment, so the mod's file level locals, such
as the texture cache, cannot leak from one test into the next.

## What it checks

Before the specs run:

- **The level art.** Six sizes, four levels, a plate and a border each. A missing file is
  not an error at runtime: `getTexture` returns null and nothing draws. The moodle
  symbols named in the Lua are resolved against the install for the same reason.
- **Syntax**, by compiling each file with the game's own compiler.
- **Constant validity.** Every `MoodleType.X` and `CharacterStat.X` in shipped mod source
  is verified against the constants actually present in the installed build, read
  straight out of the jar. Comments are skipped, since they routinely name a retired
  constant to explain why it is gone.
- **Texture paths.** Every literal `getTexture` path is resolved against the mod's own
  tree and the game install.

The `MoodleType` table exposed to tests is built from that same jar reflection, so a
constant retired by a future build is nil in tests exactly as it is in game, and the
first spec fails on it by name.

## Adding a spec

```lua
Test("description of the behaviour", function()
    local panel = Attach()
    Harness.SetMoodle(MoodleType.HUNGRY, 3)
    Frames(panel, 60)

    AssertNotNil(FindDraw("bad_3.png"), "the level three plate was not drawn")
end)
```

Harness surface used here: `Fire`, `ClearDraws`, `SetMoodle`, `SetGoodBadNeutral`,
`SetScreenSize`, `SetMouse`, `NewMoodlePanel`, `UIIndex`, and the knobs
`MoodleSizeOption`, `MissingTextures`, `ActivePlayers`, `FrameMs`.

Assertions: `AssertTrue`, `AssertFalse`, `AssertNil`, `AssertNotNil`, `AssertEquals`,
`AssertNear`, `AssertContains`.

## Requirements

A JDK. The JRE bundled with the game has no compiler, so the runner looks for one in
`Program Files`; Adoptium and the JetBrains runtime included with IntelliJ both work.
Tests execute from the game directory, because Kahlua resolves `stdlib.lua` relative to
the working directory.

## Provenance

`TestRunner.java`, `pz_stubs.lua` and `test_lib.lua` come from the QoL Compendium test
harness. The only change to the runner is that the static checks now treat the mod's
`common` and version folders as shipped source, rather than everything under the
repository root, so the harness's own placeholder texture paths are not flagged.
