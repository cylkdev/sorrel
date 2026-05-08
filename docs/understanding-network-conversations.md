# Understanding Network Conversations

This document is a primer on the three shapes a conversation between two
computers can take — a plain HTTP exchange, a raw TCP socket, and an
HTTP-to-something-else *tunnel* — and on how the Sorrel library in this
repository implements each one.

It is in two parts. **Part 1** explains the three flows at a generic
network level, with no Elixir and no Sorrel. **Part 2** walks through
how Sorrel does each one in practice — which function to call, which
transport runs underneath, which headers go on the wire, and what the
caller gets back. A reader new to networking can read Part 1 first; a
reader new to Sorrel can read both in order.

---

# Part 1 — The three flows, in general

## Background

A network conversation between two computers starts with a **TCP
connection** — a two-way pipe of bytes that one computer (the client)
opens to another (the server). TCP only delivers raw bytes from one end
to the other in order. It does not know what those bytes mean; whatever
meaning they carry comes from a higher-level protocol layered on top.
Some applications skip standard protocols entirely and define the
meaning of those bytes themselves — this is what people mean when they
talk about a **raw socket** or **TCP socket** connection.

**HTTP** is one such higher-level protocol. It defines a strict text
format the bytes must follow. The client sends a *request* — a method
and path on the first line (such as `GET /items`), then named headers,
then a blank line, then an optional body. The server sends a *response*
in the same shape — a status code on the first line (such as `200 OK`),
then headers, blank line, body. Once the response is delivered, the
HTTP exchange is over. The TCP connection it ran on is still physically
open, but HTTP either closes it or keeps it idle until the next request
reuses it.

A **tunnel** is a way to stop using a TCP connection for HTTP and start
using it for something else, without closing the connection or opening
a new one. The two sides agree to the switch through a normal HTTP
exchange: the client sends a request that includes an `Upgrade` header
asking for a different protocol, and the server agrees by replying
`101 Switching Protocols`. After that response, neither side parses
bytes on this connection as HTTP anymore. The connection becomes a raw
byte channel — both sides read and write whatever the new protocol
calls for. In other words, a tunnel begins as HTTP and ends as a raw
socket on the same TCP connection.

This handshake is how protocols like WebSocket connect. They need a
long-lived, bidirectional byte channel that HTTP's
one-request-then-one-response shape cannot give them, but they want to
reuse the same hostname, port, routing, and authentication as the
website. Wrapping the handshake in HTTP solves both problems at once.

## Typical HTTP lifecycle

```
Client                                  Server
  |                                        |
  |  (1) TCP connect                       |
  |--------------------------------------->|
  |                                        |
  |  (2) HTTP/1.1 request                  |
  |--------------------------------------->|
  |                                        |
  |                     (3) read + process |
  |                                        |
  |              (4) HTTP/1.1 response     |
  |<---------------------------------------|
  |                                        |
  |  (5) read status + headers + body      |
  |                                        |
  |  (6) close, or keep-alive for reuse    |
  |- - - - - - - - - - - - - - - - - - - ->|
  |                                        |
```

1. The client opens a TCP connection to the server's address and port.

2. The client sends an HTTP/1.1 request — a method, path, and headers,
   ending in a blank line:

   ```http
   GET /items HTTP/1.1
   Host: example.com
   ```

3. The server reads the full request and runs whatever handler matches
   the path.

4. The server sends an HTTP response — a status line, headers, blank
   line, and body:

   ```http
   HTTP/1.1 200 OK
   Content-Type: application/json
   Content-Length: 16

   {"items":[...]}
   ```

5. The client reads the response in full: the status line tells it what
   happened, the headers describe the body, and the body is the actual
   payload.

6. The exchange is complete. The connection is either closed or held
   idle for the next request between the same two peers (this is called
   *keep-alive*).

## Typical socket lifecycle

```
Client                                  Server
  |                                        |
  |  (1) TCP connect                       |
  |--------------------------------------->|
  |                                        |
  |  (2) raw byte exchange                 |
  |      meaning defined by the app        |
  |<======================================>|
  |<======================================>|
  |                                        |
  |  (3) connection stays open until       |
  |      either peer or the network closes |
  |- - - - - - - - - - - - - - - - - - - ->|
  |                                        |
```

