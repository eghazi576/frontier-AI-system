#!/bin/sh
# Mock mode: load mock credentials + the workflow into n8n, then start it.
set -e
# Voice notes go to the mock transcriber instead of Groq.
sed 's|https://api.groq.com|http://evolution_api:8080|' /workflows/whatsapp-fronter.json > /tmp/whatsapp-fronter.json
n8n import:credentials --input=/mock/n8n-credentials.json
n8n import:workflow --input=/tmp/whatsapp-fronter.json
n8n publish:workflow --id=aiFronterWhatsApp
exec n8n start
