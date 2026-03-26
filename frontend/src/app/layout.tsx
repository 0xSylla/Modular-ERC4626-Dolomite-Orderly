import type { Metadata } from "next";
import { Nunito } from "next/font/google";
import Image from "next/image";
import Link from "next/link";
import Providers from "@/components/Providers";
import ConnectButton from "@/components/ConnectButton";
import MobileNav from "@/components/MobileNav";
import "./globals.css";

const nunito = Nunito({ subsets: ["latin"], variable: "--font-nunito" });

export const metadata: Metadata = {
  title: "Dirac Finance",
  description: "Curated Delta-Neutral Vaults",
  icons: { icon: "/favicon.svg" },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <body
        className={`${nunito.variable} antialiased min-h-screen`}
        style={{ fontFamily: "var(--font-nunito), system-ui, sans-serif" }}
      >
        <Providers>
          <nav className="border-b sticky top-0 z-50 backdrop-blur-md" style={{ borderColor: "#3C323A", background: "rgba(0,0,0,0.4)" }}>
            <div className="max-w-7xl mx-auto px-3 sm:px-6 py-3 sm:py-4 flex items-center justify-between">
              <div className="flex items-center gap-4 sm:gap-8">
                <Link href="/" className="flex items-center shrink-0">
                  <Image
                    src="/logos/dirac-logos/dirac_finance_logo_WH.svg"
                    width={110}
                    height={32}
                    alt="Dirac Finance"
                    priority
                    className="sm:w-[140px]"
                  />
                </Link>
                {/* Desktop nav */}
                <div className="hidden sm:flex items-center gap-1 text-sm">
                  <Link
                    href="/"
                    className="px-3 py-1.5 text-gray-400 hover:text-white hover:bg-white/5 rounded-lg transition-colors"
                  >
                    Vaults Registry
                  </Link>
                  <Link
                    href="/deploy-v2"
                    className="px-3 py-1.5 text-gray-400 hover:text-white hover:bg-white/5 rounded-lg transition-colors"
                  >
                    Deploy
                  </Link>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <div className="hidden sm:block">
                  <ConnectButton />
                </div>
                <MobileNav />
              </div>
            </div>
          </nav>
          <main className="max-w-5xl mx-auto px-3 sm:px-6 py-6 sm:py-10">{children}</main>
        </Providers>
      </body>
    </html>
  );
}
