#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo bash install.sh <BUCKET> [PROFILE] [REGION]
# Example:
#   sudo bash install.sh fruit-fresca fruit_uploader us-east-2

BUCKET="${1:-}"
PROFILE="${2:-fruit_uploader}"
REGION="${3:-us-east-2}"

if [[ -z "$BUCKET" ]]; then
  echo "Usage: sudo bash install.sh <BUCKET> [PROFILE] [REGION]"
  exit 1
fi

echo "[*] Installing field uploader -> bucket: s3://$BUCKET  profile: $PROFILE  region: $REGION"

# 0) sanity: must run as root
if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo/root."
  exit 1
fi

# 1) deps + outbox
if ! command -v aws >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y awscli
fi
mkdir -p /data/outbox

# 2) config -> /etc/field-uploader.conf
CONF_SRC=""
for c in field-uploader.conf field-uploader.conf.example; do
  [[ -f "$c" ]] && CONF_SRC="$c" && break
done
if [[ -z "$CONF_SRC" ]]; then
  echo "Could not find field-uploader.conf or field-uploader.conf.example in the current directory."
  exit 1
fi

install -m 0644 "$CONF_SRC" /etc/field-uploader.conf
# ensure required keys exist in config with sane defaults
grep -q '^PROFILE=' /etc/field-uploader.conf || echo 'PROFILE=""' >> /etc/field-uploader.conf
grep -q '^DST='     /etc/field-uploader.conf || echo 'DST=""'     >> /etc/field-uploader.conf
grep -q '^SRC='     /etc/field-uploader.conf || echo 'SRC="/data/outbox"' >> /etc/field-uploader.conf
grep -q '^PING_HOST=' /etc/field-uploader.conf || echo 'PING_HOST="s3.amazonaws.com"' >> /etc/field-uploader.conf

# set PROFILE and DST in the config
sed -i "s#^PROFILE=.*#PROFILE=\"$PROFILE\"#g" /etc/field-uploader.conf
# point to per-device prefix using hostname -s
DST_VALUE="s3://$BUCKET/device-$(hostname -s)"
sed -i "s#^DST=.*#DST=\"$DST_VALUE\"#g" /etc/field-uploader.conf

echo "[*] Config written to /etc/field-uploader.conf"
echo "    PROFILE=$PROFILE"
echo "    DST=$DST_VALUE"

# 3) install scripts
install -m 0755 s3-sync-captures /usr/local/bin/s3-sync-captures
install -m 0755 80-s3-sync /etc/NetworkManager/dispatcher.d/80-s3-sync
chown root:root /etc/NetworkManager/dispatcher.d/80-s3-sync

# 4) ensure AWS profile exists; prompt if missing
if ! aws --profile "$PROFILE" sts get-caller-identity >/dev/null 2>&1; then
  echo "[*] AWS profile \"$PROFILE\" not configured. Enter keys from your CSV."
  read -rp "  AWS Access Key ID: " AWS_KEY
  read -srp "  AWS Secret Access Key: " AWS_SECRET
  echo
  aws configure set aws_access_key_id "$AWS_KEY" --profile "$PROFILE"
  aws configure set aws_secret_access_key "$AWS_SECRET" --profile "$PROFILE"
  aws configure set region "$REGION" --profile "$PROFILE"
fi

# 5) quick smoke test (read permission to bucket root)
if aws --profile "$PROFILE" s3 ls "s3://$BUCKET" >/dev/null 2>&1; then
  echo "[✓] AWS credentials look good."
else
  echo "[!] Warning: could not list s3://$BUCKET with profile $PROFILE. Double-check IAM policy/region."
fi

cat <<EOF

Done.

Outbox: /data/outbox
Uploader: /usr/local/bin/s3-sync-captures
NM Hook: /etc/NetworkManager/dispatcher.d/80-s3-sync
Profile: $PROFILE
Bucket : s3://$BUCKET (prefix device-$(hostname -s)/)

Quick test:
  sudo mkdir -p /data/outbox/test_run
  echo "hello" | sudo tee /data/outbox/test_run/file.txt >/dev/null
  sudo touch /data/outbox/test_run/.done
  sudo /usr/local/bin/s3-sync-captures
  aws --profile $PROFILE s3 ls s3://$BUCKET/device-$(hostname -s)/

Automatic uploads will run whenever Wi-Fi connects and the internet is reachable.
EOF
