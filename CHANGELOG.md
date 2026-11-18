# Changelog

All notable changes to Gullfire are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Gullfire uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-11-18

### Added

- Flight height: T and V raise and lower the autopilot's flight height in 10 m steps, from 60 m below to 120 m above the route's own height. The HUD shows it as HEIGHT. It resets to 0 when you change route with C.
- Mouse flight: J turns it on and off. Moving the mouse right banks right, and moving it forward puts the nose down. The scroll wheel changes throttle. Turning it on switches to manual flight, and Esc gives the pointer back. Settings (View tab) has Mouse flight sensitivity and Invert pitch.

### Known issues

- Mouse flight does not work with a trackpad yet. It works with a mouse.

## [1.0.1] - 2026-11-18

### Changed

- The route list appears at the bottom of the window when the app starts, for four seconds, with the line PRESS C FOR THE NEXT ROUTE. The line is also under the list each time you press C.
- The key list's C row reads NEXT ROUTE, not ROUTE.

### Fixed

- A second start request no longer restarts the MIDI piece while it is already playing.

## [1.0.0] - 2026-11-17

The first release. Gullfire flies a simulated aircraft over a real city, drawn as green hidden-line wireframes. Chicago is the one city this release prepares. You build its map once from public data; the app itself never uses the network.

### Added

- Chicago, flown by hand or on the cruise autopilot along the Scenic and River routes, with street routes as well.
- Manual flight with the keys listed in the README, and a readout (H) with the flight information, then the performance lines.
- A route list (C) at the bottom of the window, with the route you are flying marked.
- A key list (K), bottom right at the start, kept between launches.
- Three colour schemes, Default, Brand and Lime (B).
- Music: an endless or looping Satie piece, a folder of your own music in a random order with a crossfade, a cathedral track that loops with a fade, and a MIDI file you choose. Settings (Gullfire > Settings) holds the music choices and the view options.
- An optional glider. Install a model file as described in Adding a glider in the README, and G shows or hides it. The release contains no model; an example model is included.
- An About window with the version, and an empty state that gives the one command to prepare Chicago.

### Known issues

- On the River route the frame rate can drop to about 33 fps for a few seconds during a long full-screen flight. The cause is not known yet. GPU time stays normal while it happens.
- The game controller is supported, but it has not been tested with a real controller.
- The Settings window and the route list have not yet been checked with VoiceOver.
- Chicago is the only city the build script prepares.
