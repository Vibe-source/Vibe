defmodule VibeWeb.EndpointDbSslTest do
  use ExUnit.Case, async: true

  alias VibeWeb.Endpoint

  describe "db_ssl_opts/2" do
    test "defaults to peer verification when CA path is available (unset env)" do
      assert Endpoint.db_ssl_opts(nil, "/etc/ssl/certs/ca-certificates.crt") == [
               verify: :verify_peer,
               cacertfile: "/etc/ssl/certs/ca-certificates.crt"
             ]

      assert Endpoint.db_ssl_opts("", "/etc/ssl/cert.pem") == [
               verify: :verify_peer,
               cacertfile: "/etc/ssl/cert.pem"
             ]
    end

    test "explicit DB_SSL_VERIFY=none opts out even when CA exists" do
      assert Endpoint.db_ssl_opts("none", "/etc/ssl/certs/ca-certificates.crt") == [
               verify: :verify_none
             ]

      assert Endpoint.db_ssl_opts("NONE", "/etc/ssl/cert.pem") == [verify: :verify_none]
      assert Endpoint.db_ssl_opts("  none  ", nil) == [verify: :verify_none]
    end

    test "peer verify when verify env is peer or other non-none value" do
      assert Endpoint.db_ssl_opts("peer", "/path/to/ca.pem") == [
               verify: :verify_peer,
               cacertfile: "/path/to/ca.pem"
             ]

      assert Endpoint.db_ssl_opts("true", "/path/to/ca.pem") == [
               verify: :verify_peer,
               cacertfile: "/path/to/ca.pem"
             ]
    end

    test "falls back to verify_none when no CA bundle is available" do
      assert Endpoint.db_ssl_opts(nil, nil) == [verify: :verify_none]
      assert Endpoint.db_ssl_opts("peer", nil) == [verify: :verify_none]
      assert Endpoint.db_ssl_opts(nil, "") == [verify: :verify_none]
      assert Endpoint.db_ssl_opts(nil, "   ") == [verify: :verify_none]
    end
  end
end
