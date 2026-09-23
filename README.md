# WEBSSL

IIS ve nginx sitelerinin binding ve SSL sürelerini toplayan merkezi dashboard.

Merkez sunucu: **192.168.254.90** (`http://192.168.254.90:8080`)

Her Windows / Linux sunucuya küçük bir agent kurulur. Agent günde bir kez site binding'lerini ve sertifika bitiş tarihlerini merkeze gönderir.

## Durum renkleri

| Durum | Anlam |
| --- | --- |
| Sağlıklı | 30 günden fazla |
| Yaklaşıyor | 8–30 gün |
| Kritik | 7 gün veya az |
| Süresi dolmuş | Bitiş tarihi geçmiş |
| SSL yok | HTTP binding veya sertifika yok |
| stale | Agent 24 saatten fazla sessiz |

## 1) Ubuntu merkeze kurulum (192.168.254.90)

Private GitHub repo: https://github.com/gokhancolaq/webssl

Ubuntu sunucuda:

```bash
sudo apt-get update
sudo apt-get install -y git
sudo git clone https://github.com/gokhancolaq/webssl.git /opt/webssl
sudo bash /opt/webssl/scripts/install-ubuntu.sh
sudo nano /opt/webssl/.env
```

Repo private olduğu için Ubuntu’da GitHub erişimi gerekir (`gh auth login` veya HTTPS token / deploy key).

`.env` içinde mutlaka değiştirin:

- `DASHBOARD_PASSWORD`
- `AGENT_TOKEN` (agent'larda da aynı olacak)
- Script zaten `SECRET_KEY` üretir

Kontrol:

```bash
sudo systemctl status webssl
curl http://192.168.254.90:8080/api/health
```

Tarayıcı: `http://192.168.254.90:8080`  
Giriş: `DASHBOARD_USER` / `DASHBOARD_PASSWORD`

Firewall kapalıysa veya ufw aktifse 8080 açık olmalı:

```bash
sudo ufw allow 8080/tcp
sudo ufw reload
```

Agent token'ı görmek için:

```bash
sudo grep AGENT_TOKEN /opt/webssl/.env
```

## 2) Windows agent (IIS)

IIS Management Scripts and Tools (WebAdministration) açık olmalı. `agents/windows` klasörünü sunucuya kopyalayın.

```powershell
cd C:\WEBSSL-agent
.\install-scheduled-task.ps1 -CentralUrl "http://192.168.254.90:8080" -AgentToken "UBUNTU-.ENV-ICINDEKI-TOKEN"
```

Her gün 06:00'da çalışır ve ilk taramayı hemen başlatır.

Elle:

```powershell
.\webssl-agent.ps1 -CentralUrl "http://192.168.254.90:8080" -AgentToken "UBUNTU-.ENV-ICINDEKI-TOKEN"
```

Windows sunucunun 192.168.254.90:8080 adresine TCP erişimi olmalı.

## 3) Linux agent (nginx)

Nginx sitelerinin olduğu her Ubuntu/Linux sunucuda (merkezden ayrı):

```bash
sudo mkdir -p /opt/webssl-agent
sudo cp webssl_agent.py /opt/webssl-agent/
sudo apt-get update
sudo apt-get install -y python3 python3-pip
sudo python3 -m pip install cryptography
```

İlk gönderim:

```bash
sudo CENTRAL_URL=http://192.168.254.90:8080 AGENT_TOKEN=UBUNTU-.ENV-ICINDEKI-TOKEN python3 /opt/webssl-agent/webssl_agent.py
```

Günlük cron — `/etc/cron.d/webssl-agent`:

```cron
0 6 * * * root CENTRAL_URL=http://192.168.254.90:8080 AGENT_TOKEN=UBUNTU-.ENV-ICINDEKI-TOKEN /usr/bin/python3 /opt/webssl-agent/webssl_agent.py >> /var/log/webssl-agent.log 2>&1
```

Agent `nginx -T` çıktısını okur; root veya nginx config + sertifika dosyalarını okuyabilen kullanıcı gerekir.

## Agent API

`POST http://192.168.254.90:8080/api/ingest`

Header: `X-Agent-Token: <AGENT_TOKEN>`

```powershell
.\scripts\send-demo.ps1 -CentralUrl "http://192.168.254.90:8080" -AgentToken "token"
```

Aynı hostname tekrar gönderilirse o sunucunun binding kayıtları silinip yeni snapshot yazılır.

## Klasörler

```
central/                 FastAPI uygulaması + systemd unit
agents/windows/          IIS PowerShell agent
agents/linux/            nginx Python agent
scripts/install-ubuntu.sh
samples/                 örnek ingest JSON
```

## Bu sürümde yok

- E-posta / Teams uyarısı
- Sertifika yenileme veya binding değiştirme
- Apache
