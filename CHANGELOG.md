# Changelog

All notable changes to Gullfire are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Gullfire uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-11-19

### Added

- Street graph: a city package can carry an optional `streets.json`, listing the open straight street stretches already checked clear at 15 m, with their names and class. `Tools/make_street_graph.py` writes it. A package without it flies as before.
- Endless flight: U flies loops made from the city's streets, one after another, with no input. Without a street graph, U says so and does nothing else. Press U again, or C, to stop.
- Pick a street (alpha): I, then click a street in the flight view to fly it as endless flight. While pick mode is on, the streets you can follow are drawn as yellow lines: thin for each street nearby, thick for the one under the pointer, thickest for the one picked. The mode stays on after a click, so you can pick another. Only streets that can start a loop are offered; the build marks them. If a clicked street still cannot start a loop, the nearest one that can is flown. I or Esc leaves pick mode.
- Height keys T and V work when flying by hand. They set a target altitude 10 m above or below the aircraft, or the last target, and the HUD shows it as HEIGHT TARGET.

### Changed

- Mouse flight works with a trackpad as well as a mouse. We tested both by hand; the cause of the earlier failure was never found.
- J turns mouse flight on and switches to manual flight by itself. Space is no longer needed first.
- Lowering in cruise is limited by what the aircraft can recover before the roofs and towers ahead. A street run never goes below its own height. Over open ground the full setting is allowed.
- Smoother flight on street runs and endless flight. The autopilot now follows the slope of the route ahead, and the street routes are raised and rounded in memory when they load (the route files are not changed). Scenic and River are flown as authored.
- Entering endless flight or a picked street is always a climb over the roofs first, then a join. For the first minute after it, the aircraft flies up to 60 m higher than the route and settles down.

### Known issues

- Pressing U while low, at about 80 m over the tallest towers, can brush a roof once, with about 5 m clearance, before the aircraft climbs away.
- Downtown, where the towers rule out most joins, few or no streets can be picked, so pick mode can show nothing there.
- Picking a street, and endless flight with it, is an alpha feature. Expect streets that cannot be picked and the odd rough join.
- Flight is not smooth everywhere yet. Street runs and endless flight still have small vertical bumps at the tops of climbs and dips. The Scenic route has jolts where the lap closes. The River route has bumps we have not explained.

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
