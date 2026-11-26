#!/bin/bash
# send_message.sh: posts a fake Evolution webhook to n8n. Usage: <instance> <jid> <text> [fromMe]
curl -s -X POST localhost:5678/webhook/whatsapp-inbound -H 'content-type: application/json' -d "$(python3 -c '
import json,sys
inst,jid,text=sys.argv[1:4]; fm=len(sys.argv)>4
print(json.dumps({"event":"messages.upsert","instance":inst,"data":{"key":{"remoteJid":jid,"fromMe":fm,"id":"ABC"},"pushName":"Ali","message":{"conversation":text},"messageType":"conversation","messageTimestamp":1}}))' "$@")"; echo
