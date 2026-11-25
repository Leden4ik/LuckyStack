# LuckyStack

[По-русски](README.md)

An installer for a hosting server on ISPConfig. It sets up nginx, PHP, MariaDB, mail,
DNS, FTP, certificates and the panel itself, and then it stays on the server and helps
you look after it: updates, backups, security.

It started with the HowtoForge guide "The Perfect Server", which I used to follow by
hand to build servers. Doing it by hand takes long and every time you forget something,
so the guide turned into a step-by-step wizard. Then it grew the extras I no longer want
to live without: a maintenance panel right inside ISPConfig, Telegram notifications,
CrowdSec, backups with restore from the panel and so on.

Documentation with examples: https://luckystack.luckyman.name/en/

The console speaks Russian and English. The wizard asks for the language on the first
run, and you can switch any command with `--lang en`, for example `luckyctl --lang en check`.
The ISPConfig panels follow the language of the ISPConfig user, and notifications can be
in English too (Add-ons → Notifications → Notification language).

## What gets installed

- nginx built from source: HTTP/3, Brotli and zstd, a fresh OpenSSL. You pick the build
  profile in the wizard or tick the modules by hand.
- Several PHP versions at once (7.4 to 8.6 from the Sury repository), FPM and OPcache.
- MariaDB from its official repository or from the system packages, Redis if you want it.
- Mail: Postfix, Dovecot, Rspamd, ClamAV, Roundcube.
- DNS on BIND, FTP on PureFTPd with quotas.
- Let's Encrypt certificates, including a real certificate for the server name itself
  (panel and mail).
- Protection: CrowdSec or UFW, fail2ban, a malware scan.
- Monit, Node.js, phpMyAdmin, PostgreSQL with pgAdmin if you want them.
- ISPConfig, a fresh build of the development branch by default, stable if you prefer.

Everything except the base is a checkbox in the wizard.

Apache is hidden in the wizard for now. With it you only get the base, without the
extras, so full Apache support will come in a later release.

## What comes on top

- A maintenance panel in ISPConfig: updates item by item, a backup before a core update,
  rollback of nginx and Roundcube, a server health check, buttons that fix the problems
  it finds.
- Notifications by email and Telegram. From the bot you can allow an IP (`/allow`) and see
  where it is banned (`/check`).
- CrowdSec and fail2ban panels: who is banned, lift a ban, a list of trusted IPs.
- Backups on a timer and restore from the panel.
- Vhost freeze: your edits in a site config survive when ISPConfig regenerates it.
- Auto-tuning of MariaDB, PHP and Postfix for the server's memory.

## Requirements

- A clean Debian 12 or 13, Ubuntu 22.04 or newer.
- root.
- At least 2 GB of RAM (nginx is compiled on the server) and a couple of gigabytes of disk.
- A server name like `server1.example.com`, ideally with an A record already.

Don't install it on a server where something already runs. The installer will notice and
offer safe options, but it is made for a clean system.

## How to install

The easiest way is one command:

```bash
curl -fsSL https://raw.githubusercontent.com/Leden4ik/LuckyStack/main/get.sh | sudo bash
```

It downloads the latest release, checks its signature and checksum and starts the
installer. If the signature doesn't match, nothing gets installed.

Or by hand:

```bash
curl -L https://github.com/Leden4ik/LuckyStack/archive/refs/heads/main.tar.gz | tar xz
cd LuckyStack-main
sudo bash server-setup.sh --lang en
```

A menu opens, then the wizard asks everything in order. First the installer copies itself
to `/opt/luckystack` and from then on runs from there.

If you want to see what it would do first, there is a demo run that changes nothing:

```bash
sudo bash server-setup.sh --lang en --dry-run
```

Building nginx and the first download of the ClamAV databases take a while, that's normal.
You can watch what happens in the log: `tail -f /var/log/luckystack/setup.log`.

## How to use it afterwards

After the install everything is done with the `luckyctl` command. Plain `luckyctl` opens
the same menu, and there are commands for common tasks:

```bash
luckyctl status                # what is installed and which versions
luckyctl check                 # server health check
luckyctl cve                   # whether security fixes are out for nginx, PHP and Roundcube
luckyctl blacklist             # whether the IP and mail domains are on blacklists
luckyctl sites                 # how every site and the panel respond
luckyctl changes               # which files the installer changed and when
luckyctl update                # update packages and reapply our settings
luckyctl update nginx          # rebuild nginx on a fresh version
luckyctl rollback nginx        # bring back the previous nginx build
luckyctl backup                # make a backup now
luckyctl add-php 8.4           # add a PHP version
luckyctl log                   # tail of the log
luckyctl help                  # all commands
```

Most of this can also be done from the ISPConfig panel, in the "Add-ons" menu.

## Where things are

```
/opt/luckystack/current          code of the running release (previous ones next to it, for rollback)
/etc/luckystack/setup.conf       wizard answers and passwords, root only
/var/lib/luckystack/setup.state  which stages are done
/var/log/luckystack/setup.log    log
```

`setup.conf` holds generated passwords, don't publish it anywhere.

At the end of the install all the logins are on the screen. Change the ISPConfig `admin`
password right away.

## If something goes wrong

If a stage fails, the installer shows the last lines of the log and offers to retry, skip
or exit. You can continue later from the same place: `luckyctl install --resume`.

If the nginx build fails again and again, a clean build without leftovers from earlier
attempts helps: `luckyctl install --clean-build --only webserver`.

All options, stages and settings are described in [DOCUMENTATION.md](DOCUMENTATION.md)
(in Russian) and on the [site](https://luckystack.luckyman.name/en/docs.html) (in English),
the first steps after the install in [GETTING-STARTED.md](GETTING-STARTED.md).

## Important

The script installs packages and changes system settings: fstab, firewall, systemd,
service configs. Try it on a test server before a production one.

## Versions and updates

Every version is a release on GitHub, what changed is in [CHANGELOG.md](CHANGELOG.md).
To see what is installed, whether there is something newer, and to update:

```bash
luckyctl version
luckyctl self-update
```

The update puts the new version next to the old one, you can go back with
`luckyctl rollback luckystack`. It doesn't touch the server settings, the new things that
concern the server itself are applied by `luckyctl update`.

## License

MIT, the full text is in [LICENSE](LICENSE). Use it, change it and build it into anything,
just keep the copyright line.
