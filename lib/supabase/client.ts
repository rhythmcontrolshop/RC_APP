import { createBrowserClient } from "@supabase/ssr";

// Public reads only — uses Publishable Key (replaces legacy anon key)
export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!
  );
}
