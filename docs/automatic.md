# Automatic conversion

Add a watched folder on the **Automatic** tab. Then change a file's extension in Finder. The app converts its contents to the new format and keeps the original for Undo. Subfolders are included. Excluded folders are left alone.

## Monitoring scope

Selected folders are the default. **Watch whole system** instead listens for future filesystem events from the root directory. The saved watched folders remain available when this mode is turned off. Excluded folders still apply. Enabling the mode does not scan existing files or turn on paused conversion.

Watched and excluded folders are saved as bookmarks and come back when the app reopens. A folder that has since been deleted is dropped from the saved list with a message; it does not block adding or removing the others.

Whole-system mode needs Full Disk Access. Use **Full Disk Access Settings…** to open the macOS control, then try the toggle again. The app checks whether existing Safari, Mail, and Messages directories under the user's Library are accessible. It opens no user files and retains no directory entry names during that check. Denied or inconclusive access leaves whole-system mode off. This check is an access signal; it is not an authoritative report of every macOS permission.

Access is checked when enabling the mode, when loading a saved whole-system setting, and when its app window becomes active. If the check fails, the app returns to selected folders. Monitoring pauses if there are none. macOS still enforces file access, volume permissions, and write protection.

**Ignore system and cache files** is on by default and applies in both modes. It skips these locations and their descendants:

| Location | Excluded folders |
| --- | --- |
| System | `/System`, `/bin`, `/sbin`, `/usr`, `/cores`, `/Library`, `/private/var`, `/private/tmp`, `/private/etc`, `/var`, `/tmp`, `/etc`, `/opt/homebrew`, `/.Trashes` |
| User Library | Accounts, Application Support, Autosave Information, Caches, Calendars, ColorSync, Containers, Cookies, Developer, Group Containers, HTTPStorages, Input Methods, Intents, Internet Plug-Ins, Keychains, LaunchAgents, Logs, Mail, Messages, Metadata, Preferences, Saved Application State, Sounds, Spelling, Suggestions, WebKit, Spotlight |
| User home | `.Trash`, `.npm`, `.nvm`, `.pnpm-store`, `.yarn`, `.bun`, `.cargo`, `.rustup`, `.gradle`, `.m2`, `.cocoapods`, `.gem`, `.rbenv`, `.pyenv`, `.conda`, `.swiftpm`, `.local`, `.cache`, `.docker`, `.orbstack`, `.vscode`, `.zsh_sessions`, `.bash_sessions` |

If every watched folder sits inside a location this filter or your excluded folders cover, monitoring refuses to start and says so, because nothing there could ever be converted. Turn the filter off, remove the exclusion, or choose another folder.

The filter uses folder boundaries. For example, `Caches-other` is not excluded by `Caches`. Startup data-volume aliases and `/private` aliases use the same filter rules. The app's recovery directories stay excluded even when the option is off. Changing scope or this filter restarts active monitoring and clears pending decisions. Queued and running work is cancelled; a commit that already finished retains its Undo record.

The filter runs on the event queue before resolving retained event paths. Empty batches do not wake the app model. A lost batch of events restarts monitoring and reports that renames during the gap were not seen. After three consecutive recovery attempts, another loss stops monitoring for review. A watched folder that is no longer there also stops monitoring. Apple's [FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) describes the directory event service.

Root watching, actual Full Disk Access changes, external-volume mounting, and macOS 14 behavior still need runtime release checks. See [Release checks](release-checks.md). Automated tests use temporary watched folders and simulated permission states. They do not activate whole-system watching or access private app folders.

## Choose what happens after a rename

**After an extension change** has three choices:

| Choice | Behavior |
| --- | --- |
| Convert immediately | Convert once the renamed file has settled. This is the default. |
| Ask first | Put the file under **Waiting for your decision** on the Automatic tab. Choose **Convert** or **Skip**. |
| Do not convert | Leave the renamed file's contents unchanged. |

The app also asks first when the volume is low on free space, whatever action is chosen. Converting writes the result beside the original, so it needs about twice the source size plus 128 MiB. The waiting entry explains why. Choosing **Convert** still proceeds, so free some space first if you want it to succeed. A **Do not convert** rule is unaffected and still leaves the file alone.

