# frozen_string_literal: true

module Dials
  # App-wide configuration, set once at boot via Dials.configure.
  class Config
    # Seconds between staleness probes (see Cache). 0 probes every read;
    # nil never probes.
    attr_reader :cache_ttl

    # Builds the human label stored on every change-log entry.
    attr_accessor :actor_label

    # Fallback attribution for writes that pass no actor: — for apps without
    # user identity (no User model, single-operator tools, scripts). A
    # string/object, or a callable evaluated per write
    # (`-> { ENV.fetch("USER", "console") }`). nil (the default) keeps
    # actor: required on every write. This is a declared app-level fallback,
    # not discovery — the gem still never guesses (no Current.user magic),
    # and an explicit actor: always wins.
    attr_accessor :default_actor

    def initialize
      @store = nil
      @cache_ttl = 5.0
      @actor_label = Actor::DEFAULT_LABEL
      @default_actor = nil
    end

    def cache_ttl=(seconds)
      @cache_ttl = seconds
      Dials.cache.ttl = seconds
    end

    # Accepts a store instance, or the symbols :memory / :active_record.
    def store=(store)
      @store = case store
               when :memory then Stores::Memory.new
               when :active_record
                 require "dials/active_record"
                 Stores::ActiveRecordStore.new
               else store
               end
      Dials.reset_cache!
    end

    def store
      @store ||= Stores::Memory.new
    end
  end
end
