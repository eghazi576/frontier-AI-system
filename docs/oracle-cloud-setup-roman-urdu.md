# Oracle Cloud (Always Free) par AI Fronter chalana — Roman Urdu guide

Is guide se aap ka WhatsApp AI front desk ek **free cloud server** par 24 ghante chalega. Laptop band ho
to bhi bot chalta rahega. Waqt: taqreeban 1 se 1.5 ghanta.

**Kya free hai:** Oracle ka "Always Free" Ampere (ARM) server: 4 CPU core aur 24 GB RAM tak, 200 GB disk
tak, aur 10 TB internet data har mahine. Hamare system ke liye 2 core / 12 GB bhi kaafi hai.

**Kya chahiye:**
- Ek email aur mobile number
- Ek debit/credit card (sirf verification ke liye; Always Free cheezon ka paisa nahi katta)
- Windows/Mac par terminal (Windows 10/11 mein PowerShell mein `ssh` pehle se hota hai)

Server par hum yeh chalayenge: **n8n + Evolution API (WhatsApp) + Caddy (free HTTPS)**. Database
Supabase (free) par rehta hai, jaise README mein hai. Shuru mein bina kisi account ke **mock mode** bhi
chala sakte hain (Step 9A).

---

## Step 1: Oracle account banayein
1. `oracle.com/cloud/free` par jayein → **Start for free**.
2. Country, naam, email bharein. Email verify karein.
3. **Home Region** chunein. Yeh baad mein badal nahi sakta. Apne customers ke qareeb wala chunein,
   misal ke taur par **UAE East (Dubai)**, **Saudi Arabia West (Jeddah)**, **Germany Central (Frankfurt)**
   ya **India West (Mumbai)**. Turkey/Pakistan dono ke liye Dubai ya Frankfurt theek hain.
4. Card details dein. Chhoti si verification charge aa sakti hai jo wapas ho jati hai.
5. Account bannay mein 5 se 30 minute lag sakte hain. Email aaye to **Sign in** karein.

> Tip: Free account kabhi kabhi "Out of capacity" deta hai (Step 2). Agar baar baar aaye to account ko
> **Pay As You Go** par upgrade karein (Billing → Upgrade). Always Free hissa phir bhi free rehta hai,
> aur capacity aur "idle server band karne" wala masla (Step 12) khatam ho jata hai. Billing mein ek
> **budget alert** (misal $1) laga dein taake ghalti se koi kharcha ho to foran email aaye.

## Step 2: Server (VM) banayein
1. Upar left menu (☰) → **Compute** → **Instances** → **Create instance**.
2. **Name:** `ai-fronter`.
3. **Image and shape** → *Edit*:
   - **Change image** → **Ubuntu** → **Canonical Ubuntu 24.04** (aarch64 wala, ARM ke liye) → Select.
   - **Change shape** → **Ampere** → **VM.Standard.A1.Flex** → OCPU **2**, Memory **12 GB** (ya 4 / 24) → Select.
     Neeche "Always Free-eligible" likha hona chahiye.
4. **Networking:** default VCN aur public subnet theek hai. **Assign a public IPv4 address: Yes**.
5. **Add SSH keys:** **Generate a key pair for me** → **Save private key** dabayein. File
   (`ssh-key-....key`) sambhal kar rakhein, yahi server ki chabi hai. Is ke baghair login nahi hoga.
6. **Boot volume:** default (taqreeban 50 GB) theek hai.
7. **Create**. 1-2 minute mein status **Running** ho jayega. **Public IP address** copy kar lein
   (misal `129.151.x.x`).

"Out of capacity for shape VM.Standard.A1.Flex" aaye to: doosra **Availability domain** chunein,
OCPU kam karein (1 OCPU / 6 GB), thori der baad dobara try karein, ya upar wala Pay As You Go tip.

