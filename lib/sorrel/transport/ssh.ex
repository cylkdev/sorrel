defmodule Sorrel.Transport.SSH do
  @moduledoc """
  Opens an HTTP/1.1 connection that speaks to a remote process over an
  SSH-forwarded byte stream.

  `Mint.HTTP1.connect/4` only knows how to talk to `:gen_tcp` and `:ssl`
  sockets. To get HTTP/1.1 over an SSH channel without forking Mint, this
  transport interposes a **loopback bridge**:

      Mint  <───────────────>  Bridge  <─────────────>  remote
            127.0.0.1:port              SSH channel

  The transport opens an SSH connection, opens an SSH channel of the
  shape required by `endpoint.target`, hands ownership of both to a
  `Sorrel.Transport.SSH.Bridge` process, then asks Mint to connect
  to the bridge's loopback port. Mint sees a perfectly ordinary TCP
  socket and is none the wiser. The bridge stays alive after `connect/2`
  returns; it tears itself (and the SSH connection) down when the
  loopback socket closes -- which Mint does after the request completes,
  or which a caller of `Sorrel.tunnel/5` does when finished.

  ## When you would call this module yourself

  Most callers do not. `Sorrel.Transport.connect/2` looks at an
  endpoint's `:transport` field and forwards `:ssh` endpoints here
  automatically. Reach for `Sorrel.Transport.SSH.connect/2`
  directly only when you want to bypass the dispatcher (e.g. in a test).

  ## The three target shapes

  An `:ssh` endpoint always carries a `:target` field on the struct that
  describes what is on the far side of the SSH connection. Each shape
  picks a different SSH channel type. The choice has both functional
  and security consequences -- read each row's "Risk" entry before
  picking one.

    * `{:exec, command}` - `command` is `iodata()`. Opens a `session`
      channel and issues an `exec` request with `command`. The remote
      sshd starts the program; its stdout becomes the channel's
      payload bytes (stdin is fed by us). Use this for any remote
      command that speaks HTTP/1.1 on its stdio. `docker system
      dial-stdio` is one such command and ships with first-class
      support - see `Sorrel.Transport.SSH.DockerDialStdio`
      for the optional wrapper script. Any other stdio-HTTP command
      works too.

      **Risk - remote command injection.** `command` is sent verbatim
      to the remote sshd, which executes it in a shell context with
      the SSH user's privileges. If a caller builds `command` from
      untrusted input (a URL fragment, an environment variable
      controlled by another tenant, etc.), that caller has handed the
      attacker remote code execution on the SSH host. Treat `command`
      as a literal, hard-coded string under your control. If the
      command must be parameterised, build it server-side (e.g. via a
      shell wrapper installed on the SSH host) rather than letting
      callers pass arbitrary `iodata()`.

      **Risk - exit status is only surfaced before a response
      starts.** When the remote command exits *before* producing any
      bytes (e.g. `dial-stdio: not found`, exit 127), the transport
      surfaces this as `{:error, {:ssh_exec_failed, {:status, 127}}}`
      from `connect/2`. But once any byte has crossed toward Mint -
      either through the active socket or through the pre-accept
      buffer - a subsequent non-zero exit is **deliberately ignored**.
      Mint may already have parsed an HTTP response and surfaced it
      to the caller; inventing a late error would corrupt the
      caller's view. If you need mid-stream failure detection, do it
      at the HTTP layer (truncated body, mismatched
      Content-Length) or use a wrapper that converts non-zero exits
      into HTTP 5xx *before* stdout closes.

    * `{:tcp, host, port}` - opens a `direct-tcpip` channel that the
      sshd uses to make an outbound TCP connection to `host:port` and
      bridge bytes. Use this when an HTTP server is listening on a TCP
      port reachable from the SSH host but not from us.

      **Risk - the SSH host becomes a TCP relay.** The sshd will
      attempt to open a TCP connection to **whatever host:port the
      caller names**, not to a fixed allow-listed target. A caller
      with a valid SSH session can therefore use this transport to
      reach internal services on the SSH host's network that they
      could not otherwise touch (intranet web apps, metadata
      services, internal databases). The defense lives on the SSH
      server: configure `PermitOpen` in `sshd_config` to constrain
      direct-tcpip targets to a fixed list of host:port pairs, or
      disable forwarding entirely with `AllowTcpForwarding no` for
      this user.

    * `{:unix, path}` - opens a `direct-streamlocal@openssh.com`
      channel pointing at the Unix socket file at `path` on the SSH
      host. This is the OpenSSH extension OpenSSH itself implements;
      the OTP `:ssh` daemon does **not** implement it (so this target
      will fail against an Erlang-based SSH server). Use this when an
      HTTP server is listening on a Unix socket on the SSH host (a
      Unix-domain HTTP socket reachable from the SSH host - the
      Docker daemon's `/var/run/docker.sock` is a typical case).

      **Risk - the SSH host becomes a Unix-socket relay.** Same
      shape as `{:tcp, ...}` but for Unix sockets. A caller can ask
      the sshd to open **any** socket file the SSH user has rights to
      read/write, including ones that confer privileged access (the
      Docker socket effectively grants root, but the same caution
      applies to any privileged Unix-socket service: kubelet,
      container runtimes, init managers, etc.). The defense lives on
      the SSH server: `PermitOpen` does not cover streamlocal, but
      `AllowStreamLocalForwarding no` does, and OpenSSH's
      `PermitListen`/`PermitOpen` style allow-lists for streamlocal
      arrived in OpenSSH 6.7+ (`StreamLocalBindUnlink`,
      `AllowStreamLocalForwarding`). Confirm the relevant directives
      against the OpenSSH version you run.

  ## What this module returns

  `connect/2` returns `{:ok, conn}` where `conn` is a `Mint.HTTP1.t()`
  connected to the loopback bridge. It is indistinguishable from a
  connection returned by the TCP or Unix transports: hand it to
  `Sorrel.Conn.request/6`, close it with `Mint.HTTP.close/1`.

  ## Lifetime

  The bridge process is *linked to the calling process* (typically a
  `Sorrel.Pool.Worker`). Three things can happen:

    * The Mint connection is closed cleanly by the caller. The bridge
      observes the loopback close, closes the SSH channel and
      connection, and exits `:normal`.
    * The remote side closes the channel (e.g. `dial-stdio` exits).
      The bridge observes the SSH-side close, shuts the loopback
      socket, and exits `:normal`. Mint then sees a closed socket on
      the next `recv`.
    * The owning process dies. The bridge's link tears it down, and
      its `terminate/2` closes the SSH connection on the way out.

  No SSH connection is left dangling on any error path inside
  `connect/2`: each failure point closes whatever has already been
  opened before returning. The bridge's `terminate/2` runs even on
  abnormal exits because it traps exits, so the SSH connection ref is
  closed exactly once on every shutdown path.

  ## Optional Docker dial-stdio wrapper

  If you use the `{:exec, "docker system dial-stdio"}` target shape,
  an optional wrapper script can give you typed HTTP errors
  (synthetic `502 Bad Gateway`) instead of a clean EOF when
  `dial-stdio` fails before producing output. The wrapper is
  Docker-specific and entirely opt-in; it does not affect any other
  use of this transport. See
  `Sorrel.Transport.SSH.DockerDialStdio` for the rationale,
  the streaming-endpoint caveat, and the deployment recipe.

  ## Security considerations

  This transport ferries authenticated, often privileged, byte streams
  (internal HTTP APIs, container-runtime control sockets, and other
  authenticated byte streams) over a process-local loopback socket.
  The threat model and concrete mitigations:

  ### Loopback exposure (local-attacker risk)

  The bridge binds a TCP listener on `127.0.0.1:0` with `backlog: 1`
  and accepts **exactly one** inbound connection - Mint's. On a
  multi-tenant host, however, **every local process can reach
  `127.0.0.1:port` until that one connection has been accepted**.
  Because the loopback listener performs no authentication of the
  connecting peer, a local attacker who wins the accept race obtains
  a free pipe into the SSH-tunneled remote: it can issue arbitrary
  HTTP requests to whatever sits on the far side (an internal HTTP
  API, a Docker daemon, a kubelet) under the SSH user's identity,
  with no further credentials.

      Attack window:
        Bridge.start_link returns ──► Mint.HTTP1.connect issues connect()
                            ▲────────────────────────▲
                             this gap is when a local
                             attacker can race in

  In practice the gap is microseconds because Mint connects from the
  same OS process that just received the bridge pid, but on a
  contended scheduler, under a tracer, or on a host where an attacker
  controls scheduling, the window can be widened. **Treat any local
  user with shell access as having access to the tunneled stream.**

  Mitigations:

    * Run the application on a dedicated host or container where no
      untrusted users have shell access. This is the primary
      defense; everything else is defense-in-depth.
    * If OS-level multi-tenancy is unavoidable, run the application
      under a UID that no other user can `ptrace`/strace, and ensure
      `/proc/sys/kernel/yama/ptrace_scope` (Linux) is at least `1`.
    * On macOS/Linux, `127.0.0.1` is reachable by **all** local
      UIDs; binding to a random ephemeral port does not hide it.
      Port-scanning by a curious neighbour will find it.
    * Future hardening (not currently implemented): bind to an
      `AF_UNIX` socket with mode `0600` instead of `127.0.0.1`, or
      perform a `SO_PEERCRED`/`getpeereid()` check on the accepted
      socket and reject connections whose UID is not the application's.

  ### Host-key verification (`endpoint.ssh.verify`)

  Two settings; only one is safe by default:

  | `verify`        | Behaviour                                                                                                                                  | When to use                                                                                       |
  | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
  | `:verify_peer`  | OTP looks up the server's host key in `known_hosts` (under `user_dir`) and rejects the connection if it is not present or does not match. Pairs with `silently_accept_hosts: false` and `user_interaction: false` so OTP fails the handshake rather than prompting on stdin. | The default. Production code should never use anything else.                                       |
  | `:verify_none`  | OTP is told `silently_accept_hosts: true`, which accepts **any** host key without checking it against `known_hosts`. The connection completes against any server that holds out an SSH banner. | Only for tests against a fixture sshd you control, or one-shot exploration on a trusted network. |

  **Risk - man-in-the-middle.** Setting `verify: :verify_none`
  removes the only thing that proves the far side is the host you
  intended to reach. An attacker on the path (a hostile coffee-shop
  router, a rogue cloud-provider hop, a misconfigured load balancer)
  can present any host key, complete the SSH handshake, and forward
  bytes to the real server. Every byte you send afterwards - API
  calls, secrets, payloads - is cleartext to the attacker.
  Authentication credentials (passwords,
  agent challenges) leak too: agent-based public-key auth survives a
  passive MITM, but a password is read by the impostor server in
  the clear.

  Mitigation: leave `verify` at `:verify_peer`. Provide a
  `known_hosts_file` whose **directory** is readable by the
  application UID, and pre-populate it with the server's host-key
  fingerprint (e.g. by running `ssh-keyscan` once during deploy and
  committing the result). See the "Identity files and known_hosts:
  directory-based discovery" caveat below.

  ### Authentication credential handling

  The endpoint's `:ssh.password` and `:ssh.identity_file` are passed
  to OTP `:ssh` as charlists; they are not logged by this transport,
  but:

    * **Passwords live in the endpoint struct.** Anyone who can
      `:erlang.process_info(pid, :dictionary)` or otherwise inspect
      a worker's state can read the password. Prefer
      `auth: [:agent]` or `auth: [:identity]` over
      `auth: [:password]` on multi-tenant hosts.
    * **Identity files are read by OTP at connect time**, not by
      this module. The application UID needs read access to the
      file. Permission failures surface as
      `{:error, {:ssh_auth_failed, _}}` rather than as a clear
      "file unreadable" error - be aware when troubleshooting.
    * **Agent-based auth (`:agent`) requires `SSH_AUTH_SOCK` in the
      environment** of the running BEAM. Containers commonly drop
      this; if your endpoint advertises `auth: [:agent]` and
      authentication is being refused, check that the
      `SSH_AUTH_SOCK` environment variable is actually set in the
      runtime.

  ### Identity files and known_hosts: directory-based discovery

  OTP's default key callback (`:ssh_file`) does not let a caller
  point at an arbitrary identity-file or `known_hosts` path. It
  scans a **directory** (`user_dir`) for files with conventional
  names: `id_rsa`, `id_ecdsa`, `id_ed25519`, `known_hosts`. The
  transport sets `user_dir` to the **parent directory** of whichever
  file the endpoint named.

  Concrete consequences:

    * Endpoint says `identity_file: "~/.ssh/deploy_key"`. OTP looks
      in `~/.ssh/` for `id_rsa` etc. - it does **not** load
      `deploy_key`. The connection silently falls back to whatever
      else is configured (agent, password). The user thinks they are
      authenticating with `deploy_key`; they are not.
    * Endpoint says `known_hosts_file: "~/.ssh/my_known_hosts"`.
      OTP looks for `~/.ssh/known_hosts`, **not** `my_known_hosts`.
      If `known_hosts` does not exist or does not contain the host
      key, the handshake fails as host-key-mismatch - which can be
      misleading.
    * If both `identity_file` and `known_hosts_file` are set in
      different directories, `known_hosts_file`'s parent wins
      (host-key verification is the more security-critical
      concern).

  Mitigation: rename the file to a name OTP recognises, or use
  ssh-agent (`auth: [:agent]`) and let agent-loaded keys flow in
  through `SSH_AUTH_SOCK`. A future custom `key_cb` could lift this
  restriction; the present default callback cannot.

  ### Buffered SSH-side data is unbounded

  Between the moment the bridge starts and the moment Mint's
  loopback connect is accepted, any bytes the remote sends are
  buffered in `pending_ssh_data`. This buffer has **no size limit**.
  In normal operation it is empty (the remote does not send before
  receiving a request) and the window is microseconds long. A
  malicious or buggy remote that pushes data preemptively could,
  combined with a stalled accept, grow this buffer; the
  `accept_timeout` (default 10_000 ms) caps the time window but
  not the byte count.

  Mitigation: keep `accept_timeout` modest (the default is fine).
  If you talk to remotes you do not trust, set a small
  `:connect_timeout` on the call so the accept window is shorter.

  ### Error-classification fragility

  The atoms `:ssh_auth_failed` and `:ssh_host_key_mismatch` returned
  from `connect/2` are derived by **substring-matching** OTP's
  human-readable error charlists. The substrings are stable across
  OTP 26, 27, and 28 at the time of writing, but a future OTP
  release that reword these messages will cause this transport to
  fall through to the generic `{:error, term}` clause. Callers that
  branch on `:ssh_auth_failed` to retry or rotate credentials
  should also be prepared to see the underlying string verbatim.

  ## OTP version

  Verified against OTP 26, 27, and 28 (`:ssh` v5.5.2). The project
  currently pins Elixir `~> 1.18`, which requires OTP 26+. The
  channel-open path (`:ssh_connection.open_channel/4`) is documented
  in the OTP source but does not appear in the public hexdocs for
  the `:ssh_connection` module - it is treated here as a stable
  contract because OpenSSH compatibility depends on it, but a hard
  break in a future OTP could surface as
  `{:ssh_target_unreachable, _}` for `{:tcp, _, _}` targets and as
  `{:streamlocal_not_supported_by_otp, _}` for `{:unix, _}` targets.

  ## Examples

      # Worked example: build an :ssh endpoint pointing at a remote
      # that runs `docker system dial-stdio`. The same shape works
      # for any remote stdio-HTTP command:
      iex> ep = %Sorrel.Endpoint{
      ...>   transport: :ssh,
      ...>   host: "remote.example.com",
      ...>   port: 22,
      ...>   user: "deploy",
      ...>   ssh: %{
      ...>     auth: [:agent],
      ...>     identity_file: nil,
      ...>     password: nil,
      ...>     known_hosts_file: nil,
      ...>     verify: :verify_none,
      ...>     connect_timeout: 10_000
      ...>   },
      ...>   target: {:exec, "docker system dial-stdio"}
      ...> }
      iex> {:ok, conn} = Sorrel.Transport.SSH.connect(ep)
      iex> is_struct(conn, Mint.HTTP1)
      true
  """

  # What this module does:
  #   1. Builds `:ssh.connect/4` options via `Auth.options/1`.
  #   2. Calls `:ssh.connect/4`. Maps the OTP error shapes to a small
  #      vocabulary of atoms documented on `connect/2`.
  #   3. Opens an SSH channel matching `endpoint.target`.
  #   4. Starts a `Bridge` process linked to `self()` and lets it own the
  #      SSH connection + channel.
  #   5. Calls `Mint.HTTP1.connect(:http, "127.0.0.1", bound_port, ...)`.
  #
  # Rules that always hold:
  #   1. `connect/2` is only called with endpoints whose `:transport` is
  #      `:ssh`. The function clause guards on this.
  #   2. On any error before `Mint.HTTP1.connect/4` returns success, no
  #      SSH connection is left open. The bridge (when started) is told
  #      to stop, and `:ssh.close/1` is called for connections opened
  #      before the bridge took ownership.
  #   3. The owner of the bridge is the calling process. Caller death
  #      tears down the bridge and the SSH connection.

  @behaviour Sorrel.Transport

  alias Sorrel.Endpoint
  alias Sorrel.Transport.SSH.Auth
  alias Sorrel.Transport.SSH.Bridge

  # Ms to drain the mailbox on the success branch of `do_connect_mint/7`
  # for a late-arriving bridge `:DOWN` carrying `{:ssh_exec_failed, _}`.
  # See the comment on the success branch for the empirical rationale.
  @exec_failure_drain_timeout 10

  @doc """
  Opens an SSH connection, opens the right channel for `endpoint.target`,
  splices it onto a loopback port via a `Bridge` process, and returns a
  `Mint.HTTP1.t()` connected to that loopback port.

  Read the module's "Security considerations" section before calling
  this with anything other than the project defaults - in particular
  before passing `verify: :verify_none`, before letting callers supply
  the `:exec` command, or before deploying on a host with multiple
  local users.

  ## Parameters

    * `endpoint` - `Sorrel.Endpoint.t()`. The struct's `:transport`
      must be `:ssh`; any other value raises `FunctionClauseError` (a
      function-clause failure here surfaces a corrupted struct
      immediately rather than a misleading network error later).

      Required fields and their consequences:

      | Field    | Effect                                                                                                                                                                                                                                                                                                                                                                                                |
      | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
      | `host`   | The SSH server host or IP. Resolved by OTP `:ssh` via the system resolver. Bad value -> `{:ssh_unreachable, :nxdomain}`.                                                                                                                                                                                                                                                                              |
      | `port`   | The SSH server port. Defaults to 22 from `parse/2`. No syntactic validation here beyond `1..65_535`; if nothing is listening, `{:ssh_unreachable, :econnrefused}`.                                                                                                                                                                                                                                   |
      | `user`   | The SSH login. Sent verbatim to the server. Empty values are rejected by `parse/2`, not by this function.                                                                                                                                                                                                                                                                                            |
      | `ssh`    | Map of authentication and verification options. The field-by-field mapping to `:ssh.connect/4` keys lives in `Sorrel.Transport.SSH.Auth`. Critical sub-fields: `:verify` (see "Host-key verification" in this module's security section), `:auth` (a list ordered by preference; `:agent` and `:identity` both map to OTP's `publickey`), `:identity_file` and `:known_hosts_file` (subject to the directory-based discovery caveat in the security section), `:connect_timeout` (milliseconds, applied to the SSH handshake - not to the loopback hop). |
      | `target` | One of `{:exec, iodata}`, `{:tcp, host, port}`, `{:unix, path}`. Picks the SSH channel type. Each shape has distinct security implications - see "The three target shapes" above.                                                                                                                                                                                                                    |

    * `opts` - `keyword()`. Recognised keys:

      | Key                | Type                   | Default    | What it does                                                                                                                                                                                                                                                                            |
      | ------------------ | ---------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
      | `:connect_timeout` | `non_neg_integer()`    | `10_000`   | Two roles: (a) milliseconds Mint waits for the loopback connect (almost instantaneous in practice - the listener is on `127.0.0.1` with `backlog: 1`); (b) milliseconds the bridge waits for Mint's accept (`accept_timeout`). The SSH-handshake timeout is **separate** and lives on the endpoint as `endpoint.ssh.connect_timeout`. |
      | `:mode`            | `:passive` \| `:active` | `:passive` | Underlying socket mode handed to Mint. Mint's own default is `:active`; this transport overrides to `:passive` so callers can drive `Mint.HTTP.recv/3` directly. Pass `:active` only if you intend to handle the `{:tcp, _, _}` mailbox messages yourself.                                |

      Unknown keys are ignored. Note that `endpoint.ssh.connect_timeout`
      is **not** read from `opts` - it lives on the endpoint struct, so
      callers who want a different SSH-handshake timeout must build a
      new endpoint, not patch `opts`.

  ## Returns

    * `{:ok, conn}` - `conn` is a `Mint.HTTP1.t()` connected to the
      bridge's loopback port. The bridge process is already pumping
      bytes; the caller does nothing further to wire it up. Closing
      `conn` (or the owning process exiting) tears the bridge and
      its SSH connection down - see "Lifetime" above.

    * `{:error, {:ssh_auth_failed, reason}}` - every authentication
      method the endpoint advertises was refused by the server. Common
      causes: wrong password; wrong username; no agent reachable
      (`SSH_AUTH_SOCK` unset in the BEAM's environment); identity
      file not picked up by OTP's `:ssh_file` callback (named
      something other than `id_rsa`/`id_ecdsa`/`id_ed25519` - see
      "Identity files and known_hosts" in the security section); or
      the server not advertising any of the methods we offered.
      `reason` is the underlying OTP error string (a binary).

    * `{:error, {:ssh_host_key_mismatch, reason}}` - the server's host
      key did not match an entry in `known_hosts` under `user_dir`.
      Only emitted when `verify: :verify_peer`. **If you see this,
      do not "fix" it by switching to `verify: :verify_none`** - that
      disables host-key verification entirely (see security section).
      Either pre-populate `known_hosts` with the correct fingerprint
      or fix whatever is interposing on the connection. `reason` is
      the underlying OTP error string (a binary).

    * `{:error, {:ssh_unreachable, reason}}` - the SSH connection could
      not be established because of a network-layer failure: DNS
      lookup failed, the host refused the connection, the route was
      unreachable, or negotiation was torn down before completing.
      `reason` is the underlying POSIX atom or OTP shutdown tuple
      (e.g. `:nxdomain`, `:econnrefused`, `:enetunreach`,
      `:ehostunreach`, `:timeout`, `{:shutdown, _}`).

    * `{:error, {:ssh_target_unreachable, reason}}` - the SSH
      connection succeeded but the channel could not be opened.
      Distinguishes from `:ssh_unreachable` (no SSH at all) and from
      `:ssh_auth_failed` (SSH refused our credentials). Causes by
      target shape:

      - `{:exec, _}` - the remote sshd refused the exec request, or
        the session-channel allocation failed. `reason` is the OTP
        channel-open error term, or `:connection_failed` when the
        remote sshd returned `:failure` to the exec request (note
        that this fires **before** the command runs; a command that
        starts and then exits non-zero looks like a clean close, not
        an error - see "Risk - exit status is ignored" above).
      - `{:tcp, host, port}` - the SSH host refused or could not
        reach `host:port`, or `sshd_config` `PermitOpen` excluded
        it. `reason` is the OTP channel-open error term.
      - `{:unix, path}` - the SSH host could not open the socket
        file (does not exist, wrong permissions, or
        `AllowStreamLocalForwarding no`). `reason` is the OTP
        channel-open error term.

    * `{:error, {:ssh_exec_failed, reason}}` - the SSH connection and
      channel both opened, the remote sshd accepted the `exec`
      request, but the remote command exited (or was killed by a
      signal) **before producing any response bytes**. `reason` is
      `{:status, n}` for a non-zero exit code (typically 127 for
      "command not found", 126 for "command found but not
      executable") or `{:signal, sig}` where `sig` is a string like
      `"TERM"` or `"KILL"`. Only emitted for `{:exec, _}` targets.

      Failures that arrive *after* a response has begun streaming are
      deliberately not surfaced under this tag - see "Risk - exit
      status is ignored" in the module-level "The three target
      shapes" section. The boundary is whether any byte from the SSH
      side has crossed toward Mint.

    * `{:error, {:streamlocal_not_supported_by_otp, reason}}` - the
      endpoint target is `{:unix, path}` and `:ssh_connection.open_channel/4`
      rejected the `direct-streamlocal@openssh.com` request. This
      tag covers two distinct causes: (a) the OTP runtime in use
      does not expose the channel-open path at all (older or
      stripped OTP builds - none currently observed in the
      supported 26..28 range), or (b) the remote SSH server is OTP
      `:ssh` itself, which never implemented this OpenSSH
      extension. `reason` is the underlying OTP channel-open error
      term.

    * `{:error, :timeout}` - the SSH connect or the channel-open
      exceeded its timeout. The SSH handshake timeout comes from
      `endpoint.ssh.connect_timeout`; the channel-open timeout
      reuses the same value (see `Bridge.start_link/1`). The
      loopback connect's timeout is `opts[:connect_timeout]` and
      surfaces as a Mint error rather than as `:timeout`.

    * `{:error, term}` - any other error, returned as-is. Examples:
      `{:tls_alert, _}` (rare, on misconfigured servers fronted by
      a TLS proxy); the literal OTP error charlist for an
      auth-failure wording we did not substring-match (see
      "Error-classification fragility" in the security section); or
      a `Mint.TransportError` from the loopback connect (in
      practice unreachable - the listener is on 127.0.0.1 - but
      kept in the type for completeness).

  This function does not raise for expected failures.

  ## Examples

      # Successful exec target. The exec command speaks HTTP/1.1 on stdout:
      iex> ep = %Sorrel.Endpoint{
      ...>   transport: :ssh, host: "127.0.0.1", port: 22, user: "u",
      ...>   ssh: %{auth: [:password], password: "s", identity_file: nil,
      ...>          known_hosts_file: nil, verify: :verify_none, connect_timeout: 5000},
      ...>   target: {:exec, "/usr/local/bin/dial-http"}}
      iex> {:ok, conn} = Sorrel.Transport.SSH.connect(ep)
      iex> is_struct(conn, Mint.HTTP1)
      true

      # A direct-tcpip target reaches an HTTP server living on the SSH host's
      # loopback (e.g. a daemon bound to 127.0.0.1:8080 over there):
      iex> ep = %Sorrel.Endpoint{
      ...>   transport: :ssh, host: "remote", port: 22, user: "u",
      ...>   ssh: %{auth: [:agent], password: nil, identity_file: nil,
      ...>          known_hosts_file: nil, verify: :verify_peer, connect_timeout: 10_000},
      ...>   target: {:tcp, "127.0.0.1", 8080}}
      iex> {:ok, _conn} = Sorrel.Transport.SSH.connect(ep)
  """
  @impl Sorrel.Transport
  @spec connect(Endpoint.t(), keyword()) :: {:ok, Mint.HTTP.t()} | {:error, term()}
  def connect(%Endpoint{transport: :ssh} = endpoint, opts \\ []) do
    with {:ok, ssh_conn} <- open_ssh_connection(endpoint) do
      start_bridge_and_connect(ssh_conn, endpoint, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Step 1: open the SSH connection.
  # ---------------------------------------------------------------------------

  @spec open_ssh_connection(Endpoint.t()) :: {:ok, term()} | {:error, term()}
  defp open_ssh_connection(%Endpoint{} = endpoint) do
    ssh_opts = Auth.options(endpoint)
    host_charlist = String.to_charlist(endpoint.host)
    timeout = endpoint.ssh.connect_timeout

    case :ssh.connect(host_charlist, endpoint.port, ssh_opts, timeout) do
      {:ok, conn_ref} ->
        {:ok, conn_ref}

      {:error, reason} ->
        {:error, map_ssh_connect_error(reason)}
    end
  end

  # The OTP `:ssh.connect/4` error vocabulary varies by OTP version; the
  # most common shapes seen in OTP 26 and 27 are:
  #
  #   * `:nxdomain`, `:econnrefused`, `:enetunreach`, `:ehostunreach`
  #     - POSIX-style atoms from the underlying gen_tcp connect.
  #   * `:timeout` - timeout fired before negotiation finished.
  #   * a charlist starting with `~c"User auth failed for ..."` - the
  #     server refused every method we offered.
  #   * a charlist starting with `~c"Key exchange failed"` mentioning
  #     "host key" or "received_hostkey_unknown" - host-key mismatch.
  #   * `{:shutdown, _}` - connection torn down before negotiation
  #     finished. Treat as unreachable.
  #
  # We translate the most common ones to the documented atoms; anything
  # else is returned verbatim so we don't lose information.
  defp map_ssh_connect_error(:nxdomain), do: {:ssh_unreachable, :nxdomain}
  defp map_ssh_connect_error(:econnrefused), do: {:ssh_unreachable, :econnrefused}
  defp map_ssh_connect_error(:enetunreach), do: {:ssh_unreachable, :enetunreach}
  defp map_ssh_connect_error(:ehostunreach), do: {:ssh_unreachable, :ehostunreach}
  defp map_ssh_connect_error(:timeout), do: {:ssh_unreachable, :timeout}
  defp map_ssh_connect_error({:shutdown, _} = reason), do: {:ssh_unreachable, reason}

  defp map_ssh_connect_error(reason) when is_list(reason) do
    classify_ssh_charlist_error(IO.iodata_to_binary([reason]))
  rescue
    # `reason` may be an improper list / contain non-iodata in some OTP
    # builds; if we can't render it, fall through to the generic case.
    _ -> reason
  end

  defp map_ssh_connect_error(reason) when is_binary(reason) do
    classify_ssh_charlist_error(reason)
  end

  defp map_ssh_connect_error(other), do: other

  # Pattern-match the human-readable error string OTP returns for auth
  # and host-key failures. These strings are stable enough across OTP 26
  # and 27 to grep on; if a version changes the wording, the test suite
  # will surface it as the literal binary coming through, and we can
  # update this list.
  defp classify_ssh_charlist_error(string) do
    cond do
      auth_failed_message?(string) -> {:ssh_auth_failed, string}
      host_key_mismatch_message?(string) -> {:ssh_host_key_mismatch, string}
      true -> string
    end
  end

  # OTP's auth-failed messages. A few wordings have been observed across
  # OTP 26 and 27.
  defp auth_failed_message?(string) do
    String.contains?(string, "User auth failed") or
      String.contains?(string, "Unable to connect using the available authentication methods")
  end

  # OTP's host-key-rejection messages. The variants reflect different OTP
  # codepaths - older "Host key verification failed", newer
  # "received_hostkey_unknown", and the disconnect-during-KEX wording
  # ("Service not available" / "User interaction is not allowed") that
  # OTP emits when the host is unknown and `user_interaction: false`.
  defp host_key_mismatch_message?(string) do
    String.contains?(string, "received_hostkey_unknown") or
      String.contains?(string, "Host key verification failed") or
      (String.contains?(string, "host key") and String.contains?(string, "not match")) or
      String.contains?(string, "User interaction is not allowed") or
      String.contains?(string, "Service not available") or
      String.contains?(string, "Key exchange failed")
  end

  # Channel opening lives in `Sorrel.Transport.SSH.Bridge` so the
  # bridge process is the channel owner - see that module's "Why the
  # bridge opens the channel" section.

  # ---------------------------------------------------------------------------
  # Step 3: start the bridge and let Mint connect through it.
  # ---------------------------------------------------------------------------

  defp start_bridge_and_connect(ssh_conn, endpoint, opts) do
    case Bridge.start_link(
           ssh_conn: ssh_conn,
           target: endpoint.target,
           channel_open_timeout: endpoint.ssh.connect_timeout,
           owner: self(),
           accept_timeout: bridge_accept_timeout(endpoint, opts)
         ) do
      {:ok, %{port: port, bridge: bridge}} ->
        # Monitor the bridge so we can observe its exit reason
        # independently of the link. The bridge's `:owner` link makes
        # *us* die if the bridge exits abnormally - we sever that
        # link only on the error paths below where we are deliberately
        # converting the bridge's exit reason into our return value.
        # On the success path the link stays in place because the
        # caller wants the bridge to die with them.
        ref = Process.monitor(bridge)
        connect_mint(ssh_conn, bridge, ref, port, endpoint, opts)

      {:error, reason} ->
        # Bridge couldn't start (channel-open failure, listener bind
        # failure, etc.) - the bridge has already torn down its SSH
        # state in its `terminate/2`, but on the failure path it never
        # took ownership of the connection ref, so we close the
        # connection ourselves.
        _ = safe_ssh_close(ssh_conn)
        {:error, reason}
    end
  end

  defp connect_mint(ssh_conn, bridge, ref, port, endpoint, opts) do
    timeout = Sorrel.Config.connect_timeout(opts)
    mode = Keyword.get(opts, :mode, :passive)
    hostname = mint_hostname(endpoint)

    # Temporarily trap exits so a bridge that exits with
    # `{:shutdown, {:ssh_exec_failed, _}}` does not kill us via the
    # `:owner` link before we get a chance to convert that exit
    # reason into a typed error return value. We restore the
    # original flag before returning so the caller's link semantics
    # are unchanged for the lifetime of the returned conn.
    prior_trap = Process.flag(:trap_exit, true)

    try do
      do_connect_mint(ssh_conn, bridge, ref, port, hostname, mode, timeout)
    after
      Process.flag(:trap_exit, prior_trap)
    end
  end

  defp do_connect_mint(ssh_conn, bridge, ref, port, hostname, mode, timeout) do
    case Mint.HTTP1.connect(:http, "127.0.0.1", port,
           hostname: hostname,
           mode: mode,
           transport_opts: [timeout: timeout]
         ) do
      {:ok, conn} ->
        # Mint's loopback connect succeeded. Briefly drain the mailbox
        # for an already-delivered or imminently-delivered bridge DOWN
        # carrying `{:shutdown, {:ssh_exec_failed, _}}` so we surface
        # the typed exec error rather than letting the caller get a
        # generic Mint `:closed` on first request.
        #
        # Why @exec_failure_drain_timeout ms (and not 0): for the
        # accept-time-poisoned cases the bridge's `:DOWN` is
        # essentially always already in the mailbox by the time Mint
        # connects - a zero-timeout poll would catch those. But a
        # real-world SSH server's `exit_status` channel-message can
        # land a few ms AFTER Mint's loopback TCP handshake completes
        # - empirically observed against the project's FakeSSHServer.
        # @exec_failure_drain_timeout catches that window while
        # keeping the success-path cost trivially small.
        #
        # This is best-effort: SSH servers that emit `exit_status`
        # more than @exec_failure_drain_timeout ms after Mint connect
        # will fall back to a Mint-level `:closed` on first request,
        # same as pre-fix behaviour.
        receive do
          {:DOWN, ^ref, :process, ^bridge, {:shutdown, {:ssh_exec_failed, _} = reason}} ->
            _ = Mint.HTTP1.close(conn)
            # Sever the link so the bridge's already-delivered exit
            # signal does not also kill us when we return. The bridge
            # is already dead at this point (we just observed its
            # DOWN), so unlink is a defensive no-op against a
            # racing-but-already-finished link tear-down.
            _ = safe_unlink(bridge)
            {:error, reason}
        after
          @exec_failure_drain_timeout ->
            # Bridge is still alive. Demonitor cleanly so the caller
            # never sees a stray DOWN from this bridge.
            Process.demonitor(ref, [:flush])
            {:ok, conn}
        end

      {:error, _} = err ->
        # Loopback connect failed. Two distinct possibilities:
        #
        #   1. The bridge already exited (accept-time poisoning fired
        #      and closed the listener) and Mint saw econnrefused or
        #      :closed. The REAL reason is the exec failure - drain
        #      the mailbox briefly to find the DOWN and prefer that
        #      typed error over the generic Mint transport error.
        #
        #   2. The bridge is alive and something else genuinely went
        #      wrong (vanishingly rare; the listener is on 127.0.0.1
        #      with backlog 1). Tear it down and return the Mint err.
        receive do
          {:DOWN, ^ref, :process, ^bridge, {:shutdown, {:ssh_exec_failed, _} = reason}} ->
            _ = safe_unlink(bridge)
            {:error, reason}
        after
          50 ->
            Process.demonitor(ref, [:flush])
            # Tear down the bridge. Its `terminate/2` closes the SSH
            # connection. Both `:ssh.close` and the bridge's close
            # are idempotent.
            Process.exit(bridge, :shutdown)
            _ = safe_ssh_close(ssh_conn)
            err
        end
    end
  end

  # Unlinks from `pid` without raising if the process is already gone.
  # Used on the error-return paths where we have just decided to
  # convert the bridge's non-`:normal` exit reason into our return
  # value: leaving the link in place would propagate that exit signal
  # to the caller and kill them.
  @spec safe_unlink(pid()) :: true
  defp safe_unlink(pid) when is_pid(pid) do
    Process.unlink(pid)
  rescue
    _ -> true
  catch
    _kind, _reason -> true
  end

  defp bridge_accept_timeout(_endpoint, opts) do
    # Mint connects to the loopback listener immediately after we return
    # from start_link, so the accept window only needs to cover the time
    # between Bridge.start_link returning and Mint.HTTP1.connect issuing
    # the connect. Bound it by the user's connect_timeout (or the default).
    Sorrel.Config.connect_timeout(opts)
  end

  # The `hostname:` Mint uses to fill in HTTP request `Host` headers.
  # For exec and unix targets there's no real hostname, so use
  # "localhost". For tcp targets, the user told us a host -- prefer it.
  defp mint_hostname(%Endpoint{target: {:tcp, host, _port}}), do: host
  defp mint_hostname(%Endpoint{target: _other}), do: "localhost"

  defp safe_ssh_close(ssh_conn) do
    :ssh.close(ssh_conn)
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end
end
