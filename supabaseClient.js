/**
 * Supabase Client Module for Task Manager Prototype
 * 
 * Configured strictly with public/publishable anon keys.
 * NEVER store or use service_role keys or secrets in frontend code.
 */

import { createClient } from '@supabase/supabase-js';

// Retrieve configuration from environment or window.__ENV__
export const supabaseUrl =
  (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_SUPABASE_URL) ||
  (typeof window !== 'undefined' && window.__ENV__ && window.__ENV__.VITE_SUPABASE_URL) ||
  '';

export const supabaseKey =
  (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY) ||
  (typeof window !== 'undefined' && window.__ENV__ && window.__ENV__.VITE_SUPABASE_PUBLISHABLE_KEY) ||
  '';

// Convenience alias — this is the publishable/anon key, safe for the browser.
// Never the service_role key; that only ever lives server-side (see the
// create-employee Edge Function).
export const supabaseAnonKey = supabaseKey;

export let supabase = null;

if (supabaseUrl && supabaseKey) {
  supabase = createClient(supabaseUrl, supabaseKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true
    }
  });
}

/**
 * A separate, in-memory-only client used solely to confirm a signed-in user's
 * CURRENT password before they change it (Profile → Change password).
 * It never persists or refreshes a session and uses its own storage key, so
 * the check cannot replace or fire events on the app's real session.
 */
export function createPasswordCheckClient() {
  if (!supabaseUrl || !supabaseKey) return null;
  return createClient(supabaseUrl, supabaseKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
      storageKey: 'sb-password-check'
    }
  });
}

/**
 * Helper to initialize or reconfigure Supabase client at runtime
 */
export function initSupabase(url, key) {
  if (!url || !key) {
    console.warn('Supabase URL or Publishable Key is missing.');
    return null;
  }
  supabase = createClient(url, key, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true
    }
  });
  return supabase;
}

export default supabase;
