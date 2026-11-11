/* Device location for attendance punches.
 *
 * Native app (Capacitor Android/iOS): @capacitor/geolocation — checks the
 * runtime permission, asks for it when needed, then reads a fresh GPS fix.
 * Browser / Electron desktop: the standard navigator.geolocation API, as before.
 *
 * getDevicePosition() resolves to a Position-shaped object
 *   { coords:{ latitude, longitude, accuracy }, timestamp }
 * so callers treat both sources the same, and rejects with a LocationError
 * whose `kind` is one of: permission | services_off | timeout | unavailable |
 * unsupported. locationErrorMessage(err) turns that into user-facing text.
 */
import { Capacitor } from '@capacitor/core';
import { Geolocation } from '@capacitor/geolocation';

/* Same options the punch flow has always used: best available source, 15s for
   a first indoor fix, and never a cached reading. */
const POSITION_OPTIONS = { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 };

export class LocationError extends Error {
  constructor(kind, message, cause) {
    super(message || kind);
    this.name = 'LocationError';
    this.kind = kind;
    this.cause = cause;
  }
}

export function isNativeApp() {
  try { return Capacitor.isNativePlatform(); } catch (e) { return false; }
}

const isGranted = st => !!st && (st.location === 'granted' || st.coarseLocation === 'granted');

/* Map @capacitor/geolocation native errors (OS-PLUG-GLOC-xxxx) to a kind. */
function fromNativeError(e) {
  if (e instanceof LocationError) return e;
  const code = String((e && e.code) || '');
  const msg = String((e && e.message) || e || '');
  const num = (code.match(/GLOC-(\d+)/) || msg.match(/GLOC-(\d+)/) || [])[1];
  switch (num) {
    case '0003': return new LocationError('permission', msg, e);
    case '0007': case '0009': case '0016': case '0017':
      return new LocationError('services_off', msg, e);
    case '0010': return new LocationError('timeout', msg, e);
    case '0018': return new LocationError('unavailable', 'Location permissions are missing from the app configuration.', e);
  }
  if (/location services|not enabled|turned off|disabled/i.test(msg)) return new LocationError('services_off', msg, e);
  if (/permission|denied/i.test(msg)) return new LocationError('permission', msg, e);
  if (/time ?out|in time/i.test(msg)) return new LocationError('timeout', msg, e);
  return new LocationError('unavailable', msg, e);
}

async function getNativePosition() {
  try {
    // 1. Check the current permission state.
    let status = await Geolocation.checkPermissions();
    // 2. Not granted yet → show the Android permission dialog. If the user
    //    previously chose "Don't allow" permanently, Android resolves this
    //    immediately as denied without showing anything.
    if (!isGranted(status)) {
      status = await Geolocation.requestPermissions({ permissions: ['location', 'coarseLocation'] });
    }
    // 3. Still not granted → the user has to enable it in app settings.
    if (!isGranted(status)) throw new LocationError('permission', 'Location permission denied');
    // 4. Fresh, high-accuracy fix. Falls back to Android's LocationManager on
    //    devices without (working) Google Play Services.
    return await Geolocation.getCurrentPosition({ ...POSITION_OPTIONS, enableLocationFallback: true });
  } catch (e) {
    throw fromNativeError(e);
  }
}

function getBrowserPosition() {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation)
      return reject(new LocationError('unsupported', 'This browser does not support location'));
    navigator.geolocation.getCurrentPosition(resolve, err => {
      const kind = { 1: 'permission', 2: 'unavailable', 3: 'timeout' }[err && err.code] || 'unavailable';
      reject(new LocationError(kind, err && err.message, err));
    }, POSITION_OPTIONS);
  });
}

export function getDevicePosition() {
  return isNativeApp() ? getNativePosition() : getBrowserPosition();
}

/* User-facing reason (callers append "Punch was not recorded."). */
export function locationErrorMessage(err) {
  const native = isNativeApp();
  switch (err && err.kind) {
    case 'permission':
      return native
        ? 'Location permission is denied. To punch, open Android Settings → Apps → Practice Manager → ' +
          'Permissions → Location, choose "Allow only while using the app" and turn on "Use precise location", then try again'
        : 'Location permission denied — allow location access and try again';
    case 'services_off':
      return 'Location (GPS) is turned off on this device — turn on Location in your phone\'s quick settings ' +
        'or Settings → Location, then try again';
    case 'timeout':
      return 'Location request timed out — try again, ideally outdoors or near a window';
    case 'unsupported':
      return 'This browser does not support location';
    case 'unavailable':
      return 'Location unavailable — check GPS/network and try again';
    default:
      return 'Location error — ' + ((err && err.message) || 'unknown error');
  }
}
