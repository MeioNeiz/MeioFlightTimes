# Meio Flight Times

How long a flight takes, on the flight map and while you fly, even for routes you haven't
flown yet.

For WoW Forever.

![The flight map in Stormwind with the mouse on Sentinel Hill, never flown to: before, only its name
and cost; with Meio Flight Times, "Flight time: ~1:09, lands 12:04 AM (estimate)" under them, and
the timer bar on the flight there](docs/before-after.png)

## What it does

Every route has a time from your first flight: the times come from the game's own flight
paths, and each flight you take is timed leg by leg so they get closer to your own.

- Flight time on the flight map's tooltip, marked `~` (estimate) for a route you haven't
  flown
- Names the flight point worth learning when a route detours: "Learn Talrendis Point
  (Azshara): ~6:10, 7:10 faster", and marks it on the flight map
- The clock time you land at, on the tooltip and the timer bar
- A timer bar while flying, counting down to landing (move it with Edit Mode's Timer Bars)
- A chime just before you land, flashing the taskbar if the game is in the background
- Stays right when a newly learned flight point changes a route
- With FlareUI's Flight Timer bar on, fills that bar instead
- Tells your group where you're flying and when you land, if you want (off until you turn
  it on)

`/meioflighttimes chime off` turns the chime off (`on`, or a number of seconds before
landing, to change it). `/meioflighttimes announce on` posts "Stormwind -> Darkshire,
lands in ~1:50" to party, raid or instance chat at every take-off in a group;
`/meioflighttimes tell` posts the time left mid-flight. `/meioflighttimes stats` shows
what has been learned, `/meioflighttimes forget confirm` starts over (`/flighttimes` works too).

## Install

Use your addon manager (CurseForge, Wago), or unzip a GitHub release into
`World of Warcraft\_forever_\Interface\AddOns` and restart WoW fully.

## Feedback

Bugs and ideas: [GitHub issues](https://github.com/MeioNeiz/MeioFlightTimes/issues)

## More Meio addons

[Meio Trainer Compare](https://www.curseforge.com/wow/addons/trainercompare) | [Meio Next Stop](https://www.curseforge.com/wow/addons/leavebutton) | [Meio Auto Rank](https://www.curseforge.com/wow/addons/meio-autorank) | [Meio Meter Hover](https://www.curseforge.com/wow/addons/meterhover) | [Meio Map](https://addons.wago.io/addons/meiomap) | [Meio Alts](https://addons.wago.io/addons/meioalts) | [Meio DPS](https://addons.wago.io/addons/meiodps) | [Meio Plates](https://addons.wago.io/addons/meioplates) | [Meio Hub](https://addons.wago.io/addons/meiohub) | [Meio Pets](https://addons.wago.io/addons/meiopets) | [Meio Stats](https://addons.wago.io/addons/meiostats) | [Meio Bags](https://addons.wago.io/addons/meiobags) | [Meio Fixes](https://addons.wago.io/addons/meiofixes) | [Meio Tooltip Fold](https://addons.wago.io/addons/meiotooltipfold) | [Meio Auto Run Turn](https://addons.wago.io/addons/meioautorunturn) | [Meio Mail](https://addons.wago.io/addons/meiomail) | [Meio QoL](https://addons.wago.io/addons/meioqol) | [Meio TSM Browse](https://addons.wago.io/addons/tsmbrowse) | [Meio Shards](https://addons.wago.io/addons/meioshards) | [Meio Spike Check](https://addons.wago.io/addons/meiospikecheck) | [Meio BiS Extras](https://addons.wago.io/addons/meiobisextras) | [Meio Buff Thanks](https://addons.wago.io/addons/meiobuffthanks) | [Meio Flare Fixes](https://addons.wago.io/addons/meioflarefixes) | [Meio Flare Questie](https://addons.wago.io/addons/meioflarequestie)

## Licence

[MIT](LICENSE)