## Step 3: Oracle firewall mein port 80 aur 443 kholein
Yeh HTTPS (n8n ka link) ke liye hai.
1. Instance page → **Primary VNIC** → **Subnet** link → **Security** (ya *Security Lists*) → **Default Security List**.
2. **Add Ingress Rules** → do rules:
   - Source CIDR `0.0.0.0/0`, IP Protocol TCP, Destination Port `80`
   - Source CIDR `0.0.0.0/0`, IP Protocol TCP, Destination Port `443`
3. **Add**. Port 22 (SSH) pehle se khula hota hai. **5678 aur 8080 na kholein**: n8n HTTPS se khulega aur
   Evolution sirf server ke andar rahega.

## Step 4: Server mein login (SSH)
Apne computer par terminal/PowerShell kholein, jis folder mein key save ki thi wahan jayein:

```bash
# Mac/Linux par pehli dafa key ki permission theek karein:
chmod 600 ssh-key-*.key

ssh -i ssh-key-XXXX.key ubuntu@<PUBLIC_IP>
```
"Are you sure you want to continue connecting" par `yes` likhein. Ab aap server ke andar hain
(prompt `ubuntu@ai-fronter:~$` jaisa dikhega). Aage ki saari commands yahin chalani hain.

Windows par "permissions are too open" error aaye to: key file → Properties → Security → Advanced →
inheritance band karein aur sirf apna user rakhein.

## Step 5: Ubuntu ka andar wala firewall kholein
Oracle ke Ubuntu mein ek aur firewall (iptables) hota hai jo 80/443 band rakhta hai:

```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

## Step 6: Updates aur Docker install karein
```bash
sudo apt update && sudo apt -y upgrade
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu
exit
```
`exit` ke baad dobara Step 4 wali `ssh` command se login karein, phir check karein:
```bash
docker run --rm hello-world
```
"Hello from Docker!" aaye to Docker tayyar hai.

## Step 7: Free domain (DuckDNS) banayein
HTTPS ke liye ek naam chahiye. Free tareeqa:
1. `duckdns.org` par Google/GitHub se login karein.
2. Subdomain likhein, misal `myfronter` → **add domain**.
3. **current ip** wale khane mein server ka Public IP likhein → **update ip**.
Ab aap ka domain `myfronter.duckdns.org` hai. (Apna domain ho to us ka **A record** server IP par karein.)

Check: server par `ping -c 2 myfronter.duckdns.org` server ka IP dikhaye.

## Step 8: Project server par laayein
```bash
git clone https://github.com/eghazi576/frontier-ai-system.git
cd frontier-ai-system
```
Agar repo **private** hai to password ki jagah GitHub **Personal Access Token** maangega:
GitHub → Settings → Developer settings → Personal access tokens → Fine-grained → sirf is repo ki
*Contents: Read* permission → token copy kar ke password ki jagah paste karein.

## Step 9A: Pehle MOCK mode (koi account nahi chahiye)
Bina WhatsApp, Supabase, Gemini ke poora system dekhne ke liye:
```bash
docker compose -f docker-compose.mock.yml up -d
docker compose -f docker-compose.mock.yml ps     # sab "running/healthy" hon
```
Test chat page server ke andar port 8080 par hai. Apne computer se dekhne ke liye **naya terminal**
kholein aur yeh "tunnel" chalayein (window khuli rehne dein):
```bash
ssh -i ssh-key-XXXX.key -L 8080:localhost:8080 ubuntu@<PUBLIC_IP>
```
Ab apne browser mein `http://localhost:8080` kholein: business chunein aur customer ban kar chat karein.
Band karna: `docker compose -f docker-compose.mock.yml down -v`.

ARM server par koi image na chale (error mein `exec format error` ya `no matching manifest`) to mujhe
batayein, us image ka ARM wala tareeqa de doon ga.

## Step 9B: Asli (live) setup
Jab Supabase, Gemini, Groq aur ek spare WhatsApp number tayyar hon (README "Setup" step 1-2):

1. Settings file banayein:
   ```bash
   cp .env.example .env
   nano .env
   ```
   Teen lambi random values ke liye `openssl rand -hex 24` teen dafa chalayein aur
   `EVOLUTION_API_KEY`, `EVOLUTION_DB_PASSWORD`, `N8N_ENCRYPTION_KEY` mein paste karein.
   `DOMAIN=myfronter.duckdns.org` likhein. Save: `Ctrl+O`, Enter, `Ctrl+X`.
