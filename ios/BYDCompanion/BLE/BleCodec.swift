import CommonCrypto
import CryptoKit
import Foundation

// Swift port of the BYD dkey BLE codec from BydBleAutoLock
// (https://github.com/PoorGrammerA/BydBleAutoLock, MIT licence, © BLE AutoLock contributors).
// Verified there only on a Korean ATTO 3; other regions and models are unverified.

enum BleCodec {
    static let serviceUUID = "42594420-4155-544F-E0A9-E50E24DCCA9E"
    static let writeUUID = "42590002-4155-544F-E0A9-E50E24DCCA9E"
    static let notifyUUID = "42590003-4155-544F-E0A9-E50E24DCCA9E"

    static let responseControl: UInt8 = 0x24
    static let responseRandomExchange: UInt8 = 0x2A
    static let responseAuthentication: UInt8 = 0x2B
    static let controlCommandType: UInt8 = 0xE5

    /// Local BLE control codes confirmed on the reference car.
    enum Control: UInt8 {
        case unlock = 0x05
        case trunkOpen = 0x06
        case lock = 0x07
        case lightsAndHorn = 0x0A
        case lightsOnly = 0x16
    }

    static func wakeUpFrame() -> Data {
        Data([0x5A, 0xA5, 0xD5, 0x00, 0x00, 0xF5, 0xFA])
    }

    static func randomExchangeFrame(keyNumber: UInt8, appRandom: [UInt8]) -> Data {
        precondition(appRandom.count == 8)
        var frame = [UInt8](repeating: 0, count: 20)
        frame[0] = 0x5A
        frame[1] = 0xA5
        frame[2] = 0xD6
        frame.replaceSubrange(3..<11, with: appRandom)
        frame[11] = keyNumber
        for i in 12...16 { frame[i] = 0xFF }
        frame[17] = crc8(frame, from: 0, throughInclusive: 16)
        frame[18] = 0xF5
        frame[19] = 0xFA
        return Data(frame)
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }

    /// CRC-8 (poly 0x07) over data[from...throughInclusive].
    static func crc8(_ data: [UInt8], from start: Int, throughInclusive end: Int) -> UInt8 {
        guard start >= 0, end >= start, end < data.count else { return 0 }
        var crc: UInt8 = 0
        for i in start...end {
            crc ^= data[i]
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex.trimmingCharacters(in: .whitespaces))
        guard !chars.isEmpty, chars.count % 2 == 0, chars.count <= 64 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
}

/// Keys for one authenticated BLE session. Created after the random exchange.
struct BleSession {
    let iv: [UInt8]
    let aesKey: [UInt8]
    let cmacKey: [UInt8]
    private(set) var sequence: UInt16 = 0

    /// Session material = SHA-256(dkey || vehicleRandom || appRandom), split into AES and CMAC keys.
    init?(dkeyHex: String, vehicleRandom: [UInt8], appRandom: [UInt8]) {
        guard let dkey = BleCodec.hexBytes(dkeyHex), vehicleRandom.count == 8, appRandom.count == 8 else { return nil }
        iv = vehicleRandom + appRandom
        let digest = Array(SHA256.hash(data: dkey + iv))
        aesKey = Array(digest[0..<16])
        cmacKey = Array(digest[16..<32])
    }

    func authenticationFrame() -> Data {
        var plain = [UInt8](repeating: 0xFF, count: 16)
        plain[0] = 0xD8
        plain.replaceSubrange(12..<16, with: BleCrypto.aesCmac(key: cmacKey, message: Array(plain[0..<12])).prefix(4))
        return wrap(plain)
    }

