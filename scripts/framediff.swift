import Foundation

// Compares two streams of raw BGRA frames, as `Outbound --render - --seconds` writes them, pixel by pixel.
//
//     framediff a.raw b.raw <width> <height> [most a channel may differ by] [share of pixels that may differ]
//
// Fast maths lets a restructured shader round a stray pixel the other way, so a difference of 1 in 255 on up to a
// thousandth of the pixels passes unless told otherwise. Anything more, or a different number of frames, fails.

let arguments = CommandLine.arguments
guard arguments.count >= 5, let width = Int(arguments[3]), let height = Int(arguments[4]) else {
    FileHandle.standardError.write(Data("framediff a.raw b.raw <width> <height> [allowed] [share]\n".utf8))
    exit(2)
}
let allowed = arguments.count > 5 ? Int(arguments[5]) ?? 1 : 1
let share = arguments.count > 6 ? Double(arguments[6]) ?? 0.001 : 0.001

guard let a = FileHandle(forReadingAtPath: arguments[1]), let b = FileHandle(forReadingAtPath: arguments[2]) else {
    FileHandle.standardError.write(Data("Can't open the streams.\n".utf8))
    exit(2)
}

let frameBytes = width * height * 4
var frames = 0
var differing = 0
var largest = 0
var worstFrame = 0
var uneven = false
while true {
    let one = a.readData(ofLength: frameBytes), two = b.readData(ofLength: frameBytes)
    if one.isEmpty && two.isEmpty { break }
    guard one.count == frameBytes, two.count == frameBytes else {
        uneven = true
        break
    }
    frames += 1
    guard one != two else { continue }
    var differingHere = 0
    one.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        two.withUnsafeBytes { (q: UnsafeRawBufferPointer) in
            var i = 0
            while i < frameBytes {
                let d0 = abs(Int(p[i]) - Int(q[i])), d1 = abs(Int(p[i + 1]) - Int(q[i + 1]))
                let d2 = abs(Int(p[i + 2]) - Int(q[i + 2]))
                let d = max(d0, max(d1, d2))
                if d > 0 {
                    differingHere += 1
                    if d > largest {
                        largest = d
                        worstFrame = frames
                    }
                }
                i += 4
            }
        }
    }
    differing += differingHere
}

let pixels = max(frames * width * height, 1)
let part = Double(differing) / Double(pixels)
if uneven || frames == 0 {
    print("the streams hold different numbers of frames, or none")
    exit(1)
}
if differing == 0 {
    print("\(frames) frames, identical")
} else {
    print(String(format: "%d frames, %d pixels differ (%.4f%%), by %d at most (frame %d)", frames, differing, part * 100,
                 largest, worstFrame))
}
exit(largest > allowed || part > share ? 1 : 0)
