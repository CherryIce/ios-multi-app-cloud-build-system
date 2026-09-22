# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/lib/app_store_metadata"
require_relative "../scripts/lib/app_store_release"

class ScriptedASCClient
  attr_reader :calls

  def initialize
    @responses = Hash.new { |hash, key| hash[key] = [] }
    @calls = []
  end

  def enqueue(method, path, response)
    @responses[[method, path]] << response
  end

  def get(path, query = nil)
    take(:get, path, query)
  end

  def post(path, payload)
    take(:post, path, payload)
  end

  def patch(path, payload)
    take(:patch, path, payload)
  end

  def paginate(path, query = nil, max_pages: 20)
    _ = max_pages
    take(:paginate, path, query)
  end

  private

  def take(method, path, argument)
    @calls << [method, path, argument]
    responses = @responses[[method, path]]
    raise "unexpected #{method} #{path}" if responses.empty?

    responses.shift
  end
end

class AppStoreReleaseTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  METADATA_PATH = File.join(__dir__, "fixtures/app-store/metadata.yml")
  APP_ID = "1234567890"
  VERSION = "1.0.2"
  BUILD_ID = "build-102"
  BUILD_NUMBER = "42"
  VERSION_ID = "version-102"

  def setup
    @metadata = IOSBuild::ASC::AppStoreMetadata.load_file(METADATA_PATH)
  end

  def test_metadata_requires_release_notes_and_protected_demo_credentials
    invalid = Marshal.load(Marshal.dump(@metadata))
    invalid["localizations"]["en-US"]["whats_new"] = ""
    error = assert_raises(IOSBuild::ASC::MetadataError) do
      IOSBuild::ASC::AppStoreMetadata.validate!(invalid)
    end
    assert_includes error.message, "whats_new"

    protected_metadata = Marshal.load(Marshal.dump(@metadata))
    protected_metadata["review_detail"]["demo_account_required"] = true
    assert_raises(IOSBuild::ASC::MetadataError) do
      IOSBuild::ASC::AppStoreMetadata.review_detail_attributes(
        protected_metadata,
        demo_account_name: "",
        demo_account_password: ""
      )
    end
  end

  def test_creates_version_syncs_metadata_and_attaches_exact_build_without_submitting
    client = ScriptedASCClient.new
    versions_path = "/v1/apps/#{APP_ID}/appStoreVersions"
    client.enqueue(:paginate, versions_path, [])
    client.enqueue(:paginate, versions_path, [distributed_version("1.0.1")])
    client.enqueue(:post, "/v1/appStoreVersions", { "data" => editable_version("AFTER_APPROVAL") })
    client.enqueue(:paginate, "/v1/appStoreVersions/#{VERSION_ID}/appStoreVersionLocalizations", [])
    2.times { client.enqueue(:post, "/v1/appStoreVersionLocalizations", {}) }
    client.enqueue(:get, "/v1/appStoreVersions/#{VERSION_ID}/appStoreReviewDetail", { "data" => nil })
    client.enqueue(:post, "/v1/appStoreReviewDetails", {})
    client.enqueue(:get, "/v1/builds/#{BUILD_ID}", valid_build_response)
    relationship_path = "/v1/appStoreVersions/#{VERSION_ID}/relationships/build"
    client.enqueue(:patch, relationship_path, {})
    client.enqueue(:get, relationship_path, { "data" => { "type" => "builds", "id" => BUILD_ID } })

    summary = release(client, submit: false).execute

    assert_equal true, summary["version_created"]
    assert_equal true, summary["build_attached"]
    assert_equal false, summary["review_submitted"]
    create_call = client.calls.find { |method, path, _| method == :post && path == "/v1/appStoreVersions" }
    assert_equal "AFTER_APPROVAL", create_call.last.dig("data", "attributes", "releaseType")
    refute client.calls.any? { |_method, path, _| path.include?("reviewSubmissions") }
  end

  def test_prepare_phase_creates_the_store_version_before_build_processing
    client = ScriptedASCClient.new
    versions_path = "/v1/apps/#{APP_ID}/appStoreVersions"
    client.enqueue(:paginate, versions_path, [])
    client.enqueue(:paginate, versions_path, [distributed_version("1.0.1")])
    client.enqueue(:post, "/v1/appStoreVersions", { "data" => editable_version("AFTER_APPROVAL") })
    client.enqueue(:paginate, "/v1/appStoreVersions/#{VERSION_ID}/appStoreVersionLocalizations", [])
    2.times { client.enqueue(:post, "/v1/appStoreVersionLocalizations", {}) }
    client.enqueue(:get, "/v1/appStoreVersions/#{VERSION_ID}/appStoreReviewDetail", { "data" => nil })
    client.enqueue(:post, "/v1/appStoreReviewDetails", {})
    release = IOSBuild::ASC::AppStoreRelease.new(
      client: client,
      app_id: APP_ID,
      marketing_version: VERSION,
      metadata: @metadata,
      automatic_release: true,
      submit_to_review: false
    )

    summary = release.prepare

    assert_equal true, summary["version_created"]
    assert_equal true, summary["metadata_synced"]
    refute client.calls.any? { |_method, path, _| path.start_with?("/v1/builds/") }
  end

  def test_prepare_phase_is_a_no_op_for_an_already_submitted_version
    client = ScriptedASCClient.new
    submitted_version = editable_version("MANUAL")
    submitted_version["attributes"]["appVersionState"] = "WAITING_FOR_REVIEW"
    client.enqueue(:paginate, "/v1/apps/#{APP_ID}/appStoreVersions", [submitted_version])

    summary = release(client, submit: true).prepare

    assert_equal true, summary["already_submitted"]
    assert_equal true, summary["no_op"]
    assert_equal "already_submitted", summary["no_op_reason"]
    assert_equal 1, client.calls.length
  end

  def test_prepare_phase_is_a_no_op_for_an_already_released_version
    client = ScriptedASCClient.new
    client.enqueue(:paginate, "/v1/apps/#{APP_ID}/appStoreVersions", [distributed_version(VERSION)])

    summary = release(client, submit: true).prepare

    assert_equal true, summary["already_released"]
    assert_equal true, summary["no_op"]
    assert_equal "already_released", summary["no_op_reason"]
    assert_equal 1, client.calls.length
  end

  def test_reuses_version_and_submits_a_review_submission
    client = ScriptedASCClient.new
    versions_path = "/v1/apps/#{APP_ID}/appStoreVersions"
    client.enqueue(:paginate, versions_path, [editable_version("MANUAL")])
    client.enqueue(:patch, "/v1/appStoreVersions/#{VERSION_ID}", { "data" => editable_version("AFTER_APPROVAL") })
    localizations_path = "/v1/appStoreVersions/#{VERSION_ID}/appStoreVersionLocalizations"
    client.enqueue(:paginate, localizations_path, [localization("en-US", "loc-en"), localization("zh-Hans", "loc-zh")])
    client.enqueue(:patch, "/v1/appStoreVersionLocalizations/loc-en", {})
    client.enqueue(:patch, "/v1/appStoreVersionLocalizations/loc-zh", {})
    client.enqueue(
      :get,
      "/v1/appStoreVersions/#{VERSION_ID}/appStoreReviewDetail",
      { "data" => { "type" => "appStoreReviewDetails", "id" => "review-detail-1" } }
    )
    client.enqueue(:patch, "/v1/appStoreReviewDetails/review-detail-1", {})
    client.enqueue(:get, "/v1/builds/#{BUILD_ID}", valid_build_response)
    relationship_path = "/v1/appStoreVersions/#{VERSION_ID}/relationships/build"
    client.enqueue(:patch, relationship_path, {})
    client.enqueue(:get, relationship_path, { "data" => { "type" => "builds", "id" => BUILD_ID } })
    submissions_path = "/v1/apps/#{APP_ID}/reviewSubmissions"
    client.enqueue(:paginate, submissions_path, [])
    client.enqueue(:paginate, submissions_path, [])
    client.enqueue(:post, "/v1/reviewSubmissions", { "data" => review_submission("READY_FOR_REVIEW") })
    client.enqueue(:post, "/v1/reviewSubmissionItems", {})
    client.enqueue(:patch, "/v1/reviewSubmissions/submission-1", { "data" => review_submission("WAITING_FOR_REVIEW") })
    client.enqueue(:get, "/v1/reviewSubmissions/submission-1", { "data" => review_submission("WAITING_FOR_REVIEW") })

    summary = release(client, submit: true).execute

    assert_equal true, summary["review_submitted"]
    assert_equal "submission-1", summary["review_submission_id"]
    assert_equal "WAITING_FOR_REVIEW", summary["review_submission_state"]
    submit_call = client.calls.find do |method, path, _argument|
      method == :patch && path == "/v1/reviewSubmissions/submission-1"
    end
    assert_equal true, submit_call.last.dig("data", "attributes", "submitted")
  end

  def test_rerun_confirms_existing_submission_without_mutation
    client = ScriptedASCClient.new
    submitted_version = editable_version("AFTER_APPROVAL")
    submitted_version["attributes"]["appVersionState"] = "WAITING_FOR_REVIEW"
    client.enqueue(:paginate, "/v1/apps/#{APP_ID}/appStoreVersions", [submitted_version])

    summary = release(client, submit: true).execute

    assert_equal true, summary["already_submitted"]
    assert_equal true, summary["review_submitted"]
    assert_equal true, summary["no_op"]
    assert_equal "already_submitted", summary["no_op_reason"]
    refute client.calls.any? { |method, _path, _| %i[post patch].include?(method) }
    refute client.calls.any? { |_method, path, _| path.start_with?("/v1/builds/") }
  end

  def test_submitted_version_is_a_no_op_even_when_the_new_upload_is_a_different_build
    client = ScriptedASCClient.new
    submitted_version = editable_version("AFTER_APPROVAL")
    submitted_version["attributes"]["appVersionState"] = "WAITING_FOR_REVIEW"
    client.enqueue(:paginate, "/v1/apps/#{APP_ID}/appStoreVersions", [submitted_version])

    summary = release(client, submit: true).execute

    assert_equal true, summary["no_op"]
    assert_equal "already_submitted", summary["no_op_reason"]
    assert_equal false, summary["build_attached"]
    assert_equal [[:paginate, "/v1/apps/#{APP_ID}/appStoreVersions", {
      "filter[versionString]" => VERSION,
      "filter[platform]" => "IOS",
      "limit" => "200"
    }]], client.calls
  end

  def test_does_not_reuse_a_completed_submission_for_an_editable_version
    client = ScriptedASCClient.new
    versions_path = "/v1/apps/#{APP_ID}/appStoreVersions"
    client.enqueue(:paginate, versions_path, [editable_version("AFTER_APPROVAL")])
    client.enqueue(:get, "/v1/builds/#{BUILD_ID}", valid_build_response)
    localizations_path = "/v1/appStoreVersions/#{VERSION_ID}/appStoreVersionLocalizations"
    client.enqueue(:paginate, localizations_path, [localization("en-US", "loc-en"), localization("zh-Hans", "loc-zh")])
    client.enqueue(:patch, "/v1/appStoreVersionLocalizations/loc-en", {})
    client.enqueue(:patch, "/v1/appStoreVersionLocalizations/loc-zh", {})
    client.enqueue(
      :get,
      "/v1/appStoreVersions/#{VERSION_ID}/appStoreReviewDetail",
      { "data" => { "type" => "appStoreReviewDetails", "id" => "review-detail-1" } }
    )
    client.enqueue(:patch, "/v1/appStoreReviewDetails/review-detail-1", {})
    relationship_path = "/v1/appStoreVersions/#{VERSION_ID}/relationships/build"
    client.enqueue(:patch, relationship_path, {})
    client.enqueue(:get, relationship_path, { "data" => { "type" => "builds", "id" => BUILD_ID } })
    submissions_path = "/v1/apps/#{APP_ID}/reviewSubmissions"
    client.enqueue(:paginate, submissions_path, [review_submission("COMPLETE")])
    client.enqueue(:paginate, submissions_path, [review_submission("COMPLETE")])
    client.enqueue(:post, "/v1/reviewSubmissions", { "data" => review_submission("READY_FOR_REVIEW") })
    client.enqueue(:post, "/v1/reviewSubmissionItems", {})
    client.enqueue(:patch, "/v1/reviewSubmissions/submission-1", { "data" => review_submission("WAITING_FOR_REVIEW") })
    client.enqueue(:get, "/v1/reviewSubmissions/submission-1", { "data" => review_submission("WAITING_FOR_REVIEW") })

    summary = release(client, submit: true).execute

    assert_equal true, summary["review_submitted"]
    assert client.calls.any? { |method, path, _| method == :post && path == "/v1/reviewSubmissions" }
  end

  def test_rejects_build_from_a_different_marketing_version
    client = ScriptedASCClient.new
    client.enqueue(:paginate, "/v1/apps/#{APP_ID}/appStoreVersions", [editable_version("AFTER_APPROVAL")])
    client.enqueue(:paginate, "/v1/appStoreVersions/#{VERSION_ID}/appStoreVersionLocalizations", [])
    2.times { client.enqueue(:post, "/v1/appStoreVersionLocalizations", {}) }
    client.enqueue(:get, "/v1/appStoreVersions/#{VERSION_ID}/appStoreReviewDetail", { "data" => nil })
    client.enqueue(:post, "/v1/appStoreReviewDetails", {})
    wrong_build = valid_build_response
    wrong_build["included"][0]["attributes"]["version"] = "9.9.9"
    client.enqueue(:get, "/v1/builds/#{BUILD_ID}", wrong_build)

    error = assert_raises(IOSBuild::ASC::ReleaseError) { release(client, submit: false).execute }
    assert_includes error.message, "does not belong"
  end

  def test_already_distributed_target_version_is_a_successful_no_op
    client = ScriptedASCClient.new
    client.enqueue(:paginate, "/v1/apps/#{APP_ID}/appStoreVersions", [distributed_version(VERSION)])

    summary = release(client, submit: true).execute

    assert_equal true, summary["already_released"]
    assert_equal true, summary["no_op"]
    assert_equal "already_released", summary["no_op_reason"]
    assert_equal false, summary["review_submitted"]
    refute client.calls.any? { |_method, path, _| path.start_with?("/v1/builds/") }
  end

  def test_historically_released_target_version_is_a_successful_no_op
    client = ScriptedASCClient.new
    historical = distributed_version(VERSION)
    historical["attributes"]["appVersionState"] = "REPLACED_WITH_NEW_VERSION"
    client.enqueue(:paginate, "/v1/apps/#{APP_ID}/appStoreVersions", [historical])

    summary = release(client, submit: true).execute

    assert_equal true, summary["already_released"]
    assert_equal "already_released", summary["no_op_reason"]
    assert_equal 1, client.calls.length
  end

  def test_ready_for_review_version_is_updated_with_the_new_build_and_submitted
    client = ScriptedASCClient.new
    draft = editable_version("MANUAL")
    draft["attributes"]["appVersionState"] = "READY_FOR_REVIEW"
    client.enqueue(:paginate, "/v1/apps/#{APP_ID}/appStoreVersions", [draft])
    client.enqueue(:get, "/v1/builds/#{BUILD_ID}", valid_build_response)
    updated = editable_version("AFTER_APPROVAL")
    updated["attributes"]["appVersionState"] = "READY_FOR_REVIEW"
    client.enqueue(:patch, "/v1/appStoreVersions/#{VERSION_ID}", { "data" => updated })
    localizations_path = "/v1/appStoreVersions/#{VERSION_ID}/appStoreVersionLocalizations"
    client.enqueue(:paginate, localizations_path, [localization("en-US", "loc-en"), localization("zh-Hans", "loc-zh")])
    client.enqueue(:patch, "/v1/appStoreVersionLocalizations/loc-en", {})
    client.enqueue(:patch, "/v1/appStoreVersionLocalizations/loc-zh", {})
    client.enqueue(
      :get,
      "/v1/appStoreVersions/#{VERSION_ID}/appStoreReviewDetail",
      { "data" => { "type" => "appStoreReviewDetails", "id" => "review-detail-1" } }
    )
    client.enqueue(:patch, "/v1/appStoreReviewDetails/review-detail-1", {})
    relationship_path = "/v1/appStoreVersions/#{VERSION_ID}/relationships/build"
    client.enqueue(:patch, relationship_path, {})
    client.enqueue(:get, relationship_path, { "data" => { "type" => "builds", "id" => BUILD_ID } })
    submissions_path = "/v1/apps/#{APP_ID}/reviewSubmissions"
    client.enqueue(:paginate, submissions_path, [])
    client.enqueue(:paginate, submissions_path, [])
    client.enqueue(:post, "/v1/reviewSubmissions", { "data" => review_submission("READY_FOR_REVIEW") })
    client.enqueue(:post, "/v1/reviewSubmissionItems", {})
    client.enqueue(:patch, "/v1/reviewSubmissions/submission-1", { "data" => review_submission("WAITING_FOR_REVIEW") })
    client.enqueue(:get, "/v1/reviewSubmissions/submission-1", { "data" => review_submission("WAITING_FOR_REVIEW") })

    summary = release(client, submit: true).execute

    assert_equal true, summary["build_attached"]
    assert_equal true, summary["review_submitted"]
    assert_equal false, summary["no_op"]
    release_update = client.calls.find do |method, path, _argument|
      method == :patch && path == "/v1/appStoreVersions/#{VERSION_ID}"
    end
    assert_equal "AFTER_APPROVAL", release_update.last.dig("data", "attributes", "releaseType")
  end

  private

  def release(client, submit:)
    IOSBuild::ASC::AppStoreRelease.new(
      client: client,
      app_id: APP_ID,
      marketing_version: VERSION,
      build_id: BUILD_ID,
      build_number: BUILD_NUMBER,
      metadata: @metadata,
      automatic_release: true,
      submit_to_review: submit
    )
  end

  def distributed_version(version)
    {
      "type" => "appStoreVersions",
      "id" => "distributed-#{version}",
      "attributes" => {
        "versionString" => version,
        "appVersionState" => "READY_FOR_DISTRIBUTION"
      }
    }
  end

  def editable_version(release_type)
    {
      "type" => "appStoreVersions",
      "id" => VERSION_ID,
      "attributes" => {
        "versionString" => VERSION,
        "appVersionState" => "PREPARE_FOR_SUBMISSION",
        "releaseType" => release_type,
        "copyright" => @metadata["copyright"],
        "usesIdfa" => false
      }
    }
  end

  def localization(locale, id)
    {
      "type" => "appStoreVersionLocalizations",
      "id" => id,
      "attributes" => { "locale" => locale }
    }
  end

  def valid_build_response
    {
      "data" => {
        "type" => "builds",
        "id" => BUILD_ID,
        "attributes" => {
          "version" => BUILD_NUMBER,
          "processingState" => "VALID",
          "usesNonExemptEncryption" => false
        },
        "relationships" => {
          "preReleaseVersion" => {
            "data" => { "type" => "preReleaseVersions", "id" => "prerelease-102" }
          }
        }
      },
      "included" => [{
        "type" => "preReleaseVersions",
        "id" => "prerelease-102",
        "attributes" => { "version" => VERSION }
      }]
    }
  end

  def review_submission(state)
    {
      "type" => "reviewSubmissions",
      "id" => "submission-1",
      "attributes" => { "platform" => "IOS", "state" => state }
    }
  end
end
