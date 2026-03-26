import { NextRequest, NextResponse } from "next/server";

const VALID_CODES = (process.env.ACCESS_CODES || "CURATOR1").split(",");
const COOKIE_NAME = "dirac-access";

export async function POST(request: NextRequest) {
  const body = await request.json();
  const code = (body.code ?? "").trim();

  if (!VALID_CODES.includes(code)) {
    return NextResponse.json({ error: "Invalid code" }, { status: 401 });
  }

  const redirectTo = body.next || "/";
  const response = NextResponse.json({ ok: true, redirect: redirectTo });

  response.cookies.set(COOKIE_NAME, code, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 7, // 7 days
  });

  return response;
}
