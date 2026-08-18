import Foundation
import Testing

@testable import SOCore

/// Held to the published FIPS 180-4 / NIST vectors, not to itself. A hash
/// implementation that only agrees with its own output is worthless: the
/// server computes this digest with a completely different implementation
/// (Deno's Web Crypto), and if the two disagree every run fails to score.
@Suite("SHA-256")
struct SHA256DigestTests {
    @Test("the published test vectors")
    func knownVectors() {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
            (
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
                    + "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
                "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
            ),
        ]
        for (input, expected) in vectors {
            #expect(SHA256Digest.hex(of: Data(input.utf8)) == expected, "input: \"\(input)\"")
        }
    }

    @Test("one million 'a' characters")
    func millionAs() {
        // The classic long vector. It is the one that catches a broken
        // multi-block loop or a length field that overflows at 2^32 bits.
        let input = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(
            SHA256Digest.hex(of: input)
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    @Test("every length across the padding boundary")
    func paddingBoundary() {
        // 55/56 and 63/64 are where the length field no longer fits in the
        // final block and a second block is appended. Lengths are compared
        // against a distinct digest each, so a padding bug cannot pass by
        // producing a plausible-looking constant.
        var seen = Set<String>()
        for length in 0...130 {
            let digest = SHA256Digest.hex(of: Data(repeating: 0x61, count: length))
            #expect(digest.count == 64)
            #expect(seen.insert(digest).inserted, "collision at length \(length)")
        }
    }

    @Test("a single flipped bit changes the digest")
    func avalanche() {
        let a = SHA256Digest.hex(of: Data([0x00, 0x01, 0x02, 0x03]))
        let b = SHA256Digest.hex(of: Data([0x00, 0x01, 0x02, 0x04]))
        #expect(a != b)
    }

    @Test("the digest is 32 bytes and hex is its lowercase rendering")
    func shape() {
        let digest = SHA256Digest.digest(of: Data("smooooth".utf8))
        #expect(digest.count == 32)
        let hex = SHA256Digest.hex(of: Data("smooooth".utf8))
        #expect(hex == digest.map { String(format: "%02x", $0) }.joined())
        #expect(hex == hex.lowercased())
    }
}
