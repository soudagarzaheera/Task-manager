/* Saving generated files (Excel exports, payslip PDFs) in the mobile app.
 *
 * Browser and Electron desktop keep their existing download behaviour — the
 * callers only route here when isNativeApp() is true, because Android's
 * WebView silently ignores <a download> / blob: links and jsPDF's doc.save().
 *
 * On Android/iOS, saveNativeFile():
 *   1. writes the file to the app cache (always shareable through the app's
 *      FileProvider),
 *   2. best-effort also keeps a copy in the public Documents/Practice Manager
 *      folder so it shows up in the phone's Files app (Android 11+ needs no
 *      permission for this; Android 9 and older asks for storage permission),
 *   3. opens the system share sheet so the employee can open the file in
 *      Excel / a PDF viewer, save it to Drive / Downloads, or send it on.
 * File names and bytes are exactly what the desktop download produces.
 */
import { Capacitor } from '@capacitor/core';
import { Filesystem, Directory } from '@capacitor/filesystem';
import { Share } from '@capacitor/share';

const DOCS_FOLDER = 'Practice Manager';

export function isNativeApp() {
  try { return Capacitor.isNativePlatform(); } catch (e) { return false; }
}

const say = msg => { try { (window.toast || alert)(msg); } catch (e) { /* no UI available */ } };

/* Uint8Array | ArrayBuffer | Blob → base64 (Filesystem's binary format). */
async function toBase64(data) {
  let bytes;
  if (data instanceof Blob) bytes = new Uint8Array(await data.arrayBuffer());
  else if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
  else bytes = data;
  let bin = '';
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK)
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  return btoa(bin);
}

/* Keep the app's file name, only stripping characters no filesystem accepts. */
const safeName = name => String(name || 'download').replace(/[\\/:*?"<>|\u0000-\u001f]+/g, '_');

async function storagePermissionOk() {
  try {
    let st = await Filesystem.checkPermissions();
    if (st.publicStorage === 'granted') return true;
    st = await Filesystem.requestPermissions();
    return st.publicStorage === 'granted';
  } catch (e) {
    return false;
  }
}

async function saveToDocuments(name, base64) {
  if (!(await storagePermissionOk())) return null;
  try {
    const r = await Filesystem.writeFile({
      path: DOCS_FOLDER + '/' + name, data: base64, directory: Directory.Documents, recursive: true
    });
    return r.uri;
  } catch (e) {
    // e.g. Android 10 scoped storage, or an older copy from a previous install
    // that this install doesn't own. The share sheet still lets them save it.
    console.warn('[fileSave] Documents copy not saved:', e);
    return null;
  }
}

function friendlyError(e) {
  const msg = String((e && e.message) || e || '');
  if (/space|ENOSPC|full/i.test(msg)) return 'there is not enough free storage on this phone';
  if (/permission|denied|EACCES/i.test(msg)) return 'storage access was denied — allow it in Android Settings → Apps → Practice Manager';
  return msg || 'unknown error';
}

/**
 * Save a generated file on the phone and offer it through the share sheet.
 * Never throws — failures are reported to the user with a toast.
 * @returns {Promise<boolean>} true if the file was written.
 */
export async function saveNativeFile(filename, data, mimeType) {
  const name = safeName(filename);
  let base64, cacheUri;
  try {
    base64 = await toBase64(data);
    cacheUri = (await Filesystem.writeFile({
      path: 'exports/' + name, data: base64, directory: Directory.Cache, recursive: true
    })).uri;
  } catch (e) {
    console.error('[fileSave] write failed', e);
    say('Could not save ' + name + ' — ' + friendlyError(e));
    return false;
  }

  const docUri = await saveToDocuments(name, base64);
  say(docUri ? 'Saved to Documents/' + DOCS_FOLDER + '/' + name : 'File ready — choose where to open or save it');

  try {
    await Share.share({
      title: name,
      files: [cacheUri],
      dialogTitle: 'Open or save ' + name
    });
  } catch (e) {
    const msg = String((e && e.message) || e || '');
    if (/cancel/i.test(msg)) return true;                // user closed the share sheet
    console.error('[fileSave] share failed', e, mimeType);
    say(docUri
      ? 'Saved to Documents/' + DOCS_FOLDER + ' — open it from your Files app'
      : 'Could not open the share options for ' + name + ' — ' + friendlyError(e));
  }
  return true;
}
