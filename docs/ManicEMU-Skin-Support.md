# ManicEMU J2ME skin support

phoneME can import controller skins packaged as `.manicskin` files from ManicEMU.

## Supported layout data

The importer reads the flat ZIP archive and its `info.json` file. It selects the iPhone standard representation when present, falls back to edge-to-edge, and supports portrait and landscape layouts. It uses:

- `gameTypeIdentifier` to accept Java ME skins only (`public.aoshuang.game.j2me`);
- `mappingSize` to convert skin coordinates into normalized layout coordinates;
- the first screen's `outputFrame` as the phoneME Java display viewport;
- `assets.resizable` as the skin background;
- `items[].frame`, `items[].asset.normal`, `items[].asset.selected`, and `items[].inputs` for touch controls.

The first implementation maps standard Java ME directions, Fire, Soft Left/Right, digits, star and pound. D-pad inputs with multiple directions are treated as directional zones. Unsupported input identifiers are ignored rather than sent as arbitrary key codes.

## Import and storage

In phoneME Settings, select **Java Controller Skin → Import ManicEMU Skin**. Imported skin assets are extracted into the active phoneME data root under `skins/<sha256>/`; the original archive is not modified. The selected skin is stored in app preferences. Switching to the built-in keypad does not delete imported skins.

The importer accepts non-encrypted ZIP entries using Stored or Deflate compression, checks CRC-32, rejects path traversal and non-flat file paths, limits archive size to 32 MiB, expanded supported assets to 64 MiB, and accepts up to 512 entries.

## Current limitations

- This first integration targets iPhone layouts, not iPad-specific representations.
- It renders PDF and common raster image assets; advanced controller types, analog pressure, custom gestures, switches, and console-specific input identifiers are not implemented.
- The app uses the standard representation before edge-to-edge where both are available.
- Skin editing and the ManicEMU FLEX editor are not included.
- If a skin has no compatible portrait or landscape layout, import is rejected and the built-in keypad remains available.

## Attribution

The `.manicskin` format and reference skin collection are from [Manic-EMU/ManicEMUSkins](https://github.com/Manic-EMU/ManicEMUSkins), licensed under **Creative Commons Attribution 4.0 International (CC BY 4.0)**. No third-party skin artwork is bundled by this change; users import their own skin archives. ManicEMU is not affiliated with or endorsing phoneME.
