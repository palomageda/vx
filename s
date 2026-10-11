#!/usr/bin/env bash
# =====================================================================
#  SIAPKAN SERVER VORTEX - jalankan SEKALI setelah Ubuntu terpasang
#  Idempotent: aman dijalankan berulang.
# =====================================================================
set -uo pipefail

C='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
judul(){ echo -e "\n${C}=== $* ===${N}"; }
ok(){    echo -e "  ${G}[OK]${N} $*"; }
info(){  echo -e "  [-]  $*"; }
warn(){  echo -e "  ${Y}[!]${N} $*"; }
gagal(){ echo -e "  ${R}[X]${N} $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}Jalankan dengan sudo:${N}  sudo bash $0"; exit 1
fi

echo "================================================================"
echo "  PENYIAPAN SERVER VORTEX  -  $(date '+%d %b %Y %H:%M')"
echo "  Host: $(hostname)   Ubuntu: $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "================================================================"

# ---------------------------------------------------------------- 1
judul "1. Zona waktu & waktu (NTP)"
timedatectl set-timezone Asia/Jakarta 2>/dev/null && ok "zona waktu: Asia/Jakarta"
timedatectl set-ntp true 2>/dev/null && ok "NTP aktif"

# ---------------------------------------------------------------- 2
judul "2. Perbarui sistem"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && ok "daftar paket diperbarui"
apt-get -y -qq upgrade && ok "paket diperbarui"

# ---------------------------------------------------------------- 3
judul "3. Paket dasar"
PAKET="git curl wget ca-certificates unzip build-essential sqlite3 ffmpeg rsync \
htop btop jq python3-venv python3-pip python3-dev openssh-server samba cockpit at"
apt-get install -y -qq $PAKET && ok "terpasang: $PAKET"

# ---------------------------------------------------------------- 4
judul "4. FONT Microsoft (wajib agar dokumen Arial 12pt tidak bergeser)"
echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections
echo "ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note" | debconf-set-selections
apt-get install -y -qq ttf-mscorefonts-installer fonts-liberation fonts-crosextra-carlito fonts-crosextra-caladea \
  && ok "font Arial/Times + Carlito (metrik Calibri) + Caladea terpasang" \
  || warn "font Microsoft gagal - jalankan manual: sudo apt install ttf-mscorefonts-installer"

# ---------------------------------------------------------------- 5
judul "5. LibreOffice (cadangan cetak PDF kalau laptop mati)"
apt-get install -y -qq libreoffice-core libreoffice-writer libreoffice-impress \
  && ok "LibreOffice terpasang (pakai mode headless)" || warn "LibreOffice gagal dipasang"

# ---------------------------------------------------------------- 6
judul "6. Cockpit (dashboard web - lihat status dari HP)"
systemctl enable --now cockpit.socket 2>/dev/null && ok "Cockpit aktif di port 9090"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "${IP:-}" ] && info "buka: http://$IP:9090"

# ---------------------------------------------------------------- 7
judul "7. Update keamanan otomatis TANPA restart sendiri"
sed -i 's|^//Unattended-Upgrade::Automatic-Reboot |Unattended-Upgrade::Automatic-Reboot |' \
  /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null
if ! grep -q '^Unattended-Upgrade::Automatic-Reboot' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
  echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades
fi
grep -h 'Automatic-Reboot' /etc/apt/apt.conf.d/50unattended-upgrades | sed 's/^/     /'
ok "update keamanan otomatis aktif, restart otomatis DIMATIKAN"

# ---------------------------------------------------------------- 8
judul "8. Hard disk data (HDD 932 GB) - PERLU KONFIRMASI ANDA"
mapfile -t HDD < <(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk"')
echo "  Disk yang terdeteksi di sistem ini:"
lsblk -dpo NAME,SIZE,MODEL,TYPE | sed 's/^/     /'
echo
# cari disk NON-NVMe (HDD) berukuran besar, jangan sentuh NVMe (tempat OS)
KANDIDAT=""
while read -r dev size type; do
  case "$dev" in
    *nvme*) continue ;;
    /dev/sd*) : ;;
    *) continue ;;
  esac
  # ukuran > 400 GB dianggap HDD data
  bytes=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
  if [ "${bytes:-0}" -gt 400000000000 ]; then KANDIDAT="$dev"; fi
done < <(lsblk -dpno NAME,SIZE,TYPE | awk '{print $1, $2, $3}')

if [ -z "$KANDIDAT" ]; then
  warn "Tidak menemukan HDD besar (>400 GB) non-NVMe. Dilewati."
