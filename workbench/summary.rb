# frozen_string_literal: true

require_relative 'steps'

module Workbench
  # What the page says about one deck, worked out from its deck-status.rb
  # counts: each step's badge, the suggested next step, the note shown when a
  # step runs ahead of one it depends on, and the Advice list. Pure functions
  # of the counts, so they're easy to test.
  #
  # deck: one entry of deck-status.rb --json's "decks" ({ "name", "total",
  # "needs_work", "counts" }), or nil for a deck with no Kaishi cards yet.
  module Summary
    module_function

    def for(deck, takoboto_decks: [], translation_notes: [])
      deck ||= { 'name' => nil, 'total' => 0, 'needs_work' => 0, 'counts' => {} }
      counts = deck['counts']
      waiting = takoboto_decks.sum { |d| d['count'] }
      {
        badges: Steps::ALL.to_h { |step| [step.id, badge(step, counts, waiting)] },
        suggested: suggested(counts),
        dep_notes: Steps::ALL.select(&:deps).to_h { |step| [step.id, dep_note(step, counts)] }.compact,
        advice: advice(deck, waiting, translation_notes)
      }
    end

    # Cards a step would still process (word and sentence clips add up for audio).
    def missing(step, counts)
      (step.checks || []).sum { |key| counts.fetch(key, 0) }
    end

    # Furigana's review is part of the same step but reads differently.
    def badge(step, counts, waiting)
      return { text: 'Info', kind: 'info' } if step.info
      return { text: waiting.positive? ? "#{waiting} waiting" : 'Empty', kind: waiting.positive? ? 'todo' : 'info' } if step.id == 'takoboto'
      return { text: 'Manual', kind: 'info' } if step.id == 'word_list'
      return { text: 'Optional', kind: 'info' } if step.optional

      if step.id == 'furigana'
        return { text: "#{counts['furigana']} missing", kind: 'todo' } if counts.fetch('furigana', 0).positive?
        return { text: "#{counts['furigana_review']} unreviewed", kind: 'todo' } if counts.fetch('furigana_review', 0).positive?
      end
      n = missing(step, counts)
      return { text: step.id == 'audio' ? "#{n} clips" : "#{n} missing", kind: 'todo' } if n.positive?

      { text: 'Complete', kind: 'done' }
    end

    def fill_steps
      Steps::ALL.select { |step| step.group == :fill && !step.optional }
    end

    def suggested(counts)
      fill_steps.find { |step| missing(step, counts).positive? }&.id
    end

    # Non-blocking: any step can run any time; this says what it'll skip.
    def dep_note(step, counts)
      pending = step.deps.map { |id| Steps.find(id) }.select { |dep| missing(dep, counts).positive? }
      return nil if pending.empty?

      pending.map do |dep|
        n = missing(dep, counts)
        "#{dep.label}: #{n} #{n == 1 ? 'card still needs' : 'cards still need'} it. " \
          "Run #{step.label} again after #{dep.label} to pick #{n == 1 ? 'it' : 'them'} up."
      end.join(' ')
    end

    def advice(deck, waiting, translation_notes)
      c = deck['counts']
      name = deck['name']
      list = []
      if waiting.positive?
        list << item("#{plural(waiting, 'word')} waiting in Takoboto decks.", 'info', 'takoboto', 'Pull from Takoboto')
      end
      if deck['total'].zero?
        list << item('This deck has no Kaishi cards yet. Get words in first: pull from Takoboto or add a word list.',
                     'info', 'word_list', 'Add from word list')
        return list
      end

      if c['stray_html'].to_i.positive?
        list << item("#{plural(c['stray_html'], 'card')} #{verb(c['stray_html'], 'has', 'have')} stray HTML. " \
                     'Strip it first: furigana, pitch accent and grammar notes read the Word field.',
                     'todo', 'strip_html', 'Strip HTML')
      end
      if c['sentence'].to_i.positive?
        list << item("#{plural(c['sentence'], 'card')} #{verb(c['sentence'], 'has', 'have')} no example sentence. " \
                     'Generate them before sentence meanings, furigana and audio, which all need the sentence.',
                     'todo', 'sentences', 'Example sentences')
      end
      if c['word_meaning'].to_i.positive?
        list << item("#{plural(c['word_meaning'], 'card')} #{verb(c['word_meaning'], 'has', 'have')} no word meaning. " \
                     'Add meanings fills them from JMdict.', 'todo', 'meanings', 'Add meanings')
      end
      if c['sentence_meaning'].to_i.positive? && name && !translation_notes.include?(name)
        list << item("No translation notes for this deck (prompts/translation/#{name}.md). Names and recurring " \
                     'terms translate more consistently with them.', 'info', 'sentence_meanings', nil)
      end
      if c['furigana'].to_i.zero? && c['furigana_review'].to_i.positive?
        list << item("#{plural(c['furigana_review'], 'sentence')}' furigana #{verb(c['furigana_review'], 'hasn’t', 'haven’t')} " \
                     'been reviewed yet (a review stopped by a usage limit leaves these).',
                     'todo', 'furigana', 'Review furigana', preset: { 'review_unreviewed' => true })
      end
      if c['furigana'].to_i.positive? && (c['word_audio'].to_i + c['sentence_audio'].to_i).positive?
        list << item('Generate furigana before audio: the Whisper reading check compares each clip against it.',
                     'info', 'furigana', 'Furigana')
      end
      list << item('Every card in this deck is complete.', 'ok', nil, nil) if deck['needs_work'].to_i.zero?
      list
    end

    def item(text, kind, step, action, preset: nil)
      { text: text, kind: kind, step: step, action: action, preset: preset }.compact
    end

    def plural(n, word)
      "#{n} #{n == 1 ? word : "#{word}s"}"
    end

    def verb(n, one, many)
      n == 1 ? one : many
    end
  end
end
