# Meio Flight Times

How long a flight takes, on the flight map and while you fly, even for routes you haven't
flown yet.

![The flight map in Stormwind with the mouse on Darkshire: before, only its name and cost;
with Meio Flight Times, "Flight time: 1:50" under them](docs/before-after.png)

## What it does

Each flight is timed leg by leg, between the flight points you pass on the way, so a route
you haven't flown is still worked out from the legs you have.

- Flight time on the flight map's tooltip, marked `~` (estimate) for a route you haven't
  flown
- A timer bar while flying, counting down to landing (move it with Edit Mode's Timer Bars)
- Stays right when a newly learned flight point changes a route
- With FlareUI's Flight Timer bar on, fills that bar instead

No settings. `/meioflighttimes stats` shows what has been learned, `/meioflighttimes forget`
starts over (`/flighttimes` works too).

## Install

Use your addon manager (CurseForge, Wago), or unzip a GitHub release into
`World of Warcraft\_forever_\Interface\AddOns` and restart WoW fully.

## Feedback

Bugs and ideas: [GitHub issues](https://github.com/MeioNeiz/MeioFlightTimes/issues)

## More Meio addons

[Meio TrainerCompare](https://www.curseforge.com/wow/addons/trainercompare) | [Meio Next Stop](https://www.curseforge.com/wow/addons/leavebutton) | [Meio AutoRank](https://www.curseforge.com/wow/addons/meio-autorank) | [Meio MeterHover](https://www.curseforge.com/wow/addons/meterhover) | [Meio Map](https://addons.wago.io/addons/meiomap) | [Meio Alts](https://addons.wago.io/addons/meioalts) | [Meio DPS](https://addons.wago.io/addons/meiodps) | [Meio Plates](https://addons.wago.io/addons/meioplates) | [Meio Hub](https://addons.wago.io/addons/meiohub) | [Meio Pets](https://addons.wago.io/addons/meiopets) | [Meio Stats](https://addons.wago.io/addons/meiostats) | [Meio Bags](https://addons.wago.io/addons/meiobags) | [Meio Fixes](https://addons.wago.io/addons/meiofixes)

## Licence

[MIT](LICENSE)
