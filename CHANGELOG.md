# Meio Flight Times

## 1.5.0

- Boat and zeppelin timers: by a pier, a bar per route counts down to its next departure
  (or says when it's due); the minimap's addon button lists every dock's next departure,
  and broker bars (Titan, ChocolateBar) get it too
- Each route is timed the first time you ride it, and schedules saved by Nauticus carry over
- `/meioflighttimes boats`, `boats on|off`, `boats reset`

## 1.4.0

- Tell your group where you're flying and when you land: `/meioflighttimes announce on`
  posts "Stormwind -> Darkshire, lands in ~1:50" to party, raid or instance chat at every
  take-off (nothing when solo; off until you turn it on)
- `/meioflighttimes tell` posts the time left on your flight now

## 1.3.0

- The clock time you land at, on the flight map's tooltip and the timer bar ("lands
  14:32", or 2:32 PM as your minimap clock shows it)
- A chime 30 seconds before landing, with the taskbar flashing if the game is in the
  background. `/meioflighttimes chime off`, `on`, or a number of seconds

## 1.2.0

- The flight point a detouring route should learn is marked on the flight map while you
  hover the destination, with its name

## 1.1.1

- Meio Next Stop shows the time to the next stop from these flight times

## 1.1.0

- Built-in times for every route, worked out from the game's own flight paths, so a route
  shows a time before you have flown anything. Your own flights still take over leg by leg
- Flying faster (Frequent Flier) scales the built-in times to your speed after a flight
- On a route that detours, the tooltip names the flight point to learn and how much faster
  the flight would be

## 1.0.1

- Logging out mid-flight no longer saves a flight time with the time offline in it: only
  legs flown before you logged out are learned, and the countdown carries on from where it
  stopped. A /reload mid-flight still learns the whole flight
- A saved in-flight record is cleared once you are seen on the ground

## 1.0.0

- First release: flight times on the flight map's tooltip and a timer bar while flying,
  learned leg by leg so a route you haven't flown (or one a new flight point changed) is
  still timed. Fills FlareUI's Flight Timer bar when that is on
