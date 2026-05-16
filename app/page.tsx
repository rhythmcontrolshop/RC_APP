import { redirect } from "next/navigation";

// Root redirects to default locale
export default function RootPage() {
  redirect("/es");
}
