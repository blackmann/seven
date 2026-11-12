# seven

A native macOS menu bar app recreating the cursor interaction in the supplied recording.

## Run

Open **seven.xcodeproj**, choose the **seven** scheme and **My Mac**, then press **⌘R**. Xcode resolves the SoulverCore 3.5.1 Swift package on the first build (Xcode 26 or newer is required). Debug builds use local ad hoc signing so they run without selecting a development team. macOS 15.2 or later is required.

- Press **Command–Space** to open the launcher directly, centered 8 points below the active display's notch or menu bar. Search is focused immediately, and results expand downward.
- Press **Option–Tab**, keeping **Option** held, to show the switcher at the pointer.
- Move the pointer: the curved pill follows to the left of the normal system cursor. The search panel opens to the right, flipping left only when needed to fit onscreen.
- Scroll **up** for the blue **Launcher**, **down** for orange **Notes**.
- Release **Option** to confirm. The first item opens the launcher; the second opens Notes.
- **Escape** or right-click cancels; click or **Return** confirms.
- **↑ / T** and **↓ / N** also select modes while the switcher is visible.

The dotted app icon adapts to the menu bar's background and appearance. Its menu shows the current mode and shortcuts. **Show Launcher** opens below the notch; **Show Switcher** opens a persistent preview. Enable **Keep Open After Releasing Option** for a persistent Option–Tab toggle instead of the default hold behavior.

## Build and install

Run `./scripts/install.sh` from the project folder to build a Release version, install it into `/Applications/seven.app`, and launch it. The script quits an existing seven instance before replacing it and restores the old app if installation fails. Xcode must be installed and selected. Release installation needs an Apple signing identity so Seven and the embedded SoulverCore framework can share a Team ID while Hardened Runtime library validation remains enabled. The installer uses an available Apple Development certificate, or accepts `--signing-identity <certificate-name-or-SHA1>` / `SEVEN_SIGNING_IDENTITY`. It asks for administrator access only if the destination needs it.

Use `./scripts/install.sh --no-open` to install without launching, or `./scripts/install.sh --destination "$HOME/Applications"` to choose another Applications folder.

## Implementation

The HUD is drawn with SwiftUI vector shapes and gradients at approximately the reference's 24 × 56 point size. The glowing lens bends along the track's centerline, stretches and narrows through the waist, and settles with a spring. The lens rim stays inset from the outer track throughout overshoot. The launcher uses the native `command` SF Symbol and Notes uses `tornado`. Both symbols bend along the same centerline and local normals as the lens. Its rim, reflections, icon emphasis, and color share the same animated progress, including when scrolling reverses mid-transition. Transparent, nonactivating AppKit panels cover each display only during selection, intercept scrolling, and preserve the foreground app. The pill flips to the other side near the left edge. Trackpad noise and inertial scrolling are filtered.

The shortcuts use `RegisterEventHotKey`. The launcher uses a nonactivating panel so the original app remains active while searching. Application search and clipboard recording need no Accessibility, Input Monitoring, Screen Recording, or Automation access. It stores the selected mode and switcher behavior in local preferences. The first tab searches applications and macOS commands. Application discovery looks in /Applications, /System/Applications, the system Cryptex Applications folder, CoreServices Applications, and ~/Applications, following app links such as Safari. Application folders are monitored for installs, removals, moves, and renames, including nested folders. The catalog also refreshes whenever the launcher opens. Background refreshes preserve the current query and selection. Search matches display names, package filenames, bundle names, executables, and bundle identifiers. Use the arrow keys to select a result, and press Return or click to open it. The results area expands to a fixed six-row viewport before rows appear in a short stagger. No matches or an empty application query dismiss the rows in reverse order before collapsing the list, keeping the search field anchored. Nonempty result updates appear immediately and longer lists scroll. Reduce Motion skips the staged transition. Escape or clicking outside closes the launcher. SwiftUI’s native `ultraThinMaterial` follows macOS light/dark appearance, with adaptive text and selection colors, a 20-point radius, concentric row corners, a subtle border, and the native window shadow. Website/app usage tracking is not connected.

