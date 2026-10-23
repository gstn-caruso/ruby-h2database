# frozen_string_literal: true

require_relative "test_helper"
require "h2/mvstore"
require "tmpdir"

class TimeZoneTest < Minitest::Test
  def test_fixed_offsets_match_h2_parsing_and_bounds
    {"Z" => 0, "UTC" => 0, "GMT" => 0, "+3" => 10_800, "UTC-03:30:15" => -12_615,
      "+12:99" => 49_140, "+18:00" => 64_800, "-18" => -64_800, "5:00" => 18_000}.each do |name, offset|
      zone = H2::TimeZone.parse(name)
      assert zone.fixed?
      assert_equal offset, zone.offset_utc(0)
      assert_equal offset, zone.offset_local(H2::DateValue.new(2000, 1, 1), 0)
    end
    ["+18:00:01", "-19", "UTCbad", "../etc/passwd", "Europe/../Paris", "missing/zone"].each do |name|
      assert_equal 90008, assert_raises(H2::Error) { H2::TimeZone.parse(name) }.code
    end
  end

  def test_named_zones_resolve_transitions_gaps_and_overlaps_without_global_changes
    original = ENV["TZ"]
    zone = H2::TimeZone.parse("America/New_York")
    refute zone.fixed?
    assert_equal(-18_000, zone.offset_local(H2::DateValue.new(2024, 1, 1), 0))
    assert_equal(-14_400, zone.offset_local(H2::DateValue.new(2024, 7, 1), 0))
    gap = H2::DateValue.new(2024, 3, 10)
    nanos = H2::TimeValue.parse("02:30:00").nanos
    assert_equal(-14_400, zone.offset_local(gap, nanos))
    assert_equal gap.absolute_day * 86_400 + 2 * 3600 + 1800 + 18_000, zone.epoch_local(gap, nanos)
    assert_equal(-14_400, zone.offset_local(H2::DateValue.new(2024, 11, 3), H2::TimeValue.parse("01:30:00").nanos))
    assert ENV["TZ"] == original
  end

  def test_future_rules_cover_gregorian_cycles_and_non_hour_dst
    zone = H2::TimeZone.parse("Europe/Paris")
    [2400, 2800, 999_999_999, 1_000_000_000].each do |year|
      assert_equal 3600, zone.offset_local(H2::DateValue.new(year, 1, 15), 0)
      assert_equal 7200, zone.offset_local(H2::DateValue.new(year, 7, 15), 0)
    end
    lord_howe = H2::TimeZone.parse("Australia/Lord_Howe")
    assert_equal 39_600, lord_howe.offset_local(H2::DateValue.new(2400, 1, 15), 0)
    assert_equal 37_800, lord_howe.offset_local(H2::DateValue.new(2400, 7, 15), 0)
    assert_equal 561, zone.offset_local(H2::DateValue.new(-1_000_000_000, 1, 1), 0)
  end

  def test_native_maps_compare_zoned_keys_as_unwrapped_instants
    Dir.mktmpdir do |directory|
      path = File.join(directory, "zone-keys")
      date = H2::DateValue.new(2000, 1, 1).packed
      hour = 3600 * H2::Temporal::SECOND
      keys = {
        "time" => [H2::MVStore::Value.new(:time_tz, [12 * hour, 10_800]), H2::MVStore::Value.new(:time_tz, [9 * hour, 0])],
        "timestamp" => [H2::MVStore::Value.new(:timestamp_tz, [date, 12 * hour, 10_800]), H2::MVStore::Value.new(:timestamp_tz, [date, 9 * hour, 0])]
      }
      H2::MVStore::Store.open(path) do |store|
        keys.each do |name, (first, same)|
          map = store.open_map(name, key_type: :value, value_type: :string)
          map[first] = "first"
          map[same] = "same instant"
          assert_equal 1, map.size
          assert_equal "same instant", map[first]
        end
      end
      H2::MVStore::Store.open(path, read_only: true) do |store|
        keys.each do |name, (first, _same)|
          assert_equal "same instant", store.open_map(name, key_type: :value, value_type: :string)[first]
        end
      end
    end
  end
end
