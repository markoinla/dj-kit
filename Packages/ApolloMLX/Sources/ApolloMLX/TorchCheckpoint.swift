// Minimal reader for PyTorch zip checkpoints (torch.save, _use_new_zipfile_serialization),
// enough to pull the float tensors out of the Apollo release without Python.
//
// The archive is an uncompressed ("stored") zip holding <root>/data.pkl plus one file per
// storage under <root>/data/<key>. data.pkl is a protocol-2 pickle; tensors appear as
// torch._utils._rebuild_tensor_v2(storage, offset, size, stride, ...) with the storage
// given by a persistent id ("storage", FloatStorage, key, location, numel). Everything
// else in the pickle (omegaconf config objects, version info) is parsed into opaque values
// and ignored.
import Foundation

struct TorchTensor {
  var dtype: String  // "FloatStorage", "HalfStorage", ...
  var storageKey: String
  var offset: Int
  var shape: [Int]
  var stride: [Int]
}

/// Reads float32 tensors from a torch checkpoint. Returns name -> (shape, values).
enum TorchCheckpoint {
  static func readStateDict(_ url: URL) throws -> [String: (shape: [Int], values: [Float])] {
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    let zip = try StoredZip(data)
    guard let pklName = zip.names.first(where: { $0.hasSuffix("/data.pkl") || $0 == "data.pkl" })
    else { throw ApolloMLXError.checkpoint("Not a PyTorch zip checkpoint (no data.pkl)") }
    let root = String(pklName.dropLast("data.pkl".count))
    let top = try Unpickler(zip.data(for: pklName)).load()

    // The state dict: either the top object or top["state_dict"].
    var stateDict: PickleDict?
    if case .dict(let d) = top {
      if let sd = d.items.first(where: { $0.0 == .string("state_dict") })?.1, case .dict(let s) = sd {
        stateDict = s
      } else {
        stateDict = d
      }
    }
    guard let stateDict else { throw ApolloMLXError.checkpoint("Checkpoint has no state dict") }

    var out: [String: (shape: [Int], values: [Float])] = [:]
    for (key, value) in stateDict.items {
      guard case .string(let name) = key, case .tensor(let t) = value else { continue }
      guard t.dtype == "FloatStorage" else {
        throw ApolloMLXError.checkpoint("Tensor \(name) has unsupported storage \(t.dtype)")
      }
      let raw = try zip.data(for: root + "data/" + t.storageKey)
      // Little-endian float32, as on arm64; copied so alignment never matters.
      var storage = [Float](repeating: 0, count: raw.count / 4)
      storage.withUnsafeMutableBytes { dst in _ = raw.copyBytes(to: dst) }
      let count = t.shape.reduce(1, *)
      var values = [Float](repeating: 0, count: count)
      // General strided gather (Apollo's tensors are all contiguous, but be safe).
      var index = [Int](repeating: 0, count: t.shape.count)
      for i in 0..<count {
        var src = t.offset
        for d in 0..<t.shape.count { src += index[d] * t.stride[d] }
        guard src < storage.count else {
          throw ApolloMLXError.checkpoint("Tensor \(name) reads past its storage")
        }
        values[i] = storage[src]
        var d = t.shape.count - 1
        while d >= 0 {
          index[d] += 1
          if index[d] < t.shape[d] { break }
          index[d] = 0
          d -= 1
        }
      }
      out[name] = (t.shape, values)
    }
    return out
  }
}

// MARK: - zip (stored entries only)

struct StoredZip {
  private let blob: Data
  private var entries: [String: (offset: Int, size: Int)] = [:]
  var names: [String] { Array(entries.keys) }

  init(_ data: Data) throws {
    blob = data
    func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    func u64(_ o: Int) -> Int { u32(o) | u32(o + 4) << 32 }
    // End of central directory record (scan back over a possible comment).
    var eocd = -1
    var i = data.count - 22
    while i >= max(0, data.count - 22 - 65_535) {
      if u32(i) == 0x0605_4b50 { eocd = i; break }
      i -= 1
    }
    guard eocd >= 0 else { throw ApolloMLXError.checkpoint("Not a zip file") }
    var count = u16(eocd + 10)
    var cdOffset = u32(eocd + 16)
    // zip64 (torch writes it for large archives)
    if cdOffset == 0xFFFF_FFFF || count == 0xFFFF, eocd >= 20, u32(eocd - 20) == 0x0706_4b50 {
      let z64 = u64(eocd - 20 + 8)
      guard u32(z64) == 0x0606_4b50 else { throw ApolloMLXError.checkpoint("Bad zip64 record") }
      count = u64(z64 + 32)
      cdOffset = u64(z64 + 48)
    }
    var p = cdOffset
    for _ in 0..<count {
      guard u32(p) == 0x0201_4b50 else { throw ApolloMLXError.checkpoint("Bad zip directory") }
      let method = u16(p + 10)
      var size = u32(p + 20)
      let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
      var local = u32(p + 42)
      let nameStart = data.startIndex + p + 46
      let name = String(decoding: data[nameStart..<(nameStart + nameLen)], as: UTF8.self)
      // zip64 extra field carries the real sizes/offset when the 32-bit ones are saturated.
      var e = p + 46 + nameLen
      let end = e + extraLen
      while e + 4 <= end {
        let id = u16(e), len = u16(e + 2)
        if id == 0x0001 {
          var f = e + 4
          if u32(p + 24) == 0xFFFF_FFFF { f += 8 }  // uncompressed size
          if size == 0xFFFF_FFFF { size = u64(f); f += 8 }
          if local == 0xFFFF_FFFF { local = u64(f) }
        }
        e += 4 + len
      }
      guard method == 0 else { throw ApolloMLXError.checkpoint("Compressed zip entry \(name)") }
      let lNameLen = u16(local + 26), lExtraLen = u16(local + 28)
      entries[name] = (local + 30 + lNameLen + lExtraLen, size)
      p += 46 + nameLen + extraLen + commentLen
    }
  }

