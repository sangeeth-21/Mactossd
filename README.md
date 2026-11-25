<p align="center"><img src="Resources/Logo.png" width="160" alt="PhotoBridge logo"></p>

# PhotoBridge

A native macOS app (SwiftUI + PhotoKit) that compares your **Photos library** with an **external SSD folder**.
It shows which images are in both places, which are only in Photos, and which are only on the SSD.
You can view them side by side, copy them either way, and filter by **People**.

## Build & run

Requires macOS 14+ and Swift 5.10+ (the Command Line Tools are enough; Xcode is optional).

```bash
scripts/build-app.sh --run        # builds build/PhotoBridge.app and launches it
```

**Installer:** `scripts/make-dmg.sh` produces `build/PhotoBridge-<version>.dmg`. Open it and drag PhotoBridge to Applications.
On first launch, right-click the app › Open (it isn't from the App Store).

Debug iteration: `swift build`. Run the bundled `.app` rather than the bare binary, because Photos permission
needs the `Info.plist` usage strings.

> **Permissions:** macOS asks for Photos access on first launch. The **People** filter also needs
> *Full Disk Access* (System Settings › Privacy & Security › Full Disk Access › add PhotoBridge).
> Ad-hoc signed builds may re-ask after each rebuild. To avoid that, sign with a stable identity:
> `SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh`.

## Using it

1. **Connect Photos**, then **Choose SSD Folder** (or click a drive under *External Drives*).
2. The sidebar's *Compare* section filters the grid: **All · In Both · Only in Photos · Only on SSD**.
3. Select images (click, ⌘-click, ⇧-click, ⌘A) and use **Copy to SSD** (⇧⌘E) or **Add to Photos** (⇧⌘I).
4. Double-click or press Space to open the viewer. Images that exist in both places are shown side by side.
   Use ← → to move between images.
5. **People:** tick one or more people. **Any** shows photos with any of them; **All** shows only photos with all of them.
   This combines with the Compare filter. For example, *Only in Photos* plus *Mom* shows every photo of Mom that isn't backed up yet.

6. **Unwanted Images** (below People): Screenshots, Bills & Documents, Chat & Forwarded (WhatsApp, Telegram…)
   and Blurry & Low Quality. Screenshots and chat images are found instantly from metadata and file names.
   Click **Find Bills & Blurry Photos** to check the rest. Apple's Vision framework runs on this Mac, nothing is uploaded,
   and results are cached. Click a category to show those images, then **Select All** and **Delete…**.
7. **Delete** (toolbar, right-click, ⌘⌫ or Delete key): choose *from Photos*, *SSD files to Trash* or *Everywhere*.
   Photos go to *Recently Deleted* (restorable for 30 days) and SSD files go to the Trash, so both can be undone.

8. **iPhone** (sidebar): connect with a cable, unlock it and tap *Trust*, then click the iPhone.
   Every iPhone photo shows whether it's already **in Photos** and **on the SSD**. Filters: *Not on SSD · Not in Photos ·
   New · Backed Up*. **Copy to SSD** / **Add to Photos** transfer byte-exact originals (full quality) and skip photos already there.
   The iPhone is read-only: PhotoBridge never changes or deletes anything on it.

9. **Select Mode** (toolbar, next to Select All): turn it on and every click adds or removes a photo, with a checkbox on each
   thumbnail and no ⌘ key needed. Shift-click still selects a range. Esc or clicking the button again finishes.
10. **Duplicates** (Unwanted Images › Duplicates, or **Find Duplicates**): copies show a yellow "2", "3"… badge. Select one and the
    right-hand panel lists every other copy and where it lives. Click a copy to jump to it, or use *Keep This, Delete Other Copies…*,
    which still goes through the normal confirmation.
    Only strong evidence counts: identical SHA-256 checksum, the same shot saved twice (same name, second and size), or the same
    second and size plus a near-identical picture. Burst shots and lookalikes taken at different times are never flagged.

## Safety guarantees

- **Nothing is deleted unless you click Delete and confirm.** The confirmation alert's default button is *Cancel*, so
  Return or Esc never deletes. Photos also shows its own system confirmation. Deleted photos go to *Recently Deleted* (30 days) and SSD files go to the Trash.
  The alert warns you when a selected image is your only copy.
- **Copies never overwrite.** Files are written to a hidden temp name and moved into place with an operation that refuses to replace
  an existing file. A name clash becomes `name (1).ext`. Imports into Photos copy the file and never move the source.
- **No false matches.** A pair needs positive evidence (same size or same capture time) and no contradiction. iPhone file names
  that repeat every 10,000 shots, burst shots and photos with no evidence are left unmatched, so nothing is ever shown as backed up when it isn't.

Shortcuts: ⌘O choose folder · ⌘R rescan · ⌘1–4 filters · ⌘+/⌘− thumbnail size · ⌥⌘I inspector · ⇧⌘R reveal in Finder · ⌘A select all · ⌘D deselect · ⌘⌫ delete.

## How it works

```
Sources/PhotoBridge
├── App/
│   ├── PhotoBridgeApp.swift     App, window, menus & shortcuts
│   └── AppModel.swift           @Observable state: sources, matching, filters, selection, transfers, people
├── Models/Models.swift          PhotoAsset, DiskFile, CompareItem, Person, filters
├── Services/
│   ├── PhotoLibraryService      PhotoKit: fetch, thumbnails, export originals, import files
│   ├── DiskScanner              Folder walk + ImageIO header reads (size, EXIF date), cached
│   ├── Matcher                  O(n) hash matching of Photos ↔ SSD
│   ├── ThumbnailLoader          NSCache-backed thumbnails for both sources, size-bucketed
│   ├── PeopleService            Reads People from a temp copy of Photos.sqlite + Vision face crops
│   ├── DeviceService            iPhone/camera access via ImageCaptureCore (read-only)
│   ├── DuplicateFinder          Checksum / same-shot / look-alike duplicate groups
│   ├── JunkDetector             Screenshot/chat/document/blurry detection (metadata + Vision)
│   ├── TransferService          Off-main export work
│   └── Storage                  Caches, unique file naming, formatting
└── Views/                       Sidebar, grid, inspector, viewer, settings
```

**Matching.** Files match when they have the same name stem, ignoring case, extension and " (1)" suffixes.
So `IMG_1234.HEIC` in Photos matches `IMG_1234.jpg` on the SSD. The match must also agree on pixel size or capture time.
Renamed files are still caught by an exact capture time plus pixel size match.

**Speed.**
- Photos original filenames are read in parallel and cached on disk, so the next launch is near-instant.
- SSD metadata comes only from image headers, read in parallel and cached by path, size and modified date. Rescans only read new or changed files.
- Grid thumbnails load lazily and are cancelled when they scroll off screen.
- SSD thumbnails use embedded EXIF previews when they're large enough, otherwise a downsampled ImageIO decode.
- Filtering 50k+ items is a single linear pass.

**Copying is non-destructive.**
- Photos → SSD writes the untouched original (from iCloud if needed). It goes into `YYYY/YYYY-MM/` folders unless you turn that off in Settings, and never overwrites: duplicate names get " (1)".
- SSD → Photos copies the file in and never moves or deletes it.
- Nothing is deleted unless you choose Delete. Even then, everything can be recovered (Recently Deleted or the Trash).

**People.** PhotoKit has no public People API. PhotoBridge copies `Photos.sqlite` to a temp folder, reads the
face → person table there, and deletes the copy. Your library itself is never opened for writing. The schema is
detected at runtime, so it works across macOS versions. People apply to Photos items and to SSD files matched
to them. Images that exist only on the SSD have no People data.
