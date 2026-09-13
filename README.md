# Reopen

**⇧⌘T for every window on your Mac.**

Closed a Finder folder three levels deep? A PDF in Preview? A project in Xcode? Press ⇧⌘T and it comes back — same document, same place, same screen.

Browsers have had this forever. macOS never did.

## How it works

Reopen is a tiny menu bar app. It uses the Accessibility API to keep a live snapshot of every standard window: the document it shows (the same thing as the title bar proxy icon), its title and its frame. When a window is destroyed and no other window shows the same document, the snapshot goes into the history. When an app quits, all its snapshots go in as one entry.

⇧⌘T asks the original app to open that document again, then moves the new window to the saved frame.

- Quitting an app counts too: ⇧⌘T relaunches it and reopens the windows it had. Apps that macOS terminates by itself once they have no window left (TextEdit, Preview), and apps closed by a shutdown, are not recorded.
- In browsers, terminals and code editors, ⇧⌘T is left to the app, which already uses it for closed tabs. The history stays reachable from the menu bar.
- History is kept in `~/Library/Application Support/Reopen/history.json` (last 30 windows) and never leaves your Mac.

## Limitations

- A window showing a file or folder comes back with it. A window without one (Spotify, Messages, ChatGPT…) comes back only if it was the app's last window: Reopen does what clicking the app's Dock icon does.
- Untitled documents are not saved anywhere, so they can't come back.
- In Finder, ⇧⌘T replaces *View › Show Tab Bar*.
- Windows are only discovered on the current Space; a window you never visited on another Space isn't tracked until you do.
- A window's scroll position, selection or page isn't restored — only the document and the frame.

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```bash
./build.sh --run
```

Then allow Reopen in **System Settings › Privacy & Security › Accessibility**. The build is signed ad hoc, so macOS asks again after each rebuild — unless you sign with a local certificate: `SIGN_IDENTITY="My Cert" ./build.sh --run`.

## Debugging

If a window doesn't come back, turn on the trace, restart Reopen and look at `~/Library/Application Support/Reopen/debug.log`:

```bash
defaults write io.github.azerht.reopen DebugLog -bool true
```

It records window titles and file paths, so turn it off again afterwards (`-bool false`).

## License

MIT