else
  echo -e "  ${Y}Kandidat HDD data: $KANDIDAT${N}"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$KANDIDAT" | sed 's/^/     /'
  echo
  warn "SEMUA ISI DISK $KANDIDAT AKAN DIHAPUS dan diformat ext4 -> /srv/arsip"
  read -r -p "  Lanjutkan? (ketik HAPUS untuk melanjutkan, selain itu dilewati): " JAWAB
  if [ "$JAWAB" = "HAPUS" ]; then
    swapoff -a 2>/dev/null || true
    umount "${KANDIDAT}"?* 2>/dev/null || true
    for p in $(lsblk -pno NAME "$KANDIDAT" | tail -n +2); do
      umount "$p" 2>/dev/null || true
    done
    wipefs -a "$KANDIDAT" >/dev/null 2>&1
    parted -s "$KANDIDAT" mklabel gpt
    parted -s "$KANDIDAT" mkpart primary ext4 0% 100%
    sleep 2
    partprobe "$KANDIDAT" 2>/dev/null || true
    sleep 2
    PART="$KANDIDAT"1
    [ -b "$PART" ] || PART=$(lsblk -pno NAME "$KANDIDAT" | tail -n +2 | head -1)
    mkfs.ext4 -F -L ARSIP "$PART" >/dev/null 2>&1 && ok "diformat: $PART (label ARSIP)"
    mkdir -p /srv/arsip
    UUID=$(blkid -s UUID -o value "$PART")
    if [ -n "$UUID" ] && ! grep -q "$UUID" /etc/fstab; then
      echo "UUID=$UUID /srv/arsip ext4 defaults,noatime 0 2" >> /etc/fstab
      ok "ditambahkan ke /etc/fstab (otomatis ter-mount saat nyala)"
    fi
    mount -a 2>/dev/null && ok "ter-mount di /srv/arsip"
    df -h /srv/arsip | sed 's/^/     /'
  else
    info "HDD dilewati (aman - bisa dikerjakan nanti)"
  fi
fi

# ---------------------------------------------------------------- 9
judul "9. Folder kerja"
mkdir -p /srv/arsip /srv/layanan /srv/backup
ok "dibuat: /srv/arsip  /srv/layanan  /srv/backup"

# ---------------------------------------------------------------- 10
judul "10. Jaringan pribadi & sinkronisasi (Tailscale, Syncthing, rclone)"
LOGIN_USER="${SUDO_USER:-wahyu}"

# --- Tailscale: jaringan pribadi, akses dari mana saja
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 \
    && ok "Tailscale terpasang" || warn "Tailscale GAGAL dipasang (jaringan/blokir?) - coba manual nanti"
else
  ok "Tailscale sudah terpasang"
fi

# --- Syncthing: sinkron antar device tanpa awan
if ! command -v syncthing >/dev/null 2>&1; then
  apt-get install -y -qq syncthing && ok "Syncthing terpasang" || warn "Syncthing gagal dipasang"
else
  ok "Syncthing sudah terpasang"
fi

# --- rclone: jembatan OneDrive
if ! command -v rclone >/dev/null 2>&1; then
  apt-get install -y -qq rclone && ok "rclone terpasang" || warn "rclone gagal dipasang"
else
  ok "rclone sudah terpasang"
fi

# --- batas memori untuk Syncthing (jangan sampai memakan RAM server)
if [ -f /etc/default/syncthing ] && ! grep -q 'GOMEMLIMIT' /etc/default/syncthing 2>/dev/null; then
  echo 'GOMEMLIMIT=512MiB' >> /etc/default/syncthing
fi

# --- nyalakan Syncthing otomatis (tidak perlu manual lagi)
systemctl enable --now "syncthing@$LOGIN_USER" >/dev/null 2>&1 \
  && ok "Syncthing aktif (layanan syncthing@$LOGIN_USER)" \
  || warn "Syncthing belum aktif - jalankan: sudo systemctl enable --now syncthing@$LOGIN_USER"

# --- Cockpit: izinkan diakses dari jaringan pribadi
mkdir -p /etc/cockpit
printf '[WebService]\nAllowUnencrypted=false\nOrigins = https://* http://*\n' > /etc/cockpit/cockpit.conf 2>/dev/null || true
systemctl restart cockpit.socket >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 11
judul "11. Ringkasan"
echo "  Hostname     : $(hostname)"
echo "  IP lokal     : ${IP:-tidak terdeteksi}"
echo "  Ubuntu       : $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "  CPU/RAM      : $(nproc) core / $(free -h | awk '/Mem:/{print $2}')"
echo "  Penyimpanan  :"
df -h --output=source,size,avail,target / /srv/arsip 2>/dev/null | sed 's/^/     /'
echo "  SSH          : $(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null)"
echo "  Cockpit      : $(systemctl is-active cockpit 2>/dev/null)"
echo
echo -e "${Y}--- 2 LANGKAH MANUAL SAJA (butuh login sekali) ---${N}"
echo "   1. Jaringan pribadi (pakai akun SAMA seperti di HP/laptop):"
echo "        sudo tailscale up"
echo "        (setelah ini:  ssh vortex  /  http://vortex:9090  jalan dari mana saja)"
echo
echo "   2. Jembatan OneDrive (rclone) - bisa dikerjakan nanti:"
echo "        rclone config   -> 'n' (new), nama: onedrive, tipe: onedrive"
echo
echo "   Syncthing SUDAH otomatis aktif. Panelnya: http://vortex:8384"
echo
echo -e "${G}================================================================"
echo "  SELESAI. Langkah berikutnya:"
echo "   - Akses server:  ssh wahyu@vortex   (setelah Tailscale aktif)"
echo "   - Dashboard:     http://vortex:9090 (Cockpit)"
echo "   - Lanjut Tahap 5-7 di dokumen 2-ALUR-LENGKAP.txt"
echo -e "================================================================${N}"