1. The client opens a TCP connection to the server's address and port.
   This is the same TCP handshake that an HTTP exchange performs — TCP
   itself does not know which protocol, if any, will be layered on top.

2. From the first byte onward, both sides exchange whatever bytes the
   application's own protocol defines. There is no standard
   request/response shape, no headers, and no status codes. Either side
   may send at any time, in any direction, in whatever order the
   protocol allows. Custom binary protocols, database wire protocols,
   and message buses all use the connection this way.

3. The connection stays open until the client closes it, the server
   closes it, or the network drops it. There is no built-in notion of
   an exchange being "complete" — that is a decision the application
   makes.

## Tunnel lifecycle

This walk-through uses the **WebSocket** handshake as its concrete
example, because WebSocket is the most common reason an application
performs an HTTP-to-something-else upgrade. The shape is the same for
any upgrade — only the header values change.

```
Client                                  Server
  |                                        |
  |  (1) TCP connect                       |
  |--------------------------------------->|
  |                                        |
  |  (2) HTTP/1.1 request, Upgrade header  |
  |--------------------------------------->|
  |                                        |
  |                     (3) read + decide  |
  |                                        |
  |  (4) HTTP/1.1 101 Switching Protocols  |
  |<---------------------------------------|
  |                                        |
  |  (5) HTTP conversation ends            |
  |      TCP connection remains open       |
  |======================================= |
  |                                        |
  |  (6) same TCP connection, new protocol |
  |                                        |
  |  (7) upgraded protocol traffic         |
  |<======================================>|
  |<======================================>|
  |                                        |
  |  (8) connection stays open until       |
  |      either peer or the network closes |
  |- - - - - - - - - - - - - - - - - - - ->|
  |                                        |
```

1. The client opens a TCP connection to the server's address and port.
   This is identical to the typical HTTP case — TCP itself does not
   know an upgrade is coming.

2. The client sends an HTTP/1.1 request and adds the headers that ask
   the server to switch protocols. `Connection: Upgrade` tells the
   server the next header carries upgrade instructions; `Upgrade:`
   names the protocol the client wants. WebSocket also requires
   `Sec-WebSocket-Key` (a fresh random 16-byte value, base64-encoded)
   and `Sec-WebSocket-Version: 13`:

   ```http
   GET /chat HTTP/1.1
   Host: example.com
   Upgrade: websocket
   Connection: Upgrade
   Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
   Sec-WebSocket-Version: 13
   ```

3. The server reads the request and decides whether it can speak the
   requested protocol. If not, it responds with a normal HTTP status
   (such as `400` or `426`) and the conversation ends like a typical
   HTTP exchange. If it can, it continues to step 4.

4. The server confirms the switch with `101 Switching Protocols` and
   echoes back proof that it actually understood the handshake — a
   value called `Sec-WebSocket-Accept`, derived from the key the
   client sent. This is the last HTTP message ever sent on this
   connection:

   ```http
   HTTP/1.1 101 Switching Protocols
   Upgrade: websocket
   Connection: Upgrade
   Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
   ```

   **How `Sec-WebSocket-Accept` is computed.** The server takes the
   `Sec-WebSocket-Key` value the client sent, appends a fixed
   well-known string (the WebSocket "magic GUID"
   `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`), takes the SHA-1 hash of
   that concatenation, and base64-encodes the result. With the example
   key above:

   ```
   key:   dGhlIHNhbXBsZSBub25jZQ==
   guid:  258EAFA5-E914-47DA-95CA-C5AB0DC85B11
   input: dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11
   sha1:  b3 7a 4f 2c c0 62 4f 16 90 f6 46 06 cf 38 59 45 b2 be c4 ea
   accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
   ```

   The client recomputes the expected value the same way and compares.
   The point of this dance is to prove the server is actually a
   WebSocket-aware server, not an HTTP server that happened to send
   `101` for unrelated reasons.

5. The HTTP conversation is over. Neither side will parse another HTTP
   request or response on this connection. The TCP connection remains
   physically open.

