defmodule CertFixture do
  @moduledoc """
  Generates a self-signed CA, a server certificate for `127.0.0.1`, and a
  client certificate for use in mTLS tests.

  Each call to `generate/0` writes a fresh set of PEM files to a unique
  directory under `System.tmp_dir!/0` and returns absolute paths to those
  files. Nothing is cached across calls; nothing is cleaned up automatically
  (callers may register an `on_exit/1` to remove the directory if desired).

  The server certificate carries a SubjectAltName extension with
  `iPAddress: 127.0.0.1`, which is required for hostname verification on the
  Mint client side when connecting to `host: "127.0.0.1"`.

  ## Examples

      iex> %{ca: ca, server_cert: sc, server_key: sk,
      ...>   client_cert: cc, client_key: ck, dir: _dir} = CertFixture.generate()
      iex> File.exists?(ca) and File.exists?(sc) and File.exists?(sk) and
      ...>   File.exists?(cc) and File.exists?(ck)
      true
  """

  # Abstraction Function:
  #   Stateless. Each call produces a self-signed CA and two leaf certificates
  #   (server + client) signed by that CA, materialised as PEM files in a
  #   fresh temp directory. The returned map is the only handle a caller
  #   needs for ssl/Mint configuration.
  #
  # Data Invariant:
  #   1. The five returned paths are absolute and live under a single
  #      per-call directory under System.tmp_dir!/0.
  #   2. The server certificate has SAN iPAddress 127.0.0.1.
  #   3. extKeyUsage on server cert is serverAuth; on client cert clientAuth.
  #   4. CA, server, and client RSA keypairs are independently generated per
  #      call (no cross-test reuse).

  require Record

  # OTP records we need from :public_key. The 3-arg form of defrecordp lets
  # us keep a snake_case macro name while preserving the OTP record tag
  # (e.g. :"OTPTBSCertificate"). The tag MUST match the original record name
  # because :public_key.pkix_sign/2 pattern-matches on it.
  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :signature_algorithm,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :public_key_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :attr,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :basic_constraints,
    :BasicConstraints,
    Record.extract(:BasicConstraints, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  # OIDs we use directly. These are the IANA-registered Object Identifiers
  # for the X.509 attributes/extensions we need.
  @oid_common_name {2, 5, 4, 3}
  @oid_basic_constraints {2, 5, 29, 19}
  @oid_key_usage {2, 5, 29, 15}
  @oid_subject_alt_name {2, 5, 29, 17}
  @oid_ext_key_usage {2, 5, 29, 37}
  @oid_server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @oid_client_auth {1, 3, 6, 1, 5, 5, 7, 3, 2}
  @oid_sha256_with_rsa {1, 2, 840, 113_549, 1, 1, 11}
  @oid_rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}

  @doc """
  Generates a fresh CA, server cert, and client cert; writes them as PEM
  files to a temp directory; returns absolute paths.

  ## What it returns

  A map:

    * `:dir` — temp directory holding all five files
    * `:ca` — CA certificate (PEM)
    * `:server_cert` — server leaf cert (PEM)
    * `:server_key` — server private key (PEM)
    * `:client_cert` — client leaf cert (PEM)
    * `:client_key` — client private key (PEM)

  This function does not raise on filesystem-shaped errors caused by a missing
  temp dir — those are surfaced by `File.write!/2`. Cryptographic operations
  also raise on failure, which would only occur on a misconfigured OTP install.
  """
  @spec generate() :: %{
          dir: String.t(),
          ca: String.t(),
          server_cert: String.t(),
          server_key: String.t(),
          client_cert: String.t(),
          client_key: String.t()
        }
  def generate do
    dir =
      Path.join(
        System.tmp_dir!(),
        "docker-cert-fixture-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)

    ca_key = rsa_keypair()
    server_key = rsa_keypair()
    client_key = rsa_keypair()

    ca_cert_der = build_ca_cert(ca_key)
    server_cert_der = build_server_cert(server_key, ca_cert_der, ca_key)
    client_cert_der = build_client_cert(client_key, ca_cert_der, ca_key)

    paths = %{
      dir: dir,
      ca: Path.join(dir, "ca.pem"),
      server_cert: Path.join(dir, "server.pem"),
      server_key: Path.join(dir, "server-key.pem"),
      client_cert: Path.join(dir, "client.pem"),
      client_key: Path.join(dir, "client-key.pem")
    }

    File.write!(paths.ca, encode_cert_pem(ca_cert_der))
    File.write!(paths.server_cert, encode_cert_pem(server_cert_der))
    File.write!(paths.server_key, encode_rsa_key_pem(server_key))
    File.write!(paths.client_cert, encode_cert_pem(client_cert_der))
    File.write!(paths.client_key, encode_rsa_key_pem(client_key))

    paths
  end

  # ---------------------------------------------------------------------------
  # Key generation
  # ---------------------------------------------------------------------------

  # Returns an :RSAPrivateKey record (the OTP record shape, not PEM bytes).
  defp rsa_keypair do
    :public_key.generate_key({:rsa, 2048, 65_537})
  end

  # ---------------------------------------------------------------------------
  # Cert builders. Each returns DER bytes.
  # ---------------------------------------------------------------------------

  defp build_ca_cert(ca_key) do
    tbs =
      otp_tbs_certificate(
        version: :v3,
        serialNumber: serial(),
        signature: signature_algorithm(algorithm: @oid_sha256_with_rsa, parameters: :NULL),
        issuer: rdn("docker-test-ca"),
        validity: validity_now(),
        subject: rdn("docker-test-ca"),
        subjectPublicKeyInfo: spki(ca_key),
        extensions: [
          ext(@oid_basic_constraints, true, basic_constraints(cA: true)),
          ext(@oid_key_usage, true, [:keyCertSign, :cRLSign])
        ]
      )

    :public_key.pkix_sign(tbs, ca_key)
  end

  defp build_server_cert(server_key, ca_cert_der, ca_key) do
    tbs =
      otp_tbs_certificate(
        version: :v3,
        serialNumber: serial(),
        signature: signature_algorithm(algorithm: @oid_sha256_with_rsa, parameters: :NULL),
        issuer: subject_of(ca_cert_der),
        validity: validity_now(),
        subject: rdn("127.0.0.1"),
        subjectPublicKeyInfo: spki(server_key),
        extensions: [
          ext(@oid_basic_constraints, true, basic_constraints(cA: false)),
          ext(@oid_key_usage, true, [:digitalSignature, :keyEncipherment]),
          ext(@oid_ext_key_usage, false, [@oid_server_auth]),
          # SAN: iPAddress: 127.0.0.1 — encoded as a 4-byte tuple.
          ext(@oid_subject_alt_name, false, [{:iPAddress, [127, 0, 0, 1]}])
        ]
      )

    :public_key.pkix_sign(tbs, ca_key)
  end

  defp build_client_cert(client_key, ca_cert_der, ca_key) do
    tbs =
      otp_tbs_certificate(
        version: :v3,
        serialNumber: serial(),
        signature: signature_algorithm(algorithm: @oid_sha256_with_rsa, parameters: :NULL),
        issuer: subject_of(ca_cert_der),
        validity: validity_now(),
        subject: rdn("docker-test-client"),
        subjectPublicKeyInfo: spki(client_key),
        extensions: [
          ext(@oid_basic_constraints, true, basic_constraints(cA: false)),
          ext(@oid_key_usage, true, [:digitalSignature, :keyEncipherment]),
          ext(@oid_ext_key_usage, false, [@oid_client_auth])
        ]
      )

    :public_key.pkix_sign(tbs, ca_key)
  end

  # ---------------------------------------------------------------------------
  # Encoding helpers
  # ---------------------------------------------------------------------------

  defp encode_cert_pem(der) do
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  defp encode_rsa_key_pem(rsa_key) do
    der = :public_key.der_encode(:RSAPrivateKey, rsa_key)
    :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])
  end

  # ---------------------------------------------------------------------------
  # Small builders for X.509 fields
  # ---------------------------------------------------------------------------

  # Pulls the subject RDN out of an existing CA cert, so the issuer field on
  # leaf certs matches byte-for-byte. This is what pkix_path_validation uses
  # to chain the leaf to the CA.
  defp subject_of(cert_der) do
    otp_certificate(tbsCertificate: tbs) = :public_key.pkix_decode_cert(cert_der, :otp)
    otp_tbs_certificate(tbs, :subject)
  end

  defp rdn(common_name) do
    {:rdnSequence,
     [
       [
         attr(
           type: @oid_common_name,
           value: {:utf8String, common_name}
         )
       ]
     ]}
  end

  defp validity_now do
    not_before = utc_time(-300)
    not_after = utc_time(86_400)
    validity(notBefore: {:utcTime, not_before}, notAfter: {:utcTime, not_after})
  end

  # Returns a UTCTime charlist "YYMMDDHHMMSSZ" relative to now.
  defp utc_time(offset_seconds) do
    {{y, mo, d}, {h, mi, s}} =
      :calendar.gregorian_seconds_to_datetime(
        :calendar.datetime_to_gregorian_seconds(:calendar.universal_time()) + offset_seconds
      )

    yy = rem(y, 100)
    iolist = :io_lib.format(~c"~2..0B~2..0B~2..0B~2..0B~2..0B~2..0BZ", [yy, mo, d, h, mi, s])
    List.flatten(iolist)
  end

  defp spki(rsa_key) do
    {:RSAPrivateKey, _, modulus, public_exponent, _, _, _, _, _, _, _} = rsa_key
    public_key = {:RSAPublicKey, modulus, public_exponent}
    der_pubkey = :public_key.der_encode(:RSAPublicKey, public_key)

    otp_subject_public_key_info(
      algorithm: public_key_algorithm(algorithm: @oid_rsa_encryption, parameters: :NULL),
      subjectPublicKey: public_key_from_der(der_pubkey)
    )
  end

  # In OTP-decoded form (the `:otp` decoding mode used by pkix_sign), the
  # subjectPublicKey field holds the decoded RSAPublicKey record, not its
  # DER bytes. Decoding the DER we just built keeps us symmetric with what
  # pkix_decode_cert/2 would return for an existing cert.
  defp public_key_from_der(der), do: :public_key.der_decode(:RSAPublicKey, der)

  defp ext(oid, critical?, value) do
    extension(extnID: oid, critical: critical?, extnValue: value)
  end

  # Random 64-bit positive serial. Real CAs use longer serials; this is fine
  # for test fixtures. Note pkix_sign accepts any positive integer.
  defp serial do
    <<n::64>> = :crypto.strong_rand_bytes(8)
    Bitwise.band(n, 0x7FFF_FFFF_FFFF_FFFF) + 1
  end
end
