#!/usr/bin/env bash
# =====================================================================
#  PASANG PEMANTAU LUAR (healthchecks.io) DI SERVER VORTEX
#  Pemakaian:
#    curl -fsSL github.com/palomageda/vx/raw/master/hc | sudo bash -s -- <PING_URL>
# =====================================================================
set -uo pipefail
URL="${1:-}"

if [ -z "$URL" ]; then
  echo "GAGAL: Ping URL belum diisi."
  echo "Pemakaian:  ... | sudo bash -s -- <PING_URL>"
  exit 1
fi

case "$URL" in
  *hc-ping.com*|*healthchecks.io*) : ;;
  *) echo "Catatan: URL bukan dari hc-ping.com - pastikan benar." ;;
esac

echo "=== 1. Menulis skrip pemeriksa ==="
cat > /usr/local/bin/hc-ping.sh <<EOF
#!/usr/bin/env bash
# Ping healthchecks.io. Kalau layanan lokal mati -> kirim /fail.
URL="$URL"
GAGAL=()

# --- daftar layanan yang diperiksa ---
# format: url:<alamat>:<nama>
# kosongkan dulu; diisi otomatis saat migrasi produk (FMM/TPI/Briv)
PERIKSA=()

for item in "\${PERIKSA[@]:-}"; do
  [ -z "\$item" ] && continue
  jenis="\${item%%:*}"; sisa="\${item#*:}"
  [ "\$jenis" != "url" ] && continue
  almt="\${sisa%%:*}"; nama="\${sisa##*:}"
  kode=\$(curl -s -o /dev/null -m 10 -w '%{http_code}' "\$almt" 2>/dev/null || echo 000)
  case "\$kode" in
    2*|3*) : ;;
    *) GAGAL+=("\$nama=\$kode") ;;
  esac
done

if [ \${#GAGAL[@]} -eq 0 ]; then
  curl -fsS -m 20 --retry 3 "\$URL" >/dev/null 2>&1
  echo "ping terkirim (sehat)"
else
  curl -fsS -m 20 --retry 2 --data "LAYANAN MATI: \${GAGAL[*]}" "\$URL/fail" >/dev/null 2>&1
  echo "DILAPORKAN GAGAL: \${GAGAL[*]}"
fi
EOF
chmod 700 /usr/local/bin/hc-ping.sh
echo "  OK -> /usr/local/bin/hc-ping.sh (hanya bisa dibaca root)"

echo "=== 2. Membuat layanan systemd ==="
cat > /etc/systemd/system/hc-ping.service <<'UNIT'
[Unit]
Description=Ping healthchecks.io (pemantau luar server Vortex)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hc-ping.sh
UNIT

cat > /etc/systemd/system/hc-ping.timer <<'UNIT'
[Unit]
Description=Jalankan ping healthchecks tiap 5 menit

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now hc-ping.timer >/dev/null 2>&1
echo "  OK -> timer hc-ping aktif (tiap 5 menit, otomatis jalan setelah reboot)"

echo "=== 3. Uji kirim sekarang ==="
hasil=$(systemctl start hc-ping.service 2>&1 && /usr/local/bin/hc-ping.sh 2>&1 | tail -1)
echo "  $hasil"

echo
echo "=== 4. Status ==="
systemctl is-active hc-ping.timer | sed 's/^/  timer : /'
systemctl list-timers hc-ping.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/  jadwal: /'
echo
echo "================================================================"
echo " SETELAN CHECK DI healthchecks.io (kalau belum):"
echo "   Name       : Vortex - server rumah"
echo "   Period     : 10 minutes"
echo "   Grace Time : 5 minutes"
echo "   Notifikasi : Email aktif; opsi 'when the check goes up' -> matikan"
echo
echo " Setelah ini: buka dashboard healthchecks.io, check-nya harus HIJAU."
echo "================================================================"