6. The same TCP connection is now used for the upgraded protocol. No
   new connection is opened — the bytes simply have a different
   meaning from this point on.

7. The client and server exchange whatever bytes the upgraded protocol
   defines, in whatever direction and order it allows. WebSocket, for
   example, lets either side send a message at any time, with no
   concept of request and response. The exact layout of those bytes
   (frame headers, payload masking, ping/pong, close handshake) is
   defined by the WebSocket spec and is out of scope for this
   document — what matters here is that *HTTP is done* and the
   connection is now a raw byte channel.

8. The connection stays open until the client closes it, the server
   closes it, or the network drops it.

## Where the three flows diverge

| Stage                  | Socket                                          | HTTP                                                  | Tunnel                                                                       |
| ---------------------- | ----------------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------- |
| Open TCP               | yes                                             | yes                                                   | yes                                                                          |
| Initial framing        | none — raw bytes from the first byte            | HTTP/1.1 request from the client                      | HTTP/1.1 request **with `Connection: Upgrade` and `Upgrade:`**               |
| Server's first reply   | none standard — server replies in the app's own format | HTTP/1.1 response                              | `101 Switching Protocols` — the last HTTP message on the connection          |
| After the first reply  | continued raw bytes in both directions          | exchange complete; connection closed or kept idle     | raw bytes for the upgraded protocol, in both directions                      |
| Termination            | client, server, or network closes               | closed, or held idle for the next request             | client, server, or network closes                                            |

The TCP connect stage is the only one that is truly identical across
all three: the TCP handshake does not depend on what, if anything, will
be layered on top. After that, each flow follows its own rules.

The tunnel is what makes the three flows worth comparing in one
document. Its first half is HTTP — request, headers, status code — and
its second half is a raw socket — bidirectional bytes whose meaning is
defined by the upgraded protocol. The HTTP half supplies the routing,
authentication, and protocol negotiation that come for free with a
familiar HTTP endpoint; the socket half supplies the freedom to carry
whatever long-lived, bidirectional exchange the new protocol needs.
Seen together, a tunnel is not a third kind of conversation — it is the
first half of the HTTP flow joined to the second half of the socket
flow on a single TCP connection.

The rest of this document describes how Sorrel — the library this
repository implements — performs each of these three flows in practice.

---

# Part 2 — How Sorrel implements these flows

## 2.1 Sorrel at a glance

