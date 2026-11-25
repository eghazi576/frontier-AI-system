#!/usr/bin/env bash
# Connects one WhatsApp number to the AI Fronter (run once per business number).
# Usage: scripts/create-whatsapp-instance.sh fronter_realestate
# The name must match channels.evolution_instance in the database for that business.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=${1:?Give the instance name, e.g. fronter_realestate}
set -a; source .env; set +a
EVO=${EVOLUTION_URL:-http://localhost:8080}

curl -sS -X POST "$EVO/instance/create" \
  -H "apikey: $EVOLUTION_API_KEY" -H "Content-Type: application/json" \
  -d @- <<JSON
{
  "instanceName": "$NAME",
  "qrcode": true,
  "integration": "WHATSAPP-BAILEYS",
  "groupsIgnore": true,
  "rejectCall": false,
  "webhook": {
    "url": "http://n8n:5678/webhook/whatsapp-inbound",
    "byEvents": false,
    "base64": true,
    "events": ["MESSAGES_UPSERT"]
  }
}
JSON
echo
echo "Now scan the QR code: open the Evolution manager at $EVO/manager (log in with your EVOLUTION_API_KEY),"
echo "or fetch it with: curl -H \"apikey: \$EVOLUTION_API_KEY\" $EVO/instance/connect/$NAME"
echo "On the phone: WhatsApp > Settings > Linked devices > Link a device."
