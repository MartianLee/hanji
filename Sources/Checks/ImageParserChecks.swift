import MarkdownCore

func imageParserChecks() {
    let a = ImageParser.images(in: "![[test.png]]")
    expectEqual(a.count, 1, "one embed image")
    expectEqual(a.first?.path, "test.png", "embed path")

    let b = ImageParser.images(in: "![alt](img/p.png)")
    expectEqual(b.first?.path, "img/p.png", "markdown image path")

    let c = ImageParser.images(in: "![[a.png|200]]")
    expectEqual(c.first?.path, "a.png", "strips |size")

    let none = ImageParser.images(in: "just text, not an image")
    expectEqual(none.count, 0, "no images in plain text")
}