Sorrel is a small Elixir HTTP/1.1 client. It does **not** implement
HTTP/1.1 itself: under the hood it uses the [`Mint`](https://github.com/elixir-mint/mint)
library (declared in `mix.exs:44` as `{:mint, "~> 1.7"}`) for the HTTP
framing, and adds three things on top:

1. A pluggable **transport** layer — Sorrel can run HTTP/1.1 over a
   Unix-domain socket, a TCP connection (with optional TLS), or an
   SSH-forwarded byte stream.
2. A **connection pool** so callers can issue many requests against
   the same endpoint without reopening connections.
3. Three **top-level functions**, each one a specialised version of
   one of the Part 1 flows:

| Flow from Part 1 | Sorrel function       | What you get back                                  | Source                                |
| ---------------- | --------------------- | -------------------------------------------------- | ------------------------------------- |
| HTTP             | `Sorrel.request/5`    | `{:ok, response}` for 2xx, `{:error, response}` for 4xx/5xx | `lib/sorrel.ex:415`           |
| HTTP, streaming  | `Sorrel.stream/5`     | `{:ok, Stream.t()}` — a lazy stream of body events | `lib/sorrel.ex:579`                   |
| Tunnel           | `Sorrel.tunnel/5`     | `{:ok, socket, leftover}` — a raw byte channel     | `lib/sorrel.ex:711`                   |

All three take the same first argument: a `%Sorrel.Endpoint{}` struct
that describes *where* to connect. The endpoint is what makes the
transport layer pluggable — the same three functions work whether the
endpoint resolves to a Unix socket, a TCP host, or an SSH tunnel.

## 2.2 Three transports, one API

Sorrel exposes three transports. The endpoint struct chooses between
them, usually built from a URL via `Sorrel.Endpoint.parse/2`
(`lib/sorrel/endpoint.ex:201`):

| Transport     | URL form                              | What "TCP connect" means here                             | Source                          |
| ------------- | ------------------------------------- | --------------------------------------------------------- | ------------------------------- |
| Unix          | `unix:///var/run/docker.sock`         | Open an `AF_UNIX` socket to a path on the local filesystem. No host, no port, no TLS. | `lib/sorrel/transport/unix.ex` |
| TCP / TLS     | `http://host:8080`, `https://host`    | Open an `AF_INET` / `AF_INET6` socket to host:port. If `https://`, perform a TLS handshake before sending HTTP. | `lib/sorrel/transport/tcp.ex` |
| SSH-forwarded | (no URL form — built via `Endpoint` with a `target:` option) | Open an SSH connection, then open a *channel* inside it that proxies bytes to one of: a remote command's stdio (`{:exec, cmd}`), a remote TCP target (`{:tcp, h, p}`), or a remote Unix socket (`{:unix, path}`). | `lib/sorrel/transport/ssh.ex` |

The "TCP connect" step from Part 1 is the only stage that meaningfully
differs across these. Once the transport delivers a byte stream, every
layer above it — Mint's HTTP/1.1 framing, Sorrel's pool, the three
top-level functions — runs the same way regardless of which transport
is underneath.

The schemes `Sorrel.Endpoint.parse/2` accepts (per
`lib/sorrel/endpoint.ex:215-221`):

| Scheme prefix              | Result                                                                    |
| -------------------------- | ------------------------------------------------------------------------- |
| `unix:///path`             | Unix endpoint pointing at the socket file at `/path`.                     |
| `tcp://host[:p]`           | TCP endpoint, `scheme: :http`, port defaults to **80**.                   |
| `http://host[:p]`          | TCP endpoint, `scheme: :http`, port defaults to **80**.                   |
| `https://host[:p]`         | TCP endpoint, `scheme: :https`, port defaults to **443**.                 |
| `ssh://[user@]host[:p]`    | SSH endpoint, port defaults to **22**. The caller must supply `:target` (and may supply `:ssh` and `:user`) via the `options` argument. |

`parse/2` never reads certificate files. If the caller wants TLS
verification, they fill in the `:tls` field on the returned struct
themselves before passing it on.

## 2.3 Sorrel's HTTP flow — `Sorrel.request/5`

```
Caller                Sorrel.request/5         Pool worker        Mint           Server
  |                         |                       |              |               |
  |  request(endpoint, ...) |                       |              |               |
  |------------------------>|                       |              |               |
  |                         |  Pool.checkout/3      |              |               |
  |                         |---------------------->|              |               |
  |                         |                       |              |               |
  |                         |                       | (idle conn   |               |
  |                         |                       |  switched    |               |
  |                         |                       |  to passive) |               |
  |                         |                       |              |               |
  |                         |                       | Mint.HTTP.request/4          |
  |                         |                       |------------->|--- HTTP req ->|
  |                         |                       |              |               |
  |                         |                       |              |<-- HTTP resp -|
  |                         |                       | Mint.HTTP.recv/3 (loop)      |
  |                         |                       |<-------------|               |
  |                         |  {:ok, response}      | (conn        |               |
  |                         |  or {:error, resp}    |  back to     |               |
  |                         |<----------------------|  active mode)|               |
  |<------------------------|                       |              |               |
```

1. The caller invokes `Sorrel.request(endpoint, method, path, body, options)`.
   The function head pattern-matches on `%Endpoint{}` — anything else
   raises `FunctionClauseError` rather than returning an error tuple
   (`lib/sorrel.ex:711` shows the same pattern in `tunnel/5`).

2. Sorrel checks out a worker from a pool. Pools are keyed by
   *endpoint signature* (e.g. `{:unix, "/var/run/docker.sock"}` or
   `{:tcp, :https, "host", 443, tls_sig}`), and the first call to a
   new endpoint lazily creates a pool of `:pool_size` workers (default
   **10**, see `lib/sorrel/pool.ex:121`).

3. The worker (`lib/sorrel/pool/worker.ex`) holds a Mint connection in
   *active* mode while idle — meaning Erlang messages drain into the
   worker process so it can notice if the server hangs up. When
   checked out, the worker switches the connection to *passive* mode
   so the calling process can drive `Mint.HTTP.recv/3` directly.

4. `Sorrel.Conn.request/6` (`lib/sorrel/conn.ex:188`) calls
   `Mint.HTTP.request/4` to send the request, then loops on
   `Mint.HTTP.recv/3` until the full response is buffered.

5. The result is one of:

   - `{:ok, response}` — the server returned 2xx.
   - `{:error, response}` — the server returned 4xx or 5xx. The HTTP
     exchange itself succeeded; Sorrel surfaces the
     application-level outcome via `:ok` / `:error`, not the
     protocol-level outcome.
   - `{:error, reason}` — a transport or protocol failure (the
     connection dropped, the response was malformed, etc.).

6. The worker is checked back in. The connection returns to active
   mode and is reusable. If it sits idle longer than
   `:conn_max_idle_time` (default **30,000 ms**, see
   `lib/sorrel/pool.ex:122`), it is dropped and a fresh one will
   open on the next checkout. **Sorrel does not multiplex** — one
   request at a time per connection.

## 2.4 Sorrel's streaming flow — `Sorrel.stream/5`

`stream/5` is for HTTP responses that are long-running sequences of
events rather than a single payload — newline-delimited JSON event
streams, log tails, server-sent-style feeds. It is still a single HTTP
exchange (one request, one response); the response body just arrives
over time instead of all at once.

Two behaviours differ from `request/5`:

- **No pooling.** `stream/5` opens its own connection per call rather
  than checking one out (`lib/sorrel/stream_session.ex`,
  `lib/sorrel/stream_session/impl.ex`). The session is a `GenServer`
  linked to the caller. Once the response head is read, the
  underlying socket is put into active mode and body chunks arrive as
  Erlang messages routed into the session.

- **Decoded events, not raw bytes.** The `:into` option chooses how
  the incoming chunks are turned into Stream elements
  (`lib/sorrel/stream_session.ex:97`):

  | `:into` value | What each Stream element is                                |
  | ------------- | ---------------------------------------------------------- |
  | `:ndjson` (default) | One JSON value per line. Sorrel splits arriving bytes on `\n` and JSON-decodes each line. Typical use: Docker `/events`, log streams. |
  | `:raw`              | One binary chunk per element, exactly as it arrived from the socket. The caller does its own framing. |

Iterating the returned `Stream.t()` is what drives the GenServer; the
exchange ends when the iteration ends or when the server closes the
response body.

## 2.5 Sorrel's tunnel flow — `Sorrel.tunnel/5`

This is where Sorrel's behaviour diverges from the *generic* tunnel
flow described in Part 1. The shape is the same — HTTP request with
upgrade headers, `101` (or in Sorrel's case, `200`) reply, raw bytes
afterwards — but the specifics differ in three ways worth knowing.

### The headers Sorrel sends

`Sorrel.Tunnel.Handshake.upgrade/4` builds these base headers
(`lib/sorrel/tunnel/handshake.ex:254-266`):

```
host: localhost
upgrade: tcp
connection: Upgrade
content-type: application/json
content-length: <body length>
```

Two things to notice:

1. **`Upgrade: tcp` is not WebSocket.** Sorrel implements the
   *generic* HTTP/1.1 Upgrade mechanism, not the WebSocket-specific
   one. The token `tcp` is a placeholder that says "after this point,
   speak whatever raw protocol both sides have agreed on out of
   band." If a caller wants to perform a real WebSocket handshake —
   with `Upgrade: websocket`, `Sec-WebSocket-Key`,
   `Sec-WebSocket-Version`, and `Sec-WebSocket-Accept` validation —
   they pass those headers themselves via `options[:headers]`, and
   they validate the server's `Sec-WebSocket-Accept` themselves on
   the returned socket. Sorrel will not generate or check those
   values for them.

2. **`Host: localhost` is hard-coded.** This is fine over a Unix
   socket (where the hostname has no meaning) and acceptable for
   typical tunnel targets like the local Docker daemon. Callers who
   need a different `Host` value can override it via
   `options[:headers]`.

### The status codes Sorrel accepts

`Sorrel.Tunnel.Handshake.check_status/2`
(`lib/sorrel/tunnel/handshake.ex:355-366`) treats the upgrade as
successful on either of:

- `101 Switching Protocols` — the standard HTTP/1.1 upgrade response.
- `200 OK` — the response shape used by the Docker engine's
  `/containers/{id}/attach` endpoint, which "hijacks" the
  connection without going through `101`.

Any other status returns `{:error, %{status: code, body: body}}` and
the connection is closed.

### What the caller gets back

On success, `Sorrel.tunnel/5` returns `{:ok, socket, leftover}`
(`lib/sorrel.ex:670-678`):

- `socket` is the underlying transport socket — a `:gen_tcp.socket()`
  for plain Unix or TCP, or a `:ssl.sslsocket()` for HTTPS. It is
  switched to passive mode with `packet: :raw`
  (`lib/sorrel/tunnel/handshake.ex:240`).
- `leftover` is any bytes that were already buffered past the response
  head when the upgrade completed. The caller **must consume
  `leftover` first**, then start reading from the socket — otherwise
  those bytes are lost.

After this point Sorrel does no parsing. There is no WebSocket frame
parser, no Docker stdio demuxer, no length-prefix logic.
`Sorrel.Tunnel.Socket` (`lib/sorrel/tunnel/socket.ex`) only provides
thin `send/2`, `recv/3`, and `close/1` helpers that pick between
`:gen_tcp` and `:ssl` based on the socket type. Whatever protocol
runs on top of the upgraded connection is the caller's responsibility.

### Worked example: attach to a Docker container

```elixir
{:ok, endpoint} = Sorrel.Endpoint.parse("unix:///var/run/docker.sock")

{:ok, socket, leftover} =
  Sorrel.tunnel(
    endpoint,
    :post,
    "/v1.43/containers/abc123/attach?stream=1&stdout=1&stderr=1",
    ""
  )

# `leftover` contains any container output bytes that arrived before
# the upgrade completed. Consume those first, then read more from the
# socket directly.

# When done, close it explicitly — the caller owns the socket.
:ok = Sorrel.Tunnel.close(socket)
```

This is the canonical use case for `tunnel/5`: Docker's `/attach`
endpoint replies with `200`, hijacks the connection, and starts
sending the container's multiplexed stdout/stderr over the raw
socket. Sorrel hands you the socket; demultiplexing the Docker stdio
frames is yours to do.

## 2.6 Putting it together

```
                        ┌──────────────────────────────────────┐
                        │         %Sorrel.Endpoint{}           │
                        │  parsed from a URL or built directly │
                        └─────────────────┬────────────────────┘
                                          │
              ┌───────────────────────────┼───────────────────────────┐
              │                           │                           │
        Unix socket                  TCP / TLS                  SSH-forwarded
   (lib/sorrel/transport/unix.ex)  (.../tcp.ex)            (.../ssh.ex)
              │                           │                           │
              └────────────────┬──────────┴───────────────────────────┘
                               │
                       byte stream from
                       the chosen transport
                               │
                               ▼
                         ┌─────────────┐
                         │    Mint     │   speaks HTTP/1.1
                         └──────┬──────┘
                                │
                ┌───────────────┼─────────────────────────┐
                │               │                         │
        Sorrel.request/5  Sorrel.stream/5         Sorrel.tunnel/5
        (Part 1: HTTP)    (Part 1: HTTP, with    (Part 1: tunnel —
                           a long-lived body)     HTTP-then-raw-bytes)
                │               │                         │
                ▼               ▼                         ▼
        {:ok, response}   {:ok, Stream.t()}        {:ok, socket,
        or {:error, _}    of decoded events         leftover}
                                                   (raw byte channel)
```

The three Sorrel functions are the three Part 1 flows, in order: a
plain HTTP exchange (`request/5`), a plain HTTP exchange whose body
streams over time (`stream/5`), and a tunnel that begins as HTTP and
becomes a raw socket (`tunnel/5`). The transport layer underneath
makes the same three functions work whether the other end of the
connection is a Unix socket on the local filesystem, a TCP host on the
internet, or a remote service reached through SSH.
