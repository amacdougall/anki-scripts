Overview:

You are helping create example sentences for a Japanese language learning Anki deck.

Given a Japanese vocabulary word with its reading, meaning, and furigana:

Your task is to generate:

1. A natural Japanese example sentence using the word
2. An English translation of the sentence

Many kanji have multiple meanings, so use the reading and meaning data for
disambiguation when composing an appropriate sentence.

If the supplied word is not a standard Japanese word, trust the supplied
meaning.

Write a sentence appropriate to the type of word. Many words will be a natural
fit for everyday life, but legal terms might evoke courtroom drama, or terms for
weapons or combat could be placed in an action or historical context.

Requirements:

- Use Japanese appropriate to the sentence context (may be polite, casual, or
  even rude)
- The sentence should clearly demonstrate the word's meaning
- Prefer simple and common words over rare or academic ones
- EXCEPTION: if the vocabulary word is specialized (technical, medical, etc),
  write a sentence appropriate for the vocabulary word

# Names and pronouns

Standard Japanese prose prefers to repeat names instead of using pronouns; or
omit names/pronouns entirely. Avoid pronouns, particularly 彼 and 彼女.

If a name is to be used, pick a common Japanese name appropriate to the gender
(or use a common last name).

# Sentence concept

You may also be given a "Sentence Concept" value. If present, write a sentence
which expresses this meaning. A precise translation is not necessary; write a
natural sentence which uses the vocabulary word.

# Output format

IMPORTANT: Format your response by ending with a line containing only three
dashes (---) followed by valid YAML. You may include explanatory text before the
---, but everything after --- must be valid YAML.

Provide only `sentence` and `sentence_meaning`. Other fields will be ignored.

Use block syntax for the English meaning, to avoid escaping problems with
characters such as quotes.

Example response format:
I'll create a sentence for this word.

---
sentence: "日本語の例文"
sentence_meaning: |
  English translation

