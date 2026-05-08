defmodule FakeHttpServer.Impl do
  @moduledoc """
  Pure helpers for `FakeHttpServer`.

  Holds:

    * the HTTP/1.1 request parser used by the acceptor loop,
    * the listen-socket option builders for `:tcp`, `:tls`, and `:unix`,
    * a small classifier that translates a responder's return value into
      a normalised dispatch directive.

  All functions here are deterministic — no sockets, no processes. They
  exist so the test-support server can be reasoned about (and unit-tested)
  without spawning a listener.
  """

  @type request :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @doc """
  Tries to parse one HTTP/1.1 request out of `buffer`.

  ## What it returns

    * `{:ok, request, leftover}` — One full request was parsed; any extra
      bytes are returned as `leftover`.
    * `{:need_more, buffer}` — Need more bytes; returns `buffer` unchanged.
  """
  @spec parse_request(binary()) :: {:ok, request(), binary()} | {:need_more, binary()}
  def parse_request(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [_only] ->
        {:need_more, buffer}

      [head, rest] ->
        parse_after_head_split(buffer, head, rest)
    end
  end

  defp parse_after_head_split(buffer, head, rest) do
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, path, _http_version] = String.split(request_line, " ", parts: 3)
    headers = Enum.map(header_lines, &parse_header/1)
    content_length = content_length(headers)

    if byte_size(rest) >= content_length do
      <<body::binary-size(content_length), leftover::binary>> = rest

      request = %{
        method: method,
        path: path,
        headers: headers,
        body: body
      }

      {:ok, request, leftover}
    else
      {:need_more, buffer}
    end
  end

  @doc """
  Parses one `"Name: Value"` header line. The name is lower-cased and
  trimmed.
  """
  @spec parse_header(String.t()) :: {String.t(), String.t()}
  def parse_header(line) do
    case :binary.split(line, ":") do
      [name, value] -> {downcased_trim(name), String.trim(value)}
      [name] -> {downcased_trim(name), ""}
    end
  end

  @doc """
  Reads the `content-length` header from a list of headers (keys
  lower-cased). Returns `0` if the header is absent.
  """
  @spec content_length([{String.t(), String.t()}]) :: non_neg_integer()
  def content_length(headers) do
    case List.keyfind(headers, "content-length", 0) do
      {"content-length", value} -> String.to_integer(value)
      _other -> 0
    end
  end

  @doc """
  Builds the `:gen_tcp.listen/2` options for a TCP listener.
  """
  @spec tcp_listen_opts(:inet.ip_address()) :: keyword()
  def tcp_listen_opts(ip) do
    [
      :binary,
      ip: ip,
      active: false,
      reuseaddr: true,
      packet: :raw,
      backlog: 16
    ]
  end

  @doc """
  Builds the `:ssl.listen/2` options for a TLS listener.
  """
  @spec tls_listen_opts(:inet.ip_address(), Path.t(), Path.t(), Path.t(), boolean()) ::
          keyword()
  def tls_listen_opts(ip, cacertfile, certfile, keyfile, fail_if_no_peer_cert) do
    [
      :binary,
      ip: ip,
      active: false,
      reuseaddr: true,
      packet: :raw,
      backlog: 16,
      cacertfile: cacertfile,
      certfile: certfile,
      keyfile: keyfile,
      verify: :verify_peer,
      fail_if_no_peer_cert: fail_if_no_peer_cert
    ]
  end

  @doc """
  Builds the `:gen_tcp.listen/2` options for a Unix-socket listener.
  """
  @spec unix_listen_opts(Path.t()) :: keyword()
  def unix_listen_opts(socket_path) do
    [
      :binary,
      {:ifaddr, {:local, socket_path}},
      active: false,
      packet: :raw,
      backlog: 16
    ]
  end

  @doc """
  Classifies the value returned by a `:responder` function.

  ## What it returns

    * `{:close_after, iodata}` — write iodata, then close.
    * `{:script, steps}` — list of timed steps.
    * `{:keep_alive, iodata}` — write iodata, keep socket open for the
      next request.
  """
  @spec classify_responder_result(term()) ::
          {:close_after, iodata()}
          | {:script, list()}
          | {:keep_alive, iodata()}
  def classify_responder_result({:close_after, iodata}) do
    {:close_after, iodata}
  end

  def classify_responder_result({:script, steps}) when is_list(steps) do
    {:script, steps}
  end

  def classify_responder_result(iodata) when is_binary(iodata) or is_list(iodata) do
    {:keep_alive, iodata}
  end

  defp downcased_trim(value) do
    value |> String.trim() |> String.downcase()
  end
end