The menu bar has a **Review Pending Conversions** command when decisions are waiting. Each entry shows the old name, new name, and containing folder. **Convert** uses the pair's saved settings, or the current global settings if the pair has none.

Choose **Settings…** to review and change options for one pending conversion. These edits do not change global defaults. The options shown when the sheet opens stay in that sheet until you convert or cancel.

Skip keeps the new filename and the existing contents. It does not change the extension back. Do not convert has the same file behavior. Neither choice creates an Undo record because no conversion occurred.

The action is saved across app launches. Pending decisions are not saved. Pausing monitoring, changing the action, or quitting clears them. Changing the action does not cancel work already approved. Pausing or quitting cancels queued and running work. A commit can finish just before cancellation; its Undo record is kept.

If a file changes while awaiting approval, conversion refuses it. Rename the file again to request a new conversion. Renaming an awaiting file to another supported extension replaces the old decision. Returning it to its original format cancels the decision.

## Format rules and remembered settings

Choose **Add Rule…** on the Automatic tab. Select a source format, a target format, and an action. A matching rule takes priority over the default action. For example, PNG to JPEG can ask first while other pairs convert immediately.

Rules match format IDs. Extension aliases such as `.jpg` and `.jpeg` use the same rule. Direction matters: PNG to JPEG and JPEG to PNG are separate pairs. Rules do not enable an unsupported conversion.

Turn on **Save conversion settings for this pair** to store its own options. Otherwise, the pair follows the current global settings. **Original file** can follow the default, keep a visible original, or keep it only for Undo. The same conversion settings controls are used in the rule editor, the pending conversion sheet, and the Settings tab. CPU use stays global.

In a pending conversion's settings sheet, **Remember settings for this pair** saves the options, stage overrides, and original-file choice when you choose Convert. It keeps the pair's current action. It does not turn Ask first into Convert immediately. Cancel closes the sheet without changing the rule or starting conversion. The main list still has the pending decision.

Saving a rule replaces any rule for the selected pair. Edit changes the selected rule. Remove restores the default action and global settings for future renames. Rules persist across launches. Invalid saved rules cause Ask first mode and an error message.

Changing a pair's effective action clears its pending decisions. Changing only its settings keeps those decisions. Other pairs stay pending. Work already approved keeps its selected options. A remembered setting also keeps other decisions for the same pair available.

## Settings for individual stages

Choose **Stage Settings…** from manual conversion, a format rule, or a pending conversion's settings sheet. Select a stage, then turn on **Override settings for this stage**. Its controls start with the output's defaults. Intermediate tables start at sheet index 0. Changes apply only to that stage's input/output pair. CPU use follows the global setting.

For example, a YAML-to-DOCX route can use JSON and TSV intermediates. An override for YAML to JSON can infer number types while the later stages keep their output defaults. History records the settings actually passed to each stage. A converter still determines which options apply to the input.

Other stages continue to use the output defaults. Turning an override off restores those defaults. **Use Defaults for All Stages** removes every override in the current editor. Stage settings in a rule persist across launches. A pending decision uses the settings visible in its sheet. Manual overrides last for the current selection and reset when the source or output format changes.

The rule and approval editors preview a route from the format pair. Image previews assume one frame. Manual conversion reads the selected file to plan its route. Actual contents can require another route. If a saved override no longer matches, that output is not converted and the source is kept. Other outputs in a group can still complete. Review the stage settings and use **Remove Unused Overrides** to remove stale entries. Duplicate overrides are also rejected. Changing a rule's format pair clears its previous stage overrides.

Each output in a multiple-format request has its own stage settings. An exact source copy has no configurable stages. An explicitly configured intermediate PNG stage applies its compression choice before the next stage reads it. These controls use the existing converters and do not install another helper.

Tests check an override across a three-stage route, inherited settings, global CPU use, per-output choices, saved rules, one-time approvals, clearing an inherited override, source preservation, Undo, older settings data, and rejection of duplicate or stale stages. Native editor interaction still needs a release check, listed in [Release checks](release-checks.md).

## New files with the wrong extension

Turn on **Convert new files with the wrong extension** to check future files created, copied, or moved into watched folders. It is off by default. Existing folders are not scanned when it is enabled.

The filename chooses the output format. For example, a PNG copied in as `photo.jpg` becomes a JPEG at that same name. The app identifies the contents first. The usual action, pair rule, and saved options then apply. Pending decisions show the detected format. A PNG-to-JPEG rule also covers this example.

