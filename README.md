# 🕶️ MaskedIP

**Masked IP, rotated automatically through Tor.**

MaskedIP asks the Tor network for a fresh identity (a new exit IP address) at an interval you choose, so the IP address websites see keeps changing.

## ✨ Features

- 🔄 Automatic IP rotation at user-defined intervals
- 🛡️ Uses the Tor network (authenticated control port, no passwords stored)
- 🚀 Works on multiple Linux distributions
- ⚡ Easy installation as a background service
- ⌛ Run without installation, a single script
- 📊 Built-in status check: compares your real IP with your Tor IP

## 🐧 Supported distributions

- Arch Linux / Manjaro
- Debian / Ubuntu
- Kali Linux
- Parrot OS
- Fedora
- openSUSE

## 📋 Prerequisites

- Linux with `sudo` privileges
- Internet connection
- `tor` and `curl` (MaskedIP installs them automatically if missing)

## 🚀 Run without installation

```bash
git clone https://github.com/r1charyan/maskedip.git
cd maskedip
chmod +x maskedip.sh
sudo ./maskedip.sh
```

Or pass options directly:

```bash
sudo ./maskedip.sh -i 30          # new IP every 30 seconds
sudo ./maskedip.sh -i 60 -n 10    # 10 rotations, 60 seconds apart
sudo ./maskedip.sh --once         # rotate once and exit
```

## 🧩 Install as a service

```bash
git clone https://github.com/r1charyan/maskedip.git
cd maskedip
chmod +x setup.sh
./setup.sh
```

The installer sets up Tor, asks for your interval, and starts the `maskedip` service on boot.

| Task | Command |
|------|---------|
| Status | `systemctl status maskedip.service` |
| Live logs | `journalctl -u maskedip.service -f` |
| Stop | `sudo systemctl stop maskedip.service` |
| Start | `sudo systemctl start maskedip.service` |
| Change interval | `sudo maskedip --set-interval 120` |
| Full status + IP check | `sudo maskedip --status` |

## ⚠️ Important: how it works

MaskedIP changes your **Tor exit IP**. It does **not** change the IP of your whole system. Only traffic that goes through Tor's SOCKS proxy (`127.0.0.1:9050`) gets the masked IP:

```bash
# curl
curl --socks5-hostname 127.0.0.1:9050 https://api.ipify.org

# any command via proxychains (set "socks5 127.0.0.1 9050" in proxychains.conf)
proxychains4 firefox

# browser: Settings -> Network -> SOCKS5 proxy 127.0.0.1:9050, tick "Proxy DNS"
```

Use `--socks5-hostname` / "Proxy DNS" so DNS lookups also go through Tor and do not leak.

## 🔐 Security notes

- Some websites block Tor exit nodes.
- Connection speed is slower than a direct connection.
- Tor rate-limits identity changes, so the minimum interval is 10 seconds.
- Rotating often breaks logged-in sessions, because the site sees a new IP each time.
- Always use HTTPS for sensitive data. Exit nodes can see unencrypted traffic.
- Tor reduces tracking but is not magic: do not log in to accounts tied to your real identity.
- Use this tool only for lawful purposes. Do not use it to evade bans, attack systems, or abuse services.

## 🛠️ Troubleshooting

| Problem | Fix |
|---------|-----|
| `Tor control cookie not found` | Run with `sudo`; check `systemctl status tor` |
| IP does not change | Make sure your app uses the SOCKS proxy; wait 10+ seconds between rotations |
| Exit IP unchanged after a rotation | Tor sometimes reuses an exit; the next rotation usually differs |
| `--status` shows Tor IP = real IP | Traffic is not going through Tor |

## 🗑️ Uninstall

```bash
chmod +x uninstall.sh
./uninstall.sh
```

This removes the service, config and binary, and only the lines MaskedIP added to `torrc`.

## 📁 Project layout

```
maskedip/
├── maskedip.sh      # main tool (run without installation)
├── setup.sh       # installs the systemd service
├── uninstall.sh   # clean removal
├── LICENSE
└── README.md
```

## 📄 License

MIT. Made by ARYAN PARASHAR ([@r1charyan](https://github.com/r1charyan)). See [LICENSE](LICENSE).