  func data(for name: String) throws -> Data {
    guard let e = entries[name] else { throw ApolloMLXError.checkpoint("Missing \(name) in checkpoint") }
    let s = blob.startIndex + e.offset
    return blob.subdata(in: s..<(s + e.size))
  }
}

// MARK: - pickle

final class PickleDict {
  var items: [(PickleValue, PickleValue)] = []
}
final class PickleList {
  var items: [PickleValue] = []
}

indirect enum PickleValue: Equatable {
  case none, bool(Bool), int(Int), float(Double), string(String), bytes(Data)
  case tuple([PickleValue])
  case list(PickleList)
  case dict(PickleDict)
  case global(String, String)
  case storage(dtype: String, key: String)
  case tensor(TorchTensor)
  case object  // anything we don't model
  case mark

  static func == (a: PickleValue, b: PickleValue) -> Bool {
    switch (a, b) {
    case (.string(let x), .string(let y)): x == y
    case (.int(let x), .int(let y)): x == y
    case (.none, .none): true
    default: false
    }
  }
}

final class Unpickler {
  private let d: Data
  private var pos: Int
  private var stack: [PickleValue] = []
  private var memo: [Int: PickleValue] = [:]

  init(_ data: Data) {
    d = data
    pos = data.startIndex
  }

  private func byte() throws -> UInt8 {
    guard pos < d.endIndex else { throw ApolloMLXError.checkpoint("Truncated pickle") }
    defer { pos += 1 }
    return d[pos]
  }
  private func bytes(_ n: Int) throws -> Data {
    guard pos + n <= d.endIndex else { throw ApolloMLXError.checkpoint("Truncated pickle") }
    defer { pos += n }
    return d.subdata(in: pos..<(pos + n))
  }
  private func uint(_ n: Int) throws -> Int {
    var v = 0
    for i in 0..<n { v |= Int(try byte()) << (8 * i) }
    return v
  }
  private func line() throws -> String {
    var out = Data()
    while true {
      let b = try byte()
      if b == 0x0A { break }
      out.append(b)
    }
    return String(decoding: out, as: UTF8.self)
  }
  private func pop() throws -> PickleValue {
    guard let v = stack.popLast() else { throw ApolloMLXError.checkpoint("Pickle stack underflow") }
    return v
  }
  private func popMark() throws -> [PickleValue] {
    var items: [PickleValue] = []
    while true {
      let v = try pop()
      if case .mark = v { break }
      items.append(v)
    }
    return items.reversed()
  }

  private func reduce(_ callable: PickleValue, _ args: PickleValue) -> PickleValue {
    guard case .global(let module, let name) = callable else { return .object }
    switch (module, name) {
    case ("torch._utils", "_rebuild_tensor_v2"), ("torch._utils", "_rebuild_tensor"):
      guard case .tuple(let a) = args, a.count >= 4, case .storage(let dtype, let key) = a[0],
        case .int(let offset) = a[1], case .tuple(let size) = a[2], case .tuple(let stride) = a[3]
      else { return .object }
      let ints: ([PickleValue]) -> [Int] = { $0.compactMap { if case .int(let i) = $0 { i } else { nil } } }
      return .tensor(
        TorchTensor(dtype: dtype, storageKey: key, offset: offset, shape: ints(size), stride: ints(stride)))
    case ("collections", "OrderedDict"), ("__builtin__", "dict"), ("builtins", "dict"),
      ("collections", "defaultdict"):
      return .dict(PickleDict())
    case ("__builtin__", "list"), ("builtins", "list"):
      return .list(PickleList())
    default:
      return .object
    }
  }

