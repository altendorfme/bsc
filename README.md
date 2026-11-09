# BSC (Base Server Config)

[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](bsc.sh)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![Debian](https://img.shields.io/badge/Debian-A81D33?logo=debian&logoColor=white)](https://www.debian.org)
[![License](https://img.shields.io/github/license/altendorfme/bsc)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/altendorfme/bsc)](https://github.com/altendorfme/bsc/commits)

Interactive script that prepares a fresh Ubuntu/Debian VPS/Cloud server!

## Usage

```bash
ssh -t ubuntu@IP
curl -fsSLO https://raw.githubusercontent.com/altendorfme/bsc/main/bsc.sh
sudo bash bsc.sh
```

Take a VM snapshot first and keep the session open until the end. The log goes to `/var/log/bsc.log` (passwords and private keys are left out), and when it finishes the script offers to delete itself from the server.

## What it does

Every step asks first, and almost all of them are optional.

- **System:** `apt upgrade`, base packages, timezone, and swap sized from the RAM.
- **User:** creates a sudo user with an optional password and an SSH key that is copied, pasted or generated.
- **SSH:** changes the port without losing access (works with `ssh.socket` and with OCI's iptables rules) and hardens the config through a drop-in.
- **Security:** UFW, Fail2ban, unattended-upgrades, kernel sysctl settings and persistent journald.
- **Apps:** Docker (with the ufw-docker fix), Tailscale, Dockhand and Hawser, each under `/opt/<app>/`.
- **Cleanup:** removes the cloud's default user (`ubuntu`, `opc`, `ec2-user`...) and the OCI, AWS, GCP, DigitalOcean, Alibaba, Tencent and Landscape agents. The Azure agent is never removed.

## Non-interactive mode**

```bash
sudo bash bsc.sh --yes \
  --user deploy --key copy:ubuntu --sudo-nopasswd \
  --swap 2G --ufw --ufw-ports 80,443 --fail2ban \
  --auto-updates --auto-reboot 04:00 \
  --docker --docker-group --remove-cloud-user
```

`--help` lists every flags.

> With `--yes`, the access test only checks that sshd answers locally, so it can't see the provider's firewall. Open the port in the Security List/Group before you use `--ssh-port`.

## License

[MIT](LICENSE)
