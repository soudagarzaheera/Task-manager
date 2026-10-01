-- ==============================================================================
-- GEOFENCE FIX: record the device's reported location accuracy
-- ==============================================================================
-- Root cause of "outside the fence" while physically inside the office (see
-- index.html's doPunch()/recordPunch()/geofenceCheck() for the full fix):
--   1. The app never read position.coords.accuracy at all. A browser's
--      Geolocation API can legitimately report 50-300m+ of error indoors or
--      on a device with no GPS chip (enableHighAccuracy only requests the
--      best *available* source, not a GPS-grade fix) — and a strict
--      distance<=radius comparison with zero tolerance for that error turns
--      a correct "inside" position into a false "outside".
--   2. Punches were matched to the single geometrically NEAREST configured
--      site, then checked only against that one site's radius — instead of
--      "inside ANY authorized site's own radius". A punch genuinely inside
--      Head Office's fence could be rejected because some other, closer but
--      smaller-radius client site didn't happen to reach the user.
-- Neither issue was in the office coordinates themselves, the Haversine
-- formula (verified correct, unchanged), or the lat/lng ordering (verified
-- consistent everywhere, unchanged) — so no coordinates or radius were
-- touched by this fix.
--
-- This migration adds the one column genuinely needed to support the
-- accuracy-aware fix and to let a reviewer see, after the fact, why a punch
-- was or wasn't flagged: attendance_punches already stored distance_meters
-- and is_within_geofence/needs_review; it had nowhere to keep the accuracy
-- value the decision was actually made with.
-- ==============================================================================

ALTER TABLE attendance_punches
  ADD COLUMN IF NOT EXISTS accuracy_meters NUMERIC(8,2);

COMMENT ON COLUMN attendance_punches.accuracy_meters IS
  'position.coords.accuracy from the Geolocation API at the moment of this punch, in metres. NULL when no location fix was obtained at all (permission denied / timeout / unavailable).';