2. Mock chal raha ho to pehle band karein: `docker compose -f docker-compose.mock.yml down -v`
3. Start:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.server.yml up -d
   docker compose -f docker-compose.yml -f docker-compose.server.yml ps
   ```
4. Browser mein `https://myfronter.duckdns.org` kholein (pehli dafa certificate mein 1 minute lag sakta
   hai). n8n ka owner account banayein (strong password).
5. Database: Supabase SQL Editor mein `db/001` se `db/005` chalayein (README step 2).
6. Workflow: `docs/n8n-guide-roman-urdu.md` ka **Tareeqa 1** (import + 4 credentials + Publish).
7. WhatsApp number jorna (server par):
   ```bash
   ./scripts/create-whatsapp-instance.sh fronter_realestate
   ```
   QR code dekhne ke liye apne computer par tunnel kholein:
   `ssh -i ssh-key-XXXX.key -L 8080:localhost:8080 ubuntu@<PUBLIC_IP>`
   phir browser mein `http://localhost:8080/manager` → `EVOLUTION_API_KEY` se login → instance → QR.
   Phone: WhatsApp → Settings → Linked devices → Link a device → scan.
8. Test: doosre number se "Salam" bhejein. n8n → Executions mein har message nazar aayega.

## Step 10: Roz marra ke kaam
```bash
cd ~/frontier-ai-system
C="docker compose -f docker-compose.yml -f docker-compose.server.yml"

$C ps                    # kya sab chal raha hai
$C logs -f --tail 50 n8n # n8n ke logs (Ctrl+C se bahar)
$C restart               # sab restart
git pull && $C up -d     # naya code aane par update
```
Server restart ho jaye to containers khud chal parte hain (`restart: always`).

## Step 11: Backup
- **n8n workflow:** n8n → workflow → ⋯ → Download, aur repo mein `n8n/` mein rakhein.
- **Business data:** Supabase mein hai (paid plan par roz ka backup; free par kabhi kabhi
  Database → Backups / ya SQL export).
- **WhatsApp session:** Docker volume `evolution_instances` mein. Agar server dobara banana pare to sirf
  QR dobara scan karna hoga.

## Step 12: Zaroori baatein
- **Idle server:** Oracle free account par agar 7 din tak server bohat kam istemal ho (CPU 20% se kam)
  to Oracle usay band kar sakta hai. Pay As You Go par upgrade se yeh nahi hota (Always Free phir bhi free).
- **Security:** sirf 22, 80, 443 khule rakhein. `.env` aur SSH key kisi ko na dein, Git mein na daalein.
  n8n ka password mazboot rakhein.
- **WhatsApp ban risk:** Evolution (Baileys) WhatsApp ka official tareeqa nahi. Spare number par test
  karein; paying clients ke liye baad mein official WhatsApp Cloud API.
- **Kharcha:** Ampere 4 core/24 GB, 200 GB disk aur 10 TB data tak Always Free hai. In se zyada na lein.

## Masle aur hal

| Masla | Hal |
| --- | --- |
| `ssh: connect ... timed out` | Public IP sahi hai? Instance *Running* hai? Security list mein port 22 hai? |
| `Permission denied (publickey)` | Sahi key file aur user `ubuntu` use karein: `ssh -i <key> ubuntu@IP` |
| `https://domain` nahi khulta | Step 3 aur Step 5 dono kiye? DuckDNS mein sahi IP? `$C logs caddy` dekhein |
| n8n login ke baad wapas login page | `.env` mein `DOMAIN` sahi ho aur `https://` se kholein |
| "Out of capacity" | Doosra availability domain, kam OCPU, baad mein try, ya Pay As You Go |
| WhatsApp message par n8n mein kuch nahi aata | Instance ka naam database ke `channels.evolution_instance` se milta ho; `$C logs evolution_api` |
