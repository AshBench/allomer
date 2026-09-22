# Release checks

Some behavior cannot be proved by the test suite: a rename performed by Finder itself, the menu bar
item, the native window, and how any of it behaves on the oldest supported system. This page records
what is checked automatically, what was last checked by hand, and what is still open.

## Checked automatically

| Command | Covers |
| --- | --- |
| `python3 tools/check-macos-runtime.py` | Vision startup, a cold framework cache, allowed input, and denial of an unrelated file inside the native helper sandbox. |
| `swift test` | Every converter, the watcher, decisions, originals, Undo, history, and backups. |
| `swift test --filter 'AppSettingsTests\|AutomaticActionTests\|BackupRetentionTests\|ConversionModelTests\|FormatDetectionTests\|HistoryTests\|KeepOriginalTests\|MonitoredPathsTests\|MultipleOutputTests\|SourcePackageTests\|WatchedFolderTests\|testAutomaticConversionAfterExternalRename'` | The automatic-conversion surface on its own. |
| `python3 tools/check-app.py` | The packaged command outside the repository, with no development paths. |

`tools/check-app.py` drives `Contents/MacOS/allomer`, the command-line converter. It never
launches the app itself, so the watcher, decisions, Undo, history, and the menu bar are outside it.

Last clean oldest-system run: 2026-09-21 on macOS 14.8.7, arm64, in a fresh Tart clone. The
packaged-app suite and the cold-cache Vision sandbox probe both passed. The run found and fixed
three system differences: AVIF encoding availability, VideoToolbox quality handling, and EPUB ZIP
metadata. The checks now exercise those paths on macOS 14.

`WatchedFolderTests` covers the saved watched and excluded folders, which are the only preference
stored as bookmarks. If they do not come back after a restart, every automatic behavior stops at
once, and nothing else in the suite reads that write path.

