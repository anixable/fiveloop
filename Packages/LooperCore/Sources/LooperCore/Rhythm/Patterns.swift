import Foundation

/// Original rhythm patterns (written for this project), grouped with the genre names
/// used by the hardware's GENRE parameter. One line per instrument, one character per step:
/// X = accent, x = normal, o = ghost, anything else = rest.
public struct PatternDef {
    public let genre: String
    public let name: String
    public let stepsPerQuarter: Int   // 4 = 16ths, 3 = triplet 8ths
    public let swing: Double          // 0…0.6 (delay of off-beat 16ths, fraction of a step)
    let lines: [String]
}

public let rhythmGenres = ["ACOUSTIC", "BALLAD", "BLUES", "JAZZ", "FUSION", "R&B", "SOUL", "FUNK", "POP",
                           "SOFT ROCK", "ROCK", "ALT ROCK", "PUNK", "HEAVY ROCK", "METAL", "TRAD", "WORLD",
                           "BALLRM", "ELCTRO", "GUIDE"]

public let patternDefs: [PatternDef] = {
    var p: [PatternDef] = []
    func d(_ g: String, _ n: String, _ l: [String], spq: Int = 4, swing: Double = 0) {
        p.append(PatternDef(genre: g, name: n, stepsPerQuarter: spq, swing: swing, lines: l))
    }
    // ACOUSTIC
    d("ACOUSTIC", "Folk 8", ["K:x.......x.......", "R:....x.......x...", "Z:x.x.x.x.x.x.x.x."])
    d("ACOUSTIC", "Strum 16", ["K:x.....x...x.....", "S:....o.......o...", "Z:xoxoxoxoxoxoxoxo"])
    d("ACOUSTIC", "Brush Train", ["K:x.......x.......", "S:o.xoo.xoo.xoo.xo"], swing: 0.2)
    // BALLAD
    d("BALLAD", "Slow 8", ["K:x.......x.x.....", "S:....x.......x...", "H:x.x.x.x.x.x.x.x."])
    d("BALLAD", "6/8 Feel", ["K:x.....x.....", "S:...x.....x..", "H:xxxxxxxxxxxx"].map { String($0.prefix(14)) }, spq: 3)
    d("BALLAD", "Power Ballad", ["K:x.......x..x....", "S:....X.......X...", "H:x.x.x.x.x.x.x.x.", "X:x..............."])
    // BLUES
    d("BLUES", "Shuffle", ["K:x.....x.....", "S:...x.....x..", "H:x.xx.xx.xx.x"], spq: 3)
    d("BLUES", "Slow Blues", ["K:x...........", "S:...X.....X..", "Y:xxxxxxxxxxxx"], spq: 3)
    d("BLUES", "Texas Shuffle", ["K:x.....x.x...", "S:...x.....x..", "H:x.xx.xx.xx.x"], spq: 3)
    // JAZZ
    d("JAZZ", "Swing Ride", ["K:o.....o.....", "H:...x.....x..", "Y:x..x.xx..x.x"], spq: 3)
    d("JAZZ", "Bossa", ["K:x..xx..xx..xx..x", "R:x..x..x...x..x..", "H:xxxxxxxxxxxxxxxx"])
    d("JAZZ", "Jazz Waltz Feel", ["K:x.....o.....", "H:...x.....x..", "Y:x..x.xx..x.x"], spq: 3)
    // FUSION
    d("FUSION", "Linear", ["K:x..x....x.x.....", "S:..x...x....x..x.", "H:.x..x....x..x..x"])
    d("FUSION", "Half-time Shuffle", ["K:x.....x.x...", "S:o.o.o.X.o.o.", "H:x.xx.xx.xx.x"], spq: 3)
    // R&B
    d("R&B", "Neo Soul", ["K:x......x.x......", "S:....x.......x...", "H:x.x.x.x.x.x.x.x."], swing: 0.35)
    d("R&B", "Slow Jam", ["K:x.....x.x.......", "C:....x.......x...", "H:x.xxx.x.x.xxx.x."], swing: 0.25)
    d("R&B", "Modern R&B", ["K:x..x......x.....", "C:....x.......x...", "H:xxx.xxx.xxx.xxx."])
    // SOUL
    d("SOUL", "Motown", ["K:x.x...x.x.x.....", "S:....x.......x...", "H:x.x.x.x.x.x.x.x.", "Z:x.x.x.x.x.x.x.x."])
    d("SOUL", "Southern Soul", ["K:x......x..x.....", "S:....x.......x...", "H:x.x.x.x.x.x.x.x."], swing: 0.15)
    // FUNK
    d("FUNK", "Funk 1", ["K:x.x.......x..x..", "S:....x..o.o..x..o", "H:xxxxxxxxxxxxxxxx"])
    d("FUNK", "Funk 2", ["K:x..x..x...x.....", "S:....x.o.o...x.o.", "H:x.x.x.x.x.x.x.x.", "O:..............x."])
    d("FUNK", "Second Line", ["K:x..x..x.x..x....", "S:o.xo.xo.x.xo.xoo"], swing: 0.3)
    d("FUNK", "Disco Funk", ["K:x...x...x...x...", "S:....x.......x...", "H:x...x...x...x...", "O:..x...x...x...x."])
    // POP
    d("POP", "Pop 8", ["K:x.......x.x.....", "S:....x.......x...", "H:x.x.x.x.x.x.x.x."])
    d("POP", "Pop 16", ["K:x.....x...x.....", "S:....x.......x...", "H:xxxxxxxxxxxxxxxx"])
    d("POP", "Dance Pop", ["K:x...x...x...x...", "C:....x.......x...", "H:..x...x...x...x."])
    d("POP", "Half Time", ["K:x.....x.........", "S:........X.......", "H:x.x.x.x.x.x.x.x."])
    // SOFT ROCK
    d("SOFT ROCK", "Soft 8", ["K:x.......x.......", "R:....x.......x...", "H:x.x.x.x.x.x.x.x."])
    d("SOFT ROCK", "Laid Back", ["K:x......xx.......", "S:....x.......x...", "H:x.x.x.x.x.x.x.x."], swing: 0.1)
    // ROCK
    d("ROCK", "Rock 8", ["K:x.......x.x.....", "S:....X.......X...", "H:x.x.x.x.x.x.x.x."])
    d("ROCK", "Rock 16", ["K:x.....x.x.......", "S:....X.......X...", "H:xxxxxxxxxxxxxxxx"])
    d("ROCK", "Four on Floor Rock", ["K:x...x...x...x...", "S:....X.......X...", "H:x.x.x.x.x.x.x.x."])
    d("ROCK", "Tom Groove", ["K:x.......x.......", "S:....X.......X...", "L:x..x..x...x..x.."])
    // ALT ROCK
    d("ALT ROCK", "Alt 1", ["K:x..x..x...x.....", "S:....X.......X...", "Y:x.x.x.x.x.x.x.x."])
    d("ALT ROCK", "Driving", ["K:x.x.x.x.x.x.x.x.", "S:....X.......X...", "O:x.x.x.x.x.x.x.x."])
    // PUNK
    d("PUNK", "Punk Beat", ["K:x.x.x.x.x.x.x.x.", "S:..X...X...X...X.", "H:x.x.x.x.x.x.x.x."])
    d("PUNK", "Skate", ["K:x...x...x...x...", "S:..X...X...X...X.", "Y:x.x.x.x.x.x.x.x."])
    // HEAVY ROCK
    d("HEAVY ROCK", "Heavy 1", ["K:x.x.....x.x.....", "S:....X.......X...", "O:x.x.x.x.x.x.x.x."])
    d("HEAVY ROCK", "Stomp", ["K:x..x....x..x....", "S:....X.......X...", "Y:x...x...x...x..."])
    // METAL
    d("METAL", "Double Kick", ["K:xxxxxxxxxxxxxxxx", "S:....X.......X...", "Y:x.x.x.x.x.x.x.x."])
    d("METAL", "Gallop", ["K:x.xxx.xxx.xxx.xx", "S:....X.......X...", "H:x.x.x.x.x.x.x.x."])
    d("METAL", "Blast", ["K:x.x.x.x.x.x.x.x.", "S:.x.x.x.x.x.x.x.x", "X:x.x.x.x.x.x.x.x."])
    // TRAD
    d("TRAD", "Country Train", ["K:x.......x.......", "S:o.xoo.xoo.xoo.xo"])
    d("TRAD", "March", ["K:x.......x.......", "S:x.oox.o.x.oox.o.", "X:x..............."])
    d("TRAD", "Polka", ["K:x.......x.......", "S:....x.......x...", "H:x.x.x.x.x.x.x.x."])
    // WORLD
    d("WORLD", "Reggae One Drop", ["K:........X.......", "R:........x.......", "H:x.x.x.x.x.x.x.x."], swing: 0.25)
    d("WORLD", "Afro 12/8", ["K:x.....x.....", "B:x.xx.x.x.x.x", "Z:xxxxxxxxxxxx"].map { String($0.prefix(14)) }, spq: 3)
    d("WORLD", "Samba", ["K:x..xx..xx..xx..x", "R:x.x..x.x.x..x.x.", "Z:xxxxxxxxxxxxxxxx"])
    d("WORLD", "Latin Clave", ["K:x...x...x...x...", "R:x..x..x...x.x...", "B:x.x.x.x.x.x.x.x."])
    // BALLRM
    d("BALLRM", "Waltz Feel", ["K:x...............", "R:....x...x.......", "H:x.x.x.x.x.x.x.x."])
    d("BALLRM", "Tango", ["K:x.....x.x...x...", "S:..............x.", "R:x...x...x...x..."])
    d("BALLRM", "Cha-Cha", ["K:x...x...x...x...", "B:x...x...x.x.x...", "R:....x.......x..."])
    // ELCTRO
    d("ELCTRO", "House", ["K:x...x...x...x...", "C:....x.......x...", "O:..x...x...x...x.", "H:xxxxxxxxxxxxxxxx"])
    d("ELCTRO", "Techno", ["K:x...x...x...x...", "R:..x...x...x..x..", "H:..x...x...x...x."])
    d("ELCTRO", "Breakbeat", ["K:x.........x.....", "S:....x..o.o..x...", "H:x.x.x.x.x.x.x.x."])
    d("ELCTRO", "Drum & Bass", ["K:x.........x.....", "S:....x.......x...", "H:x.x.x.x.x.x.x.x."])
    d("ELCTRO", "Trap", ["K:x.....x...x.....", "C:........x.......", "H:xxxxxxxxxxxxxxxx"])
    d("ELCTRO", "Hip Hop", ["K:x......x..x.....", "S:....x.......x...", "H:x.x.x.x.x.x.x.x."], swing: 0.3)
    // GUIDE (metronome)
    d("GUIDE", "Click 1/4", ["B:X...x...x...x..."])
    d("GUIDE", "Click 1/8", ["B:X.x.x.x.x.x.x.x."])
    d("GUIDE", "Click 1/16", ["B:Xxxxxxxxxxxxxxxx"])
    d("GUIDE", "Hi-Hat 1/8", ["H:X.x.x.x.x.x.x.x."])
    return p
}()

