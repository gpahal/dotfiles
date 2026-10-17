# Key icons

The Stream Deck plugin's app keys use each app's official icon or logo. This folder keeps the
upstream originals, so the keys can be rebuilt without the upstream URLs. The setup step doesn't
install anything from here.

The plugin's PNG keys are these 1024px icons resized to 72px and 144px (`@2x`), as with
`sips -Z 144 zed.png --out key-editor@2x.png`. Its SVG keys put the logo on a tile the size of
the PNG icons' tiles.

| Original | Key | Source |
| :- | :- | :- |
| `zed.png` | Editor: `key-editor.png`, `@2x` | Zed's [`crates/zed/resources/app-icon@2x.png`](https://github.com/zed-industries/zed/blob/670a779a5ed9e7161c97aa4f998d395c207d5631/crates/zed/resources/app-icon@2x.png) |
| `ghostty.png` | Terminal: `key-terminal.png`, `@2x` | Ghostty's [`macos/Assets.xcassets/AppIconImage.imageset/macOS-AppIcon-1024px.png`](https://github.com/ghostty-org/ghostty/blob/e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110/macos/Assets.xcassets/AppIconImage.imageset/macOS-AppIcon-1024px.png) |
| `t3-code.png` | T3 Code: `key-t3-code.png`, `@2x` | T3 Code's [`assets/prod/black-macos-1024.png`](https://github.com/pingdotgg/t3code/blob/489d08a0549428d3baefd10e610003c10d60e5ef/assets/prod/black-macos-1024.png) |
| `chrome.svg` | Chrome, New Tab: `key-chrome.svg`, `key-chrome-tab.svg` | [Google Chrome icon (February 2022)](https://commons.wikimedia.org/wiki/File:Google_Chrome_icon_(February_2022).svg), on a white tile; New Tab adds a plus badge |
| `gmail.svg` | Gmail: `key-gmail.svg` | [Gmail icon (2020)](https://commons.wikimedia.org/wiki/File:Gmail_icon_(2020).svg), on a white tile |
| `claude.svg` | Claude: `key-claude.svg` | Claude's logo, from T3 Code's [`apps/marketing/public/harnesses/claude-ai-icon.svg`](https://github.com/pingdotgg/t3code/blob/489d08a0549428d3baefd10e610003c10d60e5ef/apps/marketing/public/harnesses/claude-ai-icon.svg), in white on Claude's orange tile |

These icons and logos are trademarks of their owners, and the repo's MIT license doesn't cover
them.
