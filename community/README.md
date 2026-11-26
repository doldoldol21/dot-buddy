# Community characters

English | [한국어](README.ko.md)

Characters people drew for Dot Buddy. In the app, right-click the pet → Character → **More Characters…**, pick one and choose **Install**. It shows up in the Character menu right away.

## Built in

These six come with the app, so there's nothing to install. They're drawn in code by [`charas/chars.py`](../charas/chars.py).

<p align="center"><img src="../docs/media/characters.gif" alt="The six built-in characters: Dumpling, Acorn, Sprout, Cloud, Candle and Pebble" width="720"></p>

## Gallery

<!-- gallery:start -->
| | Character | By | License |
|---|---|---|---|
| <img src="ghost/preview.gif" width="220" alt="Ghost"> | **Ghost**<br>A friendly little ghost whose hem sways as it floats along. | [@doldoldol21](https://github.com/doldoldol21) | CC-BY-4.0 |
| <img src="onigiri/preview.gif" width="220" alt="Rice Ball"> | **Rice Ball**<br>A rice ball in a seaweed wrap, ready for a long day of coding. | [@doldoldol21](https://github.com/doldoldol21) | CC-BY-4.0 |
| <img src="onion/preview.gif" width="220" alt="Onion"> | **Onion**<br>A rosy onion with a fresh green sprout and a sunny little smile. | [@GaneshUbale](https://github.com/GaneshUbale) | CC-BY-4.0 |
| <img src="snowman/preview.gif" width="220" alt="Snowman"> | **Snowman**<br>A snowman with a red scarf and a carrot nose. | [@doldoldol21](https://github.com/doldoldol21) | CC-BY-4.0 |
| <img src="teacup/preview.gif" width="220" alt="Teacup"> | **Teacup**<br>A little teacup that steams while it waits. | [@doldoldol21](https://github.com/doldoldol21) | CC-BY-4.0 |
<!-- gallery:end -->

## Share your character

1. Draw a character pack as described in [CHARACTERS.md](../CHARACTERS.md). The gallery needs at least `idle`, `walk`, `work`, `sleep`, `ask` and `fall` (or `jump`); every motion you add makes it livelier.
2. Try it in the app: put the folder in your characters folder and choose **Reload Characters**.
3. Fork this repo and add the folder as `community/<name>/`. The name is 2–32 characters of `a-z`, `0-9` and `-`, and can't be a built-in character's name. One character per pull request, and nothing outside its folder.
4. Open a pull request. CI checks the pack, loads it in the app and attaches its preview (the `previews` artifact on the run). After the merge, CI draws the preview, adds it to the gallery and the in-app list.

### chara.json

On top of the [usual keys](../CHARACTERS.md#charajson), a community pack needs three more:

```json
{
  "name": "Teacup",
  "names": { "en": "Teacup", "ko": "찻잔" },
  "author": "your-github-name",
  "license": "CC-BY-4.0",
  "description": "A little teacup that steams while it waits."
}
```

Fan art also adds `"based_on": "Character (Series)"`.

| Key | Meaning |
|---|---|
| `author` | Your GitHub username (shown as "by …" and linked in the gallery) |
| `license` | The license for your drawings: `CC-BY-4.0`, `CC-BY-SA-4.0`, `CC0-1.0` or `MIT` |
| `description` | One short line, at most 140 characters (optional) |
| `based_on` | Fan art only: the character and series it's based on, at most 60 characters. Shown as "Fan art of …" |

### Rules

- **Draw it yourself.** Don't copy other people's sprites or art, and don't recolor another pack (CI compares outlines).
- **Fan art is welcome** if you drew it and fill in `based_on`. The original character belongs to its owner; your `license` covers only your drawing.
- Only you can change your pack: CI checks that `author` is the GitHub account opening the pull request.
- Only `chara.json` and `<motion>.png` files (motion names are in [CHARACTERS.md](../CHARACTERS.md#motion-names)). No other files.
- Frames are at most 30×32 dots, every motion uses the same frame size, at most 16 frames per motion.
- Each file is at most 64 KB and the pack at most 512 KB. Pixel art is usually far smaller.
- Keep it friendly: no violent, sexual or hateful content.

Check a pack locally before opening the pull request:

```bash
python3 scripts/community.py check                    # file names, sizes, chara.json
python3 scripts/community.py check --app bin/DotBuddy # also load it in the app (after ./build.sh)
```

No drawing skills? Open a [character idea](https://github.com/doldoldol21/dot-buddy/issues/new?template=character_idea.yml) and someone may pick it up.

## Removing a character

We can't judge copyright for every character, so packs are taken down on request. If a pack uses your character or art, or breaks the rules above, [report it](https://github.com/doldoldol21/dot-buddy/issues/new?template=report_character.yml) and a maintainer will check and remove it from the gallery and the in-app list. Copies people already installed stay on their Macs. Authors can ask to remove their own pack the same way.

## How installing works

The app downloads `community/index.json` from this repo only when you open **More Characters…**. Installing a pack downloads just the files the list names for it (`chara.json` and PNGs), checks each file's size and SHA-256 against the list, and puts the pack in your characters folder. Packs are images and a small JSON file, read with the same loader and limits as packs you add by hand.

Each pack keeps the license its author chose (the `license` key); the app's code is MIT.