  func load() throws -> PickleValue {
    while true {
      let op = try byte()
      switch op {
      case 0x80: _ = try byte()  // PROTO
      case 0x95: _ = try bytes(8)  // FRAME
      case 0x2E: return try pop()  // STOP
      case 0x28: stack.append(.mark)  // MARK
      case 0x4E: stack.append(.none)
      case 0x88: stack.append(.bool(true))
      case 0x89: stack.append(.bool(false))
      case 0x4A: stack.append(.int(Int(Int32(truncatingIfNeeded: try uint(4)))))  // BININT
      case 0x4B: stack.append(.int(try uint(1)))  // BININT1
      case 0x4D: stack.append(.int(try uint(2)))  // BININT2
      case 0x8A:  // LONG1
        let n = try uint(1)
        let b = try bytes(n)
        var v = 0
        for (i, x) in b.enumerated() where i < 8 { v |= Int(x) << (8 * i) }
        if n > 0, n < 8, b.last! & 0x80 != 0 { v -= 1 << (8 * n) }
        stack.append(.int(v))
      case 0x47:  // BINFLOAT (big-endian double)
        let b = try bytes(8)
        stack.append(.float(Double(bitPattern: b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })))
      case 0x58: stack.append(.string(String(decoding: try bytes(try uint(4)), as: UTF8.self)))
      case 0x8C: stack.append(.string(String(decoding: try bytes(try uint(1)), as: UTF8.self)))
      case 0x8D: stack.append(.string(String(decoding: try bytes(try uint(8)), as: UTF8.self)))
      case 0x55: stack.append(.string(String(decoding: try bytes(try uint(1)), as: UTF8.self)))  // SHORT_BINSTRING
      case 0x54: stack.append(.string(String(decoding: try bytes(try uint(4)), as: UTF8.self)))  // BINSTRING
      case 0x43: stack.append(.bytes(try bytes(try uint(1))))  // SHORT_BINBYTES
      case 0x42: stack.append(.bytes(try bytes(try uint(4))))  // BINBYTES
      case 0x7D: stack.append(.dict(PickleDict()))  // EMPTY_DICT
      case 0x5D: stack.append(.list(PickleList()))  // EMPTY_LIST
      case 0x29: stack.append(.tuple([]))  // EMPTY_TUPLE
      case 0x8F: stack.append(.object)  // EMPTY_SET
      case 0x74: stack.append(.tuple(try popMark()))  // TUPLE
      case 0x85: stack.append(.tuple([try pop()]))
      case 0x86:
        let b = try pop(), a = try pop()
        stack.append(.tuple([a, b]))
      case 0x87:
        let c = try pop(), b = try pop(), a = try pop()
        stack.append(.tuple([a, b, c]))
      case 0x6C:  // LIST
        let l = PickleList()
        l.items = try popMark()
        stack.append(.list(l))
      case 0x64:  // DICT
        let items = try popMark()
        let dict = PickleDict()
        for i in stride(from: 0, to: items.count - 1, by: 2) { dict.items.append((items[i], items[i + 1])) }
        stack.append(.dict(dict))
      case 0x71: let k = try uint(1); memo[k] = stack.last  // BINPUT
      case 0x72: let k = try uint(4); memo[k] = stack.last  // LONG_BINPUT
      case 0x94: memo[memo.count] = stack.last  // MEMOIZE
      case 0x68: let k = try uint(1); stack.append(memo[k] ?? .none)  // BINGET
      case 0x6A: let k = try uint(4); stack.append(memo[k] ?? .none)  // LONG_BINGET
      case 0x63:  // GLOBAL
        let module = try line(), name = try line()
        stack.append(.global(module, name))
      case 0x93:  // STACK_GLOBAL
        let name = try pop(), module = try pop()
        if case .string(let m) = module, case .string(let n) = name {
          stack.append(.global(m, n))
        } else {
          stack.append(.object)
        }
      case 0x52:  // REDUCE
        let args = try pop(), callable = try pop()
        stack.append(reduce(callable, args))
      case 0x81:  // NEWOBJ
        let args = try pop(), cls = try pop()
        stack.append(reduce(cls, args))
      case 0x92:  // NEWOBJ_EX
        _ = try pop()
        let args = try pop(), cls = try pop()
        stack.append(reduce(cls, args))
      case 0x62: _ = try pop()  // BUILD: drop the state, keep the object
      case 0x73:  // SETITEM
        let v = try pop(), k = try pop()
        if case .dict(let dict) = stack.last { dict.items.append((k, v)) }
      case 0x75:  // SETITEMS
        let items = try popMark()
        if case .dict(let dict) = stack.last {
          for i in stride(from: 0, to: items.count - 1, by: 2) { dict.items.append((items[i], items[i + 1])) }
        }
      case 0x61:  // APPEND
        let v = try pop()
        if case .list(let l) = stack.last { l.items.append(v) }
      case 0x65:  // APPENDS
        let items = try popMark()
        if case .list(let l) = stack.last { l.items.append(contentsOf: items) }
      case 0x90: _ = try popMark()  // ADDITEMS
      case 0x91:  // FROZENSET
        _ = try popMark()
        stack.append(.object)
      case 0x51:  // BINPERSID
        let pid = try pop()
        if case .tuple(let t) = pid, t.count >= 3, case .string("storage") = t[0],
          case .global(_, let dtype) = t[1], case .string(let key) = t[2]
        {
          stack.append(.storage(dtype: dtype, key: key))
        } else {
          stack.append(.object)
        }
      case 0x30: _ = try pop()  // POP
      case 0x31: _ = try popMark()  // POP_MARK
      case 0x32: if let t = stack.last { stack.append(t) }  // DUP
      default:
        throw ApolloMLXError.checkpoint(String(format: "Unsupported pickle opcode 0x%02X", op))
      }
    }
  }
}
