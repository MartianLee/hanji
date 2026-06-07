import WordCountPlugin

func wordCounterChecks() {
    expectEqual(WordCounter.words(in: "hello world"), 2, "two words")
    expectEqual(WordCounter.words(in: ""), 0, "empty has no words")
    expectEqual(WordCounter.words(in: "a\nb c"), 3, "newline and space split")
    expectEqual(WordCounter.characters(in: "hello"), 5, "character count")
}
