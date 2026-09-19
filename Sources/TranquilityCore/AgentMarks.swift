import Foundation

/// The five agents' own marks, as each vendor publishes them.
///
/// **Fetched, verified by eye, and embedded** on 14 Sep 2026 — not drawn by
/// this project. A logo somebody approximates is a logo that is wrong, and
/// these identify other people's products, so they are theirs or they are not
/// used at all. Nominative use: the mark names the thing it names, which is
/// the same thing a browser does when it shows a site's favicon.
///
/// Base64 rather than bundle resources, deliberately. This package has no
/// resource pipeline, the app is assembled by a script rather than by Xcode,
/// and a path that resolves on a developer's machine and not inside a signed
/// bundle is the fallback this codebase has already been bitten by. 10 KB of
/// string constants cannot fail to load.
///
/// **Every mark sits on one identical light tile.** Four of the five arrive
/// with an opaque light background baked in, so on the panel's dark ground the
/// choice was a uniform tile or four white squares and one floating glyph. A
/// first attempt measured each mark's average luminance and "lifted the dark
/// ones to panel ink": the numbers said four of five were fine, and looking at
/// the result showed OpenCode had been flattened into a blank beige square.
/// The sheet is the evidence, not the metric.
public enum AgentMarks {

    /// PNG bytes for an agent's mark, or nil for one we have no logo for.
    public static func png(_ agentID: String) -> Data? {
        base64[agentID].flatMap { Data(base64Encoded: $0) }
    }

    /// Which agents carry a real mark. A test asserts this covers the roster,
    /// so an agent added without one is caught rather than shipping a hole.
    public static var known: Set<String> { Set(base64.keys) }


