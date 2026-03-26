import { NextRequest, NextResponse } from "next/server";

const VALID_CODES = (process.env.ACCESS_CODES || "CURATOR1").split(",");
const COOKIE_NAME = "dirac-access";

export function middleware(request: NextRequest) {
  // Allow the gate page and its API route through
  if (
    request.nextUrl.pathname === "/gate" ||
    request.nextUrl.pathname === "/api/gate"
  ) {
    return NextResponse.next();
  }

  // Allow static assets, _next, favicon
  if (
    request.nextUrl.pathname.startsWith("/_next") ||
    request.nextUrl.pathname.startsWith("/logos") ||
    request.nextUrl.pathname.startsWith("/images") ||
    request.nextUrl.pathname === "/favicon.svg" ||
    request.nextUrl.pathname === "/favicon.ico"
  ) {
    return NextResponse.next();
  }

  // Check cookie
  const cookie = request.cookies.get(COOKIE_NAME);
  if (cookie && VALID_CODES.includes(cookie.value)) {
    return NextResponse.next();
  }

  // Redirect to gate
  const gateUrl = new URL("/gate", request.url);
  gateUrl.searchParams.set("next", request.nextUrl.pathname);
  return NextResponse.redirect(gateUrl);
}

export const config = {
  matcher: ["/((?!_next/static|_next/image).*)"],
};
