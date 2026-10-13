# Better Music

**The iOS 26 look for the Apple Music app on iOS 15.** A tweak for jailbroken iPhones (Dopamine, rootless), made by
[rocketkid300](https://github.com/Rocketkid300).

## Install (Sileo or Zebra)

Add this repo, then search for **Better Music**:

```
https://rocketkid300.github.io/better-music-repo/
```

One-tap links (open them on the phone): [Sileo](sileo://source/https://rocketkid300.github.io/better-music-repo/) ·
[Zebra](zbra://sources/add/https://rocketkid300.github.io/better-music-repo/)

Or download the `.deb` from the [Releases](../../releases) page and open it with Sileo, or install it over SSH with
`dpkg -i`. A respring finishes the install.

## What it does

**Apple Music app**
- Album and playlist pages are tinted with the colour of the cover, all the way down the page
- Round Shuffle and + buttons with a wide white Play pill, a glass back button and a glass top-right capsule
- Info line like iOS 26 ("Hip-Hop/Rap · 2008 · Lossless") with cover-coloured accents
- Word-by-word lyric highlighting that follows the song position
- Floating glass mini player and a clean pull-down animation for the full-screen player
- "Listen Now" and "Browse" become **Home** and **New**; rounder covers and cards; profile circle colours
- An app-size slider (shrinks the Music app only) with a default and a reset button

**Lock screen**
- Tap the album cover in the lock screen player to expand it: full-size cover, colour backdrop, a compact clock row and
  glass controls. Tap the cover again to close it.
- The player sits lower so tall lock screen clocks (for example Retica) are not hidden behind it
- Choose the clock transition (fade, or shrink and slide), and the clock row's size and font

Everything is in **Settings → Better Music**, including a **Safe mode** switch. Safe mode also turns itself on if Music
closes three times in a row right after opening.

## Requirements and compatibility

- iOS **15.x**, jailbroken with **Dopamine (rootless)**. The package refuses to install on other iOS versions.
- Built for arm64 and arm64e.
- **Tested on one device only:** an iPhone 7 Plus on iOS 15.8.3. Other devices should work, but I can't promise it.
  Bug reports are welcome.

## Known conflicts and limits

- Tweaks that also restyle the Music app or the lock screen player can fight with this one: **ArtFull, Reo, Arkita**.
  Turn them off if something looks wrong.
- Not done yet: the star (favourite) button, the "Paused" pill and the repeat badge on Now Playing. The volume slider is
  left as Apple made it.
- Albums with motion (video) artwork keep Apple's own header.
- Apple does not send per-word lyric timing on iOS 15, so the word-by-word fill spreads each line's time evenly across
  its words.

## Privacy

The expanded lock screen cover asks Apple's public catalog (`itunes.apple.com`) for a full-size copy of the album
cover, using the album ID the system already provides. Nothing else leaves your device. There is no analytics.

## Build

You need [Theos](https://theos.dev) with an iOS 15 SDK, and `dpkg-deb`.

```bash
THEOS=~/theos ./build.sh
```

The package lands in `dist/`. On Linux, A12+ (arm64e) builds need the "new ABI" conversion; set `ALLEMANDE` to the
converter binary, as described at the top of `build.sh`. On macOS the Xcode toolchain already produces the right ABI.

Layout: `music/` runs inside the Music app, `lock/` runs inside SpringBoard, `prefs/` and `layout/` are the Settings
page, `common/` holds the shared settings reader.

## Debugging

Settings → Better Music → Troubleshooting → **Debug logging** enables a few tools used while developing (layout
dumps and logs written to `/var/jb/var/mobile/Library`). They are off by default and write nothing when off.

## License and credits

MIT, see [LICENSE](LICENSE). Not affiliated with Apple. Apple Music is a trademark of Apple Inc.