    mutating func controlFrame(_ control: BleCodec.Control) -> Data {
        sequence = sequence >= 0xFFFF ? 1 : sequence + 1
        var plain = [UInt8](repeating: 0xFF, count: 16)
        plain[0] = BleCodec.controlCommandType
        plain[1] = control.rawValue
        plain[2] = UInt8(sequence >> 8)
        plain[3] = UInt8(sequence & 0xFF)
        plain.replaceSubrange(12..<16, with: BleCrypto.aesCmac(key: cmacKey, message: Array(plain[0..<12])).prefix(4))
        return wrap(plain)
    }

    private func wrap(_ plain: [UInt8]) -> Data {
        let encrypted = BleCrypto.aesCbcEncrypt(plain, key: aesKey, iv: iv)
        return Data([0x5B, 0xB5] + encrypted + [0xF5, 0xFA])
    }
}

enum BleCrypto {
    static func aesCbcEncrypt(_ input: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        crypt(input, key: key, iv: iv, options: 0)
    }

    static func aesEcbEncrypt(_ input: [UInt8], key: [UInt8]) -> [UInt8] {
        crypt(input, key: key, iv: nil, options: CCOptions(kCCOptionECBMode))
    }

    private static func crypt(_ input: [UInt8], key: [UInt8], iv: [UInt8]?, options: CCOptions) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
            key, key.count, iv, input, input.count, &out, out.count, &moved
        )
        precondition(status == kCCSuccess && moved == input.count, "AES failed: \(status)")
        return out
    }

    /// RFC 4493 AES-CMAC.
    static func aesCmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        func shiftLeft(_ b: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 16)
            var carry: UInt8 = 0
            for i in stride(from: 15, through: 0, by: -1) {
                out[i] = (b[i] << 1) | carry
                carry = b[i] >> 7
            }
            return out
        }
        let l = aesEcbEncrypt([UInt8](repeating: 0, count: 16), key: key)
        var k1 = shiftLeft(l)
        if l[0] & 0x80 != 0 { k1[15] ^= 0x87 }
        var k2 = shiftLeft(k1)
        if k1[0] & 0x80 != 0 { k2[15] ^= 0x87 }

        let blocks = max(1, (message.count + 15) / 16)
        let complete = !message.isEmpty && message.count % 16 == 0
        let lastStart = (blocks - 1) * 16
        var last = [UInt8](repeating: 0, count: 16)
        if complete {
            last = zip(message[lastStart..<lastStart + 16], k1).map { $0 ^ $1 }
        } else {
            let remaining = message.count - lastStart
            last.replaceSubrange(0..<remaining, with: message[lastStart..<message.count])
            last[remaining] = 0x80
            last = zip(last, k2).map { $0 ^ $1 }
        }

        var state = [UInt8](repeating: 0, count: 16)
        for block in 0..<(blocks - 1) {
            let chunk = zip(message[block * 16..<block * 16 + 16], state).map { $0 ^ $1 }
            state = aesEcbEncrypt(chunk, key: key)
        }
        return aesEcbEncrypt(zip(last, state).map { $0 ^ $1 }, key: key)
    }
}

/// Reassembles 20-byte notification frames (A5 5A … CRC F5 FA) into 16-byte payloads.
struct BleFrameAssembler {
    private var buffer: [UInt8] = []

    mutating func reset() { buffer.removeAll() }

    mutating func append(_ chunk: Data) -> [[UInt8]] {
        buffer.append(contentsOf: chunk)
        var payloads: [[UInt8]] = []
        while buffer.count >= 20 {
            let header = (buffer[0], buffer[1])
            guard header == (0xA5, 0x5A) || header == (0xB5, 0x5B) else {
                buffer.removeFirst()
                continue
            }
            let frame = Array(buffer[0..<20])
            guard frame[18] == 0xF5, frame[19] == 0xFA,
                  BleCodec.crc8(frame, from: 0, throughInclusive: 16) == frame[17] else {
                buffer.removeFirst()
                continue
            }
            payloads.append(Array(frame[2..<18]))
            buffer.removeFirst(20)
        }
        if buffer.count > 4000 { buffer.removeAll() }
        return payloads
    }
}