The app installs a standard AppKit Edit menu so macOS routes and validates editing commands through the focused control. Search supports select all, copy, cut, paste, paste and match style, undo, and redo in both application and clipboard modes. **⌘⇧C** still toggles clipboard history.

## Notes

Select the second roller item, **tornado**, by scrolling down after **Option–Tab**, then release **Option** to open Notes. **↓ / N** also selects it; click or **Return** confirms when the switcher stays open. Notes is also available from the menu bar. Notes opens in a movable, resizable panel with a 300 × 360 point content area, matching the launcher's width, material, border, and rounded corners. The editor uses the system font, with monospaced text for code. Vault and toolbar controls use native Liquid Glass on macOS 26 and later. Drag the header to move it; **⌘W** or two quick **Escape** presses (within half a second) closes it while preserving the current editor session. A single Escape still cancels editor suggestions or renaming.

Opening Notes activates Seven and gives it keyboard focus. Each activation places the panel beside the mouse pointer like the launcher, flipping left near the screen edge while preserving the editor session and resized dimensions. The panel uses normal window stacking, so switching to another app lets its windows cover Notes.

- Add a folder from the vault menu, switch between vaults, browse nested files, and search filenames, paths, or contents. Content matches show line numbers and highlighted text. Search runs in the background after a short typing pause.
- **⌘N** creates a Markdown note. Edits save atomically to the vault; click the document title to rename it. Right-click a file to move it to the Trash. Failed saves retain the draft and prevent switching documents or closing without resolving the failure.
- The Markdown editor includes headings, lists, task checkboxes, tables, code highlighting, math rendering, and native editing/undo. Type `[[` for wiki-link suggestions; use arrows and Return to insert, or Command–Return to insert and open. Command-click a link to navigate, use **⌘[** to go back, and **⌘⇧F** to browse files. Hashtags open a vault search.
- Each vault has a persistent **Scratchpad** in its menu. On first use, Seven imports W's configured vault bookmarks and scratchpads when available; the documents remain in their existing folders. Notes preferences use the `notes.` prefix in Seven's local defaults.

W's AI, illustration/drawing, and appearance customization are excluded. Notes follows macOS appearance. The vendored MarkdownEngine includes its Apache 2.0 license; Xcode resolves HighlighterSwift and SwiftMath for code and math rendering. Launch with `--notes-preview` to open the panel directly.

## Calculator

End an expression with `=` to resolve it using [SoulverCore](https://github.com/soulverteam/SoulverCore), for example `12 * (3 + 4) =` → **84**, `20% of 150 =` → **30**, or `2 meters in cm =` → **200 cm**. The panel expands before the calculation history appears. Expressions occupy the left two-thirds of each row and bold, animated results occupy the right third, separated by a vertical divider. Hover and keyboard selection highlight only the expression. Click an expression or press Return on a selected history row to reuse it. Result animations respect Reduce Motion; hover a result to read its full formatted value.

Click the trash button on a highlighted calculation or press **Option–Delete** to remove that history entry. Deleting history preserves the current input and saved variables.

Assign a variable with `rate = 25` and **Return** (no trailing `=` needed). Previewing an assignment does not save it. Type `rate =` to look up its value or `rate * 4 =` to calculate with it. Saved variables retain SoulverCore's underlying precision and units. Reassignments apply to future calculations; existing history keeps its original answers. Saved variables stay in memory until seven quits, including across launcher dismissals.

The most recent 100 calculations are saved automatically to `~/Library/Application Support/seven/calculator-history.json` and restored on relaunch with their original answers. Edits and deletions are saved immediately and atomically. Reopening the launcher, clearing Search, or returning from clipboard mode starts with only the search field; press `=` by itself to open calculation history, or resolve an expression or save an assignment. Opening history does not add an entry. Editing an expression that still ends with `=` updates its current history entry. Normal app search and clipboard search remain available; clipboard mode treats expressions as literal text.

SoulverCore is a closed-source binary framework. Its [license](https://github.com/soulverteam/SoulverCore/blob/master/LICENSE.md) permits personal/private projects; arrange a license with the Soulver team before public or commercial distribution. Currency conversions use SoulverCore's bundled rates; seven does not currently fetch live exchange rates.

## Dictionary

Type `define rampant` in the launcher to see the definition as you type—no Return needed. The panel stays collapsed until a definition is found. Lookups wait for a brief typing pause, run off the main thread, and use macOS Dictionary Services with your active system dictionaries. Entries separate the headword, pronunciation, senses, examples, and supporting notes where the system dictionary provides recognizable separators. Long entries scroll and definition text can be selected and copied. Empty, pending, and unsuccessful lookups show no results panel.

## Google search

Type `google helm` and press **Return**, or click the search result, to search Google for `helm` in your default browser. Multiword queries and Unicode are supported. Typing `google` by itself waits for a query; the browser opens only when you confirm. In clipboard mode, the same input remains a literal history search.

## Clipboard history

Click the **document.on.clipboard.fill** button beside Search, tap **Option** or press **⌘⇧C** while the launcher is open, or choose **Clipboard History** from the menu bar. With Launcher selected, releasing the Option held for Option–Tab opens it normally; a new Option tap toggles between history and general search. Option used with another key keeps its normal shortcut behavior. The same compact panel shows recent copies and searches their content, filenames, and source application. Click the clipboard button again to return to application search.

- History records new clipboard changes while seven runs, with text, original rich text/HTML, images, and multiple file references preserved. Repeated copies move to the top without duplicates. Single copied image files are captured as image data so pasting restores pixels instead of a filename. Other file copies retain references, so the originals must still exist when pasted.
- **Return** copies the selected item and restores focus to the previous application. Clicking an item pastes it directly. **Option–Return** also pastes; add **Shift** for plain text. **⌘1–9** selects and copies a visible search result by position. Arrow selection scrolls into view.
- **Option–Delete** deletes the selected history item. Right-click or **Actions ⌘ K** opens a compact custom actions panel with icons, Up/Down selection, Return to perform the selected action, and native SwiftUI material. It offers copy, paste, paste without formatting, delete, pause recording, automatic pasting, and clearing history. **Escape** closes the actions panel first. There are no pins or item count in the footer.
- Clicking a history item always pastes; automatic pasting for Return is optional. Pasting requires macOS Accessibility access. If access is missing, seven keeps the selected item and shows an Open System Settings button instead of silently copying it. Enable seven under Privacy & Security → Accessibility, then retry the selection. Explicit copying from history works without permission. After closing its panel, seven waits for the original app to regain keyboard focus and for modifier keys and mouse buttons to be released before sending Command–V through the session event stream. Switching to another app cancels the pending paste.
- History stays on this Mac in `~/Library/Application Support/seven/clipboard-history.json`, bounded to 200 entries / 64 MiB with a 16 MiB per-copy limit. Files are saved atomically with owner-only permissions. Confidential, temporary, and generated pasteboard markers are ignored. The UI reports storage failures.

## System commands

Search **Toggle Light/Dark Mode** (also matches theme, appearance, light mode, and dark mode) to change macOS appearance. macOS requests Automation access to System Events the first time this command runs. Search **Lock Screen** to lock using the standard macOS shortcut; this needs Accessibility permission. Permission failures are shown in the launcher so they can be corrected. These actions run only when selected.

The behavior reference is [Maccy’s official usage guide](https://github.com/p0deje/Maccy#usage). This implementation uses its own history storage and interface.

If Command–Space is assigned to Spotlight or another launcher, disable or reassign that shortcut before launching seven. The same applies to another utility using Option–Tab. The menu displays each shortcut's registration error if macOS rejects it; its menu action remains available.

## Verify

Run **Product → Test** in Xcode for scroll and session behavior tests. `--smoke-test` exercises shortcut registration, real AppKit overlay panels, native wheel events, cancellation, and opening Notes on Option release. `--render-previews <folder>` exports both HUD states; `--preview` starts with the persistent switcher open. `--launcher-preview` opens the launcher beside the pointer; `--notch-launcher-preview` opens it below the notch. `--launcher-smoke-test` verifies confirmation, cancellation, search focus, results, launch dispatch, and dismissal without opening another app.

The project is for local development. Distribution requires your own bundle identifier, signing identity, and notarization.
