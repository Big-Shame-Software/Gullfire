# Changelog

All notable changes to Gullfire are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Gullfire uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-11-25

### Added

- Bigger maps. `Tools/build_city.sh <id>` builds one of four maps from the open data, the same way `Tools/build_chicago.sh` builds Chicago: `chicago`, `chicagowide` (85 km²), `chicagocity` (1,499 km² box, with inner suburbs) and `cookcounty` (4,777 km², the county's bounding rectangle). No map ships with the app. Each is built once on your Mac. `build_chicago.sh` still works.
- A map picker. When more than one map is installed, Gullfire opens on a list of them, each with its area, its size on disk and a diagram that shows where it sits inside the bigger ones. Flight ▸ Choose Map… (⌘O, which also works in full screen) goes back to it, and is greyed out when there is no other map to choose. The picker's button is Fly. With one map installed, Gullfire opens straight into it, as before.
- Settings ▸ Maps lists the installed maps and the sizes this Mac can build, with the command to copy for each. The app does not download or build anything.
- Before it downloads anything, `build_city.sh` checks this Mac's memory and free disk against what the map needs. If either is short it says what is needed and stops. `--force` overrides it.
- The build pins the map data to the Overture release the maps were tested on (2026-10-21.0), named in `Resources/Recipes/recipes.json`. `--overture-release latest|<id>` chooses another. If the pinned release is no longer published, the build stops before it downloads anything. The release is recorded in the package's manifest.
- The log says what asked Gullfire to quit: the sender of a quit request from another program, or "menu or key".
- Street graphs, loops and routes for the bigger maps, made by the same build. Endless flight and picking a street work on all four.

### Changed

- Large or dense maps (over 200 km², or over 1.5 million line segments) draw only what is within 5 km of the aircraft, with a fade at the edge. A skyline farther away is not drawn. This keeps the frame rate up on ChicagoWide, ChicagoCity and Cook County. Chicago is unchanged.
- The street graph loads when the map opens, off the main thread, and is read from disk. It takes about 21 MB of memory on ChicagoCity and 53 MB on Cook County, down from about 140 and 240.
- The memory limits in the project notes are now two tiers by size: 650 MB windowed for maps of 1 million segments or fewer, 850 MB for bigger ones. Endless flight covers new ground, and the graphics driver's working memory grows with it, then gives pages back.

### Fixed

- Endless flight (U) and mouse flight (J) no longer run together. Turning endless on gives the mouse back, and taking the mouse leaves endless flight.
- Endless flight no longer stalls on its first loop. On about one Cook County start in 24, the stretch after the first loop could not start a loop, so every retry failed and the aircraft kept flying the first loop. A loop now chains only to a stretch the build marked as able to start one.

### Known issues

- Only one Mac, with 48 GB and 14 cores, has built these maps and flown them. The memory and time figures in the README come from it, and they are estimates for other Macs. Windowed memory peaked at 754 MB on ChicagoCity and 525 MB on Cook County over an hour of endless flight on that Mac.
- Once in a run, flight can stop for 0.6 to 1.2 seconds, at the start of endless flight or at one other moment. 1.2.1 does this too. We have not found the cause.
- Building ChicagoCity or Cook County takes tens of minutes and several gigabytes of memory. Most of it is the step that marks which streets can start a loop.
- On the bigger maps, Scenic and River roll fast for about a second where they turn round, at the end of the river or the edge of the map. Chicago's River does the same. There were no collision nudges in our tests, but those turns are not smooth.
- On Cook County, a street picked 50 km away is not reached in 15 minutes of flight, because the box is 4,777 km². In our test, picks on eight starts flew with no collision nudges and at least 30 m of clearance.

## [1.2.1] - 2026-11-22

### Changed

- On the Brand palette the key list's panel has the same tinted fill as the route list, instead of a black panel. The other palettes are unchanged.

### Fixed

- Pressing U (endless flight), picking a street with I, or taking over from low among tall buildings no longer brushes a roof. The aircraft now climbs above every roof within reach of a turn before it starts to join. In our test, entry climbed about 55 m higher and takes a little longer. In a test of 1,176 start positions around the Loop, flown for 30 seconds each, no start that a climb could clear brushed a roof. Before this fix, 18 did.
- An entry that arrives high above its join point now aims at a point it can glide down to. If it flies over the aim too high, it moves on to a farther one instead of circling. In our test of 1,176 start positions around the Loop, flown for two minutes each, roof brushes among the starts that a climb could clear fell from 62 in 1.2.0 to 1.
- Scenic and River no longer jolt where each lap closes. The River lap used to drop 230 m in 60 m; it now descends gradually. Scenic's first stretch no longer drops 170 m over 390 m. Scenic also climbs about 230 m over the last 1.7 km of the river stretch, before the tall towers. Both routes fly the same ground track as before. Routes you built with 1.2.0 keep their old files until you build the city again with `Tools/build_chicago.sh`.
- The key list (K) scrolls in a short window instead of running off the window.

### Known issues

- In our test of 1,176 start positions around the Loop, flown for two minutes each, one entry circled a block and brushed a roof after about 75 seconds (62 did in 1.2.0). Seven entries took longer than two minutes to join; all joined within 2 minutes 32 seconds. Entering from too high can still make the aircraft circle before it joins.
- Downtown, where the towers rule out most joins, few or no streets can be picked, so pick mode can show nothing there.
- Picking a street, and endless flight with it, is an alpha feature. Expect streets that cannot be picked and the odd rough join.
- Flight is not smooth everywhere yet. Street runs and endless flight still have small vertical bumps at the tops of climbs and dips. The River route still has a few small bumps. They are smaller, and we have not found what causes them.

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
