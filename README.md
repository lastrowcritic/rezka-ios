# Rezka: HDRezka app for iPhone and iPad

**An unofficial HDRezka client that lets you watch the films and series from the HDRezka website in a Netflix-style experience, like a premium streaming platform.** It tracks the films and episodes you have watched, so you can continue exactly where you left off. It is a native iPhone and iPad app with AirPlay to your TV, Picture in Picture and offline downloads.

<p align="center">
  <img src="screenshots/home.jpg" width="32%" alt="Rezka home screen on iPhone">
  <img src="screenshots/details.jpg" width="32%" alt="Film details on iPhone">
  <img src="screenshots/search.jpg" width="32%" alt="Search on iPhone">
</p>

Looking for Android phones, Android tablets or Google TV? See [rezka-android](https://github.com/lastrowcritic/rezka-android). Sync iPhone and iPad through your private iCloud account, or host [rezka-sync-server](https://github.com/lastrowcritic/rezka-sync-server) for custom-server and Android sync.

## Disclaimer

This project is only a client. It does not host, upload, store or distribute any films, series or other media. Everything you see in the app is loaded directly from the third party HDRezka website. We are not affiliated with that website and are not responsible for its content, its availability or how it is used. You are responsible for following the laws of your country when using it.

## What it does

- **Browse** the live catalogue: new releases, popular titles, genres, categories and collections.
- **Search** in Latin or Cyrillic.
- **Title pages** with poster, rating, description, cast, comments, franchises and related titles.
- **Choose** the voice-over (translation), season, episode and video quality before you press play.
- **Watch** in the standard iPhone player, with AirPlay, Picture in Picture, playback speed and full screen.
- **Continue watching** from exactly where you stopped. Each episode remembers its own position.
- **Autoplay** the next episode after a short countdown, even across seasons. You can turn it off.
- **Download** films and episodes to watch offline.
- **Hide countries** you are not interested in, across the whole app.
- **Watchlist** and viewing history, saved on your iPhone.
- **Sync** watch history, episode positions and Continue Watching through Apple Cloud or your own server (optional).

Your library is saved locally. If you enable sync, viewing history is also stored in your private iCloud database or on the server you select. The app has no analytics and no public sync server.

## Sync across devices (optional)

Open **Settings → Sync across devices → Sync with** and select:

- **Off** (default): history stays on this device.
- **Apple Cloud (iCloud)**: use the same iCloud account on your iPhone and iPad. Requires an iCloud-enabled build; no separate Rezka account or hosting is needed.
- **Custom server URL**: enter an HTTPS [rezka-sync-server](https://github.com/lastrowcritic/rezka-sync-server) address, apply it, then create an account or sign in. Use the same server/account on every device. This also works with Android and builds signed using a free Personal Team.

Enabling a provider immediately merges local and remote history. The watched library includes movie completion, each episode’s position, translation, season and episode, and title details needed to show Continue Watching even before the catalogue loads. The most recently updated version of each movie/episode wins, including intentional rewinds. Continue Watching shows the latest episode per title, with the most recent title on the left. New cards slide in from the left and existing cards animate to their new positions; Reduce Motion disables movement.

Sync runs on launch/foreground, before resuming playback, after pausing/closing playback, and every 20 seconds while the app is active. Saves during playback are batched for five seconds. Background uploads receive bounded execution time; local data remains durable if iOS suspends the app or the network is unavailable. Reopening the app or **Sync now** retries. This is eventual sync, not a guarantee of instantaneous delivery while either device is offline or suspended.

Clearing watch history records a durable clear marker so an offline device does not bring old history back. The custom-server API assigns clear times when it receives the deletion; playback retained from after an offline local clear is rebased after that server time. Up to 500 movie/episode records are exchanged per sync. Saved bookmarks, downloads and app preferences are currently device-local; sync covers the watched library.

### Building with Apple Cloud

The shared defaults build without iCloud entitlements, so a free Personal Team can still sign and install the app. To include Apple Cloud, use a paid Apple development team and add to your ignored `Config/Local.xcconfig`:

```xcconfig
REZKA_ICLOUD_ENTITLEMENTS = Config/CloudSync.entitlements
REZKA_CLOUDKIT_CONDITION = REZKA_CLOUDKIT
// Optional override; defaults to iCloud.<your app bundle identifier>
REZKA_ICLOUD_CONTAINER = iCloud.$(REZKA_BUNDLE_IDENTIFIER)
```

Enable iCloud/CloudKit for your app identifier and associate that container in Apple Developer/Xcode signing. Both devices must use the same container and CloudKit environment. Debug uses Development; Release uses Production. Run `xcodegen generate` after editing `project.yml` (local signing changes alone do not require it).

The app uses the private database, custom zone `WatchLibrary`, record type `WatchProgress` with a Bytes field `payload`, and `WatchLibraryState` with a Date field `clearedAt`. Development schema is created when the first records are saved. Before distributing a Release build, deploy these record types/fields to Production in CloudKit Console. No query indexes are needed. Each movie/episode uses a separate record and conditional saves retry conflicts. Cloud records older than the retained local history are ignored rather than deleted, to avoid deleting concurrent updates. An iCloud account change turns sync off until you select Apple Cloud again.

A user of an already signed iCloud-enabled build does not need their own paid developer membership. Someone re-signing with a free Personal Team must build without the two optional iCloud settings and choose the custom-server option.

### Device acceptance

Use two physical devices signed into the same iCloud account and select Apple Cloud on both. On iPad start a previously unwatched series, pause partway through an episode, then open iPhone: its card should arrive in Continue Watching with the same season/episode and resume position. Watch another title on either device and confirm it moves to the left on the other device, including while Home stays open. Check intentional rewind, completion, offline playback/reconnect, and a clear while the other device is offline. Repeat with Reduce Motion enabled. Simulator fixture tests cover insertion/reordering and the Settings picker; they do not verify Apple’s account service or real cloud delivery.

## How it works

The app works like a web browser that understands the HDRezka pages:

1. **Finding a working website address.** HDRezka is available on many mirror domains, and some are blocked in some countries. When the app starts, it downloads the list in [`mirrors.json`](mirrors.json) from this repository and picks the first mirror that responds. You can also choose a mirror yourself in Settings.
2. **Reading pages.** The app downloads the website's HTML pages and reads the titles, posters and details from them with [SwiftSoup](https://github.com/scinfu/SwiftSoup).
3. **Getting the video.** When you press play, the app asks the website for the video links, in the same way the website's own player does. The website hides those links in an encoded form. The app decodes them and passes the video to the iPhone player.
4. **Website checks.** Sometimes the website shows a "checking your browser" page. The app then opens that page in a small browser window so you can complete it. After that it continues normally.

Your progress is saved every few seconds while you watch, and when you pause or close the player.

## Install

Download the latest `.ipa` file from [Releases](https://github.com/lastrowcritic/rezka-ios/releases/latest).

The `.ipa` is not signed, because the app is not on the App Store. Install it with a sideloading tool such as [AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io). These tools sign the app with your own Apple ID. With a free Apple ID, the app must be refreshed every 7 days.

## Build it yourself

You need a Mac with Xcode 16 or newer and an iPhone or iPad running iOS/iPadOS 17 or newer. The shared project supports native builds for both device families.

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`. Set your Apple development team ID in `DEVELOPMENT_TEAM` and a unique app identifier in `REZKA_BUNDLE_IDENTIFIER`. The test targets derive their identifiers from this value.
2. Open `RezkaPort.xcodeproj` in Xcode.
3. Connect your iPhone or iPad and press **Run**.

The Xcode project is generated from `project.yml`. If you change the project settings, run `xcodegen generate` (from [XcodeGen](https://github.com/yonaskolb/XcodeGen)) to update it.

`Config/Local.xcconfig` is ignored by Git and loaded optionally by `Config/Shared.xcconfig`. Editing local settings does not require regenerating the project. Without a local file, unsigned builds use the shared defaults.

For personal launch settings, duplicate the `RezkaPort` scheme in **Product → Scheme → Manage Schemes** and leave **Shared** unchecked. Xcode stores user schemes in the ignored `xcuserdata` directory.

To build an unsigned `.ipa` from the command line:

```sh
xcodebuild -scheme RezkaPort -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/RezkaPort.app Payload/
zip -qr Rezka.ipa Payload
```

## Tests

```sh
swift test
```

These tests check the page parsing, the video link decoding and the mirror handling against saved sample pages, so no internet connection is needed. The Xcode project also includes interface tests that run in the iPhone simulator.

## Project layout

| Folder | What is inside |
| --- | --- |
| `StreamingApp/App` | App start-up |
| `StreamingApp/Features` | Screens: home, search, title page, player, downloads, settings |
| `StreamingApp/Data/Rezka` | Website access: mirrors, page parsing, video link decoding |
| `StreamingApp/Domain` | Shared data types such as titles, episodes and history |
| `StreamingApp/Core` | App state, saved history and downloads |
| `StreamingAppTests` | Automated tests and sample pages |

## Updating the mirror list

Edit [`mirrors.json`](mirrors.json) and push to the `main` branch. Installed apps download the new list the next time they start.

## Keywords

HDRezka app, HDRezka client, HDRezka iOS, HDRezka iPhone, Rezka IPA, watch films and series on iPhone, unofficial HDRezka player. Приложение HDRezka для iPhone и iOS, клиент HDRezka (Rezka, Резка), смотреть фильмы и сериалы, продолжить просмотр с того же места.

## Known limits

The website can change its layout or its video encoding at any time, which can break parts of the app until it is updated. Separate subtitle files from the website are not shown. Only subtitles built into the video are available in the player.
