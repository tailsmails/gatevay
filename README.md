# gatevay

A lightweight, multi-gateway SOCKS5 proxy tool written in V. It routes outbound TCP/UDP traffic through specific local IP addresses or network interfaces.

---

## Features

* **Multi-Gateway Binding:** Maps distinct local ports to different outbound interfaces (IPs).
* **SOCKS5 Support:** Implements both TCP `CONNECT` and UDP `UDP ASSOCIATE` commands.
* **Dynamic Routing Alignment:** Resolves destination hosts using the matching IP family (IPv4/IPv6) of the bound outbound gateway to prevent routing conflicts.
* **Zero Runtime Dependencies:** Compiles into a single, standalone binary.

---

## Quick Install

```sh
apt update -y && apt install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/gatevay && cd gatevay && v -prod gatevay.v -o gatevay && ln -sf $(pwd)/gatevay $PREFIX/bin/gatevay
```

---

## Usage

Run the compiled binary by passing gateway IP and local port pairs:

```sh
gatevay <gateway_ip1>,<local_port1>,<gateway_ip2>,<local_port2>,...
```

### Examples

Route outbound traffic through a specific network adapter IP (`192.168.1.15`) on port `8888`:
```sh
gatevay 192.168.1.15,8888
```

Route through multiple gateways simultaneously:
```sh
gatevay 192.168.1.15,8888,192.168.1.16,9999
```

---

## Client Configuration & DNS

When system-wide proxy tools operate in Fake-IP mode (such as Clash or sing-box), local DNS resolution may return non-routable local IPv6 addresses (e.g., `fc00::/7`) or benchmark IPs (`198.18.0.0/15`). Because these addresses cannot be routed via standard outbound physical adapters, DNS resolution must be delegated to the proxy.

For `curl`, use the `socks5h://` scheme instead of `socks5://`:

```sh
curl -x socks5h://127.0.0.1:8888 https://duckduckgo.com
```
