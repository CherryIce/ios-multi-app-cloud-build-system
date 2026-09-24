# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module IOSBuild
  module ASC
    class WebhookDeliveryError < StandardError; end

    class WebhookNotifier
      USER_AGENT = "ios-multi-app-cloud-build-system/asc-review-status"

      def self.attempt_review_status(summary, url:, bearer_token: "")
        return { "requested" => false, "sent" => false, "error" => nil } if url.to_s.empty?

        new(url: url, bearer_token: bearer_token).deliver(review_status_payload(summary))
        { "requested" => true, "sent" => true, "error" => nil }
      rescue WebhookDeliveryError => e
        { "requested" => true, "sent" => false, "error" => e.message }
      end

      def self.review_status_payload(summary)
        state = summary.fetch("app_store_version_state")
        version = summary.fetch("marketing_version")
        {
          "schema_version" => 1,
          "source" => "manual_query",
          "event_id" => nil,
          "event_type" => "ASC_REVIEW_STATUS_QUERY",
          "app_id" => summary.fetch("app_id"),
          "app_display_name" => nil,
          "app_store_version_id" => summary.fetch("app_store_version_id"),
          "marketing_version" => version,
          "old_state" => nil,
          "new_state" => state,
          "status_group" => summary.fetch("status_group"),
          "attention_required" => summary.fetch("attention_required"),
          "terminal" => summary.fetch("terminal"),
          "timestamp" => summary.fetch("checked_at"),
          "received_at" => summary.fetch("checked_at"),
          "text" => "[ASC] iOS #{version} review state: #{state}"
        }
      end

      def initialize(url:, bearer_token: "", transport: nil)
        @uri = URI.parse(url)
        unless @uri.scheme == "https" && @uri.host && !@uri.host.empty? && !@uri.userinfo && !@uri.fragment
          raise WebhookDeliveryError, "notification webhook URL must be an HTTPS URL without credentials or a fragment"
        end

        @bearer_token = bearer_token.to_s
        if @bearer_token.match?(/[\r\n]/)
          raise WebhookDeliveryError, "notification webhook bearer token contains a line break"
        end
        @transport = transport
      rescue URI::InvalidURIError
        raise WebhookDeliveryError, "notification webhook URL is invalid"
      end

      def deliver(payload)
        request = Net::HTTP::Post.new(@uri)
        request["Accept"] = "application/json"
        request["Content-Type"] = "application/json"
        request["User-Agent"] = USER_AGENT
        request["Authorization"] = "Bearer #{@bearer_token}" unless @bearer_token.empty?
        request.body = JSON.generate(payload)

        response = if @transport
                     @transport.call(@uri, request)
                   else
                     Net::HTTP.start(
                       @uri.host,
                       @uri.port,
                       use_ssl: true,
                       open_timeout: 10,
                       read_timeout: 20
                     ) { |http| http.request(request) }
                   end
        status = response.code.to_i
        unless status.between?(200, 299)
          raise WebhookDeliveryError, "notification webhook returned HTTP #{status}"
        end

        { "status_code" => status }
      rescue Timeout::Error, SocketError, SystemCallError, EOFError, IOError,
             Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, OpenSSL::SSL::SSLError => e
        raise WebhookDeliveryError, "notification webhook delivery failed: #{e.class}"
      end
    end
  end
end