/// A compiled pattern variation: per step a list of (voice, velocity).
public struct CompiledPattern {
    public let steps: Int
    public let stepsPerQuarter: Int
    public let swing: Double
    let hits: [[(DrumVoice, Float)]]
}

public enum PatternCompiler {
    static func velocity(_ c: Character) -> Float? {
        switch c { case "X": return 1.0; case "x": return 0.75; case "o": return 0.35; default: return nil }
    }

    /// variation 0…3 = A…D. B adds detail, C changes the cymbal / adds kick syncopation,
    /// D is the most intense (crash on 1, open hats, ghost notes).
    public static func compile(_ def: PatternDef, variation: Int) -> CompiledPattern {
        var grid: [DrumVoice: [Float]] = [:]
        var steps = 0
        for line in def.lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let ch = parts[0].first, let v = DrumVoice.letters[ch] else { continue }
            let vals = parts[1].map { velocity($0) ?? 0 }
            steps = max(steps, vals.count)
            grid[v] = vals
        }
        steps = max(steps, 1)
        for k in grid.keys { if grid[k]!.count < steps { grid[k]! += [Float](repeating: 0, count: steps - grid[k]!.count) } }
        let guide = def.genre == "GUIDE"
        let beat = def.stepsPerQuarter
        func set(_ v: DrumVoice, _ i: Int, _ vel: Float) {
            if grid[v] == nil { grid[v] = [Float](repeating: 0, count: steps) }
            if grid[v]![i] == 0 { grid[v]![i] = vel }
        }
        if !guide && variation >= 1 {
            // B: ghost notes between hats, extra kick before beat 3
            if let h = grid[.closedHat] {
                for i in 0..<steps where h[i] == 0 && i % 2 == 1 && i % 4 == 3 { grid[.closedHat]![i] = 0.3 }
            }
            if steps >= 12 { set(.kick, steps / 2 - 2 + (beat == 3 ? 1 : 0), 0.6) }
        }
        if !guide && variation >= 2 {
            // C: move time-keeping to ride, push kick
            if let h = grid[.closedHat], grid[.ride] == nil {
                grid[.ride] = h.map { $0 > 0 ? max($0, 0.6) : 0 }; grid[.closedHat] = nil
            }
            set(.kick, steps - 2, 0.65)
            if let s = grid[.snare] { for i in 0..<steps where s[i] == 0 && i % beat == beat - 1 { grid[.snare]![i] = 0.3 } }
        }
        if !guide && variation >= 3 {
            // D: crash on 1, open hat on the last off-beat, accent everything a bit
            set(.crash, 0, 0.9)
            set(.openHat, max(0, steps - beat / 2 - 1), 0.7)
            for k in grid.keys { grid[k] = grid[k]!.map { $0 > 0 ? min(1, $0 * 1.1) : 0 } }
        }
        var hits = [[(DrumVoice, Float)]](repeating: [], count: steps)
        for v in DrumVoice.allCases { if let g = grid[v] { for i in 0..<steps where g[i] > 0 { hits[i].append((v, g[i])) } } }
        return CompiledPattern(steps: steps, stepsPerQuarter: beat, swing: def.swing, hits: hits)
    }

    /// Generic one-beat fill (toms + snare) used when switching variations with FILL on.
    public static func fill(stepsPerQuarter: Int) -> [[(DrumVoice, Float)]] {
        let v: [DrumVoice] = stepsPerQuarter == 3 ? [.snare, .highTom, .lowTom] : [.snare, .highTom, .midTom, .lowTom]
        return v.enumerated().map { [($0.element, 0.6 + 0.1 * Float($0.offset))] }
    }
}
