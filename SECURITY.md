# Security

Atmovio runs with root privileges on the Raspberry Pi (it manages Docker, disks and WireGuard) and
serves its UI over plain HTTP. It is designed for a **trusted home network or a VPN**, not for the open internet.

## Do

- keep port 80 (Atmovio), 8971 (Frigate), 9090 (Cockpit) and 9443 (Portainer) reachable only from your LAN/VPN;
- use the outbound [webhook](docs/webhook.md) or your router's VPN when you want to look at cameras from outside;
- use a long admin password (12+ characters – the app enforces it) and long random tokens for the webhook and API keys;
- keep the Raspberry Pi OS updated (Cockpit → Software updates).

## Do not

- port-forward Atmovio or Frigate to the internet;
- share `INSTALL-INFO.txt`, `config.json` or logs without removing passwords/tokens.

## Reporting a vulnerability

Please do not open a public issue for security problems. E-mail the maintainer (see the GitHub profile)
with a description and, if possible, steps to reproduce. You will get an answer within a few days; fixes are
released as a new `update-atmovio.sh`.
