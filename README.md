# tor-relay-vps

One readable script that turns an **Ubuntu or Debian VPS** into a **Tor middle / guard relay**, installed from the
official Tor Project repository. It is **never an exit relay**: the config always contains
`ExitRelay 0` and `ExitPolicy reject *:*`.

```bash
curl -fsSLO https://raw.githubusercontent.com/phantomvps/tor-relay-vps/main/tor-relay-vps.sh
less tor-relay-vps.sh              # read it first: it is short
sudo bash tor-relay-vps.sh --nickname MyRelay01 --contact "relay-admin@example.com" --bandwidth-rate "10 MB"
```

## What it does

| Step | Details |
|---|---|
| Repository | adds `deb.torproject.org` with a keyring in `/usr/share/keyrings/`; the key must have fingerprint `A3C4 F0F9 79CA A22C DBA8 F512 EE8C BC9E 886D DD89` |
| Install | `tor` and `deb.torproject.org-keyring` (keeps the key up to date) |
| Config | writes `/etc/tor/torrc` for a non-exit relay; the old file is saved once as `torrc.before-tor-relay-vps` |
| Check | `tor --verify-config` must accept the new config before it replaces the old one |
| Firewall | if `ufw` is active, opens the ORPort (TCP) |
| Service | enables and starts `tor@default`; restarts it only when the config changed |
| Output | relay fingerprint and the metrics.torproject.org link |

Running it again is safe: the relay identity keys in `/var/lib/tor/keys` are never touched, and tor is not
restarted when nothing changed.

## Options

| Option | Default | Meaning |
|---|---|---|
| `--nickname NAME` | required | 1-19 letters and digits, shown on Tor Metrics |
| `--contact TEXT` | required | e-mail or other contact, **published** in the relay descriptor |
| `--orport N` | `9001` | TCP port other relays connect to |
| `--bandwidth-rate V` | unlimited | average limit, e.g. `"10 MB"` (bytes/s) or `"100 Mbits"` |
| `--bandwidth-burst V` | unlimited | short peak limit (must be at least the rate) |
| `--no-publish` | off | run but do not announce the relay to the network (testing) |
| `--yes` | off | do not ask for confirmation |

**Why a contact is required:** the Tor Project and other relay operators use it to reach you if your relay is
misconfigured, out of date or under attack. A dedicated address is fine.

## Safety notes

- **Non-exit only.** A middle / guard relay passes encrypted traffic between Tor relays. It does not connect to
  websites on behalf of Tor users, so it does not receive the abuse complaints that exit relays get.
  Your server's IP will be listed publicly as a Tor relay, and some services block all relay IPs.
- Check your hosting provider's terms about Tor relays before you start, and watch monthly traffic: a relay
  can use a lot of bandwidth. Use `--bandwidth-rate` if your plan has a traffic limit.
- New relays get little traffic during the first weeks; the Guard flag usually comes after 8+ days of stable
  uptime. Keep the relay running and up to date.
- Back up `/var/lib/tor/keys`: it is the relay's identity. If you lose it, the relay starts over as a new one.
- Watch your relay at `https://metrics.torproject.org/rs.html#search/<fingerprint or nickname>` (about 3 hours
  after the first start) and in `journalctl -u tor@default -f`.

## Tested on

Every push runs on GitHub Actions on **Ubuntu 22.04 and 24.04** (with `--no-publish`, so CI runners never join the
real Tor network): bad input is refused; tor is installed from the Tor Project repository (checked with
`apt-cache policy`); the config contains `ExitPolicy reject *:*` and passes `tor --verify-config`; `tor@default` is
active and listening on 9001; ufw opens 9001/tcp; a second run must not restart tor or change its fingerprint;
changing a setting restarts tor and keeps the same identity. Debian 12 / 13 are supported by the script but not
tested in CI.

## Need a server?

Maintained by the team behind [PhantomVPS](https://phantomvps.com?ref=github): VPS and dedicated servers with root access,
no ID documents, paid with Monero, Bitcoin, Litecoin, USDT, USDC, SOL or TRX.
See [Tor relay hosting](https://phantomvps.com/tor-relay-hosting?ref=github).

## License

MIT
