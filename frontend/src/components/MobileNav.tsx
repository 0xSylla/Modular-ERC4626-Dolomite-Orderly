"use client";

import { useState } from "react";
import Link from "next/link";
import ConnectButton from "./ConnectButton";

export default function MobileNav() {
  const [open, setOpen] = useState(false);

  return (
    <div className="sm:hidden">
      {/* Hamburger button */}
      <button
        onClick={() => setOpen(!open)}
        className="p-2 text-[#818181] hover:text-white transition-colors"
        aria-label="Menu"
      >
        {open ? (
          <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
          </svg>
        ) : (
          <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h16" />
          </svg>
        )}
      </button>

      {/* Dropdown menu */}
      {open && (
        <div
          className="absolute top-full left-0 right-0 border-b z-50"
          style={{ background: "rgba(23,23,23,0.98)", borderColor: "#3C323A" }}
        >
          <div className="px-4 py-4 space-y-3">
            <Link
              href="/"
              onClick={() => setOpen(false)}
              className="block px-3 py-2.5 text-sm text-gray-400 hover:text-white hover:bg-white/5 rounded-lg transition-colors"
            >
              Vaults Registry
            </Link>
            <Link
              href="/deploy"
              onClick={() => setOpen(false)}
              className="block px-3 py-2.5 text-sm text-gray-400 hover:text-white hover:bg-white/5 rounded-lg transition-colors"
            >
              Deploy
            </Link>
            <Link
              href="/deploy-v2"
              onClick={() => setOpen(false)}
              className="block px-3 py-2.5 text-sm text-gray-400 hover:text-white hover:bg-white/5 rounded-lg transition-colors"
            >
              Deploy v2
            </Link>
            <div className="pt-2 border-t border-[#3C323A]">
              <ConnectButton />
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
