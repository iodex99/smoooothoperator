// Fill these in from Supabase → Project Settings → API.
//
// The publishable (anon) key is a PUBLIC key. It identifies the project and
// nothing else; it ships inside the iOS binary too, where anyone can read it.
// Row-level security is what protects data, not the secrecy of this string.
//
// The SERVICE ROLE / SECRET key must NEVER appear in this file. It bypasses
// every row-level security policy in the database. If it is ever pasted into
// anything that reaches a browser, rotate it immediately.
window.SUPABASE_URL = "https://YOUR-PROJECT-REF.supabase.co";
window.SUPABASE_ANON_KEY = "YOUR-PUBLISHABLE-KEY";
