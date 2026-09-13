<p align="center"><img src="docs/icon.png" width="160" alt="Reopen icon"></p>

<h1 align="center">Reopen</h1>

<p align="center"><b>⇧⌘T for every window on your Mac.</b></p>

Closed a Finder folder three levels deep? A PDF in Preview? Quit an app by mistake? Press ⇧⌘T and it comes back — same document, same place, scrolled where you left it.

Browsers have had this forever. macOS never did.

## What comes back

- **Windows with a file or folder** (Finder, Preview, TextEdit, Xcode…) reopen that file where the window was, with its scroll position and text selection.
- **Untitled documents**: just before the window closes, Reopen copies its text, fonts and colours included, into a file it reopens.
- **Windows without a file** (Spotify, Messages, ChatGPT…) come back through the app's *New Window* command, or like a click on its Dock icon when it was the last one.
- **Quit apps** relaunch with all the windows they had.
- **Soft close** (optional) brings back anything closed in the last seconds exactly as it was.

## Back and Forward for windows

Clicked a notification, followed a link, ⌘Tabbed away — and lost your place? **⌃⌥←** goes back to the window you were using before, then the one before that, across all apps and Spaces. **⌃⌥→** goes forward again. Like a browser's history: each window appears once, closed windows are skipped, and picking a new window after going back drops the forward history. Both shortcuts can be changed in **Settings**.

## How it works

Reopen is a tiny menu bar app. Through the Accessibility API it keeps a live snapshot of every standard window, on every Space: the document it shows (the title bar proxy icon; Finder is asked over Apple Events), its title and its frame. When ⌘W, ⌘Q or a close button is about to act, it also reads what can't be read afterwards: scroll position, selection, the text of an untitled document.

The shortcut asks the original app to open that document again, then moves the new window to the saved frame and scrolls it back.

- The shortcut can be changed in **Settings**. It is left to the apps that already use it for closed tabs (browsers, terminals, code editors; the list is editable), and when there's nothing to reopen the keystroke goes on to the app, so Finder's *Show Tab Bar* still works.
- `reopen://last`, `reopen://back` and `reopen://forward` do the same as the shortcuts, for Shortcuts, Raycast or scripts.
- History keeps the last 30 entries in `~/Library/Application Support/Reopen/history.json`; rescued untitled documents sit next to it in `Recovered/` for 14 days. Nothing leaves your Mac.

## Soft close (beta)

Off by default, in **Settings**. When on, ⌘W and the red close button hide the window instead of closing it, for 10 seconds to 2 minutes. The shortcut puts it back untouched: conversation, tabs, undo history, unsaved changes. After the delay Reopen closes it for real; if the app then asks about unsaved changes, the window comes back on screen.

- A hidden window keeps running, so apps playing or recording sound are closed normally (detected on macOS 14.2 and later).
- ⌘W is left alone in tabbed windows and in the apps that keep the shortcut, where it closes a tab.
- Quitting Reopen closes hidden windows for real. If Reopen crashes, they stay parked off screen, where Mission Control still shows them.

## Limitations

- Scroll position, selection and untitled text are read through Accessibility: most native apps expose them, web-based apps rarely do.
- They are read when a window is closed with ⌘W, ⌘Q or its close button. A window closed another way (a menu, a script) comes back without them.
- Without soft close, a window without a file comes back as a new window of its app, not with its former content.
- Windows on other Spaces are found with a private Accessibility function, as window switchers do, and apps playing sound are matched to their helper processes with another private function. A future macOS could break either; Reopen then falls back to tracking a Space's windows when you visit it.

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```bash
./build.sh --run
```

Then allow Reopen in **System Settings › Privacy & Security › Accessibility**; macOS also asks once to let it control Finder. The build is signed ad hoc, so macOS asks again after each rebuild — unless you sign with a local certificate: `SIGN_IDENTITY="My Cert" ./build.sh --run`.

## Debugging

If a window doesn't come back, turn on the trace, restart Reopen and look at `~/Library/Application Support/Reopen/debug.log`:

```bash
defaults write io.github.azerht.reopen DebugLog -bool true
```

It records window titles and file paths, so turn it off again afterwards (`-bool false`).

## License

MIT