    private static let base64: [String: String] = [
        // claude.ai favicon, 14 Sep 2026
        "claude-code": """
        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
        """.replacingOccurrences(of: "\n", with: ""),
        // github.com/openai avatar, 14 Sep 2026
        "codex": """
        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
        +1O6dme0fwB5rVAVSeKYawAAAABJRU5ErkJggg==
        """.replacingOccurrences(of: "\n", with: ""),
        // crobot's own ui/public/coframe.png
        "crobot": """
        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
        rkJggg==
        """.replacingOccurrences(of: "\n", with: ""),
        // opencode.ai favicon, 14 Sep 2026
        "opencode": """
        iVBORw0KGgoAAAANSUhEUgAAACwAAAAsCAYAAAAehFoBAAACoElEQVR4nOWZz27aQBDGv10bEwWwIyVIvSC1tz4A1x6QOCA153Jq
        nqXKo1S5wDmVuKZn7vSWHqlCJP4kKmBsVzO1KTEGBWzDWv0kZNj17P4Yz47Ha4EtGg/7Ho4g8+yN2NQnVAJ9DbhUFXYTi1QVdhOT
        VBk2ik1Ewb57+x4q6P7nj7WYXoth1SVVDoWwiDVzHtb3MZKaBk3G+6+O68J1nPSBpRCYjMeY2jbi6CSXQ6lYhOt56QFrmobRZIJm
        s4mPl5dwHIfbdpHj23y7vUWr3YZVKnFbKsBSSszmc1SrVXxqNhFHv/p9fL254TFTAw70/PyMxWIB27aRy+XgeR7/pqQevsDCb9N1
        HUKIpQ2NcbhFJyUDECgdSQTxGnm+DY1xMODVyUmDhwd0Oh3k8/llWyAhBGazGRqNBi7K5bX+gwK7rsvHXq+Hz1dXXJj8bfkn6bd9
        v7vDh3J5aXMU4ECGYeDEMHBxfs6x/GICXcfg8ZHPSUKJAJPXpvM5X/owsOM43BfXs4kCU14tnp6iUChEevj3dLpzvk4FmBYUybIs
        1Ot1PoZzqkY3m9GI+1ZtjuphEl3y4LMqIURi4UDKXLUmkTFJZEwSGZOexCC0sCh9ceoKZQHNrzviZodEgakCGwwGnIOj0tpwOORz
        lMnDlUoFX66vYfilZvicuW3zOas2RwU2LQu1Wm0nm4MC042ALj8X7UKwVykUNsF4nsehQf2Bzb43k72AqWaghRQU77sU8LpvQ2Ok
        DkxeyRsGut0u2q1WrIfQbrfLY+3qaRG187Ntb40f85+eDvKYfx/aW9srJGiCkmniLCsbKSSaaJ/J/stbs9z2AkQ1mVncHxbBF9X3
        iU0/EpYeVjk0zBW2FyGhIrQZYlqLYZWgzQiWrXAqvrr9A0TmOt/wVm4aAAAAAElFTkSuQmCC
        """.replacingOccurrences(of: "\n", with: ""),
        // app.devin.ai favicon, 14 Sep 2026
        "devin": """
        iVBORw0KGgoAAAANSUhEUgAAACwAAAAsCAYAAAAehFoBAAAEy0lEQVR4nNVZS0srSRQ+3UlMco1JTEYnGBwUdTEyigouZlzccedG
        VFRQEHUjuBJR/AMudOHKhfhaKS5VUBHxAd6AzN24EBnMTgYV8TEJo3ncdB7dwym7Qx6dTjoPbt8PGpKq9DlfnTr1naoKBRJ4/++J
        g+8Ao9lGpeqjlEQ0E+K0Usmm4kIrlWwqTrSSyYpxo5VOVoDAUQ0ZgqJol6ZI/7dao/2JptW/UBRVAjmA4zgPy4bvwiHm31Dw228c
        x1oz4pFJdDUa3V9FOkMVTasqoABg2chjMOD9JxQK/JEz4SJt8RetzvAn/zXCSyGdL64AgP5V+IUJeL8EGZ/gSxSSjtUa3VeebJg3
        rkp8h2VZCIexOyvQvE20HUZf6FOSU6oOiqLdOn1JTYzhpME9PDzA5uYmPD09wejoKDQ1NQFNZxV8WviAPn3hoJvjWIuslCjSFju0
        OsNnPg3IlAnwer1wcHAA6+vrcHNzQ6Jss9lgcHAQhoeHwW63Q5aIoC8m4HUEGd9nWYQ/GSxOlUrzKz9d0QhcX1/DwsICOBwOYBgG
        VKqPsSBpiqKgvr4eJiYmoLOzM5toE1+RSMjp97rRdxJSWkTpEvvN9vY2HB0dkbwVyH78niaEcUDLy8vg8/nkko36ivGdOWGKoorF
        2iORiGTksA+jjU+2SOUb8ihPceA4jjyFQN4JY1q4XC54eXmJa39/f4fd3V2S+6FQKGv7GZdmATjVUtHDlECZW1xchOnpabBYLHB1
        dQWrq6twcXEBer0euru7YWxsDGpra8kA5SClSpSYfhZ9ARfd7OwsPD8/RxdabH4Lg8EFabfbwWQywf39Pby9vZE27MdBV1dXE+0e
        GBgAs9mc5Mfz9pwfwugMI7aysgKnp6fg9/sJaSTf2NgIra2tJMLn5+fg8XjIO4kDE+xg28zMDExNTWVMWHZKoPOWlhYy5cfHx4S4
        2+2GoaEhUjjKysqI5K2trcH8/DyJeio7+LvX11dZ/mUTFiDkYltbG4lyZWVlVO7UajXp29ragtvbW0kZlJvDOasEkhGbcqE938ja
        YiAQIPsJ3Dv09/fD0tJSdHpxqvf29uDu7i4tabl6nZWsYfnF3D05OSElGKM7NzcHh4eHcYuOYRjJRYeqgTkvB7JVYmdnh8gakspE
        1oxGI5E1LByxslZVVRWVtdLS0sKpxOXlJTw+PoJGo0nqEzZDSKqnpyeucKBqCIWjq6uLFI66ujrZiy4rWZNygtGrqKiAyclJqKn5
        2P+3t7cTKTw7OwOr1UqURWzABSGcDhhdJFVeXh7XjhWvt7c3Z/sF2a3hDMid6pwJcxwnugPHPJXa62JfurRJh1S+JQnjJYfwMba9
        r68POjo6SDWLLbvCHrihoQHGx8fBYDCkJSbmNsF3/g6h+/v75BDqdDqjh1CUqJGRke9zCKUo2l1cYg1TFF2eeBCNPeZvbGxEj/nN
        zc25lGMWfXAc++LzuNSyj/kIvNTQfzL9zl+kiN5NCOc3TJEcwPKP+pv/7Ws4FECfopAMB76I10e8/NH8lMXlNEY0B7IsbxNtq9GX
        FNkf8zIQMrwfVsJ1q9Fs+xDLH+FCWyBMp/ubSSkw8hyji07JpI0x3OJUQomkjQmckmRNSaSNIlwkySnxr9v/ASUHhWmBasD2AAAA
        AElFTkSuQmCC
        """.replacingOccurrences(of: "\n", with: ""),
    ]
}
