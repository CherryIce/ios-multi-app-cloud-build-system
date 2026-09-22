# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/lib/app_resolver"

class AppResolverTest < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(apps)
      @apps = apps
      @calls = []
    end

    def paginate(path, query)
      @calls << [path, query]
      @apps
    end
  end

  def test_resolves_unique_app_from_bundle_id
    client = FakeClient.new([{ "type" => "apps", "id" => "1234567890" }])
    resolver = IOSBuild::ASC::AppResolver.new(client: client)

    assert_equal "1234567890", resolver.resolve(bundle_id: "com.example.app", configured_id: "0")
    assert_equal [
      "/v1/apps",
      { "filter[bundleId]" => "com.example.app", "limit" => "2" }
    ], client.calls.first
  end

  def test_rejects_missing_or_ambiguous_apps
    empty = IOSBuild::ASC::AppResolver.new(client: FakeClient.new([]))
    assert_raises(IOSBuild::ASC::AppResolutionError) do
      empty.resolve(bundle_id: "com.example.app", configured_id: "0")
    end

    ambiguous = IOSBuild::ASC::AppResolver.new(
      client: FakeClient.new([{ "id" => "1" }, { "id" => "2" }])
    )
    assert_raises(IOSBuild::ASC::AppResolutionError) do
      ambiguous.resolve(bundle_id: "com.example.app", configured_id: "0")
    end
  end

  def test_rejects_configured_id_mismatch
    resolver = IOSBuild::ASC::AppResolver.new(client: FakeClient.new([{ "id" => "1234567890" }]))

    error = assert_raises(IOSBuild::ASC::AppResolutionError) do
      resolver.resolve(bundle_id: "com.example.app", configured_id: "9999999999")
    end
    assert_includes error.message, "does not match bundle ID"
  end
end
