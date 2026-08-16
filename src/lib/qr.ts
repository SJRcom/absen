// QR payload untuk kartu member: hanya Nama, Nomor member, Nomor HP.
export type MemberQr = {
  name: string;
  member_no: string;
  phone: string;
};

export function buildMemberQr(p: { name: string; member_no: string | null; phone: string | null }): string {
  const payload: MemberQr = {
    name: p.name,
    member_no: p.member_no ?? "",
    phone: p.phone ?? "",
  };
  return JSON.stringify(payload);
}

/**
 * Terima QR berformat JSON {name, member_no, phone} atau teks polos
 * yang berisi nomor member saja.
 */
export function parseMemberQr(raw: string): MemberQr | null {
  const text = raw.trim();
  if (!text) return null;
  if (text.startsWith("{")) {
    try {
      const o = JSON.parse(text) as Partial<MemberQr>;
      const member_no = String(o.member_no ?? "").trim();
      if (!member_no) return null;
      return { name: String(o.name ?? ""), member_no, phone: String(o.phone ?? "") };
    } catch {
      return null;
    }
  }
  if (text.length > 64) return null;
  return { name: "", member_no: text, phone: "" };
}
