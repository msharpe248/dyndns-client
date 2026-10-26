# DynDNS client for macOS

A small, one-shot command line tool that updates an **existing** DynDNS hostname
to the IPv4 address of a named macOS network interface, or to an explicitly
supplied address. Private LAN addresses are accepted. It uses HTTPS and the
DynDNS update API.

## Build and install

Requires macOS 12 or newer and the Xcode Command Line Tools.

```sh
swift build -c release
./install.sh
```

The installer copies the release binary to `~/.local/bin/dyndns-client`. This
user-level location needs no administrator access. If `~/.local/bin` is not on
your `PATH`, add this line to `~/.zprofile` (for zsh) and open a new Terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Use `./install.sh --prefix /another/absolute/directory` to install into a
different `bin` directory. The installer leaves your config and saved update
state alone. If you already built the release binary, you can run just
`./install.sh`; build again before installing a new version.

### Run at login

After setting up `config.json` below, install a per-user LaunchAgent:

```sh
./install.sh --launch-agent
```

This creates or replaces `~/Library/LaunchAgents/local.dyndns-client.plist`
with a job pointing to the installed executable. If the job is already loaded,
the installer reloads it when the plist changes. The job may run immediately
when first loaded or reloaded. Existing custom settings in this client's plist
are replaced; other LaunchAgents are left alone. Output goes to
`~/Library/Logs/dyndns-client.log` and
`~/Library/Logs/dyndns-client.error.log`.

The agent runs once when you log in, including after a reboot. It does not run
before login or continuously track later IP changes. Use this option without
`sudo` so it is installed for your user account. You can combine it with
`--prefix` if you install the binary elsewhere.

## Configure

Copy the [example config](config.example.json) to the per-user config path, edit
its values, and restrict access because it contains your credential:

```sh
mkdir -p "$HOME/Library/Application Support/dyndns-client"
cp config.example.json "$HOME/Library/Application Support/dyndns-client/config.json"
chmod 600 "$HOME/Library/Application Support/dyndns-client/config.json"
```

Use the [Dyn updater client key](https://help.dyn.com/getting-started-with-remote-access.html)
as the `password` value when your account requires it. The config fields are
`hostname`, `username`, `password`, and `interface`. The interface should be the
one whose IPv4 address you want to publish, such as `en0`.

## Run

With a complete config file:

```sh
dyndns-client
```

Each command line option overrides the matching config field. For example:

```sh
dyndns-client --interface en1
dyndns-client --ip 192.168.1.207
dyndns-client --hostname other.example.com
```

An explicit `--ip` takes precedence over interface lookup. Use `--config FILE`
to load a different config file. You can still provide all values on the command
line with `--hostname`, `--username`, `--password`, and either `--interface` or
`--ip`. A missing default config is allowed when all required values are given
on the command line. Passing the key on the command line exposes it in shell
history and process listings.

For local-only use, select the interface with the machine's LAN IPv4 address.
Dyn publishes the hostname in public DNS, but a private address such as
`192.168.1.207` is only reachable from your LAN. If a request times out, check
DNS and outbound HTTPS connectivity to `members.dyndns.org` on port 443. A
timed-out request may have reached Dyn, so verify the record before retrying.

The tool prints whether Dyn changed the address, reports specific Dyn errors, and
exits with a nonzero status on failure. It stores the last successful IP per
account and hostname in `~/Library/Application Support/dyndns-client/updates.json`
and skips a repeated update to the same IP. Use `--force` only to resynchronize a
hostname after its record has changed elsewhere. Dyn may block clients that
repeatedly submit an unchanged IP.

This version accepts IPv4 only, creates no hostnames, and does not run on a
schedule. Run it again after the interface's address changes.

## Test

```sh
swift test
```

Protocol: [Dyn update request](https://help.dyn.com/perform-update.html),
[return codes](https://help.dyn.com/return-codes.html), and
[client policies](https://help.dyn.com/policies.html).
