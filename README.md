# RimWorld Utilities

RimWorld Utilities is a native macOS application for diagnosing RimWorld
saves, maintaining the Russian community translation, and managing RJW mods.
It is written in Swift and AppKit and is self-contained.

Repository: [SomaLancet/RimWorld-Utilities](https://github.com/SomaLancet/RimWorld-Utilities).

## Requirements

- macOS 14.0 or newer.
- Xcode 26.5 or newer for development.
- Git and standard macOS command-line tools for translation and mod operations.

## Open In Xcode

Open `RimWorld Utilities.xcodeproj`, select the `RimWorld Utilities` scheme,
and use Run, Build, Test, or Archive.

The project contains three targets:

- `RimWorld Utilities`: the native macOS application.
- `RimWorld UtilitiesTests`: unit tests for the analyzer and controllers.
- `RimWorld UtilitiesUITests`: launch and navigation smoke tests.

Local Debug builds use automatic ad-hoc signing. Release builds enable
Hardened Runtime. Distribution outside the Mac App Store still requires an
Apple Developer team, a Developer ID Application certificate, and
notarization.

Application versions are defined once in
`Configuration/Version.xcconfig`:

- `MARKETING_VERSION`: user-visible version.
- `CURRENT_PROJECT_VERSION`: monotonically increasing build number.

## Application Features

### Diagnostics

The application can inspect a `.rws` save together with installed mod
directories, `ModsConfig.xml`, and `Player.log`. It reports:

- game version and the ordered save mod list;
- missing, added, inactive, and reordered mods by `packageId`;
- grouped missing-definition, XML, patch, duplicate-definition, and exception
  messages from `Player.log`;
- heuristic links from log messages to mods using package IDs, names,
  Workshop paths, DLL names, and namespaces;
- save references to definitions and classes owned by inactive or missing mods;
- pawn compatibility findings such as invalid names, ages, duplicate IDs, and
  components owned by inactive mods;
- structured object diagnostics with severity, confidence, and evidence.

The analyzer is read-only. A reported reference is evidence to investigate,
not proof that an XML node can be removed safely.

The Diagnostics page also includes a Mode Remover tab. It scans a selected
mod folder, builds a conservative cleanup plan from the mod's XML definitions,
and can write a cleaned save after creating a backup next to the original
`.rws` file. Conservative cleanup removes mod metadata, faction/world-object
links, item/content nodes, genes, and parallel dictionary references while
normalizing pawns instead of deleting them wholesale.

### Translation

The Translation section downloads the current Russian community translation
from `Ludeon/RimWorld-ru` and installs it for detected game components. The
native Swift updater creates backups and rolls changes back after an error or
cancellation.

### RJW Management

The RJW section loads the categorized Libidinous Loader provider catalog,
detects installed providers, and reconciles the selected set with the local
RimWorld `Mods` directory. Git and ZIP providers are supported, with progress
and command output displayed in the application.

### Path Detection And Settings

The application suggests standard locations for saves, RimWorld, Steam
Workshop mods, `ModsConfig.xml`, and `Player.log`. Confirmed paths and the
language preference are stored at:

```text
~/Library/Application Support/RimWorld Utilities/settings.json
```

The bundled `settings.json` is only a default and migration source. User
settings are not written into the application bundle and survive replacing
the `.app`.

## Source Layout

```text
App/             Application entry point
Analysis/        Swift save, mod, and log analyzer
Models/          Analysis and application data models
Services/        Settings, path detection, updates, and process execution
Views/           Reusable AppKit views and view controllers
Controllers/     Application and window coordination
Tests/           Unit tests for the analyzer and controllers
UITests/         Application launch and navigation smoke tests
Configuration/   Shared Xcode build configuration
```

The Swift analyzer is the single diagnostics implementation and source of
truth for the application.

## Tests

Run the Swift tests in Xcode with Product > Test or from the terminal:

```bash
xcodebuild \
  -project "RimWorld Utilities.xcodeproj" \
  -scheme "RimWorld Utilities" \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  test
```

## Safety

Standard diagnostics do not modify save files. Mode Remover is the only
maintenance action that writes to a save, and it creates a timestamped backup
before changing the `.rws`. Removing a package ID from `<meta><modIds>` alone
does not remove that mod's things, hediffs, factions, world objects, quests, or
custom components, so cleanup remains conservative and should be tested by
loading the backup copy in RimWorld.
