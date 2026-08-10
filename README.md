# Moodle Quarters

Changes one additional quarter of the moodle background to a square for each moodle level.

## Thumbnail
![Thumbnail](workshop/poster.png)

## Layout

| Path | Build |
| --- | --- |
| `media/texturepacks/Quarters.pack` | 41, the original texture pack |
| `42/` | 42, the level art and the panel that draws it |

Build 41 read the mod folder itself, so the pack next to a `mod.info` at the root was the
whole mod. Build 42 reads a version folder instead and ignores everything at the mod root,
so the two live side by side and each build sees only its own.

## Why build 42 needed more than a texture pack

Build 41 drew the moodle background from eight textures, `Moodle_Bkg_Good_1..4` and
`Moodle_Bkg_Bad_1..4`, so replacing them was enough to say what each level looks like.

Build 42 draws the stack from `zombie.ui.MoodleTextureSet`, which loads exactly one
background and one border per size, `_Moodles_BGsolid.png` and `_Moodles_BGoutline.png`,
and tints the background towards the player's highlight colour by `level / 4` instead of
swapping it. There is no longer a texture that means "level three", so a texture pack
cannot express this mod. Nor is the tint any substitute: it starts from grey, ends at
whatever colour the player picked in the options, and knows nothing about the two-tone
fills this mod's art is drawn with.

Vanilla also keeps its slot state in a `HashMap<MoodleType, MoodleUIData>`, and
`MoodleType` has no `hashCode`, so the order moodles stack in is whatever the identity
hashes happen to be that session. Drawing level art over the vanilla stack would land on
the wrong moodle. So the build 42 half of the mod ships the level shapes as its own
textures and replaces the panel: `42/media/lua/client/MoodleQuarters.lua` takes the
vanilla panel out of `UIManager`'s element list and draws the stack in a fixed order,
keeping vanilla's position, tint, slide, wobble and hover label.

Moodles added by other mods through MoodleFramework live in their own panels and are left
alone, so they keep the round vanilla plate.

## Level art

`42/media/ui/MoodleQuarters/<size>/{good,bad}_<level>.png`: the eight plates in `source/`,
scaled up to each of the six sets the game uses.

```bash
python tools/generate_plates.py
```

Nothing is redrawn and no colour is recomputed. Scaling is nearest neighbour, so the hard
one pixel outline and the stepped corners stay hard and stepped instead of turning into a
soft edge, and the plates are drawn untinted so the two-tone fills arrive as they were
drawn. 32, 64 and 96 are whole multiples of the source; 126, which is what the game's
largest set really measures, is scaled to 128 and trimmed rather than resampled unevenly.

`Moodles.GoodBadNeutral()` answers good only for `FOOD_EATEN` and bad for everything else,
so good and bad are the only two sets the game can ask for.

## Tests

```bash
pwsh tests/run-tests.ps1
```

Runs the mod against the game's own Lua VM without launching it. See
[tests/README.md](tests/README.md).

## Building

```bash
./gradlew localDeploy
```