Unknown contents and unsupported filename extensions are skipped. Many text formats share the same syntax. A compatible text extension can be kept as a hint. Notebooks and glTF files larger than the 1 MiB header read also keep a compatible filename hint. Media containers have aliases; a VOB without its extension is identified as an MPEG program stream. Detection does not establish full support for every input variant.

Undo restores the exact arrival name and original bytes. With **Keep the original file after conversion**, a visible original uses the detected extension, such as `photo.png`. Undo verifies and retires that copy before restoring the arrival file. An occupied original name or an edited copy stops the operation.

Turning the option off clears pending arrival decisions and cancels their queued work. Ordinary rename decisions remain available. A conversion already committing can still finish and retain its Undo record. Detection shares the CPU job limit and waits during backup cleanup.

## Multiple output formats

**Convert to multiple formats at once** is off by default. Enable it, then rename a file with comma-separated extensions. For example, renaming `photo.png` to `photo.jpg,webp` creates `photo.jpg` and `photo.webp`. Extension aliases are accepted. Repeated formats produce one output using the first requested extension. Compound extensions such as `tar.gz` are supported. The app also handles Finder appending the old extension after a target list.

Use commas only between output extensions to avoid ambiguous names.

The app identifies the source contents before choosing each format rule. A compatible old extension helps identify ambiguous text and media containers. Detection still has the limits described under new arrivals; it is not qualified across every catalog input. Unknown contents stay unchanged. Newly created files need **Convert new files with the wrong extension** enabled as well. Turning on either option does not scan existing files.

Each output uses its pair rule and conversion settings. **Ask first** creates a separate decision for that output. Low free space makes every output in the group ask first. The group waits for every pending decision, including when some outputs use **Convert immediately**. **Skip** and **Do not convert** omit that output. If all outputs are skipped, the source keeps its comma-separated name and original contents. Renaming a pending file or disabling the option clears its group decisions. Pausing clears all pending decisions.

Selected outputs share one source snapshot. They convert in sequence as one job under the global CPU limit. Selecting the detected source format creates an exact copy instead of re-encoding it. If any selected output asks to keep the original, the group keeps one visible original. It uses the old name when that extension matches the source, or the group's base name with the detected extension otherwise. A requested source-format output can serve as that visible original.

Unknown, occupied, or failed targets appear in History. Other successfully prepared outputs can still be created. If no output can be prepared, the source stays unchanged. A name collision during final publication stops the group. Recovery moves only verified owned outputs and keeps conflicting files. Edited or ambiguous recovery data requires review.

**History → Undo All** treats the outputs as one group. It verifies their contents and file identities, including generated companion folders and any visible original. It then moves them into recovery storage and restores the retained source at its original name. Changed or replaced files stop Undo. Group Undo also restores the original inode. Recovery handles recorded interruptions during publication and Undo. This is not a guarantee against every storage or power failure.

Tests cover real temporary-folder renames, mixed decisions, per-output settings, source copies, companion resources, cancellation, occupied names, edited files, interrupted journal states, exact Undo, and backup cleanup. All-format group conversion still needs a release check. Finder's own renames, including the occupied-output case, are covered by the packaged-app run in [Release checks](release-checks.md).

## Originals and Undo

The watcher groups rename events by filesystem identity and waits for the file to settle. No snapshot or conversion starts while a decision is pending. Waiting decisions do not add a polling loop.

When conversion starts, the app makes a stable snapshot. On APFS, it uses a file clone. It verifies the source before replacing it. The original remains in a private recovery folder beside the converted file. **History → Undo** restores its original name and contents.

**Keep the original file after conversion** is off by default. Turn it on to leave a visible copy at the original name and location. For example, renaming `photo.png` to `photo.jpg` produces the JPEG and keeps `photo.png`. The visible copy uses an APFS clone when available. Other supported filesystems use a copy. The source backup remains separate, so editing the visible original cannot change that backup.

The default applies to future conversions. A pair rule can override it. The pending settings sheet can also change it for one conversion. Remembering settings saves that choice for the pair. Approved jobs keep their selected choice. Changing the setting does not create or remove originals from earlier conversions.

