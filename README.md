# Outbound

Your prompts, one keystroke away. Outbound lives in the menu bar, keeps a
library of prompts, and pastes the one you pick into whatever you're typing in.

## Build

Requires macOS 26 and Xcode 26 or later.

```sh
scripts/build-app.sh release
open build/Outbound.app
```

Move `build/Outbound.app` to Applications to keep it. Release builds are
universal and also zipped to `build/Outbound.zip`. To sign and notarize, set
`SIGN_IDENTITY` to a Developer ID Application identity and `NOTARY_PROFILE` to a
`notarytool` keychain profile before building.

## Use

Click ↩ in the menu bar, or set a shortcut in Settings. Type to
search, then press Return.

| Key | Action |
| --- | --- |
| Return | Paste into the app you were using |
| ⌘Return | Copy |
| ⌘N | New prompt, titled with your search |
| ⌘E | Edit |
| ⌘⌫ | Delete |
| ⌘Z | Undo |
| ⌘0 to ⌘9 | All prompts, or a category |
| Esc | Clear the search, go back, or close |

Categories sit on the left as dots or icons. Click + to add one, right click to
edit it, drag prompts onto it to file them, and drag categories to reorder.
Prompts can be dragged to reorder too, or dropped straight into other apps.

Pasting needs Accessibility access, which Outbound asks for the first time you
press Return. Without it, the prompt is copied and you paste it yourself. Local
builds are signed ad hoc, so macOS may ask again after a rebuild.

## Library

Everything is stored in one readable JSON file,
`~/Library/Application Support/Outbound/Library.json`. Back it up, edit it, or
symlink it into a synced folder. If it ever can't be read, it is moved aside
rather than overwritten.

To bring in existing prompts, use Import in Settings and pick text files or a
folder. Each subfolder becomes a category, and prompts already in the library
are skipped.

## Website

The site in `Website/` is plain HTML and CSS with no build step. Preview it with
`python3 -m http.server -d Website`, and publish it to Cloudflare Workers with
`npx wrangler deploy`.

## License

MIT
