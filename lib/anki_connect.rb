# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# Talks to the Anki desktop app through the AnkiConnect add-on
# (https://git.sr.ht/~foosoft/anki-connect), which runs a JSON-RPC HTTP server
# on localhost:8765 while Anki is open.
#
# This is a drop-in replacement for the old AnkiDatabase class, which wrote the
# collection.anki2 SQLite file directly. Because Anki itself performs every
# write here, all of the bespoke machinery that direct access required —
# unicase collation stubs, \x1f field-separator handling, field padding, usn/mod
# sync bookkeeping, GUID/csum generation, and "close Anki / back up first"
# safety checks — is gone.
#
# Field conversion: scripts work with an ordered field array indexed by
# Kaishi::*_IDX. AnkiConnect works with a name->value hash. This class converts
# between the two using the note type's field order (cached from modelFieldNames
# for writes; reads carry their own `order` so no lookup is needed).
#
# IMPORTANT inversion vs. the old layer: Anki must be RUNNING (with the
# AnkiConnect add-on installed) for any of this to work.
class AnkiConnect
  DEFAULT_ENDPOINT = 'http://127.0.0.1:8765'
  API_VERSION = 6
  API_KEY_ENV = 'ANKICONNECT_API_KEY'

  class Error < StandardError; end
  class NotRunningError < Error; end

  # The API key comes from $ANKICONNECT_API_KEY by default, matching the
  # "apiKey" set in AnkiConnect's add-on config. It's sent as "key" on every
  # request; with no key set, requests go out without one.
  def initialize(endpoint = DEFAULT_ENDPOINT, api_key: ENV.fetch(API_KEY_ENV, nil))
    @uri = URI(endpoint)
    @api_key = api_key unless api_key.to_s.empty?
    @field_names = {} # model name => ordered [field names]
  end

  # Verify the AnkiConnect server is reachable. Kept for API symmetry with the
  # old AnkiDatabase#connect; raises NotRunningError if Anki/AnkiConnect is down.
  def connect
    version
    self
  end

  # No-op: there is no persistent connection to close. Present so callers that
  # did `ensure db.close` keep working unchanged.
  def close
    nil
  end

  # --- Server / safety ------------------------------------------------------

  def version
    invoke('version')
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, Net::OpenTimeout => e
    raise NotRunningError, "Cannot reach AnkiConnect at #{@uri}: #{e.message}. " \
                           "Start Anki (with the AnkiConnect add-on installed)."
  end

  # Replaces the old AnkiDatabase.exit_if_anki_running! guard, but inverted:
  # every script now REQUIRES Anki to be running. Also exits on a rejected API
  # key, since `version` needs one too.
  def self.require_running!(endpoint = DEFAULT_ENDPOINT)
    new(endpoint).version
  rescue Error => e
    warn "Error: #{e.message}"
    exit 1
  end

  # Trigger a sync with AnkiWeb.
  def sync
    invoke('sync')
  end

  # No transactions over AnkiConnect. This yields so existing
  # `db.transaction do ... end` blocks keep working, but it is NOT atomic:
  # a failure partway through leaves earlier writes committed. Batch creates
  # should use add_notes (a single request) and stay idempotent on re-run.
  def transaction
    yield
  end

  # --- Decks / note types ---------------------------------------------------

  # Returns the deck name itself (truthy) if it exists, else nil. The old API
  # returned an integer deck id; downstream code only used it for truthiness
  # and to scope queries, both of which work with the name.
  def find_deck_id(name)
    deck_names.include?(name) ? name : nil
  end

  def deck_names
    invoke('deckNames')
  end

  # Delete one or more decks along with their cards. cardsToo must be true —
  # AnkiConnect refuses to delete a non-empty deck otherwise. Returns nil.
  def delete_deck(*names)
    invoke('deleteDecks', decks: names.flatten, cardsToo: true)
  end

  # Returns the note type name itself (truthy) if it exists, else nil.
  def find_note_type_id(name)
    invoke('modelNames').include?(name) ? name : nil
  end

  # Ordered field names for a note type, cached.
  def field_names(model_name)
    @field_names[model_name] ||= invoke('modelFieldNames', modelName: model_name)
  end

  # --- Reading notes --------------------------------------------------------

  # Returns { id:, fields: [ordered array], mod:, tags: } or nil — same shape as
  # the old AnkiDatabase#get_note, plus the note's tags.
  def get_note(note_id)
    info = invoke('notesInfo', notes: [note_id]).first
    return nil if info.nil? || info.empty?

    { id: info['noteId'], fields: fields_to_array(info['fields']),
      mod: info['mod'], tags: info['tags'] }
  end

  # Find note ids matching an Anki browser search query
  # (e.g. 'note:"Kaishi 1.5k" deck:"日本語の言葉"').
  def find_note_ids(query)
    invoke('findNotes', query: query)
  end

  # Returns [{ id:, fields: [ordered array], mod:, tags: }] for a search query.
  # Replaces the raw `instance_variable_get(:@db).execute(...)` note
  # enumerations scattered across the scripts.
  def find_notes(query)
    ids = find_note_ids(query)
    return [] if ids.empty?

    invoke('notesInfo', notes: ids).map do |info|
      { id: info['noteId'], fields: fields_to_array(info['fields']),
        mod: info['mod'], tags: info['tags'] }
    end
  end

  # Convenience: all notes of a note type within a deck (includes subdecks, per
  # Anki query semantics). Pass exclude_deck to get the inverse scoping the old
  # "all decks except X" queries used.
  def notes_in_deck(deck, note_type:, exclude_deck: nil)
    find_notes(deck_query(note_type, deck, exclude_deck))
  end

  # Like notes_in_deck, but each result also carries the deck name of its first
  # card ({ id:, fields:, deck:, tags: }). Uses findCards + cardsInfo because
  # notesInfo does not report decks; cardsInfo in turn does not report tags, so
  # tags are fetched with a second notesInfo batch and merged in by note id. Our
  # note type has one card per note, so "first card's deck" matches the old
  # per-note deck lookup.
  def notes_in_deck_with_deck(deck, note_type:, exclude_deck: nil)
    ids = invoke('findCards', query: deck_query(note_type, deck, exclude_deck))
    return [] if ids.empty?

    by_note = {}
    invoke('cardsInfo', cards: ids).each do |c|
      by_note[c['note']] ||= {
        id: c['note'],
        fields: fields_to_array(c['fields']),
        deck: c['deckName']
      }
    end

    tags_by_note = tags_for(by_note.keys)
    by_note.each { |note_id, note| note[:tags] = tags_by_note[note_id] }
    by_note.values.sort_by { |n| n[:id] }
  end

  # { deck name => note count } for the notes of a note type, by the deck of
  # each note's first card (e.g. which decks hold jp.takoboto notes).
  def note_counts_by_deck(note_type)
    cards_info(deck_query(note_type, nil, nil)).uniq { |card| card[:note_id] }.map { |card| card[:deck] }.tally
  end

  # --- Cards (scheduling) ---------------------------------------------------

  # Card ids matching an Anki browser search query (e.g. 'deck:"毎日" is:new').
  def find_card_ids(query)
    invoke('findCards', query: query)
  end

  # Returns [{ card_id:, note_id:, interval:, due:, deck:, fields: [ordered
  # array] }] for a card search query (e.g. 'deck:"日本語の言葉" prop:ivl>=21').
  def cards_info(query)
    ids = invoke('findCards', query: query)
    return [] if ids.empty?

    invoke('cardsInfo', cards: ids).map do |info|
      {
        card_id: info['cardId'],
        note_id: info['note'],
        interval: info['interval'],
        due: info['due'],
        deck: info['deckName'],
        fields: fields_to_array(info['fields'])
      }
    end
  end

  # --- Writing notes --------------------------------------------------------

  # Update an existing note from an ordered field array. No padding / usn / mod
  # bookkeeping — Anki handles all of that. Returns true on success, false on
  # error (matching the old contract), with the error on stderr. Note:
  # AnkiConnect refuses to update a note that is currently open in Anki's
  # Browse window.
  def update_note(note_id, fields, model_name: Kaishi::NOTE_TYPE_NAME)
    update_note!(note_id, fields, model_name: model_name)
    true
  rescue Error => e
    warn "Error updating note #{note_id}: #{e.message}"
    false
  end

  # Same as update_note, but raises AnkiConnect::Error on failure, so callers
  # can report the reason in their own output.
  def update_note!(note_id, fields, model_name: Kaishi::NOTE_TYPE_NAME)
    invoke('updateNoteFields', note: {
      id: note_id,
      fields: array_to_fields(fields, model_name)
    })
    nil
  end

  # Create a single note from an ordered field array. Returns the new note id,
  # or nil if it was a duplicate (and allow_duplicate is false) or on error.
  def add_note(deck, fields, model_name: Kaishi::NOTE_TYPE_NAME, allow_duplicate: false)
    invoke('addNote', note: note_payload(deck, fields, model_name, allow_duplicate))
  rescue Error => e
    warn "Error adding note: #{e.message}"
    nil
  end

  # True if a note with these fields can be added (i.e. not a duplicate).
  def can_add_note?(deck, fields, model_name: Kaishi::NOTE_TYPE_NAME)
    invoke('canAddNotes', notes: [note_payload(deck, fields, model_name, false)]).first
  end

  # Batch create. `rows` is an array of ordered field arrays. Returns an array
  # of note ids aligned with the input; entries are nil for duplicates/failures.
  def add_notes(deck, rows, model_name: Kaishi::NOTE_TYPE_NAME, allow_duplicate: false)
    payloads = rows.map { |fields| note_payload(deck, fields, model_name, allow_duplicate) }
    invoke('addNotes', notes: payloads)
  end

  # --- Tags -----------------------------------------------------------------

  # Add one or more tags to one or more notes. `note_ids` and `tags` each accept
  # a single value or an array; tags are sent as the space-separated string
  # AnkiConnect expects. Returns nil.
  #
  # Unlike update_note, addTags is NOT blocked by a note being open in Anki's
  # Browse window, so it is safe to use in bulk runs while browsing.
  def add_tags(note_ids, tags)
    invoke('addTags', notes: Array(note_ids), tags: Array(tags).join(' '))
  end

  # Remove one or more tags from one or more notes. Same argument shapes and
  # Browse-window tolerance as add_tags. Returns nil.
  def remove_tags(note_ids, tags)
    invoke('removeTags', notes: Array(note_ids), tags: Array(tags).join(' '))
  end

  # Store a media file in collection.media. Provide either raw bytes via `data:`
  # (sent as base64) or a local file via `path:`. Used for generated audio.
  def store_media_file(filename, data: nil, path: nil)
    params = { filename: filename }
    params[:data] = [data].pack('m0') if data # base64, no newlines
    params[:path] = path if path
    invoke('storeMediaFile', params)
  end

  # Fetch a file from collection.media. Returns its bytes, or nil if there is
  # no such file (AnkiConnect returns false).
  def retrieve_media_file(filename)
    data = invoke('retrieveMediaFile', filename: filename)
    data ? data.unpack1('m') : nil
  end

  # Set a card's new-card queue position (the `due` column for new cards).
  # setSpecificValueOfCard is AnkiConnect's deliberate low-level escape hatch and
  # requires warning_check to acknowledge it bypasses normal validation.
  #
  # `due` must be sent as an integer: `due` is an integer column and current
  # AnkiConnect type-checks it, rejecting a string with "'str' object cannot be
  # interpreted as an integer". That per-key failure comes back inside the
  # result array ([[false, message]]) with a nil top-level error, so invoke does
  # not raise — we inspect the result and raise on failure ourselves.
  def set_card_due(card_id, due)
    result = invoke('setSpecificValueOfCard',
                    card: card_id, keys: ['due'], newValues: [due.to_i], warning_check: true)
    ok, message = Array(result).first
    raise Error, (message || 'setSpecificValueOfCard failed') unless ok

    true
  end

  private

  def note_payload(deck, fields, model_name, allow_duplicate)
    {
      deckName: deck,
      modelName: model_name,
      fields: array_to_fields(fields, model_name),
      options: { allowDuplicate: allow_duplicate, duplicateScope: 'deck' },
      tags: []
    }
  end

  # note id -> tags array, via a single notesInfo batch. Used to backfill tags
  # onto results derived from cardsInfo (which does not report tags).
  def tags_for(note_ids)
    return {} if note_ids.empty?

    invoke('notesInfo', notes: note_ids).each_with_object({}) do |info, acc|
      acc[info['noteId']] = info['tags']
    end
  end

  # notesInfo/cardsInfo fields hash ({ "Word" => { "value" =>, "order" => } })
  # -> ordered array.
  def fields_to_array(fields_hash)
    fields_hash.values.sort_by { |f| f['order'] }.map { |f| f['value'] }
  end

  # Ordered field array -> { name => value } using the note type's field order.
  # Only maps as many fields as the array provides (trailing fields omitted are
  # simply left untouched, same as Anki's own behaviour).
  def array_to_fields(fields, model_name)
    names = field_names(model_name)
    pairs = names.each_with_index.filter_map do |name, idx|
      value = fields[idx]
      [name, value] unless value.nil?
    end
    pairs.to_h
  end

  # AnkiConnect rejects a missing or wrong key with "valid api key must be
  # provided"; point at the env var so the fix is obvious.
  def error_with_hint(error)
    return error unless error.to_s.include?('api key')

    hint = @api_key ? "check that $#{API_KEY_ENV} matches" : "set $#{API_KEY_ENV} to"
    "#{error} (#{hint} the apiKey in AnkiConnect's add-on config)"
  end

  # Build an Anki browser search query scoping a note type to / away from decks.
  def deck_query(note_type, deck, exclude_deck)
    query = +%(note:#{quote(note_type)})
    query << %( deck:#{quote(deck)}) if deck
    query << %( -deck:#{quote(exclude_deck)}) if exclude_deck
    query
  end

  # Quote a value for an Anki browser search query.
  def quote(value)
    %("#{value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}")
  end

  def invoke(action, params = {})
    body = { action: action, version: API_VERSION }
    body[:key] = @api_key if @api_key
    body[:params] = params unless params.empty?

    request = Net::HTTP::Post.new(@uri)
    request.body = JSON.generate(body)
    request['Content-Type'] = 'application/json'

    response = Net::HTTP.start(@uri.hostname, @uri.port, open_timeout: 5, read_timeout: 30) do |http|
      http.request(request)
    end

    payload = JSON.parse(response.body)
    raise Error, error_with_hint(payload['error']) if payload['error']

    payload['result']
  end
end
