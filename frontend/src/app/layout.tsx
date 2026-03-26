import type { Metadata } from "next";
import { Nunito } from "next/font/google";
import Image from "next/image";
import Link from "next/link";
import Providers from "@/components/Providers";
import ConnectButton from "@/components/ConnectButton";
import AccessGate from "@/components/AccessGate";
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
          <AccessGate>
          <nav className="border-b sticky top-0 z-50 backdrop-blur-md" style={{ borderColor: "#3C323A", background: "rgba(0,0,0,0.4)" }}>
            <div className="max-w-7xl mx-auto px-6 py-4 flex items-center justify-between">
              <div className="flex items-center gap-8">
                <Link href="/" className="flex items-center">
                  <Image
                    src="/logos/dirac-logos/dirac_finance_logo_WH.svg"
                    width={140}
                    height={40}
                    alt="Dirac Finance"
                    priority
                  />
                </Link>
                <div className="flex items-center gap-1 text-sm">
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
              <ConnectButton />
            </div>
          </nav>
          <main className="max-w-5xl mx-auto px-6 py-10">{children}</main>
          </AccessGate>
        </Providers>
      </body>
    </html>
  );
}
