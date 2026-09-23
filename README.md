# WEBSSL

IIS ve nginx sitelerinin binding ve SSL sürelerini toplayan merkezi dashboard.

Her Windows / Linux sunucuya küçük bir agent kurulur. Agent günde bir kez site binding'lerini ve sertifika bitiş tarihlerini merkeze gönderir. Kurulum script'leri dashboard IP'sini sorar; repoda gerçek adres tutulmaz.

## Durum renkleri

| Durum | Anlam |
| --- | --- |
| Sağlıklı | 30 günden fazla |
| Yaklaşıyor | 8–30 gün |
| Kritik | 7 gün veya az |
| Süresi dolmuş | Bitiş tarihi geçmiş |
| SSL yok | HTTP binding veya sertifika yok |
| stale | Agent 24 saatten fazla sessiz |

## 1) Ubuntu merkeze kurulum

```bash
sudo apt-get update
sudo apt-get install -y git
sudo git clone https://github.com/gokhancolaq/webssl.git /opt/webssl
sudo bash /opt/webssl/scripts/install-ubuntu.sh
```

Script sırayla sorar:

- Dashboard IP veya hostname (agent'ların bağlanacağı adres)
- Port (varsayılan `8080`)
- Panel kullanıcı adı / şifre

Agent token ve `SECRET_KEY` otomatik üretilir. Token ekrana yazılır; agent kurarken kullanın.

Kontrol:

```bash
sudo systemctl status webssl
sudo grep AGENT_TOKEN /opt/webssl/.env
```

Tarayıcı: `http://DASHBOARD_IP:8080`

Firewall:

```bash
sudo ufw allow 8080/tcp
sudo ufw reload
```

## 2) Windows agent (IIS)

IIS Management Scripts and Tools (WebAdministration) açık olmalı. IIS sunucusunda **yönetici PowerShell**:

```powershell
irm https://raw.githubusercontent.com/gokhancolaq/webssl/main/agents/windows/install.ps1 | iex
```

Komut public GitHub'dan agent'ı indirir, dashboard IP / port / token sorar, `C:\ProgramData\WEBSSL\agent` altına kurar ve her gün 06:00 görevi oluşturur. Git yüklü değilse ZIP ile devam eder.

## 3) Linux agent (nginx)

Nginx sitelerinin olduğu her Linux sunucuda (merkezden ayrı):

```bash
sudo mkdir -p /opt/webssl-src
sudo git clone https://github.com/gokhancolaq/webssl.git /opt/webssl-src
sudo bash /opt/webssl-src/agents/linux/install-agent.sh
```

Script dashboard IP, port ve agent token sorar; cron'u 06:00 için yazar ve ilk taramayı gönderir.

## Agent API

`POST http://DASHBOARD_IP:8080/api/ingest`

Header: `X-Agent-Token: <AGENT_TOKEN>`

```powershell
.\scripts\send-demo.ps1
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
