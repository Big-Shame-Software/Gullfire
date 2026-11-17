# Privacy

Gullfire 1.0.0. Last updated 2026-11-17.

Gullfire does not collect, send or share any information about you. It has no account, no analytics, no crash reports, no advertising and no third-party services. It asks macOS for no special permissions of its own.

## While the app runs

- **It never uses the network.** The app makes no connections of its own.
- **It reads** the city package you built, and any music folder, cathedral track or MIDI file you choose in Settings, and a glider model file if you install one. All of it is read on your Mac and none of it is sent anywhere.
- **It writes** only its own settings, in the app's preferences: your colour scheme, key-list and music choices, and the paths of the music folder and files you picked.
- **It prints diagnostic lines to the console**: start-up steps, frame timing, and the names of music files it skipped. It does not save them to a file or send them anywhere.
- **Settings has a link** to a web page (IMSLP, for a Debussy score). It opens in your web browser. That connection is your browser's, not Gullfire's.

## When you build the map

`Tools/build_chicago.sh` is a script you run yourself, once. It uses the network to download open map data (Overture Maps and OpenStreetMap), and uv uses it to fetch the Python packages the script needs. The map servers and package servers see your network address, as any download does. The requests ask for the area of Chicago, and nothing about you. The script writes the city package into a folder on your Mac, by default `~/Library/Application Support/Gullfire/Cities/Chicago`.

## What this means

There is nothing of yours for Gullfire to keep, sell or lose. To remove everything it leaves on your Mac, delete the app, the city package folder above, and its preferences (`defaults delete` for the app's bundle identifier, `io.github.big-shame-software.Gullfire`).

If this changes, the change is listed in [CHANGELOG.md](CHANGELOG.md) before it ships.

Questions: open an issue at <https://github.com/Big-Shame-Software/Gullfire/issues>.
