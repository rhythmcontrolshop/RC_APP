import { createClient } from "@supabase/supabase-js";

// Admin client — ONLY for webhooks, crons, and admin server writes.
// Uses Secret Key (replaces legacy service_role JWT).
// NEVER import this in public-facing routes or client components.
export function createAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SECRET_KEY;

  if (!url || !key) {
    throw new Error("Missing SUPABASE_SECRET_KEY — admin client not configured");
  }

  return createClient(url, key, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}