[GitHub Actions](https://github.com/actions/runner-images) runs these source checks on Apple Silicon hosts with macOS 14, 15, 26, and 27. The
labels are pinned to exact system generations. A change must pass every job. The macOS 27 job is a
preview runner while that image is new. It warns and continues when Vision is unavailable outside
the sandbox on the hosted image. A sandbox-only Vision failure still fails the job.

The native runtime check exists because macOS 27 changed Vision. Vision began compiling recognition
models under the helper's user cache. The old sandbox denied that write even though the code still
built. The check removes its private probe cache first, runs accurate English OCR through the same
sandbox source, and confirms that an unrelated file stays unreadable. A fixed language keeps the
hosted check independent of automatic language-detection assets.

[OrbStack](https://docs.orbstack.dev/machines/) runs Linux guests. It cannot test AppKit, Finder,
Vision, macOS permissions, or the app's helpers on an older macOS release. Use it for Linux
documentation work only.

[GitHub plans to remove its macOS 14 runner on November 2,
2026](https://github.com/actions/runner-images/issues/13518). After that date, run the same checks
in a clean Tart Sonoma VM on an Apple Silicon Mac. [Tart](https://tart.run/) uses Apple's
virtualization framework and [publishes macOS 14, 15, and 26
images](https://tart.run/quick-start/#vm-images). Its base image download is about 25 GB. Run the
exact built app in each release VM with:

```sh
python3 tools/check-app.py /path/to/Allomer.app
```

Use a fresh VM clone or remove `~/Library/Caches/nativeconvert` before the OCR check. Test macOS 27
on its GitHub preview runner and on the current development Mac until a stable Tart image exists.

## Checked by hand on the packaged app

Run these against the built `.app`, not a development binary. Use throwaway folders. The app's
preferences live in `com.ashbench.allomer`; back them up first if the machine holds real ones.

1. **Folder selection.** Choose **Add Watched Folder…**, pick a folder. It appears in the list and
   automatic conversion turns itself on.
2. **Recursive watch.** Rename a file's extension in Finder inside a subfolder of the watched folder.
   It converts.
3. **Immediate conversion and source preservation.** With **Convert immediately**, rename
   `photo.png` to `photo.jpg` in Finder. The file becomes a JPEG and the original bytes are in the
   `.allomer-…` folder beside it.
4. **Ask first.** Switch **After an extension change** to **Ask first** and rename another file. It
   appears under **Waiting for your decision**, and the menu bar offers to review it. **Skip** keeps
   the new name and the original contents.
5. **Exact Undo.** On the **History** tab choose **Undo**. The old name and the original bytes come
   back.
6. **Keep the original.** Turn on **Keep the original file after conversion** and rename again. Both
   the converted file and an untouched original are there.
7. **Collision refusal.** Turn on **Convert to multiple formats at once**, put a file named
   `x.webp` beside `x.png`, and rename `x.png` to `x.jpg,webp`. The JPEG is created, `x.webp` is
   left exactly as it was, and the window explains which output was skipped.
8. **Relaunch.** Quit and reopen. The watched folder, the chosen action, and the history rows are
   still there, and a further Finder rename still converts.
9. **Menu bar.** Its commands open the window on the tab they name, and **Pause** stops conversion.
10. **Availability messages.** Rename a helper out of `Contents/Helpers` and start the app. It
    refuses with a reinstall message instead of quietly offering fewer formats.

Last run 2026-09-20 on macOS 27.0, arm64, against the packaged app in a temporary folder. All ten
passed. Two defects found and fixed in the same change: the menu bar item was announced by its
symbol's name rather than the app's, and monitoring a folder that the skip list covers reported
success and then converted nothing.

## Still open

These need a machine or virtual machine running **macOS 14 on Apple silicon**. The source matrix
does not answer GUI behavior, and a successful build does not settle it.

1. **Menu bar activation.** Close the window, then use each menu bar command. Confirm the window
   reopens *in front* and on the tab named. `NSApp.activate()` is the macOS 14 form and activation
   from a status item is weaker there than on later systems.
2. **Live updates.** Watch the active/waiting counter, the running step rows in History, and the
   waiting-decision list while a conversion runs. macOS 14 was the first release with the
   Observation runtime this app relies on throughout.
3. **Offered image outputs.** Open an image on the **Manual** tab. Confirm AVIF appears through the
   bundled fallback. Record whether HEIC, ICNS, and ICO appear. Those writers come from ImageIO at
   run time, so macOS 14 can offer fewer.

Also open, and not tied to macOS 14: keyboard navigation with **Full Keyboard Access** turned on in
System Settings. The checks above were run on a machine where it is off, so Tab reaches only text
fields and lists there.

A signed build also needs these checks on a clean account:

1. **Quarantined first launch and translocation.** Download the disk image in a browser. Launch the
   app once from the mounted image, then drag it to Applications and launch it again. Confirm both
   launches find every bundled helper and resource. Repeat the Applications launch with networking
   disabled to prove the stapled app ticket works on its own.
2. **Launch at login.** Enable **Settings → General → Launch at login**, log out, and log back in.
   Confirm Allomer opens and resumes the saved monitoring state. Disable the setting and confirm it
   does not open after the next login.
3. **Notifications.** Enable conversion notifications, answer the real macOS permission prompt, and
   complete a conversion while the window is closed. Confirm the banner names the converted file
   and opens Allomer when selected. Repeat after revoking permission in System Settings.

## What a build already settles

Building for the deployment target rejects any API newer than macOS 14, so a clean
`swift build -c release --arch arm64` is the availability check for the app's own code. Two things
it does not check, both verified separately:

- Every bundled helper's own minimum version. `vtool -show-build` over the Mach-O files in the
  bundle reports `minos 14.0` for all of them.
- Symbol names given as strings. The app uses seven SF Symbols, all available since macOS 12, and
  two System Settings URLs, both handled since macOS 13.
