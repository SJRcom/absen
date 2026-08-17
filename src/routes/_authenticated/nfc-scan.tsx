import { createFileRoute } from "@tanstack/react-router";
import { NfcAbsenScanner } from "@/components/NfcAbsenScanner";

export const Route = createFileRoute("/_authenticated/nfc-scan")({
  head: () => ({
    meta: [
      { title: "Scan Kartu NFC · Absensi SJR" },
      {
        name: "description",
        content:
          "Tap kartu NFC (reader USB atau HP) untuk mengirim nomor member ke server bayarmabol.",
      },
    ],
  }),
  component: NfcScanPage,
});

function NfcScanPage() {
  return (
    <div className="max-w-5xl">
      <h1 className="text-2xl font-bold">Scan Kartu NFC (Absensi)</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        Tap kartu pada reader USB, atau gunakan NFC HP, untuk mengirim nomor member ke server
        bayarmabol secara langsung.
      </p>
      <div className="mt-6">
        <NfcAbsenScanner />
      </div>
    </div>
  );
}
