import { NextRequest, NextResponse } from "next/server";
import { createServerClient } from "@supabase/ssr";

const LOCALES = ["es", "ca", "en"] as const;
const DEFAULT_LOCALE = "es";

const ADMIN_PATHS = ["/admin"];

function getLocale(request: NextRequest): string {
  const pathname = request.nextUrl.pathname;
  const pathnameLocale = LOCALES.find(
    (locale) =>
      pathname.startsWith(`/${locale}/`) || pathname === `/${locale}`
  );
  if (pathnameLocale) return pathnameLocale;

  const acceptLanguage = request.headers.get("accept-language") ?? "";
  const preferred = acceptLanguage
    .split(",")
    .map((l) => l.split(";")[0].trim().slice(0, 2))
    .find((l) => LOCALES.includes(l as (typeof LOCALES)[number]));

  return preferred ?? DEFAULT_LOCALE;
}

function isAdminPath(pathname: string): boolean {
  return ADMIN_PATHS.some((p) =>
    LOCALES.some(
      (locale) =>
        pathname === `/${locale}${p}` || pathname.startsWith(`/${locale}${p}/`)
    )
  );
}

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Static files and Next.js internals — skip
  if (
    pathname.startsWith("/_next") ||
    pathname.startsWith("/api") ||
    pathname.startsWith("/favicon") ||
    pathname.match(/\.(ico|png|jpg|jpeg|svg|webp|woff2?|ttf|otf|css|js)$/)
  ) {
    return NextResponse.next();
  }

  // Redirect root to default locale
  if (pathname === "/") {
    return NextResponse.redirect(
      new URL(`/${DEFAULT_LOCALE}`, request.url)
    );
  }

  // Redirect paths without locale prefix
  const hasLocale = LOCALES.some(
    (locale) =>
      pathname.startsWith(`/${locale}/`) || pathname === `/${locale}`
  );

  if (!hasLocale) {
    const locale = getLocale(request);
    return NextResponse.redirect(
      new URL(`/${locale}${pathname}`, request.url)
    );
  }

  // Supabase: refresh session and check admin routes
  let response = NextResponse.next({
    request: { headers: request.headers },
  });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value)
          );
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        },
      },
    }
  );

  const { data: { user } } = await supabase.auth.getUser();

  // Protect admin routes
  if (isAdminPath(pathname)) {
    if (!user) {
      const locale = LOCALES.find((l) => pathname.startsWith(`/${l}`)) ?? DEFAULT_LOCALE;
      return NextResponse.redirect(new URL(`/${locale}/login`, request.url));
    }

    // Check admin role via DB
    const { data: profile } = await supabase
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .single();

    if (!profile || profile.role !== "admin") {
      const locale = LOCALES.find((l) => pathname.startsWith(`/${l}`)) ?? DEFAULT_LOCALE;
      return NextResponse.redirect(new URL(`/${locale}`, request.url));
    }
  }

  return response;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