If the original filename is occupied, conversion refuses to overwrite it. A collision during conversion rolls back the output replacement and keeps the existing file. This includes an occupied name that is a symbolic link. After an interrupted commit, recovery can finish creating a missing visible original from its verified backup. Different contents at the original name require review.

For a single output with a visible original, Undo leaves that file in place and moves the unchanged converted result into recovery storage. It checks both files first. If the original is missing or either file has changed, Undo stops. Without a visible original, Undo restores the retained source to its old name; an occupied name stops Undo. Whole Icon Composer packages and converted companion-resource folders follow the same checks. Multiple-output groups use **Undo All** as described above.

Pausing monitoring does not remove recovery files. Undo does not immediately free their storage.

## Search and manage history

History shows automatic and manual jobs. The status filter offers All, Active, Completed, Failed, and Cancelled. Active includes queued work, source detection, pending decisions, and running conversion. Search matches source names, output names, paths, and messages. It ignores case and supports common accent differences.

Use **Cancel** to stop one active job. Cancelling a multiple-output job cancels the group. Review individual output decisions on the Automatic tab. A commit can finish before cancellation takes effect; that job remains completed and keeps its Undo record. Quit waits for converter completion callbacks and pending history writes.

**Steps and Settings…** shows each output's conversion stages, their status, and the settings passed to them. The values are read-only and do not change when global defaults change. A multiple-output job has a selector for each output. Choose a step to inspect its input format, output format, settings, or failure message. The panel updates while the job runs. Exact source copies show an explanation instead of encoder controls. Older entries keep their original output settings; no past steps are inferred.

Active rows show the current step number and the number of stages in that output's route. For example, an XLS-to-DOCX route can read the selected sheet into TSV, then create DOCX from that table. History records the selected sheet index for the first stage and the intermediate table's index for the next. The count tracks conversion stages, not elapsed time. Helper internals, such as individual rendering passes, have no separate entry. Steps that have not started are not listed in the settings panel.

A completed step does not mean the job has saved its result. File checks, publication, and recovery recording still have to finish. A later failure can leave completed steps in a failed job. Cancellation records the interrupted stage when one has started. A request rejected before any stage starts has no step record. The settings are values passed to the stage; the selected converter determines which options apply to the input.

**Clear Finished…** clears completed, failed, and cancelled rows across all search terms and filters. It asks for confirmation. Jobs that are active when clearing starts remain visible. Recovery that needs review also remains visible. Clearing history does not remove converted files, originals, or retained backups. Cleared rows no longer provide Undo in this list. Backup limits and **Clear All Backups** can still find their retained files.

History is stored locally. Cleared rows stay hidden after restart and backup cleanup. A job interrupted before its final status was saved is checked against its recovery journal at startup. A completed journal restores the completed status and confirms any recorded running step for a saved output. Other unfinished jobs and steps become failed entries for review. A history-write error is shown without changing the conversion result. Files and backups retain their existing recovery rules.

Tests cover search and status matching, individual cancellation, group cancellation, step ordering and settings, cancellation between stages, source-copy records, shutdown callback completion, interrupted status records, clear/write ordering, restart, older metadata, unchanged source and output bytes, retained backup cleanup, invalid metadata, and storage failures. Native window interaction and launch/quit behavior are covered by the packaged-app run in [Release checks](release-checks.md).

## Backup limits and cleanup

In **Settings → Backups**, choose a maximum age in days, a total size limit in GiB, or both. Choose **Apply Limits** to save the values and schedule cleanup. Both limits are off by default. The initial fields show 30 days and 10 GiB. These values have no effect until their limit is enabled and applied.

Age starts at the conversion date. Size counts the contents of recovery files, including snapshots and cloned files. It does not measure shared disk blocks. One GiB is 1,073,741,824 bytes. Size cleanup removes the oldest eligible backups first. Unavailable or unreadable storage can prevent size cleanup from reaching the chosen limit.

Cleanup runs after limits change, after conversions, and about once an hour while a limit is enabled. It waits for running work and pauses new conversions until it finishes. Queued conversions and pending decisions remain available. Cleanup runs away from the UI.

