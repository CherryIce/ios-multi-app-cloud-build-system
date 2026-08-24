# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module IOSBuild
  module ASC
    API_BASE = "https://api.appstoreconnect.apple.com"

    class APIError < StandardError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
      end
    end

    class Token
      def initialize(key_id:, issuer_id:, key_path:)
        @key_id = key_id
        @issuer_id = issuer_id
        @key = OpenSSL::PKey.read(File.binread(key_path))
        raise APIError, "ASC key is not an EC private key" unless @key.is_a?(OpenSSL::PKey::EC) && @key.private?
        raise APIError, "ASC key must use the P-256 curve" unless @key.group.curve_name == "prime256v1"
      end

      def generate(now: Time.now.to_i, lifetime: 600)
        header = { "alg" => "ES256", "kid" => @key_id, "typ" => "JWT" }
        payload = {
          "iss" => @issuer_id,
          "iat" => now - 5,
          "exp" => now + lifetime,
          "aud" => "appstoreconnect-v1"
        }
        signing_input = [base64url(JSON.generate(header)), base64url(JSON.generate(payload))].join(".")
        digest = Digest::SHA256.digest(signing_input)
        der_signature = @key.dsa_sign_asn1(digest)
        raw_signature = ecdsa_der_to_raw(der_signature)
        [signing_input, base64url(raw_signature)].join(".")
      end

      private

      def base64url(value)
        Base64.urlsafe_encode64(value, padding: false)
      end

      def ecdsa_der_to_raw(signature)
        sequence = OpenSSL::ASN1.decode(signature)
        values = sequence.value
        raise APIError, "unexpected ECDSA signature format" unless values.length == 2

        values.map { |integer| integer.value.to_s(2).rjust(32, "\0")[-32, 32] }.join
      end
    end

    class Client
      def initialize(key_id:, issuer_id:, key_path:, base_url: API_BASE)
        @token = Token.new(key_id: key_id, issuer_id: issuer_id, key_path: key_path)
        @base_url = base_url
      end

      def get(path, query = nil)
        request(:get, path, query: query)
      end

      def post(path, payload)
        request(:post, path, payload: payload)
      end

      def request(method, path, query: nil, payload: nil)
        uri = if path.start_with?("http://", "https://")
                URI(path)
              else
                URI.join(@base_url, path)
              end
        uri.query = URI.encode_www_form(query) if query && !query.empty?

        request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@token.generate}"
        request["Accept"] = "application/json"
        if payload
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(payload)
        end

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 20,
          read_timeout: 60
        ) { |http| http.request(request) }

        unless response.is_a?(Net::HTTPSuccess)
          raise APIError.new(
            "App Store Connect API returned HTTP #{response.code}",
            status: response.code.to_i,
            body: response.body
          )
        end

        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise APIError, "App Store Connect returned invalid JSON: #{e.message}"
      end

      def paginate(path, query = nil, max_pages: 20)
        records = []
        next_path = path
        next_query = query
        pages = 0

        while next_path
          pages += 1
          raise APIError, "App Store Connect pagination exceeded #{max_pages} pages" if pages > max_pages

          response = get(next_path, next_query)
          records.concat(Array(response["data"]))
          next_path = response.dig("links", "next")
          next_query = nil
        end
        records
      end
    end
  end
end
