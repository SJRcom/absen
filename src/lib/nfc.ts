// NFC Web API helper. Only Chrome for Android supports NDEFReader.
// For e-toll cards (ISO 14443), Web NFC reads the tag serial from message.serialNumber
// even when no NDEF record exists.
export type NfcSupport = "supported" | "unsupported" | "insecure";

export function detectNfcSupport(): NfcSupport {
  if (typeof window === "undefined") return "unsupported";
  if (!("NDEFReader" in window)) return "unsupported";
  if (!window.isSecureContext) return "insecure";
  return "supported";
}

export interface NfcScanController {
  stop: () => void;
}

export async function startNfcScan(
  onUid: (uid: string) => void,
  onError: (err: Error) => void,
): Promise<NfcScanController> {
  const ctrl = new AbortController();
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const Reader = (window as any).NDEFReader;
    const reader = new Reader();
    await reader.scan({ signal: ctrl.signal });
    reader.onreadingerror = () => onError(new Error("Gagal membaca kartu. Coba tempel ulang."));
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    reader.onreading = (event: any) => {
      const raw: string = event.serialNumber ?? "";
      const uid = raw.replace(/:/g, "").toUpperCase();
      if (uid) onUid(uid);
    };
  } catch (e) {
    onError(e instanceof Error ? e : new Error(String(e)));
  }
  return { stop: () => ctrl.abort() };
}
