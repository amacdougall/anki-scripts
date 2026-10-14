require 'base64'
require 'uri'

module GeminiTTS
  # The Voices API: custom voices (Voice design "prompted" voices and
  # "replicated" ones) stored in the project that the API key belongs to.
  # Voices designed in Google AI Studio land here too, though the Studio UI
  # never shows their IDs. Pass an ID as `voice:` to a 3.8 model.
  #
  # Stored voices expire a year after creation, at most 200 per project. AI
  # Studio stores all three takes of each "Generate voice", and every one
  # counts toward the limit.
  #
  # Voices are returned as the API's raw hashes: "id", "display_name", "type",
  # "model", "expire_time", and for prompted voices "prompted" => { "input" }
  # (the description). `get` also returns "sample_audio" => { "data" } (a
  # base64 WAV preview) for prompted voices.
  class Voices
    CUSTOM_TYPES = %w[prompted replicated].freeze

    def initialize(api_key: ENV['GEMINI_API_KEY'], connection: nil)
      @api_key = api_key
      @connection = connection
    end

    # Every voice of the given type(s), newest first within each type, following
    # pagination. `search` is a case-insensitive substring match on name and
    # description. (The docs say repeated `type` params are OR'd, but in practice
    # that returns nothing, so each type is queried on its own.)
    def list(types: CUSTOM_TYPES, search: nil)
      Array(types).flat_map { |type| list_type(type, search) }
    end

    def get(id)
      HTTP.parse(HTTP.request("Get voice #{id}") { connection.get("voices/#{id}") })
    end

    # The decoded WAV preview of a prompted voice, or nil when it has none.
    def sample_wav(id)
      data = get(id).dig('sample_audio', 'data')
      data && Base64.decode64(data)
    end

    # Design a voice from a natural-language description. Put permanent traits
    # here (age, gender, timbre, accent); leave situational emotion to `style`.
    # Returns the new voice, including its "id" and "sample_audio".
    def create(description:, display_name:, model: DEFAULT_MODEL, gender: nil, language_code: nil)
      voice = { model: model, type: 'prompted', display_name: display_name, prompted: { input: description } }
      voice[:gender] = gender if gender
      voice[:language_code] = language_code if language_code
      response = HTTP.request('Create voice') do
        connection.post('voices') do |req|
          req.headers['Content-Type'] = 'application/json'
          req.body = JSON.generate({ store: true, voice: voice })
        end
      end
      HTTP.parse(response)
    end

    def delete(id)
      HTTP.request("Delete voice #{id}") { connection.delete("voices/#{id}") }
      true
    end

    private

    def connection
      @connection ||= HTTP.connection(@api_key)
    end

    def list_type(type, search)
      voices = []
      page_token = nil
      loop do
        params = { type: type, page_size: 1000 }
        params[:search] = search if search
        params[:page_token] = page_token if page_token
        body = HTTP.parse(HTTP.request('List voices') { connection.get('voices', params) })
        voices.concat(body['voices'] || [])
        page_token = body['next_page_token']
        break if page_token.to_s.empty?
      end
      voices
    end
  end
end
