//
//  drawing-pad-decode
//  DrawPadProtocol
//
//  A tiny CLI that decodes the wire format from stdin, line by line.
//  Useful for inspecting traffic captured with tcpdump or ngrep:
//
//      sudo ngrep -l -W byline -d en0 '' 'udp and port 7359' \
//        | grep '^{' \
//        | drawing-pad-decode
//

import Foundation
import DrawPadProtocol

@main
struct Decoder {
    static func main() throws {
        var lineCount = 0
        var errorCount = 0
        while let line = readLine() {
            lineCount += 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else {
                FileHandle.standardError.write(Data("line \(lineCount): not utf-8\n".utf8))
                errorCount += 1
                continue
            }
            do {
                let event = try PenEventCodec.decode(data)
                print("[\(lineCount)] \(format(event))")
            } catch {
                FileHandle.standardError.write(Data("line \(lineCount): \(error)\n".utf8))
                errorCount += 1
            }
        }
        if errorCount > 0 {
            FileHandle.standardError.write(Data("\n\(errorCount)/\(lineCount) lines failed to decode\n".utf8))
            exit(1)
        }
    }

    static func format(_ event: PenEvent) -> String {
        let t = event.t
        let seq = event.seq
        let type = event.typeName
        switch event {
        case .hello:
            return "hello t=\(t) seq=\(seq)"
        case .ping(_, _, let nonce), .pong(_, _, let nonce):
            return "\(type) t=\(t) seq=\(seq) nonce=\(nonce)"
        case .bye:
            return "bye t=\(t) seq=\(seq)"
        case .hover(_, _, let x, let y, let tilt):
            if let tilt {
                return "hover  t=\(t) seq=\(seq) (\(x), \(y)) alt=\(tilt.altitude) azi=\(tilt.azimuth)"
            }
            return "hover  t=\(t) seq=\(seq) (\(x), \(y))"
        case .down(_, _, let x, let y, let p, let tilt),
             .move(_, _, let x, let y, let p, let tilt):
            return "\(type)  t=\(t) seq=\(seq) (\(x), \(y)) p=\(p) alt=\(tilt.altitude) azi=\(tilt.azimuth)"
        case .up(_, _, let x, let y):
            return "up     t=\(t) seq=\(seq) (\(x), \(y))"
        case .button(_, _, let kind, let state):
            return "button t=\(t) seq=\(seq) \(kind.rawValue)=\(state.rawValue)"
        case .modifiers(_, _, let mask):
            return "modif  t=\(t) seq=\(seq) mask=\(mask.raw) (0b\(String(mask.raw, radix: 2)))"
        }
    }
}
