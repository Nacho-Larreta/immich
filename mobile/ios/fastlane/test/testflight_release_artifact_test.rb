# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../testflight_release_artifact"

class TestFlightReleaseArtifactTest < Minitest::Test
  METADATA = {
    "CFBundleIdentifier" => "com.example.private",
    "CFBundleShortVersionString" => "2.7.5",
    "CFBundleVersion" => "3047",
    "ITSAppUsesNonExemptEncryption" => false
  }.freeze

  def test_copies_and_validates_a_private_snapshot_then_cleans_it
    with_source_ipa do |source, temporary_root|
      snapshot = create_snapshot(source, temporary_root: temporary_root)

      refute_equal source, snapshot.path
      assert_equal File.binread(source), File.binread(snapshot.path)
      assert_equal 0o600, File.stat(snapshot.path).mode & 0o777
      assert snapshot.verify_unchanged!

      snapshot.cleanup!
      refute File.exist?(snapshot.path)
    end
  end

  def test_rejects_bundle_id_and_encryption_mismatch_and_cleans_partial_snapshot
    invalid_metadata = [
      METADATA.merge("CFBundleIdentifier" => "com.example.other"),
      METADATA.merge("ITSAppUsesNonExemptEncryption" => true),
      METADATA.merge("ITSAppUsesNonExemptEncryption" => nil)
    ]

    invalid_metadata.each do |metadata|
      with_source_ipa do |source, temporary_root|
        assert_raises(TestFlightReleaseArtifact::InvalidArtifact) do
          create_snapshot(source, temporary_root: temporary_root, metadata: metadata)
        end
        assert_empty Dir.children(temporary_root)
      end
    end
  end

  def test_detects_snapshot_content_replacement
    with_source_ipa do |source, temporary_root|
      snapshot = create_snapshot(source, temporary_root: temporary_root)
      File.binwrite(snapshot.path, "replacement")

      assert_raises(TestFlightReleaseArtifact::InvalidArtifact) { snapshot.verify_unchanged! }
      snapshot.cleanup!
      refute File.exist?(snapshot.path)
    end
  end

  def test_cleanup_preserves_racer_that_wins_just_before_move
    with_source_ipa do |source, temporary_root|
      snapshot = create_snapshot(source, temporary_root: temporary_root)
      racer_content = "racer-must-survive"

      snapshot.cleanup!(
        before_remove: lambda do
          racer = File.join(File.dirname(snapshot.path), "racer")
          File.binwrite(racer, racer_content)
          File.rename(racer, snapshot.path)
        end
      )

      assert_equal racer_content, File.binread(snapshot.path)
      assert_empty Dir.children(File.dirname(snapshot.path)).grep(/immich-quarantine/)
    end
  end

  def test_partial_cleanup_preserves_racer_that_wins_just_before_move
    with_source_ipa do |source, temporary_root|
      racer_content = "racer-must-survive"
      assert_raises(TestFlightReleaseArtifact::InvalidArtifact) do
        TestFlightReleaseArtifact::Snapshot.create(
          source_path: source,
          bundle_id: METADATA.fetch("CFBundleIdentifier"),
          version: METADATA.fetch("CFBundleShortVersionString"),
          build_number: METADATA.fetch("CFBundleVersion"),
          metadata_reader: ->(_path, key) { METADATA.merge("CFBundleIdentifier" => "wrong")[key] },
          temporary_root: temporary_root,
          before_partial_cleanup: lambda do
            snapshot_directory = File.join(temporary_root, Dir.children(temporary_root).fetch(0))
            path = File.join(snapshot_directory, "release.ipa")
            racer = File.join(snapshot_directory, "racer")
            File.binwrite(racer, racer_content)
            File.rename(racer, path)
          end
        )
      end

      snapshot_directory = File.join(temporary_root, Dir.children(temporary_root).fetch(0))
      assert_equal racer_content, File.binread(File.join(snapshot_directory, "release.ipa"))
      assert_empty Dir.children(snapshot_directory).grep(/immich-quarantine/)
    end
  end

  def test_rejects_source_symlink
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source.ipa")
      symlink = File.join(directory, "symlink.ipa")
      File.binwrite(source, "ipa")
      File.symlink(source, symlink)

      assert_raises(TestFlightReleaseArtifact::InvalidArtifact) do
        create_snapshot(symlink, temporary_root: directory)
      end
    end
  end

  private

  def create_snapshot(source, temporary_root:, metadata: METADATA)
    TestFlightReleaseArtifact::Snapshot.create(
      source_path: source,
      bundle_id: METADATA.fetch("CFBundleIdentifier"),
      version: METADATA.fetch("CFBundleShortVersionString"),
      build_number: METADATA.fetch("CFBundleVersion"),
      metadata_reader: ->(_path, key) { metadata[key] },
      temporary_root: temporary_root
    )
  end

  def with_source_ipa
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source.ipa")
      temporary_root = File.join(directory, "snapshots")
      Dir.mkdir(temporary_root, 0o700)
      File.binwrite(source, "representative ipa bytes")
      yield source, temporary_root
    end
  end
end
