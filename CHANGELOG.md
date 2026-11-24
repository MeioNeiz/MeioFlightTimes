# Meio Flight Times

## 1.0.1

- Logging out mid-flight no longer saves a flight time with the time offline in it: only
  legs flown before you logged out are learned, and the countdown carries on from where it
  stopped. A /reload mid-flight still learns the whole flight
- A saved in-flight record is cleared once you are seen on the ground

## 1.0.0

- First release: flight times on the flight map's tooltip and a timer bar while flying,
  learned leg by leg so a route you haven't flown (or one a new flight point changed) is
  still timed. Fills FlareUI's Flight Timer bar when that is on
