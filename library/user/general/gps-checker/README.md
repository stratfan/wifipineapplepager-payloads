# GPS Checker

**GPS Checker** tells you exactly where a stuck GPS is stuck: no data from gpsd, no satellites visible, satellites visible but not decoding, or decoding but no fix yet - and shows coordinates once a fix lands.

- **Author:** mik
- **Version:** 2.0

## Why?

"GPS isn't working" can mean several very different things: gpsd isn't receiving anything, the antenna can't see any satellites, satellites are detected but their nav data can't be decoded (the classic obstructed-sky signature - enough signal to measure SNR but not enough clean line-of-sight to decode ephemeris), or everything is decoding fine and it just needs more time for a fix. Each of these has a different fix, and the plain "is data flowing?" check couldn't tell them apart.

## Usage

Run the payload on the Pineapple Pager. It samples raw NMEA for a few seconds and reports one of:

- **No data at all** - gpsd is restarted once and rechecked; if it's still silent, check the GPS device/baud rate in Settings > GPS, the antenna connection, and the hardware itself.
- **0 satellites visible** - check antenna connection/orientation, or move somewhere with sky visibility.
- **Satellites detected but not decoding** - reports satellite count and best SNR. This means the receiver sees signal but can't decode navigation data, almost always caused by an obstructed view of sky (buildings, trees, overhangs, indoors, in a pocket). Move to open sky and check again.
- **Decoding, no fix yet** - reports how many satellites are decoding out of how many are visible. This is real progress; give it another minute or two with a clear view of sky.
- **Fix acquired** - shows latitude, longitude, altitude, and estimated accuracy.

After the first check, press **[▲]** to sample again (handy after repositioning the device) or **[▼]** to exit.
