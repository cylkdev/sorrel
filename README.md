# Sorrel

A small Elixir HTTP/1.1 client for talking to servers over Unix sockets,
TCP, or SSH-forwarded byte streams, with optional TLS. Sorrel gives you
direct control over a single connection — three functions and one
struct — and stays out of the way of higher-level concerns like
authentication, API versioning, and retries.

## Transports

- **Unix socket** — `unix:///tmp/myapp.sock`. The path *is* the
  address; no host, no port, no TLS.
- **TCP** (with optional TLS) — `http://host:port` or
  `https://host:port`. TLS configuration is yours to provide; Sorrel
  never reads certificate files implicitly.
- **SSH-forwarded** — connect to a remote process's stdio (`{:exec, …}`),
  a remote TCP target (`{:tcp, host, port}`), or a remote Unix socket
  (`{:unix, path}`) over an SSH channel.

## Quick example

```elixir
{:ok, endpoint} = Sorrel.Endpoint.parse("unix:///tmp/myapp.sock")
{:ok, response} = Sorrel.request(endpoint, :get, "/healthz")
response.status     #=> 200
response.body       #=> "ok"
```

The same `endpoint` struct works with all three top-level functions:

| Function     | Use when                                                                              |
| ------------ | ------------------------------------------------------------------------------------- |
| `request/5`  | One request, one response. The whole body fits in memory.                              |
| `stream/5`   | The response is a long-running sequence of events (NDJSON, log tails).                 |
| `tunnel/5`   | The server replies `101 Switching Protocols` and you want raw bytes after the upgrade. |

The first call to a new endpoint lazily opens a small connection pool;
later calls reuse pooled connections automatically.

## What Sorrel deliberately does not do

Sorrel exposes primitives. It does **not** handle:

- **Authentication** — no automatic Basic/Bearer/digest headers. Add
  the header yourself via `options[:headers]`.
- **API versioning** — paths are sent verbatim.
- **Request multiplexing** — one request per connection at a time.
- **Retries, circuit breaking, backoff** — failures bubble up as
  `{:error, reason}`.

These belong in higher-level wrappers built on top of Sorrel.

## Installation

```elixir
def deps do
  [
    {:sorrel, "~> 0.1.0"}
  ]
end
```

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs
will be available at <https://hexdocs.pm/sorrel>.

## Optional Docker integration

Sorrel ships with an optional Docker convenience layer for the
`{:exec, "docker system dial-stdio"}` SSH target shape: a small
wrapper script and a Mix install task
(`mix sorrel.ssh.install_dial_stdio_script user@host`) that converts
non-zero `dial-stdio` exits into typed HTTP `502` responses. This is
the only Docker-aware piece of the library; everything else is
transport-agnostic. See `Sorrel.Transport.SSH.DockerDialStdio`
for the rationale and deployment recipe.
