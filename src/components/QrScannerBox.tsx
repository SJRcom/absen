import { useEffect, useRef, useState } from "react";
import { Camera, CameraOff, Loader2 } from "lucide-react";

type Props = {
  onResult: (text: string) => void;
  disabled?: boolean;
};

export function QrScannerBox({ onResult, disabled }: Props) {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const scannerRef = useRef<any>(null);
  const [active, setActive] = useState(false);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    return () => {
      scannerRef.current?.stop();
      scannerRef.current?.destroy();
      scannerRef.current = null;
    };
  }, []);

  async function start() {
    if (!videoRef.current) return;
    setStarting(true);
    setError(null);
    try {
      const { default: QrScanner } = await import("qr-scanner");
      const scanner = new QrScanner(
        videoRef.current,
        (res: { data: string }) => onResult(res.data),
        { preferredCamera: "environment", highlightScanRegion: true, maxScansPerSecond: 4 },
      );
      scannerRef.current = scanner;
      await scanner.start();
      setActive(true);
    } catch (e) {
      setError(
        e instanceof Error
          ? `Kamera tidak bisa dibuka: ${e.message}`
          : "Kamera tidak bisa dibuka",
      );
      scannerRef.current?.destroy();
      scannerRef.current = null;
    } finally {
      setStarting(false);
    }
  }

  function stop() {
    scannerRef.current?.stop();
    scannerRef.current?.destroy();
    scannerRef.current = null;
    setActive(false);
  }

  return (
    <div className="space-y-3">
      <div className="relative aspect-[3/4] w-full overflow-hidden rounded-lg border bg-muted sm:aspect-video">
        <video
          ref={videoRef}
          className={`absolute inset-0 h-full w-full object-cover ${active ? "" : "opacity-0"}`}
          muted
          playsInline
          autoPlay
        />
        {active && (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
            <div className="h-2/3 w-2/3 rounded-xl border-2 border-primary/80 shadow-[0_0_0_9999px_oklch(0_0_0/0.35)]" />
          </div>
        )}
        {!active && (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 text-muted-foreground">
            <Camera className="h-10 w-10" />
            <p className="text-xs">Kamera mati</p>
          </div>
        )}
      </div>
      <button
        onClick={active ? stop : start}
        disabled={disabled || starting}
        className="inline-flex w-full items-center justify-center gap-2 rounded-md bg-secondary px-4 py-2.5 text-sm font-semibold hover:bg-muted disabled:opacity-50"
      >
        {starting ? <Loader2 className="h-4 w-4 animate-spin" /> : active ? <CameraOff className="h-4 w-4" /> : <Camera className="h-4 w-4" />}
        {active ? "Matikan kamera" : "Scan QR Code"}
      </button>
      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
