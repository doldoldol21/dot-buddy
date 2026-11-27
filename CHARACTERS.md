# Making characters

English | [한국어](CHARACTERS.ko.md)

This is how to add your own character to Dot Buddy. Name your PNGs after motions and the pet uses each picture in that situation. Missing motions fall back to a related motion, or to automatic motion (squashing, stretching and flipping the base picture). No code changes are needed.

The commands below call the app's binary:

```bash
DOTBUDDY="$HOME/Applications/Dot Buddy.app/Contents/MacOS/DotBuddy"   # or bin/DotBuddy in a source checkout
```

## Where to put them

```
~/Library/Application Support/DotBuddy/charas/
```

Right-click the pet → Character → **Open Characters Folder**. After adding files, choose **Reload Characters** and they show up in the menu right away (no restart).

Got a character from someone as a zip, a folder or a single PNG? Drag it onto the pet. The pet copies it into this folder and switches to it. Only the files a character uses are copied (`chara.json`, motion PNGs, a Codex pet's `pet.json` and sheet); anything else in the zip stays out. A character with the same name goes to the Trash. From a terminal: `"$DOTBUDDY" --install-chara <zip|folder|png>`.

Characters other people drew are one click away: Character → **More Characters…**. When yours is ready, share it the same way: see [dot-buddy/characters](https://github.com/dot-buddy/characters#share-your-character).

## Two formats

| Format | Files | How it moves |
|---|---|---|
| Single image | `charas/<name>.png` (+ optional `<name>.json`) | One picture. Walking, jumping, sleeping and so on are made by animating it automatically |
| Pack | `charas/<name>/idle.png`, `walk.png`, … + `chara.json` | A drawing per motion. Motions you drew use your drawing; the rest fall back |

## Using Codex pets as-is

Pet packages from the Codex app (`pet.json` + `spritesheet.webp`) are read without changes, from two places:

- `~/.codex/pets/<name>/`: pets installed for Codex (or `$CODEX_HOME/pets` if you changed `CODEX_HOME`)
- `<name>/` inside the character folder above: a folder with a `pet.json` is read as a Codex pet

If `pet.json` has a `spritesheetPath`, that file is used instead of `spritesheet.webp`. It must stay inside the pet's folder.

The sheet is 8 columns × 9 rows (each cell 192×208; a sheet scaled to the same cell ratio also works). Each row maps to these motions. The big drawing is shrunk to a pixel sprite about 24 dots tall, and each cell's feet are aligned to the floor (the app moves the sprite up for jumps).

| Row | Codex | Dot Buddy |
|---|---|---|
| 0 | idle | `idle` |
| 1 | running-right | `walk` |
| 2 | running-left | (unused; the right-facing row is mirrored) |
| 3 | waving | `wave`, `happy` |
| 4 | jumping | `jump`, `cheer` |
| 5 | failed | `pout`, `dizzy` |
| 6 | waiting | `ask` |
| 7 | running | `sneak` |
| 8 | review | `work` |

Row order and frame timing follow community documentation of the format (hatch-pet `animation-rows.md`). It works the other way too: you can export a Dot Buddy character as a Codex pet (`spritesheet.png` + `pet.json`).

```bash
"$DOTBUDDY" --export-codex-pet ~/.codex/pets/acorn acorn
```

Dot Buddy is not affiliated with OpenAI. The format is read for compatibility only.

## Drawing rules

- Transparent background, one pixel = one dot. Semi-transparent pixels are cut at 50% alpha: either there or not.
- Draw facing right. The app mirrors the picture when the pet walks left.
- The bottom row of the picture is the floor (the feet). The app handles jump and lift heights.
- A frame can be at most 30 dots wide and 32 dots tall. If the body is taller than 20 rows (`height` in `chara.json`, or the frame height), the app draws the pet smaller so it matches the other characters.
- In a pack, every motion uses the same frame size. Multiple frames go **side by side** in one PNG (`walk.png` with 2 frames is twice as wide). Files with a different frame size are skipped.
- Hearts, notes, z's, sweat, confetti, speech bubbles and the ✓ badge are drawn by the app on top. Leave them out of your drawing.

## chara.json

```json
{
  "name": "Shown name",
  "names": { "en": "Shown name", "ko": "보일 이름" },
  "frame": [18, 18],
  "height": 18,
  "fps": { "default": 3, "walk": 6, "work": 5 },
  "eyes": [[5, 2, 2, 2], [10, 2, 2, 2]]
}
```

| Key | Meaning | If missing |
|---|---|---|
| `name` | Name shown in the menu | The folder (or file) name |
| `names` | Name per UI language (`en`, `ko`) | `name` |
| `frame` | Frame size `[width, height]` | `idle.png` is one frame |
| `height` | Body height in dots, used to match sizes with other characters (leave out room for raised arms or ears) | The frame height |
| `fps` | Frames per second per motion. One-shot motions (jumps, reactions, yawns) advance frames with their progress instead | 6 |
| `eyes` | Eye rectangles `[x, y, width, height]` used for automatic blinking, happy eyes and dizzy eyes (`idle` and single images only) | No blinking |
| `hat` | Where the hat goes on special days (a party hat, a Santa hat): `[x, y]` is the dot in the first `idle` frame where the brim's middle sits, and it follows the eyes as they move in other motions. `false` means no hat, for a flame, a leaf or steam on top | Found on the top of the head |

A single image can use the same keys in `<name>.json`, except `frame` and `fps`.

## Motion names

The middle column is when the motion is used. The right column is what the app looks for, in order, when that picture is missing. The last resort is `idle` (and if that's missing too, automatic motion).

| Name | When | If missing |
|---|---|---|
| `idle` | standing still (required — sets the frame size) | — |
| `blink` | blinking | idle |
| `walk` | walking | idle |
| `sneak` | sneaking out from behind a window | walk → idle |
| `roll` | rolling | walk → idle |
| `work` | typing on a laptop (working) | idle |
| `sleep` | sleeping | idle |
| `yawn` | yawning | sleep → idle |
| `stretch` | stretching | happy → idle |
| `cheer` | done (with the ✓ badge) | happy → idle |
| `ask` | waiting for an answer | idle |
| `hum` | humming | happy → idle |
| `happy` | joy (fallback for many motions) | idle |
| `crouch` | crouching before a jump — if missing, the base sprite is squashed | idle |
| `jump` | jumping | idle |
| `land` | landing | crouch → idle |
| `fall` | falling | jump → idle |
| `drag` | being held up | fall → jump → idle |
| `pounce` | pouncing on the cursor | jump → idle |
| `stalk` | stalking before a pounce | idle |
| `dive` | diving into the floor (when going up high or to another monitor) | jump → idle |
| `climb` | climbing a side | idle |
| `descend` | climbing down | climb → idle |
| `hang` | hanging | climb → idle |
| `sit` | sitting on an edge | idle |
| `peek` | looking down | idle |
| `talk` | talking | idle |
| `petted` | being petted | happy → idle |
| `startle` | startled | idle |
| `pout` | pouting | idle |
| `party` | cheering at completion | cheer → happy → idle |
| `hop` | hopping | happy → idle |
| `spin` | spinning | idle |
| `heart` | heart | happy → idle |
| `squish` | being squished | idle |
| `dizzy` | dizzy | idle |
| `wave` | waving | idle |
| `shy` | shy | idle |
| `star` | sparkle | happy → idle |
| `flinch` | flinching | startle → idle |

`"$DOTBUDDY" --motions` prints this table from the code.

## The six built-in characters

Dumpling, Acorn, Sprout, Cloud, Candle and Pebble are original designs. `charas/chars.py` in this repository draws them as 26×26 packs (bold outlines, three-step shading, 33 motions). `build.sh` puts them inside the app (`Contents/Resources/charas`) as `mandu`, `acorn`, `sprout`, `cloud`, `candle` and `pebble`, and the app uses them instead of the small code-drawn defaults. A pack with the same name in your character folder takes priority. If you build without `python3`, you get the small versions.

```bash
python3 -I charas/chars.py <folder> --sheet   # the six packs + an overview sheet _all.png
```

- To change a shape, edit the character class in `chars.py` (`body`, `back`, `front`). To add motions, edit `Chara.frames`. Run `build.sh` again to redraw the packs inside the app. A PNG you edited by hand overrides the built-in one if you put it in your character folder under the same name.
- `height` is 24, so they share a dot size with other packs. While working, the app adds the laptop and the `work` drawing supplies the hands.
- Each character has its own lines (`CHARA_LINES` in `Sources/Chatter.swift`).
- On errors and completions each character gets its own 2.5-second effect (rain and a rainbow for Cloud, smoke and a flare for Candle, falling leaves and a flower for Sprout, and so on; see `charaFX`). Preview: `"$DOTBUDDY" --fx-sheet /tmp/fx.png`.

## Start from a template

The fastest way is to export a built-in character's automatic motions as a pack and redraw them.

```bash
"$DOTBUDDY" --export-pack ~/Library/Application\ Support/DotBuddy/charas/my-acorn acorn   # mandu, acorn, sprout, cloud, candle, pebble
"$DOTBUDDY" --charas                                      # characters that loaded, with frame counts per motion
"$DOTBUDDY" --motion-sheet /tmp/sheet.png pack:my-acorn   # one row per motion, drawn the way the pet draws it
```

`--export-pack` writes `idle`, `blink`, `walk`, `work`, `sleep`, `cheer`, `ask`, `happy`, `jump`, `drag`, `climb`, `hang`, `sit`, `talk`, `startle`, `pout`, `party`, `dizzy`, `wave` and `shy`. Delete the files you don't need; those motions fall back. To try a pack from another folder, put `DOTBUDDY_CHARAS=<folder>` in front of the command.

Character ids are `pack:<folder>` for packs, `custom:<file>` for single images and `codex:<folder>` for Codex pets.

## Copyright

Don't add characters someone else holds the rights to to this repository. Keep them in your own character folder. The app only reads that folder and never sends it anywhere.