Automatic cleanup checks retained contents before removal. Edited backups and records that need review stay in place. **Clear All Backups…** asks for confirmation and can remove edited recovery data. Unfinished conversion and Undo transactions still require recovery first. Cleanup by age and size handles recovery folders recorded in history. Separately, a conversion reclaims leftovers from an interrupted conversion in the same folder. A private marker identifies work that stopped before publication, including converter temporary files. The app removes that folder only when no history entry records it and no running conversion holds it. Older unmarked folders are removed only when they have the known unfinished shape. It does not scan folders you do not convert in.

Removing a backup permanently disables Undo for that history entry. Converted files, visible originals, and history entries remain. Removal is recorded before deletion so an interrupted removal can resume. A replaced recovery directory requires review. History shows when a backup was removed or its removal needs to finish.

## Login and notifications

**Settings → General → Launch at login** registers the app with macOS. The control reads the system's current state. If approval is needed, **Login Items Settings…** opens the relevant System Settings page. Disabling this option stops future login launches. It does not quit the current app or change the saved monitoring choice.

**Show notifications after conversion** is off by default. Turning it on requests notification permission if macOS has no prior decision. Permission is not requested at startup or during conversion. If permission was denied, use **Notification Settings…** to change it. The option remains selected so later system approval can take effect.

Automatic completions within a one-second window share a notification. It shows up to three filenames and the remaining count. Manual completions and conversion or Undo errors also use this setting. Cancelled conversions do not send failure notifications. Permission is checked again before each delivery. macOS controls banner appearance, sound, and Focus behavior.

Clicking a notification opens History, Automatic, or Manual according to its result. Clicks received during app startup wait for the window connection. Turning notifications off discards unsent completion batches. Quitting also discards them. A notification delivery failure does not change the conversion result.

The implementation uses Apple's [local notification API](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app) and [main-app login registration](https://developer.apple.com/documentation/servicemanagement/smappservice). These add no bundled helper. Actual permission dialogs, banners, window reopening, and launch after login still need runtime release checks, listed in [Release checks](release-checks.md).

## Development checks

Run `swift test --filter 'AppSettingsTests|AutomaticActionTests|BackupRetentionTests|ConversionModelTests|FormatDetectionTests|HistoryTests|KeepOriginalTests|MonitoredPathsTests|MultipleOutputTests|SourcePackageTests|WatchedFolderTests|testAutomaticConversionAfterExternalRename'`.

Folder checks cover the saved watched and excluded bookmarks across a restart, that the two lists never overwrite each other, that removing the last folder clears the saved list, and that a folder deleted from disk is dropped with a message instead of blocking the rest. A separate check refuses monitoring when every watched folder is inside a skipped location.

Scope checks cover root matching, path aliases, folder boundaries, system exclusions, symlink exclusions, and real external renames in temporary folders. A separate check feeds a dropped batch of events and covers the restart, the limit on repeats, and a watched folder that was removed. Model checks cover saved scope, denied and revoked access, and disabling during a pending check. Native access-probe checks use owned temporary directories, including missing, unreadable, and symlink paths.

The checks use real filesystem events from an external rename command. They cover approval, skipping, changed contents, a second rename, obsolete decisions, action changes, pause, rule priority, extension aliases, saved and one-time settings, default fallback, and exact Undo. A separate check covers the low-space threshold against a measured source size and the volume capacity read. Forcing a decision on a genuinely full volume still needs a release check. Original-file checks cover name collisions before and during conversion, symbolic links, interrupted commits and Undo, edited originals, whole packages, and companion resources. Preference checks cover legacy settings, rule replacement and removal, and damaged saved rules. They use temporary folders and do not launch the GUI or change the running app's settings.

Cleanup checks cover age boundaries, oldest-first size removal, disabled limits, edited backups, unfinished transactions, cancellation, interrupted deletion, directory replacement, symbolic links, and stale Undo requests. Controller checks verify saved limits and waiting for active work. Watcher checks verify queued jobs retain their approved settings while cleanup holds the queue.

Arrival checks use external copies and moves. They cover the disabled default, detected pair rules, changed files, a second rename, stale decisions, disabling only arrival decisions, maintenance holds, unknown contents, and exact Undo. Detection checks cover generated images, structured text, archive containers, and the existing media fixtures. These checks do not prove detection across every catalog format or input variant.

App-setting checks simulate native permission and login responses. They cover denied and revoked permission, grouped completions, quiet authorization, delivery errors, disabling during an authorization read, login approval and failure, external status changes, and notification window routing. They do not register a real login item or send notifications.
