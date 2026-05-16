import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Rhythm Control",
  description: "Discos de segunda mano en Barcelona",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html>
      <body>{children}</body>
    </html>
  );
}
