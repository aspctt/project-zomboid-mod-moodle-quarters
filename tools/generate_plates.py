"""Generate the build 42 moodle plates from this mod's own build 41 art.

Build 41 let a texture pack replace the eight per-level moodle backgrounds
(Moodle_Bkg_Good_1..4 / Moodle_Bkg_Bad_1..4). Build 42 loads exactly one
background and one border per size and tints the background by level instead,
so the level plates have to be shipped as extra textures and drawn by the mod.

The art itself is unchanged: source/Moodle_Bkg_*.png scaled up to each of the
six sets the game uses. Nothing is redrawn and no colour is recomputed, because
both of those are the whole point of the mod. Scaling is nearest neighbour, so
the hard one pixel outline and the stepped corners stay hard and stepped rather
than turning into a soft edge.

    python tools/generate_plates.py [--game <ProjectZomboid dir>]
"""

import argparse
import os
import sys

from PIL import Image

# The six sets zombie.ui.MoodlesUI keeps in textureSizes. The pixel dimensions
# are read from the install rather than assumed: the 128 set is really 126x126,
# and a plate that does not match its icon draws off centre.
SIZES = (32, 48, 64, 80, 96, 128)

# Moodles.GoodBadNeutral returns 1 for FOOD_EATEN and 2 for everything else, so
# good and bad are the only two sets the game can ask for.
SETS = {"good": "Moodle_Bkg_Good_%d.png", "bad": "Moodle_Bkg_Bad_%d.png"}

LEVELS = (1, 2, 3, 4)

DEFAULT_GAME_DIRS = (
    r"S:\SteamLibrary\steamapps\common\ProjectZomboid",
    r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
)


def find_game_dir(explicit):
    for c in [explicit] if explicit else list(DEFAULT_GAME_DIRS):
        if c and os.path.isfile(os.path.join(c, "projectzomboid.jar")):
            return c
    raise SystemExit("Could not find a Project Zomboid install. Pass --game <dir>.")


def vanilla_pixels(game, size):
    """The pixel dimensions of the game's own plate for this set."""
    path = os.path.join(game, "media", "ui", "Moodles", str(size), "_Moodles_BGsolid.png")
    if not os.path.isfile(path):
        raise SystemExit("Missing vanilla texture: " + path)
    with Image.open(path) as img:
        return img.size[0]


def scale_to(img, target):
    """Nearest neighbour, keeping the step even wherever the target allows it.

    32, 64 and 96 are whole multiples of the 32 pixel source. 126, which is what
    the game's largest set really measures, is one pixel short of a clean 4x on
    each side, so it is scaled to 128 and trimmed instead of resampled unevenly,
    which would leave some steps three pixels and others four. 48 and 80 fall
    between multiples and have to take the uneven step.
    """
    source = img.size[0]
    factor = max(1, round(target / source))
    whole = source * factor

    if 0 <= whole - target <= 2:
        scaled = img.resize((whole, whole), Image.NEAREST)
        inset = (whole - target) // 2
        return scaled.crop((inset, inset, inset + target, inset + target))

    return img.resize((target, target), Image.NEAREST)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game", help="Project Zomboid install directory")
    parser.add_argument(
        "--out",
        default=os.path.join("42", "media", "ui", "MoodleQuarters"),
        help="output directory, relative to the repository root",
    )
    args = parser.parse_args()

    game = find_game_dir(args.game)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_root = os.path.join(root, args.out)

    written = 0
    for size in SIZES:
        pixels = vanilla_pixels(game, size)
        dst_dir = os.path.join(out_root, str(size))
        os.makedirs(dst_dir, exist_ok=True)

        for kind, pattern in SETS.items():
            for level in LEVELS:
                src = os.path.join(root, "source", pattern % level)
                if not os.path.isfile(src):
                    raise SystemExit("Missing source art: " + src)
                with Image.open(src) as img:
                    plate = scale_to(img.convert("RGBA"), pixels)
                plate.save(os.path.join(dst_dir, "%s_%d.png" % (kind, level)))
                written += 1

    print("Wrote %d plates to %s" % (written, out_root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
